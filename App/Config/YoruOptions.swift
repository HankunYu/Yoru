import Foundation

/// Options for Yoru's own interface, stored in `script-opts/yoru.conf` in the config
/// directory: the same `key=value` format and location mpv scripts use for theirs.
struct YoruOptions: Equatable {
    /// Seek between keyframes while dragging the seek bar; exact only on release.
    var seekbarKeyframes = true
    /// Seconds seeked per point of horizontal swipe on the video.
    var swipeSeekRate = 0.15

    static let fileURL = ConfigDirectory.url.appending(path: "script-opts/yoru.conf")

    static func load() -> YoruOptions {
        let file = KeyValueFile(url: fileURL)
        var options = YoruOptions()
        if let value = file.value(for: "seekbar-keyframes") {
            options.seekbarKeyframes = value != "no"
        }
        if let value = file.value(for: "swipe-seek-rate"), let rate = Double(value), rate > 0 {
            options.swipeSeekRate = rate
        }
        return options
    }

    func save() {
        var file = KeyValueFile(url: Self.fileURL)
        file.set("seekbar-keyframes", to: seekbarKeyframes ? "yes" : "no")
        file.set("swipe-seek-rate", to: String(format: "%g", swipeSeekRate))
        file.save()
    }
}
