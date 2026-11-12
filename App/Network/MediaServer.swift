import Foundation
import Observation
import Security
import os

/// A saved SMB server. The password is kept in the Keychain, never here.
struct SMBServer: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// Shown in the browser; defaults to the host.
    var name: String
    /// Host name or IP address.
    var host: String
    /// Empty for guest access.
    var username: String

    /// Reduces what was typed as an address to the bare host: people paste `smb://nas/share`
    /// or a Windows-style `\\nas\share` as readily as `nas`.
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
}

/// The saved servers, persisted as JSON in Application Support.
@MainActor
@Observable
final class ServerStore {
    static let shared = ServerStore()

    private(set) var servers: [SMBServer] = []

    private nonisolated static let fileURL = URL.applicationSupportDirectory.appending(path: "servers.json")
    // Mirror of `servers` for readers on other threads (mpv opening a stream).
    private nonisolated static let snapshot = OSAllocatedUnfairLock<[UUID: SMBServer]>(initialState: [:])

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let servers = try? JSONDecoder().decode([SMBServer].self, from: data) {
            self.servers = servers
        }
        publish()
    }

    func add(_ server: SMBServer, password: String) {
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

    func server(_ id: UUID) -> SMBServer? {
        servers.first { $0.id == id }
    }

    /// Everything needed to connect to a saved server. Callable from any thread.
    nonisolated static func credentials(for id: UUID) -> SMBCredentials? {
        guard let server = snapshot.withLock({ $0[id] }) else { return nil }
        return SMBCredentials(host: server.host, username: server.username, password: Keychain.password(for: id) ?? "")
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
