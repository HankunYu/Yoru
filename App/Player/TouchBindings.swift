import Foundation

/// Yoru's built-in touch bindings, in input.conf syntax.
///
/// They are generated from `YoruOptions` and loaded as a default input section, so a
/// binding for the same key in the user's input.conf takes precedence.
///
/// Keys:
/// - `GESTURE_TAP`: single tap
/// - `GESTURE_DOUBLE_TAP_LEFT` / `_CENTER` / `_RIGHT`: double tap, by horizontal third
/// - `GESTURE_LEFT_UP` / `_DOWN`, `GESTURE_RIGHT_UP` / `_DOWN`: vertical drag on one half, per step
/// - `GESTURE_PINCH_IN` / `_OUT`: pinch, per step
/// - `GESTURE_HOLD`: long press (fires when the hold begins)
///
/// A horizontal drag is not a key: it scrubs continuously, like the seek bar.
enum TouchBindings {
    static func section(for options: YoruOptions) -> String {
        var bindings = [
            "GESTURE_TAP script-message yoru toggle-controls",
            "GESTURE_DOUBLE_TAP_CENTER cycle pause",
            "GESTURE_PINCH_OUT no-osd add video-zoom 0.04",
            "GESTURE_PINCH_IN no-osd add video-zoom -0.04",
            "GESTURE_HOLD script-message yoru hold-speed \(String(format: "%g", options.holdSpeed))",
        ]

        if options.doubleTapSeek > 0 {
            bindings.append("GESTURE_DOUBLE_TAP_LEFT no-osd seek -\(options.doubleTapSeek); script-message yoru show-position")
            bindings.append("GESTURE_DOUBLE_TAP_RIGHT no-osd seek \(options.doubleTapSeek); script-message yoru show-position")
        } else {
            bindings.append("GESTURE_DOUBLE_TAP_LEFT cycle pause")
            bindings.append("GESTURE_DOUBLE_TAP_RIGHT cycle pause")
        }

        let brightnessSide = options.swapsGestureSides ? "RIGHT" : "LEFT"
        let volumeSide = options.swapsGestureSides ? "LEFT" : "RIGHT"
        bindings += drag(on: brightnessSide, action: options.brightnessGesture ? "brightness" : nil)
        bindings += drag(on: volumeSide, action: options.volumeGesture ? "volume" : nil)

        return bindings.joined(separator: "\n") + "\n"
    }

    /// The two bindings of a vertical drag; `ignore` when the gesture is turned off.
    private static func drag(on side: String, action: String?) -> [String] {
        guard let action else {
            return ["GESTURE_\(side)_UP ignore", "GESTURE_\(side)_DOWN ignore"]
        }
        return [
            "GESTURE_\(side)_UP script-message yoru \(action) 0.03",
            "GESTURE_\(side)_DOWN script-message yoru \(action) -0.03",
        ]
    }
}
