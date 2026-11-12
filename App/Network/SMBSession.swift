import Foundation
import os

/// The shared browsing connection to one saved server: a lazily opened `SMBConnection`
/// confined to its own serial queue.
final class SMBSession: Sendable {
    private let serverID: UUID
    private let queue: DispatchQueue
    // Only touched on `queue`.
    private nonisolated(unsafe) var connection: SMBConnection?

    private static let sessions = OSAllocatedUnfairLock<[UUID: SMBSession]>(initialState: [:])

    private init(serverID: UUID) {
        self.serverID = serverID
        queue = DispatchQueue(label: "com.hankunyu.Yoru.smb.\(serverID.uuidString)", qos: .userInitiated)
    }

    static func session(for serverID: UUID) -> SMBSession {
        sessions.withLock { sessions in
            if let session = sessions[serverID] { return session }
            let session = SMBSession(serverID: serverID)
            sessions[serverID] = session
            return session
        }
    }

    /// Drops the session of a removed server.
    static func invalidate(_ serverID: UUID) {
        _ = sessions.withLock { $0.removeValue(forKey: serverID) }
    }

    /// Runs `body` with the connection, opening it first if needed.
    ///
    /// A connection kept from an earlier call may have gone stale (servers drop idle
    /// sessions, and the phone changes networks), so a failure on a reused connection is
    /// retried once on a fresh one. A failure on a fresh connection is reported.
    func run<T: Sendable>(_ body: @escaping @Sendable (SMBConnection) throws(SMBError) -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let credentials = ServerStore.credentials(for: serverID) else {
                        throw SMBError(code: ENOENT)
                    }
                    if let reused = connection {
                        if let result = try? body(reused) {
                            continuation.resume(returning: result)
                            return
                        }
                        connection = nil
                    }
                    let fresh = try SMBConnection(credentials)
                    let result = try body(fresh)
                    connection = fresh
                    continuation.resume(returning: result)
                } catch {
                    #if DEBUG
                    // os.Logger doesn't reach `devicectl --console`.
                    print("[smb] request failed: \(error)")
                    #endif
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
