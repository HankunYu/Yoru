import Foundation
import Observation
import Security
import os

/// A saved server. The password is kept in the Keychain, never here.
struct MediaServer: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case smb
        case webDAV = "webdav"

        /// The scheme of the URLs that address this kind's items; see `MediaSource`.
        var scheme: String {
            switch self {
            case .smb: "yoru-smb"
            case .webDAV: "yoru-dav"
            }
        }
    }

    let id: UUID
    var kind: Kind
    /// Shown in the browser; defaults to the address.
    var name: String
    /// SMB: the host name or IP address. WebDAV: the base URL, e.g. `https://nas:5006/dav`.
    var address: String
    /// Empty for guest access.
    var username: String

    // `address` keeps the key it had when only SMB existed, and `kind` defaults to SMB, so
    // servers saved back then still load.
    private enum CodingKeys: String, CodingKey {
        case id, kind, name, username
        case address = "host"
    }

    init(id: UUID, kind: Kind, name: String, address: String, username: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.address = address
        self.username = username
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .smb
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        username = try container.decode(String.self, forKey: .username)
    }

    /// The URL of the server's top level in the browser.
    var rootURL: URL {
        URL(string: "\(kind.scheme)://\(id.uuidString.lowercased())/")!
    }

    /// Splits a browser URL of either kind into the server and the path components below it.
    static func parse(_ url: URL) -> (serverID: UUID, path: [String])? {
        guard let scheme = url.scheme, Kind.allCases.contains(where: { $0.scheme == scheme }),
              let host = url.host(), let serverID = UUID(uuidString: host) else { return nil }
        return (serverID, url.pathComponents.filter { $0 != "/" })
    }

    /// Reduces what was typed as an SMB address to the bare host: people paste
    /// `smb://nas/share` or a Windows-style `\\nas\share` as readily as `nas`.
    static func host(fromAddress address: String) -> String {
        var host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = host.range(of: "://") {
            host = String(host[scheme.upperBound...])
        }
        host = String(host.drop { $0 == "/" || $0 == "\\" })
        if let end = host.firstIndex(where: { $0 == "/" || $0 == "\\" }) {
            host = String(host[..<end])
        }
        if let login = host.lastIndex(of: "@") {
            host = String(host[host.index(after: login)...])
        }
        return host
    }

    /// Completes what was typed as a WebDAV address into a base URL without a trailing
    /// slash; a bare host gets `https`.
    static func baseURL(fromAddress address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}

/// The saved servers, persisted as JSON in Application Support.
@MainActor
@Observable
final class ServerStore {
    static let shared = ServerStore()

    private(set) var servers: [MediaServer] = []

    private nonisolated static let fileURL = URL.applicationSupportDirectory.appending(path: "servers.json")
    // Mirror of `servers` for readers on other threads (mpv opening a stream).
    private nonisolated static let snapshot = OSAllocatedUnfairLock<[UUID: MediaServer]>(initialState: [:])

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let servers = try? JSONDecoder().decode([MediaServer].self, from: data) {
            self.servers = servers
        }
        publish()
    }

    func add(_ server: MediaServer, password: String) {
        Keychain.setPassword(password, for: server.id)
        servers.append(server)
        save()
    }

    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        Keychain.setPassword(nil, for: id)
        SMBSession.invalidate(id)
        save()
    }

    func server(_ id: UUID) -> MediaServer? {
        servers.first { $0.id == id }
    }

    /// Replaces a saved server; a nil password keeps the stored one.
    func update(_ server: MediaServer, password: String?) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        if let password {
            Keychain.setPassword(password, for: server.id)
        }
        // A connection opened with the old address or login must not be reused.
        SMBSession.invalidate(server.id)
        save()
    }

    /// A saved server and its password. Callable from any thread.
    nonisolated static func login(for id: UUID) -> (server: MediaServer, password: String)? {
        guard let server = snapshot.withLock({ $0[id] }) else { return nil }
        return (server, Keychain.password(for: id) ?? "")
    }

    private func save() {
        publish()
        do {
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(servers).write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.app.error("Saving servers failed: \(error, privacy: .public)")
        }
    }

    private func publish() {
        let servers = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        Self.snapshot.withLock { $0 = servers }
    }
}

/// Server passwords, one generic-password item per server.
private enum Keychain {
    private static let service = "com.hankunyu.Yoru.smb"

    static func password(for id: UUID) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the password, or removes the item when `password` is nil.
    static func setPassword(_ password: String?, for id: UUID) {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard let password else { return }
        var item = baseQuery(for: id)
        item[kSecValueData] = Data(password.utf8)
        // Readable while the phone is locked, so background playback can reconnect.
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            Log.app.error("Storing a server password failed: \(status)")
        }
    }

    private static func baseQuery(for id: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
        ]
    }
}
