import Foundation

/// printf-style format specifiers in localizable strings (the IEEE printf
/// grammar plus Foundation's `%@`, and the `.stringsdict` variable form
/// `%#@name@`, both from Apple's public documentation). See
/// `specs/ide/string-catalog.md`, "Ycode implementation".
public struct FormatSpecifier: Equatable, Sendable {
    /// The whole specifier as written (`%1$lld`, `%#@apples@`, `%%`).
    public var text: String
    /// The UTF-16 offset of `%` in the string.
    public var offset: Int
    /// The explicit argument position (`%2$@` → 2).
    public var position: Int?
    /// Length modifier plus conversion (`lld`, `d`, `@`, `f`); empty for
    /// `%%` and variables.
    public var valueType: String
    /// `%#@name@`: the variable's name.
    public var variable: String?

    /// `%%`: a literal percent sign, which takes no argument.
    public var isLiteralPercent: Bool { text == "%%" }
    /// Whether the specifier consumes an argument.
    public var takesArgument: Bool { !isLiteralPercent }

    /// The specifiers of `s`, in order. Malformed `%` sequences are skipped.
    public static func parse(_ s: String) -> [FormatSpecifier] {
        let u = Array(s.utf16)
        var out: [FormatSpecifier] = []
        var i = 0
        func ch(_ j: Int) -> UInt16? { j < u.count ? u[j] : nil }
        func isDigit(_ c: UInt16?) -> Bool { c.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
        while i < u.count {
            guard u[i] == 0x25 else { i += 1; continue } // %
            let start = i
            var j = i + 1
            if ch(j) == 0x25 {
                out.append(FormatSpecifier(text: "%%", offset: start, position: nil, valueType: "", variable: nil))
                i = j + 1
                continue
            }
            // Position: digits followed by `$`.
            var position: Int?
            var k = j
            while isDigit(ch(k)) { k += 1 }
            if k > j, ch(k) == 0x24 {
                position = Int(String(decoding: u[j..<k], as: UTF16.self))
                j = k + 1
            }
            // Variable: `#@name@`.
            if ch(j) == 0x23, ch(j + 1) == 0x40 {
                var e = j + 2
                while let c = ch(e), c != 0x40 { e += 1 }
                if ch(e) == 0x40, e > j + 2 {
                    let name = String(decoding: u[(j + 2)..<e], as: UTF16.self)
                    let text = String(decoding: u[start...e], as: UTF16.self)
                    out.append(FormatSpecifier(text: text, offset: start, position: position, valueType: "", variable: name))
                    i = e + 1
                    continue
                }
                i = j
                continue
            }
            // Flags, width, precision.
            while let c = ch(j), [0x2D, 0x2B, 0x20, 0x23, 0x30, 0x27].contains(c) { j += 1 } // - + space # 0 '
            if ch(j) == 0x2A { j += 1 } else { while isDigit(ch(j)) { j += 1 } }
            if ch(j) == 0x2E { j += 1; if ch(j) == 0x2A { j += 1 } else { while isDigit(ch(j)) { j += 1 } } }
            // Length modifier and conversion.
            let lengthStart = j
            let lengths: [[UInt16]] = [Array("hh".utf16), Array("ll".utf16), Array("h".utf16), Array("l".utf16), Array("q".utf16),
                                       Array("L".utf16), Array("z".utf16), Array("t".utf16), Array("j".utf16)]
            if let m = lengths.first(where: { m in j + m.count <= u.count && Array(u[j..<(j + m.count)]) == m }) { j += m.count }
            guard let conv = ch(j), "diouxXeEfFgGaAcCsSp@".utf16.contains(conv) else {
                i = start + 1
                continue
            }
            let text = String(decoding: u[start...j], as: UTF16.self)
            let valueType = String(decoding: u[lengthStart...j], as: UTF16.self)
            out.append(FormatSpecifier(text: text, offset: start, position: position, valueType: valueType, variable: nil))
            i = j + 1
        }
        return out
    }
}

extension String {
    /// Replaces UTF-16 ranges (sorted, non-overlapping) with new text.
    func replacingUTF16(_ edits: [(offset: Int, length: Int, text: String)]) -> String {
        var u = Array(utf16)
        for e in edits.sorted(by: { $0.offset > $1.offset }) {
            u.replaceSubrange(e.offset..<(e.offset + e.length), with: Array(e.text.utf16))
        }
        return String(decoding: u, as: UTF16.self)
    }
}
