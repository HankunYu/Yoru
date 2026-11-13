import Foundation
import Libmpv
import QuartzCore

/// Tries a shader out and reports what the renderer had to say about it.
///
/// A shader with a mistake in it does no harm: mpv declines it and the picture simply
/// goes without. But nothing says so. This runs a second of video through the same
/// renderer the player uses, off screen, with only that shader on, and collects the
/// errors and warnings, which is the one way to learn why a shader does nothing.
enum ShaderCheck {
    struct Result: Equatable, Sendable {
        /// What the renderer complained of, one message a line; empty if nothing.
        let messages: [String]
        /// Whether the sample played at all; if not, the check itself failed.
        let didRun: Bool

        var isClean: Bool { didRun && messages.isEmpty }
    }

    private static let timeout: TimeInterval = 6

    /// With an error the renderer also prints the whole program it built around the
    /// shader, hundreds of numbered lines; the complaint itself is what is wanted.
    static func isWorthShowing(_ text: String) -> Bool {
        // Nor the renderer's own call stack and the internal call that failed.
        !text.isEmpty && text.wholeMatch(of: /\[\s*\d+\].*/) == nil
            && !text.hasSuffix("shader source:") && text != "shaderc output:"
            && text != "Backtrace:" && text.wholeMatch(of: /#\d+\s.*/) == nil && !text.contains("VK_ERROR_")
    }

    /// Blocks for up to a few seconds; call off the main thread.
    static func run(shader path: String) -> Result {
        guard let sample = Bundle.main.url(forResource: "ShaderCheck", withExtension: "mp4"),
              let handle = mpv_create() else { return Result(messages: [], didRun: false) }
        // A layer of its own, never shown: the renderer needs somewhere to draw.
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 256, height: 144)
        layer.drawableSize = CGSize(width: 256, height: 144)
        var layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerPointer)
        let options = [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("ao", "null"), ("aid", "no"), ("sid", "no"), ("hwdec", "no"),
            ("config", "no"), ("load-scripts", "no"), ("osc", "no"), ("ytdl", "no"),
            ("terminal", "no"), ("input-default-bindings", "no"), ("keep-open", "yes"),
            ("glsl-shaders", path),
        ]
        for (name, value) in options {
            mpv_set_option_string(handle, name, value)
        }
        mpv_request_log_messages(handle, "warn")
        defer { withExtendedLifetime(layer) { mpv_terminate_destroy(handle) } }
        guard mpv_initialize(handle) >= 0 else { return Result(messages: [], didRun: false) }
        mpv_set_property_string(handle, "moltenvk-surface-size", "256x144")

        var arguments: [UnsafePointer<CChar>?] = [strdup("loadfile"), strdup(sample.path), nil].map { UnsafePointer($0) }
        defer { arguments.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        guard mpv_command(handle, &arguments) >= 0 else { return Result(messages: [], didRun: false) }

        var messages: [String] = []
        var didRun = false
        // Once the sample has started, a little longer for what the first frames bring up.
        var deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let event = mpv_wait_event(handle, 0.05)?.pointee else { break }
            switch event.event_id {
            case MPV_EVENT_LOG_MESSAGE:
                guard let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee else { break }
                let prefix = String(cString: message.prefix)
                // The renderer's own; other parts of mpv have nothing to say about shaders.
                guard prefix.hasPrefix("vo") else { break }
                let text = String(cString: message.text).trimmingCharacters(in: .whitespacesAndNewlines)
                if isWorthShowing(text), !messages.contains(text) {
                    messages.append(text)
                }
            case MPV_EVENT_PLAYBACK_RESTART:
                if !didRun {
                    didRun = true
                    deadline = min(deadline, Date().addingTimeInterval(1.2))
                }
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return Result(messages: messages, didRun: didRun)
            default:
                break
            }
        }
        return Result(messages: messages, didRun: didRun)
    }
}
