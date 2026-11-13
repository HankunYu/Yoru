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
    /// Bumped whenever rendering changes in a way that makes cached thumbnails stale.
    static let version = 3
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
        // The software renderer draws frames as decoded; a rotation it is told about
        // only moves the rectangle it reads from, off the frame. Turned here instead.
        ("video-rotate", "no"),
        // Nor does it apply Dolby Vision, so the frame is the base layer; without this
        // mpv would still describe it as the processed picture (PQ for an HLG base).
        ("vf", "format=dolbyvision=no"),
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

    /// Opens a file and returns a frame (nil if it has no picture or cannot be read)
    /// together with what was learned about the file.
    ///
    /// - Parameter isCancelled: Asked often while working. Once it says yes the render
    ///   gives up at once, frees its decoder and returns nil: nothing was learned.
    static func render(_ playback: PlaybackLocation, isCancelled: () -> Bool = { false }) -> (image: CGImage?, info: MediaInfo)? {
        var info = MediaInfo()
        // Declared first so that it runs last: the turn is given up only once the handle,
        // and the frames it holds, are gone.
        var holdsLargeDecode = false
        defer {
            if holdsLargeDecode {
                largeDecodes.unlock()
            }
        }
        guard let handle = mpv_create() else { return (nil, info) }
        var streamProtocols: [MPVStreamProtocol] = []
        // The protocols must outlive the handle: mpv closes its streams while shutting down.
        defer { withExtendedLifetime(streamProtocols) { mpv_terminate_destroy(handle) } }
        for (name, value) in options {
            mpv_set_option_string(handle, name, value)
        }
        mpv_request_log_messages(handle, "no")
        guard mpv_initialize(handle) >= 0, let context = makeRenderContext(handle) else {
            return (nil, info)
        }
        defer { mpv_render_context_free(context) }
        streamProtocols = MediaSources.streamProtocols.map { scheme, opener in
            MPVStreamProtocol.register(scheme, opener: opener, on: handle)
        }

        // Called once the file's tracks are known and before any is decoded, which is
        // where the picture's size decides how, or whether, to decode it.
        mpv_hook_add(handle, 0, "on_preloaded", 0)

        var arguments: [UnsafePointer<CChar>?] = [strdup("loadfile"), strdup(playback.location), nil].map { UnsafePointer($0) }
        defer { arguments.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        guard mpv_command(handle, &arguments) >= 0 else { return (nil, info) }

        var deadline = Date().addingTimeInterval(timeout)
        var rotation = 0
        var isLoaded = false
        while Date() < deadline {
            if isCancelled() { return nil }
            guard let event = mpv_wait_event(handle, 0.02)?.pointee else { break }
            switch event.event_id {
            case MPV_EVENT_HOOK:
                guard let hook = event.data?.assumingMemoryBound(to: mpv_event_hook.self).pointee else { break }
                info.duration = double(handle, "duration")
                if let track = firstVideoTrack(handle) {
                    info.width = track.width
                    info.height = track.height
                    rotation = track.rotation
                    switch decodingPlan(width: track.width, height: track.height, codec: track.codec) {
                    case .software:
                        break
                    case .hardwareOnly:
                        // One at a time, however many thumbnails are being made: even
                        // the hardware decoder's frames are a hundred megabytes each.
                        while !largeDecodes.try() {
                            if isCancelled() { return nil }
                            Thread.sleep(forTimeInterval: 0.02)
                        }
                        holdsLargeDecode = true
                        deadline = Date().addingTimeInterval(timeout)
                        mpv_set_property_string(handle, "hwdec", "videotoolbox-copy")
                        mpv_set_property_string(handle, "vd-lavc-software-fallback", "no")
                    case .skip:
                        // Let the load finish with no video selected, so nothing is decoded.
                        mpv_set_property_string(handle, "vid", "no")
                        mpv_hook_continue(handle, hook.id)
                        return (nil, info)
                    }
                }
                mpv_hook_continue(handle, hook.id)
            case MPV_EVENT_FILE_LOADED:
                isLoaded = true
                info.duration = double(handle, "duration") ?? info.duration
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return (nil, info)
            default:
                break
            }
            // Also lets the render context process the core's requests (e.g. reconfiguration).
            let flags = mpv_render_context_update(context)
            guard isLoaded, flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { continue }

            info.width = int(handle, "video-params/w") ?? info.width
            info.height = int(handle, "video-params/h") ?? info.height
            // As the frame leaves the filters, where Dolby Vision is set aside: the decoder
            // still describes the picture the enhancement would have made.
            let transfer = string(handle, "video-out-params/gamma") ?? string(handle, "video-params/gamma")
            let primaries = string(handle, "video-out-params/primaries") ?? string(handle, "video-params/primaries")
            info.isHDR = transfer == "pq" || transfer == "hlg"
            // A frame can fail to render while the video's size is still settling (a
            // still holding several pictures); the next update brings another.
            if let image = renderFrame(context, transfer: transfer, primaries: primaries) {
                return (rotated(image, clockwise: rotation), info)
            }
        }
        return (nil, info)
    }

    // MARK: - Memory

    /// How a picture of a given size may be decoded for its thumbnail.
    enum DecodingPlan: Equatable {
        case software
        /// By the hardware decoder, and not at all if that fails.
        case hardwareOnly
        case skip
    }

    /// The largest picture decoded in software: a little over 4K.
    static let softwarePixelLimit = 4096 * 2304
    private static let largeDecodes = NSLock()

    /// Software decoding holds a frame per thread and per reference, each a hundred
    /// megabytes at 8K, and several thumbnails are made at once: enough for the system to
    /// end the app. Beyond 4K only the hardware decoder is used, one video at a time; it
    /// exists for H.264 and HEVC, and other large videos get no thumbnail. A still image
    /// is a single frame and always decoded.
    static func decodingPlan(width: Int?, height: Int?, codec: String?) -> DecodingPlan {
        guard let width, let height, width * height > softwarePixelLimit else { return .software }
        switch codec {
        case "h264", "hevc": return .hardwareOnly
        case "mjpeg", "png", "webp", "bmp", "tiff", "gif": return .software
        default: return .skip
        }
    }

    /// Turns a frame the way the file asks it to be shown. Quarter turns swap its sides.
    static func rotated(_ image: CGImage, clockwise degrees: Int) -> CGImage {
        let turns = ((degrees % 360) + 360) % 360 / 90
        guard turns != 0 else { return image }
        let (width, height) = (image.width, image.height)
        let size = turns % 2 == 1 ? (height, width) : (width, height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let context = CGContext(
            data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo
        ) else { return image }
        context.translateBy(x: CGFloat(size.0) / 2, y: CGFloat(size.1) / 2)
        // Core Graphics turns counterclockwise for positive angles.
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage() ?? image
    }

    private static func firstVideoTrack(_ handle: OpaquePointer) -> (id: Int, width: Int?, height: Int?, codec: String?, rotation: Int)? {
        for index in 0..<(int(handle, "track-list/count") ?? 0) where string(handle, "track-list/\(index)/type") == "video" {
            guard let id = int(handle, "track-list/\(index)/id") else { continue }
            return (
                id,
                int(handle, "track-list/\(index)/demux-w"),
                int(handle, "track-list/\(index)/demux-h"),
                string(handle, "track-list/\(index)/codec"),
                int(handle, "track-list/\(index)/demux-rotation") ?? 0
            )
        }
        return nil
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
        // transfer function and primaries. PQ is converted to sRGB here; anything else is
        // tagged with its color space and left to Core Graphics.
        var transfer = transfer
        var primaries = primaries
        if transfer == "pq" {
            HDRToneMap.convertPQToSRGB(buffer, pixelCount: width * height, isBT2020: primaries == "bt.2020")
            transfer = nil
            primaries = nil
        }
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
        // HLG is made to look right on a display that knows nothing of it: read as plain
        // BT.2020 video, its upper range is the highlights already rolled off. Tagging it
        // as HLG instead has Core Graphics scale it for an HDR display and clip most of
        // a bright scene on the way to sRGB.
        case "hlg": CGColorSpace.itur_2020
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
