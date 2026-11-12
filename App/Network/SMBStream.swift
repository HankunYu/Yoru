import Foundation

/// A remote file read through its own SMB connection, feeding mpv's custom stream protocol.
final class SMBStream: MPVStreamSource {
    private let connection: SMBConnection
    private let file: SMBConnection.File
    // mpv reads from one thread at a time, but not always the same one.
    private let lock = NSLock()

    init(credentials: SMBCredentials, path: [String]) throws(SMBError) {
        connection = try SMBConnection(credentials)
        file = try connection.openFile(path)
    }

    var size: Int64? {
        lock.withLock { connection.size(of: file) }
    }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        lock.withLock { connection.read(file, into: buffer, count: count) }
    }

    func seek(to offset: Int64) -> Bool {
        lock.withLock { connection.seek(file, to: offset) }
    }

    func close() {
        lock.withLock { connection.close(file) }
    }
}
