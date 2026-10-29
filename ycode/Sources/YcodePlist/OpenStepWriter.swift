/// Serializes `PlistValue` trees in OpenStep ASCII format.
///
/// This is the general-purpose writer (tab-indented, one entry per line).
/// Project files use `PBXProjWriter`, which follows Xcode's exact layout.
public enum OpenStepWriter {
    /// Returns `value` as an OpenStep document, followed by a newline.
    public static func write(_ value: PlistValue) -> String {
        var out = ""
        write(value, indent: 0, into: &out)
        out += "\n"
        return out
    }

    private static func write(_ value: PlistValue, indent: Int, into out: inout String) {
        switch value {
        case .string(let s):
            out += quote(s)
        case .data(let bytes):
            out += "<"
            for (i, b) in bytes.enumerated() {
                if i > 0, i % 4 == 0 { out += " " }
                out += hex(b)
            }
            out += ">"
        case .array(let items):
            out += "(\n"
            for item in items {
                out += tabs(indent + 1)
                write(item, indent: indent + 1, into: &out)
                out += ",\n"
            }
            out += tabs(indent) + ")"
        case .dictionary(let dict):
            out += "{\n"
            for (k, v) in dict {
                out += tabs(indent + 1) + quote(k) + " = "
                write(v, indent: indent + 1, into: &out)
                out += ";\n"
            }
            out += tabs(indent) + "}"
        }
    }

    /// Quotes `s` when Xcode would. Unquoted strings are non-empty, made of
    /// `[A-Za-z0-9_$/:.]`, and contain neither `//` (comment start) nor `___`
    /// (template placeholder marker).
    public static func quote(_ s: String) -> String {
        if needsQuotes(s) { return "\"" + escape(s) + "\"" }
        return s
    }

    /// Whether `quote(_:)` must quote `s`: it is empty, has a character
    /// outside the unquoted set, or contains `//` or `___`.
    public static func needsQuotes(_ s: String) -> Bool {
        if s.isEmpty { return true }
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "$"), UInt8(ascii: "/"), UInt8(ascii: ":"), UInt8(ascii: "."):
                continue
            default:
                return true
            }
        }
        return s.contains("//") || s.contains("___")
    }

    /// Escapes `s` for use inside double quotes: backslash, quote and the
    /// C control escapes, and `\Uxxxx` for other control characters.
    /// See `specs/formats/openstep-plist.md` (Grammar).
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{07}": out += "\\a"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{0B}": out += "\\v"
            default:
                if scalar.value < 0x20 {
                    out += "\\U" + hex4(UInt16(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// `n` tab characters (the writer's indentation unit).
    public static func tabs(_ n: Int) -> String { String(repeating: "\t", count: n) }

    private static let digits = Array("0123456789abcdef")
    /// The two lowercase hex digits of `b`.
    public static func hex(_ b: UInt8) -> String { String([digits[Int(b >> 4)], digits[Int(b & 0xF)]]) }
    static func hex4(_ v: UInt16) -> String { hex(UInt8(v >> 8)) + hex(UInt8(v & 0xFF)) }
}
