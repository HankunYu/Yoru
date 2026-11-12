import Foundation

/// Options for Yoru's own interface, read from `script-opts/yoru.conf` in the config
/// directory: the same `key=value` format and location mpv scripts use for theirs.
struct YoruOptions {
    /// Seek between keyframes while dragging the seek bar; exact only on release.
    var seekbarKeyframes = true
    /// Seconds seeked per point of horizontal swipe on the video.
    var swipeSeekRate = 0.15

    static func load() -> YoruOptions {
        var options = YoruOptions()
        let url = ConfigDirectory.url.appending(path: "script-opts/yoru.conf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return options }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "seekbar-keyframes":
                options.seekbarKeyframes = value != "no"
            case "swipe-seek-rate":
                if let rate = Double(value), rate > 0 {
                    options.swipeSeekRate = rate
                }
            default:
                Log.app.warning("Unknown option in yoru.conf: \(key, privacy: .public)")
            }
        }
        return options
    }
}
