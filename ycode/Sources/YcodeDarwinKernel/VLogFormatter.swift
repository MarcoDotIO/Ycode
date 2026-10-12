/// Formats a `printf`-style string whose arguments come from an arm64 Darwin
/// `va_list`. On Darwin arm64, `va_list` is a plain pointer: every variadic
/// argument (integers, pointers, chars, doubles) occupies one 8-byte stack
/// slot, read in order from that pointer.
///
/// Supported conversions: `%s %d %i %u %x %X %o %p %c %%`, with the length
/// modifiers `hh h l ll q j z t L`, the flags `- + space # 0`, and a width and
/// precision (digits or `*`). Any other conversion is printed verbatim and
/// consumes one slot.
public struct VLogFormatter {
    /// Reads 8-byte slot `index` (0-based) of the `va_list`.
    public var slot: (Int) throws -> UInt64
    /// Reads a NUL-terminated string at a guest address.
    public var string: (UInt64) throws -> String

    public init(slot: @escaping (Int) throws -> UInt64, string: @escaping (UInt64) throws -> String) {
        self.slot = slot
        self.string = string
    }

    /// Formats `format`. Unreadable arguments render as `<fault>`.
    public func format(_ format: String) -> String {
        let f = Array(format.utf8)
        var out: [UInt8] = []
        var next = 0
        func take() -> UInt64? {
            defer { next += 1 }
            return try? slot(next)
        }
        var i = 0
        while i < f.count {
            let c = f[i]
            guard c == UInt8(ascii: "%") else { out.append(c); i += 1; continue }
            let start = i
            i += 1
            guard i < f.count else { out.append(c); break }
            if f[i] == UInt8(ascii: "%") { out.append(c); i += 1; continue }

            var leftAlign = false, plus = false, space = false, alternate = false, zeroPad = false
            flags: while i < f.count {
                switch f[i] {
                case UInt8(ascii: "-"): leftAlign = true
                case UInt8(ascii: "+"): plus = true
                case UInt8(ascii: " "): space = true
                case UInt8(ascii: "#"): alternate = true
                case UInt8(ascii: "0"): zeroPad = true
                default: break flags
                }
                i += 1
            }
            var width: Int?
            if i < f.count, f[i] == UInt8(ascii: "*") {
                let w = Int32(truncatingIfNeeded: take() ?? 0)
                if w < 0 { leftAlign = true }
                width = Int(w.magnitude)
                i += 1
            } else {
                while i < f.count, f[i] >= 0x30, f[i] <= 0x39 { width = (width ?? 0) * 10 + Int(f[i] - 0x30); i += 1 }
            }
            var precision: Int?
            if i < f.count, f[i] == UInt8(ascii: ".") {
                i += 1
                precision = 0
                if i < f.count, f[i] == UInt8(ascii: "*") {
                    let p = Int32(truncatingIfNeeded: take() ?? 0)
                    precision = p < 0 ? nil : Int(p)
                    i += 1
                } else {
                    while i < f.count, f[i] >= 0x30, f[i] <= 0x39 { precision = precision! * 10 + Int(f[i] - 0x30); i += 1 }
                }
            }
            // Length modifier: bits of the argument (64 for l/ll/q/j/z/t/L).
            var bits = 32
            lengths: while i < f.count {
                switch f[i] {
                case UInt8(ascii: "h"): bits = bits == 16 ? 8 : 16
                case UInt8(ascii: "l"), UInt8(ascii: "q"), UInt8(ascii: "j"), UInt8(ascii: "z"),
                     UInt8(ascii: "t"), UInt8(ascii: "L"): bits = 64
                default: break lengths
                }
                i += 1
            }
            guard i < f.count else { out += f[start...]; break }
            let conv = f[i]
            i += 1

            var body: String
            var sign = ""
            var numeric = true
            switch conv {
            case UInt8(ascii: "d"), UInt8(ascii: "i"):
                guard let raw = take() else { body = "<fault>"; numeric = false; break }
                let v: Int64 = switch bits {
                case 8: Int64(Int8(truncatingIfNeeded: raw))
                case 16: Int64(Int16(truncatingIfNeeded: raw))
                case 32: Int64(Int32(truncatingIfNeeded: raw))
                default: Int64(bitPattern: raw)
                }
                body = String(v.magnitude)
                sign = v < 0 ? "-" : plus ? "+" : space ? " " : ""
                if precision == 0, v == 0 { body = "" }
            case UInt8(ascii: "u"), UInt8(ascii: "x"), UInt8(ascii: "X"), UInt8(ascii: "o"):
                guard let raw = take() else { body = "<fault>"; numeric = false; break }
                let v = bits == 64 ? raw : raw & ((1 << UInt64(bits)) - 1)
                let radix = conv == UInt8(ascii: "o") ? 8 : conv == UInt8(ascii: "u") ? 10 : 16
                body = String(v, radix: radix, uppercase: conv == UInt8(ascii: "X"))
                if precision == 0, v == 0 { body = "" }
                if alternate, v != 0 {
                    if conv == UInt8(ascii: "x") { sign = "0x" } else if conv == UInt8(ascii: "X") { sign = "0X" }
                    else if conv == UInt8(ascii: "o") { body = "0" + body }
                }
            case UInt8(ascii: "p"):
                guard let raw = take() else { body = "<fault>"; numeric = false; break }
                body = String(raw, radix: 16)
                sign = "0x"
            case UInt8(ascii: "c"):
                numeric = false
                guard let raw = take() else { body = "<fault>"; break }
                body = String(decoding: [UInt8(truncatingIfNeeded: raw)], as: UTF8.self)
            case UInt8(ascii: "s"):
                numeric = false
                guard let raw = take() else { body = "<fault>"; break }
                if raw == 0 {
                    body = "(null)"
                } else if let s = try? string(raw) {
                    body = s
                } else {
                    body = "<fault>"
                }
                if let p = precision, body.utf8.count > p { body = String(decoding: Array(body.utf8.prefix(p)), as: UTF8.self) }
            default:
                // Unsupported conversion: print the specification verbatim.
                _ = take()
                out += f[start..<i]
                continue
            }

            if numeric, let p = precision, body.count < p {
                body = String(repeating: "0", count: p - body.count) + body
            }
            var text = sign + body
            if let w = width, text.count < w {
                let pad = w - text.count
                if leftAlign {
                    text += String(repeating: " ", count: pad)
                } else if zeroPad, numeric, precision == nil {
                    text = sign + String(repeating: "0", count: pad) + body
                } else {
                    text = String(repeating: " ", count: pad) + text
                }
            }
            out += Array(text.utf8)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
