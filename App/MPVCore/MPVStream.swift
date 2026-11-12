import Foundation
import Libmpv

/// A byte stream the app serves to mpv for a custom URL scheme (libmpv's `stream_cb`).
/// mpv calls it from its own threads, one call at a time.
protocol MPVStreamSource: AnyObject {
    /// The total size in bytes, if known.
    var size: Int64? { get }
    /// Reads up to `count` bytes. Returns the number read, 0 at the end, negative on error.
    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int
    func seek(to offset: Int64) -> Bool
    func close()
}

/// Opens the stream for a URL of a registered scheme; nil if it cannot be opened.
typealias MPVStreamOpener = @Sendable (_ url: String) -> (any MPVStreamSource)?

/// Keeps an opener alive for as long as mpv may call it.
final class MPVStreamProtocol: Sendable {
    private let opener: MPVStreamOpener

    init(opener: @escaping MPVStreamOpener) {
        self.opener = opener
    }

    /// Registers `scheme` with `handle`. The returned object must outlive the handle.
    static func register(_ scheme: String, opener: @escaping MPVStreamOpener, on handle: OpaquePointer) -> MPVStreamProtocol {
        let registration = MPVStreamProtocol(opener: opener)
        mpv_stream_cb_add_ro(handle, scheme, Unmanaged.passUnretained(registration).toOpaque()) { userData, url, info in
            guard let userData, let url, let info else { return MPV_ERROR_LOADING_FAILED.rawValue }
            let registration = Unmanaged<MPVStreamProtocol>.fromOpaque(userData).takeUnretainedValue()
            guard let source = registration.opener(String(cString: url)) else {
                return MPV_ERROR_LOADING_FAILED.rawValue
            }
            info.pointee.cookie = Unmanaged.passRetained(SourceBox(source)).toOpaque()
            info.pointee.read_fn = { cookie, buffer, count in
                guard let cookie, let buffer else { return -1 }
                let source = Unmanaged<SourceBox>.fromOpaque(cookie).takeUnretainedValue().source
                return Int64(source.read(into: buffer, count: Int(count)))
            }
            info.pointee.seek_fn = { cookie, offset in
                guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
                let source = Unmanaged<SourceBox>.fromOpaque(cookie).takeUnretainedValue().source
                return source.seek(to: offset) ? offset : Int64(MPV_ERROR_GENERIC.rawValue)
            }
            info.pointee.size_fn = { cookie in
                guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
                let source = Unmanaged<SourceBox>.fromOpaque(cookie).takeUnretainedValue().source
                return source.size ?? Int64(MPV_ERROR_UNSUPPORTED.rawValue)
            }
            info.pointee.close_fn = { cookie in
                guard let cookie else { return }
                Unmanaged<SourceBox>.fromOpaque(cookie).takeRetainedValue().source.close()
            }
            return 0
        }
        return registration
    }

    private final class SourceBox {
        let source: any MPVStreamSource
        init(_ source: any MPVStreamSource) { self.source = source }
    }
}
