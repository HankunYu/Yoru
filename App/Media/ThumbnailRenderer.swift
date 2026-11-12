import CoreGraphics
import Foundation
import Libmpv

/// Grabs one frame of a media file with a short-lived, offscreen mpv instance.
///
/// AVFoundation cannot read most of what Yoru plays (mkv, rmvb, ...), so thumbnails come
/// from the same libmpv that plays the file, through its software render API: no window,
/// no GPU context, software decoding. Each call owns a fresh instance, so nothing leaks
/// from one file to the next. Calls block; run them off the main thread.
enum ThumbnailRenderer {
    static let width = 640
    static let height = 360

    private static let timeout: TimeInterval = 8

    private static let options: [(String, String)] = [
        ("vo", "libmpv"),
        ("ao", "null"),
        ("aid", "no"),
        ("sid", "no"),
        ("pause", "yes"),
        // A keyframe a little way in: past logos and black leaders, and cheap to reach.
        ("start", "10%"),
        ("hr-seek", "no"),
        ("hwdec", "no"),
        ("keep-open", "yes"),
        // Fill the 16:9 thumbnail, cropping other aspect ratios.
        ("panscan", "1.0"),
        ("load-scripts", "no"),
        ("osc", "no"),
        ("ytdl", "no"),
        ("osd-level", "0"),
        ("cache", "no"),
        ("demuxer-readahead-secs", "0"),
        ("input-default-bindings", "no"),
        ("terminal", "no"),
    ]

    /// Opens `path` and returns a frame (nil if the file has no picture or cannot be read)
    /// together with what was learned about the file.
    static func render(path: String) -> (image: CGImage?, info: MediaInfo) {
        var info = MediaInfo()
        guard let handle = mpv_create() else { return (nil, info) }
        defer { mpv_terminate_destroy(handle) }
        for (name, value) in options {
            mpv_set_option_string(handle, name, value)
        }
        mpv_request_log_messages(handle, "no")
        guard mpv_initialize(handle) >= 0, let context = makeRenderContext(handle) else {
            return (nil, info)
        }
        defer { mpv_render_context_free(context) }

        var arguments: [UnsafePointer<CChar>?] = [strdup("loadfile"), strdup(path), nil].map { UnsafePointer($0) }
        defer { arguments.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        guard mpv_command(handle, &arguments) >= 0 else { return (nil, info) }

        let deadline = Date().addingTimeInterval(timeout)
        var isLoaded = false
        while Date() < deadline {
            guard let event = mpv_wait_event(handle, 0.02)?.pointee else { break }
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                isLoaded = true
                info.duration = double(handle, "duration")
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return (nil, info)
            default:
                break
            }
            // Also lets the render context process the core's requests (e.g. reconfiguration).
            let flags = mpv_render_context_update(context)
            guard isLoaded, flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { continue }

            info.width = int(handle, "video-params/w")
            info.height = int(handle, "video-params/h")
            let transfer = string(handle, "video-params/gamma")
            let primaries = string(handle, "video-params/primaries")
            info.isHDR = transfer == "pq" || transfer == "hlg"
            return (renderFrame(context, transfer: transfer, primaries: primaries), info)
        }
        return (nil, info)
    }

    // MARK: - Private

    private static func makeRenderContext(_ handle: OpaquePointer) -> OpaquePointer? {
        "sw".withCString { api in
            var parameters = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            var context: OpaquePointer?
            return mpv_render_context_create(&context, handle, &parameters) >= 0 ? context : nil
        }
    }

    private static func renderFrame(_ context: OpaquePointer, transfer: String?, primaries: String?) -> CGImage? {
        var stride = width * 4
        let bytesPerRow = stride
        let byteCount = bytesPerRow * height
        // libmpv asks for a 64-byte aligned buffer and stride.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        defer { buffer.deallocate() }
        var size = [Int32(width), Int32(height)]
        var blockForTargetTime: Int32 = 0

        let status = "bgr0".withCString { format in
            size.withUnsafeMutableBufferPointer { size in
                withUnsafeMutablePointer(to: &stride) { stride in
                    withUnsafeMutablePointer(to: &blockForTargetTime) { blockForTargetTime in
                        var parameters = [
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: size.baseAddress),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stride),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: buffer),
                            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blockForTargetTime),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                        ]
                        return mpv_render_context_render(context, &parameters)
                    }
                }
            }
        }
        guard status >= 0 else { return nil }

        // The software renderer only converts YUV to RGB: the pixels keep the video's
        // transfer function and primaries. Tagging them with that color space and drawing
        // into sRGB lets Core Graphics do the conversion, including HDR tone mapping.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let source = CGColorSpace(name: colorSpaceName(transfer: transfer, primaries: primaries)),
              let provider = CGDataProvider(data: Data(bytes: buffer, count: byteCount) as CFData),
              let tagged = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                  space: source, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let target = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo
              )
        else { return nil }
        target.draw(tagged, in: CGRect(x: 0, y: 0, width: width, height: height))
        return target.makeImage()
    }

    private static func colorSpaceName(transfer: String?, primaries: String?) -> CFString {
        switch transfer {
        case "pq": CGColorSpace.itur_2100_PQ
        case "hlg": CGColorSpace.itur_2100_HLG
        default: primaries == "bt.2020" ? CGColorSpace.itur_2020 : CGColorSpace.itur_709
        }
    }

    private static func double(_ handle: OpaquePointer, _ name: String) -> Double? {
        var value = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    private static func int(_ handle: OpaquePointer, _ name: String) -> Int? {
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? Int(value) : nil
    }

    private static func string(_ handle: OpaquePointer, _ name: String) -> String? {
        guard let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }
}
