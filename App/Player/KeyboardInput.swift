import UIKit

/// Translates hardware keyboard presses into mpv key names, so mpv's own bindings and the
/// user's input.conf apply to a connected keyboard exactly as on a desktop.
enum KeyboardInput {
    /// The mpv name of `key` with its modifiers, e.g. `SPACE`, `Shift+RIGHT`, `Ctrl+s`, `J`;
    /// nil for keys mpv has no name for (bare modifiers, media keys).
    static func mpvName(for key: UIKey) -> String? {
        var modifiers: [String] = []
        if key.modifierFlags.contains(.control) { modifiers.append("Ctrl") }
        if key.modifierFlags.contains(.alternate) { modifiers.append("Alt") }
        if key.modifierFlags.contains(.command) { modifiers.append("Meta") }

        let name: String
        if let special = special[key.keyCode] {
            // Shift is part of the name for keys that have no shifted character.
            if key.modifierFlags.contains(.shift) { modifiers.append("Shift") }
            name = special
        } else {
            // With Ctrl, Alt or Cmd held the produced character is not the key's own, so
            // the unmodified one is used; otherwise the shifted character is the name
            // (`J`, `?`), which is how mpv writes it.
            let characters = modifiers.isEmpty ? key.characters : key.charactersIgnoringModifiers
            guard characters.count == 1, let scalar = characters.unicodeScalars.first,
                  scalar.value > 0x20, !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
            name = characters == "#" ? "SHARP" : characters
        }
        return (modifiers + [name]).joined(separator: "+")
    }

    private static let special: [UIKeyboardHIDUsage: String] = [
        .keyboardSpacebar: "SPACE",
        .keyboardReturnOrEnter: "ENTER",
        .keypadEnter: "KP_ENTER",
        .keyboardEscape: "ESC",
        .keyboardTab: "TAB",
        .keyboardDeleteOrBackspace: "BS",
        .keyboardDeleteForward: "DEL",
        .keyboardInsert: "INS",
        .keyboardHome: "HOME",
        .keyboardEnd: "END",
        .keyboardPageUp: "PGUP",
        .keyboardPageDown: "PGDWN",
        .keyboardLeftArrow: "LEFT",
        .keyboardRightArrow: "RIGHT",
        .keyboardUpArrow: "UP",
        .keyboardDownArrow: "DOWN",
        .keyboardF1: "F1", .keyboardF2: "F2", .keyboardF3: "F3", .keyboardF4: "F4",
        .keyboardF5: "F5", .keyboardF6: "F6", .keyboardF7: "F7", .keyboardF8: "F8",
        .keyboardF9: "F9", .keyboardF10: "F10", .keyboardF11: "F11", .keyboardF12: "F12",
    ]
}
