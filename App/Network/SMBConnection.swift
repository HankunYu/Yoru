import CSMBClient
import Foundation

/// What is needed to reach one SMB server.
struct SMBCredentials: Sendable {
    let host: String
    /// Empty for guest access.
    let username: String
    let password: String
}

struct SMBError: Error, LocalizedError {
    /// The `errno` libsmbclient reported.
    let code: Int32

    var errorDescription: String? {
        switch code {
        case EACCES, EPERM:
            String(localized: "Wrong username or password.")
        case ENOENT, ENOTDIR:
            String(localized: "The folder could not be opened.")
        case ETIMEDOUT, ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENODEV, ECONNRESET, ECONNABORTED:
            String(localized: "The server could not be reached.")
        default:
            String(cString: strerror(code))
        }
    }
}

/// One entry of a share listing or a remote directory.
struct SMBEntry: Sendable {
    let name: String
    let isDirectory: Bool
    let size: Int?
    let modified: Date?
}

/// One libsmbclient context: a connection to a server with its own authentication state.
///
/// Not thread-safe. Each instance must be used from one thread at a time; separate
/// instances are independent.
final class SMBConnection {
    typealias File = OpaquePointer

    private let context: UnsafeMutablePointer<SMBCCTX>
    private let host: String
    private let credentialBox: Unmanaged<CredentialBox>

    private final class CredentialBox {
        let username: String
        let password: String
        init(_ credentials: SMBCredentials) {
            username = credentials.username.isEmpty ? "guest" : credentials.username
            password = credentials.password
        }
    }

    // Context creation touches Samba's process-wide configuration.
    private static let setupLock = NSLock()
    private static let directoryAttribute: UInt16 = 0x10

    init(_ credentials: SMBCredentials) throws(SMBError) {
        Self.setupLock.lock()
        defer { Self.setupLock.unlock() }
        guard let context = smbc_new_context() else { throw SMBError(code: ENOMEM) }
        let box = Unmanaged.passRetained(CredentialBox(credentials))
        smbc_setOptionUserData(context, box.toOpaque())
        smbc_setFunctionAuthDataWithContext(context) { context, _, _, _, _, username, usernameLength, password, passwordLength in
            guard let data = smbc_getOptionUserData(context) else { return }
            let box = Unmanaged<CredentialBox>.fromOpaque(data).takeUnretainedValue()
            strlcpy(username, box.username, Int(usernameLength))
            strlcpy(password, box.password, Int(passwordLength))
        }
        smbc_setTimeout(context, 10_000)
        smbc_setOptionProtocols(context, "SMB2", "SMB3")
        #if DEBUG
        smbc_setDebug(context, 1)
        smbc_setOptionDebugToStderr(context, 1)
        #endif
        guard smbc_init_context(context) != nil else {
            let code = errno
            smbc_free_context(context, 1)
            box.release()
            throw SMBError(code: code)
        }
        self.context = context
        host = credentials.host
        credentialBox = box
    }

    deinit {
        smbc_free_context(context, 1)
        credentialBox.release()
    }

    // MARK: - Listing

    /// The server's disk shares, without the hidden administrative ones (`IPC$`, `C$`, ...).
    func shares() throws(SMBError) -> [SMBEntry] {
        let directory = try openDirectory([])
        defer { closeDirectory(directory) }
        guard let read = smbc_getFunctionReaddir(context) else { throw SMBError(code: ENOSYS) }
        let nameOffset = MemoryLayout<smbc_dirent>.offset(of: \.name)!
        var shares: [SMBEntry] = []
        while let entry = read(context, directory) {
            guard entry.pointee.smbc_type == UInt32(SMBC_FILE_SHARE) else { continue }
            let name = String(cString: UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self))
            if !name.hasSuffix("$") {
                shares.append(SMBEntry(name: name, isDirectory: true, size: nil, modified: nil))
            }
        }
        return shares
    }

    /// The entries of a directory, given as path components starting with the share name.
    func contents(of path: [String]) throws(SMBError) -> [SMBEntry] {
        let directory = try openDirectory(path)
        defer { closeDirectory(directory) }
        guard let read = smbc_getFunctionReaddirPlus(context) else { throw SMBError(code: ENOSYS) }
        var entries: [SMBEntry] = []
        errno = 0
        while let info = read(context, directory)?.pointee {
            let name = String(cString: info.name)
            if name.hasPrefix(".") { continue }
            let isDirectory = info.attrs & Self.directoryAttribute != 0
            entries.append(SMBEntry(
                name: name,
                isDirectory: isDirectory,
                size: isDirectory ? nil : Int(info.size),
                modified: Date(timeIntervalSince1970: TimeInterval(info.mtime_ts.tv_sec))
            ))
        }
        if errno != 0, entries.isEmpty { throw SMBError(code: errno) }
        return entries
    }

    // MARK: - Files

    func openFile(_ path: [String]) throws(SMBError) -> File {
        guard let open = smbc_getFunctionOpen(context) else { throw SMBError(code: ENOSYS) }
        guard let file = open(context, url(for: path), O_RDONLY, 0) else { throw SMBError(code: errno) }
        return file
    }

    /// Returns the number of bytes read, 0 at the end of the file, or a negative value on error.
    func read(_ file: File, into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        smbc_getFunctionRead(context)?(context, file, buffer, count) ?? -1
    }

    func seek(_ file: File, to offset: Int64) -> Bool {
        (smbc_getFunctionLseek(context)?(context, file, offset, SEEK_SET) ?? -1) >= 0
    }

    func size(of file: File) -> Int64? {
        var status = stat()
        guard let fstat = smbc_getFunctionFstat(context), fstat(context, file, &status) >= 0 else { return nil }
        return Int64(status.st_size)
    }

    func close(_ file: File) {
        _ = smbc_getFunctionClose(context)?(context, file)
    }

    // MARK: - Private

    private func openDirectory(_ path: [String]) throws(SMBError) -> OpaquePointer {
        guard let open = smbc_getFunctionOpendir(context) else { throw SMBError(code: ENOSYS) }
        guard let directory = open(context, url(for: path)) else { throw SMBError(code: errno) }
        return directory
    }

    private func closeDirectory(_ directory: OpaquePointer) {
        _ = smbc_getFunctionClosedir(context)?(context, directory)
    }

    /// libsmbclient addresses everything by `smb://host/share/path`, percent-decoding each part.
    private func url(for path: [String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        return "smb://\(host)/" + encoded.joined(separator: "/")
    }
}
