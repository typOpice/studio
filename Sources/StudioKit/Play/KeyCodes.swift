import Foundation

/// Physical keys, named as Roblox's Enum.KeyCode names them. Mapped from macOS
/// virtual key codes, which are positions rather than characters — so W is the key
/// above S on any layout, as a game expects.
enum KeyCodes {

    private static let byVirtualKey: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "Zero", 18: "One", 19: "Two", 20: "Three", 21: "Four", 23: "Five", 22: "Six",
        26: "Seven", 28: "Eight", 25: "Nine",
        49: "Space", 36: "Return", 48: "Tab", 51: "Backspace", 53: "Escape",
        56: "LeftShift", 60: "RightShift", 59: "LeftControl", 62: "RightControl",
        58: "LeftAlt", 61: "RightAlt", 55: "LeftSuper",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
        27: "Minus", 24: "Equals", 33: "LeftBracket", 30: "RightBracket",
        41: "Semicolon", 39: "Quote", 43: "Comma", 47: "Period", 44: "Slash", 50: "Backquote"
    ]

    static func name(virtualKey: UInt16) -> String {
        byVirtualKey[virtualKey] ?? "Unknown"
    }

    /// Every name scripts can use, for `Enum.KeyCode` and for completion.
    static let allNames: [String] = {
        var names = Set(byVirtualKey.values)
        names.insert("Unknown")
        return names.sorted()
    }()

    /// Modifier keys arrive as flag changes rather than key events.
    static let modifierKeys: [UInt16] = [56, 60, 59, 62, 58, 61, 55]
}
