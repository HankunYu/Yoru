import Foundation
import os

/// A file on a WebDAV server read with HTTP range requests, feeding mpv's custom stream
/// protocol. Each read is one request on a kept-alive connection, so a seek costs nothing
/// by itself; `BlockCachedStream` in front keeps the requests few and large.
///
/// mpv calls `read`, `seek` and `close` one at a time from its own threads; `cancel` may
/// arrive from another thread while a read is waiting.
final class WebDAVStream: NSObject, MPVStreamSource, URLSessionDataDelegate, @unchecked Sendable {
    /// The request in flight and what it has produced so far.
    private struct Transfer {
        var task: URLSessionDataTask?
        var destination: UnsafeMutableRawPointer?
        var capacity = 0
        var filled = 0
        var status = 0
        /// The file's size as the server reported it in `Content-Range`.
        var total: Int64?
        var isCancelled = false
    }

    private let url: URL
    private let authorization: String?
    private var session: URLSession!
    private var position: Int64 = 0
    private var total: Int64?
    private let transfer = OSAllocatedUnfairLock(uncheckedState: Transfer())
    private let finished = DispatchSemaphore(value: 0)

    init(client: WebDAVClient, path: [String]) throws(WebDAVError) {
        guard let url = client.url(for: path) else { throw WebDAVError(reason: .invalidAddress) }
        self.url = url
        authorization = client.authorization
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        // One byte, to learn the size and that the server honors ranges at all.
        var byte: UInt8 = 0
        let (read, status, total) = fetch(from: 0, count: 1, into: &byte)
        switch status {
        case 206 where read >= 0:
            self.total = total
        case 416:
            // Nothing to give even the first byte of: an empty file.
            self.total = 0
        default:
            session.invalidateAndCancel()
            switch status {
            case 401, 403: throw WebDAVError(reason: .unauthorized)
            case 404: throw WebDAVError(reason: .notFound)
            // 200 is a server that ignores Range and would send the whole file each time.
            default: throw WebDAVError(reason: .status(status))
            }
        }
    }

    var size: Int64? { total }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        var count = count
        if let total {
            count = Int(min(Int64(count), total - position))
        }
        guard count > 0 else { return 0 }
        let (read, status, _) = fetch(from: position, count: count, into: buffer)
        // Past the end, for a file whose size the server never told.
        if status == 416 { return 0 }
        if read > 0 {
            position += Int64(read)
        }
        return read
    }

    func seek(to offset: Int64) -> Bool {
        guard offset >= 0 else { return false }
        position = offset
        return true
    }

    func cancel() {
        transfer.withLock { transfer in
            transfer.isCancelled = true
            transfer.task?.cancel()
        }
    }

    func close() {
        session.invalidateAndCancel()
    }

    /// Requests `count` bytes at `offset` and waits for them. Returns the bytes received,
    /// or -1 if none came, with the response's status (0 if there was no response).
    private func fetch(from offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer) -> (read: Int, status: Int, total: Int64?) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let task = session.dataTask(with: request)
        // The pointer stays with this thread's caller; the lock only hands it to the
        // delegate callbacks, which finish before `finished` is signaled.
        let started = transfer.withLockUnchecked { transfer in
            guard !transfer.isCancelled else { return false }
            transfer.task = task
            transfer.destination = buffer
            transfer.capacity = count
            transfer.filled = 0
            transfer.status = 0
            transfer.total = nil
            return true
        }
        guard started else { return (-1, 0, nil) }
        task.resume()
        finished.wait()
        return transfer.withLock { transfer in
            transfer.task = nil
            transfer.destination = nil
            // A transfer cut short still delivered its first part; mpv asks for the rest.
            let read = transfer.status == 206 && transfer.filled > 0 ? transfer.filled : -1
            return (read, transfer.status, transfer.total)
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        transfer.withLock { transfer in
            transfer.status = status
            transfer.total = http?.value(forHTTPHeaderField: "Content-Range").flatMap(Self.total(fromContentRange:))
        }
        // Anything but the requested range is not read: a plain 200 would be the whole file.
        completionHandler(status == 206 ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer.withLock { transfer in
            guard let destination = transfer.destination else { return }
            let length = min(data.count, transfer.capacity - transfer.filled)
            guard length > 0 else { return }
            data.copyBytes(to: (destination + transfer.filled).assumingMemoryBound(to: UInt8.self), count: length)
            transfer.filled += length
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finished.signal()
    }

    /// The total from a `Content-Range: bytes 0-0/1234` header; nil if the server gave `*`.
    static func total(fromContentRange value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
