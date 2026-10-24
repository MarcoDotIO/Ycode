// macOS virtual key codes (the public Carbon `kVK_*` values, ANSI layout)
// → USB HID keyboard usages (page 7, HID Usage Tables §10). The viewer
// sends usages; the guest applies its own keyboard layout.

#if os(macOS)
enum KeyMap {
    static let keyboardPage: UInt16 = 7

    /// kVK code → HID usage.
    static let usage: [UInt16: UInt16] = {
        var m: [UInt16: UInt16] = [:]
        // Letters.
        let letters: [(UInt16, Character)] = [
            (0x00, "a"), (0x0B, "b"), (0x08, "c"), (0x02, "d"), (0x0E, "e"), (0x03, "f"), (0x05, "g"), (0x04, "h"),
            (0x22, "i"), (0x26, "j"), (0x28, "k"), (0x25, "l"), (0x2E, "m"), (0x2D, "n"), (0x1F, "o"), (0x23, "p"),
            (0x0C, "q"), (0x0F, "r"), (0x01, "s"), (0x11, "t"), (0x20, "u"), (0x09, "v"), (0x0D, "w"), (0x07, "x"),
            (0x10, "y"), (0x06, "z"),
        ]
        for (code, ch) in letters { m[code] = UInt16(ch.asciiValue! - Character("a").asciiValue!) + 0x04 }
        // Digits 1–9, 0.
        let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (i, code) in digits.enumerated() { m[code] = 0x1E + UInt16(i) }
        let rest: [(UInt16, UInt16)] = [
            (0x24, 0x28), // return
            (0x35, 0x29), // escape
            (0x33, 0x2A), // delete (backspace)
            (0x30, 0x2B), // tab
            (0x31, 0x2C), // space
            (0x1B, 0x2D), // -
            (0x18, 0x2E), // =
            (0x21, 0x2F), // [
            (0x1E, 0x30), // ]
            (0x2A, 0x31), // backslash
            (0x29, 0x33), // ;
            (0x27, 0x34), // '
            (0x32, 0x35), // `
            (0x2B, 0x36), // ,
            (0x2F, 0x37), // .
            (0x2C, 0x38), // /
            (0x39, 0x39), // caps lock
            (0x7A, 0x3A), (0x78, 0x3B), (0x63, 0x3C), (0x76, 0x3D), (0x60, 0x3E), (0x61, 0x3F), // F1–F6
            (0x62, 0x40), (0x64, 0x41), (0x65, 0x42), (0x6D, 0x43), (0x67, 0x44), (0x6F, 0x45), // F7–F12
            (0x73, 0x4A), // home
            (0x74, 0x4B), // page up
            (0x75, 0x4C), // forward delete
            (0x77, 0x4D), // end
            (0x79, 0x4E), // page down
            (0x7C, 0x4F), // right
            (0x7B, 0x50), // left
            (0x7D, 0x51), // down
            (0x7E, 0x52), // up
            (0x47, 0x53), // keypad clear
            (0x4B, 0x54), (0x43, 0x55), (0x4E, 0x56), (0x45, 0x57), (0x4C, 0x58), // keypad / * - + enter
            (0x53, 0x59), (0x54, 0x5A), (0x55, 0x5B), (0x56, 0x5C), (0x57, 0x5D), // keypad 1–5
            (0x58, 0x5E), (0x59, 0x5F), (0x5B, 0x60), (0x5C, 0x61), (0x52, 0x62), // keypad 6–9, 0
            (0x41, 0x63), // keypad .
            (0x51, 0x67), // keypad =
            // Modifiers.
            (0x3B, 0xE0), (0x38, 0xE1), (0x3A, 0xE2), (0x37, 0xE3),
            (0x3E, 0xE4), (0x3C, 0xE5), (0x3D, 0xE6), (0x36, 0xE7),
        ]
        for (code, u) in rest { m[code] = u }
        return m
    }()

    static func isModifier(_ usage: UInt16) -> Bool { (0xE0...0xE7).contains(usage) }

    /// A character of US text → (kVK code, shift), for scripted typing.
    static func keyCode(for ch: Character) -> (code: UInt16, shift: Bool)? {
        if let lower = ch.lowercased().first, lower.isLetter, lower.isASCII {
            guard let code = usage.first(where: { $0.value == UInt16(lower.asciiValue! - 97) + 0x04 })?.key else { return nil }
            return (code, ch.isUppercase)
        }
        let plain: [Character: UInt16] = [
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
            " ": 0x31, "\n": 0x24, "\t": 0x30, "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A, ";": 0x29,
            "'": 0x27, "`": 0x32, ",": 0x2B, ".": 0x2F, "/": 0x2C,
        ]
        if let code = plain[ch] { return (code, false) }
        let shifted: [Character: UInt16] = [
            "!": 0x12, "@": 0x13, "#": 0x14, "$": 0x15, "%": 0x17, "^": 0x16, "&": 0x1A, "*": 0x1C, "(": 0x19, ")": 0x1D,
            "_": 0x1B, "+": 0x18, "{": 0x21, "}": 0x1E, "|": 0x2A, ":": 0x29, "\"": 0x27, "~": 0x32, "<": 0x2B,
            ">": 0x2F, "?": 0x2C,
        ]
        if let code = shifted[ch] { return (code, true) }
        return nil
    }
}
#endif
