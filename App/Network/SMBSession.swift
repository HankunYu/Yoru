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

    /// Runs `body` with the connection, opening it first if needed. After a failure the
    /// connection is dropped, so the next call starts from a fresh one.
    func run<T: Sendable>(_ body: @escaping @Sendable (SMBConnection) throws(SMBError) -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let credentials = ServerStore.credentials(for: serverID) else {
                        throw SMBError(code: ENOENT)
                    }
                    let connection = try connection ?? SMBConnection(credentials)
                    self.connection = connection
                    continuation.resume(returning: try body(connection))
                } catch {
                    connection = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
