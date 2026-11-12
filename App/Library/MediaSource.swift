import Foundation

/// A place media is browsed and played from. Every item is addressed by a URL whose scheme
/// names its source: `file` for the app's Documents, `yoru-smb` for a saved SMB server.
protocol MediaSource: Sendable {
    /// The entries of `directory`, in no particular order.
    func contents(of directory: URL) async throws -> [BrowserItem]
    var supportsDeletion: Bool { get }
    func delete(_ item: BrowserItem) throws
}

enum MediaSources {
    static func source(for url: URL) -> any MediaSource {
        url.scheme == SMBSource.scheme ? SMBSource() : LocalSource()
    }

    /// The URL schemes the app serves to mpv itself.
    static let streamProtocols: [String: MPVStreamOpener] = [SMBSource.scheme: SMBSource.openStream]
}

// MARK: - Local files

struct LocalSource: MediaSource {
    let supportsDeletion = true

    func contents(of directory: URL) async throws -> [BrowserItem] {
        Self.items(in: directory)
    }

    func delete(_ item: BrowserItem) throws {
        try FileManager.default.removeItem(at: item.url)
    }

    /// The visible entries of `directory`, minus the mpv config directory, which is managed
    /// through Settings and the Files app rather than played from.
    static func items(in directory: URL) -> [BrowserItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.standardizedFileURL != ConfigDirectory.url.standardizedFileURL }
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return BrowserItem(
                    url: url,
                    kind: values?.isDirectory == true ? .folder : .file,
                    name: url.lastPathComponent,
                    size: values?.fileSize,
                    modified: values?.contentModificationDate
                )
            }
    }
}

// MARK: - SMB

/// Saved SMB servers, addressed as `yoru-smb://<server id>/<share>/<path>`.
///
/// The URL carries the server's identifier rather than its address and login, so nothing
/// secret ends up in mpv's logs or resume files; credentials are looked up when connecting.
struct SMBSource: MediaSource {
    static let scheme = "yoru-smb"

    let supportsDeletion = false

    static func rootURL(for server: SMBServer) -> URL {
        URL(string: "\(scheme)://\(server.id.uuidString.lowercased())/")!
    }

    /// Splits a source URL into the server and the path components below it.
    static func parse(_ url: URL) -> (serverID: UUID, path: [String])? {
        guard url.scheme == scheme, let host = url.host(), let serverID = UUID(uuidString: host) else { return nil }
        return (serverID, url.pathComponents.filter { $0 != "/" })
    }

    func contents(of directory: URL) async throws -> [BrowserItem] {
        guard let (serverID, path) = Self.parse(directory) else { throw SMBError(code: ENOENT) }
        let entries = try await SMBSession.session(for: serverID).run { connection throws(SMBError) in
            path.isEmpty ? try connection.shares() : try connection.contents(of: path)
        }
        return entries.map { entry in
            BrowserItem(
                url: directory.appending(component: entry.name, directoryHint: entry.isDirectory ? .isDirectory : .notDirectory),
                kind: entry.isDirectory ? .folder : .file,
                name: entry.name,
                size: entry.size,
                modified: entry.modified
            )
        }
    }

    func delete(_ item: BrowserItem) throws {
        throw SMBError(code: ENOTSUP)
    }

    /// Opens a file for mpv. Runs on an mpv thread.
    static let openStream: MPVStreamOpener = { location in
        guard let url = URL(string: location), let (serverID, path) = parse(url),
              let credentials = ServerStore.credentials(for: serverID) else { return nil }
        do {
            return try SMBStream(credentials: credentials, path: path)
        } catch {
            Log.app.error("Opening an SMB stream failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
