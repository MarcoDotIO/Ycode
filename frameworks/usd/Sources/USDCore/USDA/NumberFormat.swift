/// Number formatting for USDA: the shortest text that reads back to the
/// same value, in the style OpenUSD writes (`1`, `0.25`, `1e-7`, `1.5e22`,
/// `inf`, `nan`).
public enum NumberFormat {
    public static func format(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if value == 0 { return value.sign == .minus ? "-0" : "0" }
        return layout(decompose(value.description), negative: value < 0)
    }

    public static func format(_ value: Float) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if value == 0 { return value.sign == .minus ? "-0" : "0" }
        return layout(decompose(value.description), negative: value < 0)
    }

    /// Halves, as OpenUSD prints them: six significant digits in `%g` style
    /// (`0.333008`, `6.10352e-05`).
    public static func formatHalf(_ value: Float) -> String {
        if value.isNaN || value.isInfinite || value == 0 { return format(value) }
        let (digits, exponent) = decompose(Double(value).description)
        let (d, e) = round(digits: digits, exponent: exponent, to: 6)
        let x = e - 1
        if x < -4 || x >= 6 {
            let chars = d.map { Character(Unicode.Scalar($0 + 48)) }
            var out = value < 0 ? "-" : ""
            out += String(chars[0])
            if chars.count > 1 { out += "." + String(chars[1...]) }
            let mag = abs(x)
            out += "e" + (x < 0 ? "-" : "+") + (mag < 10 ? "0" : "") + String(mag)
            return out
        }
        return layout((d, e), negative: value < 0)
    }

    /// Splits Swift's shortest description into significant digits and the
    /// decimal exponent `n` such that value = 0.d1d2… × 10^n.
    static func decompose(_ text: String) -> (digits: [UInt8], exponent: Int) {
        var mantissa = Substring(text)
        if mantissa.first == "-" { mantissa = mantissa.dropFirst() }
        var exp = 0
        if let e = mantissa.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp = Int(mantissa[mantissa.index(after: e)...]) ?? 0
            mantissa = mantissa[..<e]
        }
        var digits: [UInt8] = []
        var pointPosition: Int?
        for c in mantissa {
            if c == "." {
                pointPosition = digits.count
            } else if let v = c.asciiValue {
                digits.append(v - 48)
            }
        }
        var n = (pointPosition ?? digits.count) + exp
        while digits.first == 0, digits.count > 1 {
            digits.removeFirst()
            n -= 1
        }
        while digits.last == 0, digits.count > 1 { digits.removeLast() }
        return (digits, n)
    }

    static func round(digits: [UInt8], exponent: Int, to precision: Int) -> ([UInt8], Int) {
        guard digits.count > precision else { return (digits, exponent) }
        var kept = Array(digits[0..<precision])
        var exponent = exponent
        if digits[precision] >= 5 {
            var i = precision - 1
            while i >= 0 {
                if kept[i] == 9 {
                    kept[i] = 0
                    i -= 1
                } else {
                    kept[i] += 1
                    break
                }
            }
            if i < 0 {
                kept.insert(1, at: 0)
                kept.removeLast()
                exponent += 1
            }
        }
        while kept.last == 0, kept.count > 1 { kept.removeLast() }
        return (kept, exponent)
    }

    /// ECMAScript-style layout: plain decimal for 1e-6 ≤ |x| < 1e21,
    /// otherwise `d.ddde-x` (no `+` on positive exponents).
    static func layout(_ parts: (digits: [UInt8], exponent: Int), negative: Bool) -> String {
        let digits = parts.digits.map { Character(Unicode.Scalar($0 + 48)) }
        let k = digits.count
        let n = parts.exponent
        var out = negative ? "-" : ""
        if k <= n && n <= 21 {
            out += String(digits) + String(repeating: "0", count: n - k)
        } else if n > 0 && n <= 21 {
            out += String(digits[0..<n]) + "." + String(digits[n...])
        } else if -6 < n && n <= 0 {
            out += "0." + String(repeating: "0", count: -n) + String(digits)
        } else {
            out += String(digits[0])
            if k > 1 { out += "." + String(digits[1...]) }
            out += "e" + String(n - 1)
        }
        return out
    }
}
