import Foundation

/// Options for Yoru's own interface, stored in `script-opts/yoru.conf` in the config
/// directory: the same `key=value` format and location mpv scripts use for theirs.
/// What the player does when a video reaches its end.
enum EndAction: String, CaseIterable {
    /// Play the next file of the folder; stay on the last frame when there is none.
    case next
    /// Stay on the last frame.
    case stay
    /// Close the player.
    case close
}

struct YoruOptions: Equatable {
    /// Seek between keyframes while dragging the seek bar; exact only on release.
    var seekbarKeyframes = true
    /// Seconds seeked per point of horizontal swipe on the video.
    var swipeSeekRate = 0.15
    /// Seconds a double tap on the left or right third seeks; 0 makes the sides pause
    /// like the center.
    var doubleTapSeek = 0
    /// Vertical drags change the screen brightness on one half ...
    var brightnessGesture = true
    /// ... and the system volume on the other.
    var volumeGesture = true
    /// Brightness on the right and volume on the left, instead of the other way round.
    var swapsGestureSides = false
    /// Playback speed while a finger is held down.
    var holdSpeed = 2.0
    var endAction = EndAction.next

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
        if let value = file.value(for: "double-tap-seek"), let seconds = Int(value), seconds >= 0 {
            options.doubleTapSeek = seconds
        }
        if let value = file.value(for: "brightness-gesture") {
            options.brightnessGesture = value != "no"
        }
        if let value = file.value(for: "volume-gesture") {
            options.volumeGesture = value != "no"
        }
        if let value = file.value(for: "swap-gesture-sides") {
            options.swapsGestureSides = value == "yes"
        }
        if let value = file.value(for: "hold-speed"), let speed = Double(value), speed > 0 {
            options.holdSpeed = speed
        }
        if let value = file.value(for: "at-end"), let action = EndAction(rawValue: value) {
            options.endAction = action
        }
        return options
    }

    func save() {
        var file = KeyValueFile(url: Self.fileURL)
        file.set("seekbar-keyframes", to: Self.flag(seekbarKeyframes))
        file.set("swipe-seek-rate", to: String(format: "%g", swipeSeekRate))
        file.set("double-tap-seek", to: String(doubleTapSeek))
        file.set("brightness-gesture", to: Self.flag(brightnessGesture))
        file.set("volume-gesture", to: Self.flag(volumeGesture))
        file.set("swap-gesture-sides", to: Self.flag(swapsGestureSides))
        file.set("hold-speed", to: String(format: "%g", holdSpeed))
        file.set("at-end", to: endAction.rawValue)
        file.save()
    }

    private static func flag(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}
