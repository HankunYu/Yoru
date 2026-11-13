import Foundation
import Libmpv
import os

/// A byte stream the app serves to mpv for a custom URL scheme (libmpv's `stream_cb`).
/// mpv calls it from its own threads, one call at a time.
protocol MPVStreamSource: AnyObject {
    /// The total size in bytes, if known.
    var size: Int64? { get }
    /// Reads up to `count` bytes. Returns the number read, 0 at the end, negative on error.
    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int
    func seek(to offset: Int64) -> Bool
    /// Makes a read that is waiting return soon, and later ones fail. The one call that
    /// may arrive from another thread while a read is running.
    func cancel()
    func close()
}

extension MPVStreamSource {
    func cancel() {}
}

/// Counts the bytes mpv has read through app-served streams, so the interface can show a
/// transfer rate from the moment a file starts opening. mpv's own `cache-speed` only
/// starts once its cache is running, which is after the slowest part.
enum MPVStreamMeter {
    private static let total = OSAllocatedUnfairLock<Int64>(initialState: 0)

    static var bytesRead: Int64 {
        total.withLock { $0 }
    }

    fileprivate static func add(_ count: Int) {
        guard count > 0 else { return }
        total.withLock { $0 += Int64(count) }
    }
}

/// Opens the stream for a URL of a registered scheme; nil if it cannot be opened.
typealias MPVStreamOpener = @Sendable (_ url: String) -> (any MPVStreamSource)?

/// Keeps an opener, and the streams it opened, alive for as long as mpv may call them.
final class MPVStreamProtocol: Sendable {
    private let opener: MPVStreamOpener
    /// Every stream opened so far. mpv may still call a stream's `cancel_fn` while and
    /// after it closes it, so what its cookie points at has to outlive the stream; it is
    /// kept here until the registration goes, which is after the handle.
    private let boxes = OSAllocatedUnfairLock<[SourceBox]>(initialState: [])

    init(opener: @escaping MPVStreamOpener) {
        self.opener = opener
    }

    /// Registers `scheme` with `handle`. Streams are served through a `BlockCachedStream`.
    /// The returned object must outlive the handle.
    static func register(_ scheme: String, opener: @escaping MPVStreamOpener, on handle: OpaquePointer) -> MPVStreamProtocol {
        let registration = MPVStreamProtocol(opener: opener)
        mpv_stream_cb_add_ro(handle, scheme, Unmanaged.passUnretained(registration).toOpaque()) { userData, url, info in
            guard let userData, let url, let info else { return MPV_ERROR_LOADING_FAILED.rawValue }
            let registration = Unmanaged<MPVStreamProtocol>.fromOpaque(userData).takeUnretainedValue()
            guard let source = registration.opener(String(cString: url)) else {
                return MPV_ERROR_LOADING_FAILED.rawValue
            }
            let box = SourceBox(BlockCachedStream(source))
            registration.boxes.withLock { $0.append(box) }
            info.pointee.cookie = Unmanaged.passUnretained(box).toOpaque()
            info.pointee.read_fn = { cookie, buffer, count in
                guard let cookie, let buffer, let source = SourceBox.source(cookie) else { return -1 }
                let read = source.read(into: buffer, count: Int(count))
                MPVStreamMeter.add(read)
                return Int64(read)
            }
            info.pointee.seek_fn = { cookie, offset in
                guard let cookie, let source = SourceBox.source(cookie) else { return Int64(MPV_ERROR_GENERIC.rawValue) }
                return source.seek(to: offset) ? offset : Int64(MPV_ERROR_GENERIC.rawValue)
            }
            info.pointee.size_fn = { cookie in
                guard let cookie, let source = SourceBox.source(cookie) else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
                return source.size ?? Int64(MPV_ERROR_UNSUPPORTED.rawValue)
            }
            info.pointee.cancel_fn = { cookie in
                guard let cookie else { return }
                SourceBox.source(cookie)?.cancel()
            }
            info.pointee.close_fn = { cookie in
                guard let cookie else { return }
                Unmanaged<SourceBox>.fromOpaque(cookie).takeUnretainedValue().take()?.close()
            }
            return 0
        }
        return registration
    }

    /// What a stream's cookie points at. It lets go of the stream when mpv closes it, but
    /// stays valid itself: a late `cancel_fn` finds nothing instead of freed memory.
    private final class SourceBox: Sendable {
        private let held: OSAllocatedUnfairLock<(any MPVStreamSource)?>

        init(_ source: any MPVStreamSource) {
            held = OSAllocatedUnfairLock(uncheckedState: source)
        }

        /// The stream behind `cookie`, or nil once it is closed. The caller's reference
        /// keeps it alive for the call, outside the lock.
        static func source(_ cookie: UnsafeMutableRawPointer) -> (any MPVStreamSource)? {
            Unmanaged<SourceBox>.fromOpaque(cookie).takeUnretainedValue().held.withLockUnchecked { $0 }
        }

        /// Hands the stream over for closing and forgets it.
        func take() -> (any MPVStreamSource)? {
            held.withLockUnchecked { source in
                defer { source = nil }
                return source
            }
        }
    }
}
