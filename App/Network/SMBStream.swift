import Foundation

/// A remote file read through its own SMB connection, feeding mpv's custom stream protocol.
/// mpv calls in from its own threads; `SMBConnection` serializes them.
final class SMBStream: MPVStreamSource {
    private let connection: SMBConnection
    private let file: SMBConnection.File

    init(credentials: SMBCredentials, path: [String]) throws(SMBError) {
        connection = try SMBConnection(credentials)
        file = try connection.openFile(path)
    }

    var size: Int64? {
        connection.size(of: file)
    }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        connection.read(file, into: buffer, count: count)
    }

    func seek(to offset: Int64) -> Bool {
        connection.seek(file, to: offset)
    }

    func close() {
        connection.close(file)
    }
}
