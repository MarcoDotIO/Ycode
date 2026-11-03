/// Character-level scanning for the USDA text format: whitespace and
/// comments (`#`, `//`, `/* */`), identifiers, numbers, quoted strings,
/// asset references and path references.
struct USDAScanner {
    let bytes: [UInt8]
    var pos = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    var atEnd: Bool { pos >= bytes.count }

    func peek(_ offset: Int = 0) -> UInt8? {
        let i = pos + offset
        return i < bytes.count ? bytes[i] : nil
    }

    /// Line and column (1-based) of the current position.
    var location: (line: Int, column: Int) {
        var line = 1
        var column = 1
        for b in bytes[0..<min(pos, bytes.count)] {
            if b == 0x0A { line += 1; column = 1 } else { column += 1 }
        }
        return (line, column)
    }

    func error(_ message: String) -> USDError {
        let (l, c) = location
        return USDError("usda:\(l):\(c): \(message)")
    }

    /// Skips spaces, newlines, comments and statement separators (`;`).
    mutating func skip() {
        while let b = peek() {
            switch b {
            case 0x20, 0x09, 0x0A, 0x0D, 0x3B:
                pos += 1
            case 0x23: // '#'
                skipToEndOfLine()
            case 0x2F: // '/'
                if peek(1) == 0x2F {
                    skipToEndOfLine()
                } else if peek(1) == 0x2A {
                    pos += 2
                    while !atEnd, !(peek() == 0x2A && peek(1) == 0x2F) { pos += 1 }
                    pos = min(pos + 2, bytes.count)
                } else {
                    return
                }
            default:
                return
            }
        }
    }

    mutating func skipToEndOfLine() {
        while let b = peek(), b != 0x0A { pos += 1 }
    }

    /// Skips trivia and consumes `char` if it is next.
    mutating func consume(_ char: Character) -> Bool {
        skip()
        guard let b = peek(), b == char.asciiValue! else { return false }
        pos += 1
        return true
    }

    mutating func expect(_ char: Character) throws {
        guard consume(char) else { throw error("expected '\(char)'") }
    }

    /// The next non-trivia byte, without consuming it.
    mutating func next() -> UInt8? {
        skip()
        return peek()
    }

    static func isIdentStart(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
    }

    static func isIdentContinue(_ b: UInt8) -> Bool {
        isIdentStart(b) || (b >= 0x30 && b <= 0x39)
    }

    /// A plain identifier, or nil (position unchanged).
    mutating func identifier() -> String? {
        skip()
        guard let b = peek(), USDAScanner.isIdentStart(b) else { return nil }
        let start = pos
        while let c = peek(), USDAScanner.isIdentContinue(c) { pos += 1 }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    /// Peeks the next identifier without consuming it.
    mutating func peekIdentifier(skipping count: Int = 0) -> String? {
        let saved = pos
        defer { pos = saved }
        for _ in 0..<count { _ = namespacedName() }
        return identifier()
    }

    /// `a:b:c` (property names) — also accepts `a::b` (type names).
    mutating func namespacedName() -> String? {
        guard var name = identifier() else { return nil }
        while peek() == 0x3A {
            if peek(1) == 0x3A, let n = peek(2), USDAScanner.isIdentStart(n) {
                pos += 2
                name += "::" + (identifier() ?? "")
            } else if let n = peek(1), USDAScanner.isIdentStart(n) {
                pos += 1
                name += ":" + (identifier() ?? "")
            } else {
                break
            }
        }
        return name
    }

    mutating func expectName(_ what: String) throws -> String {
        guard let name = namespacedName() else { throw error("expected \(what)") }
        return name
    }

    mutating func expectKeyword(_ keyword: String) throws {
        let saved = pos
        guard identifier() == keyword else {
            pos = saved
            throw error("expected '\(keyword)'")
        }
    }

    /// Consumes `keyword` if it is the next identifier.
    mutating func consumeKeyword(_ keyword: String) -> Bool {
        let saved = pos
        if identifier() == keyword { return true }
        pos = saved
        return false
    }

    /// A number literal as text (`-1.5e3`, `inf`, `-inf`, `nan`), or nil.
    mutating func numberText() -> String? {
        skip()
        let start = pos
        if peek() == 0x2D || peek() == 0x2B { pos += 1 }
        if consumeWord("inf") || consumeWord("nan") {
            return String(decoding: bytes[start..<pos], as: UTF8.self)
        }
        var digits = 0
        while let b = peek(), b >= 0x30 && b <= 0x39 { pos += 1; digits += 1 }
        if peek() == 0x2E {
            pos += 1
            while let b = peek(), b >= 0x30 && b <= 0x39 { pos += 1; digits += 1 }
        }
        guard digits > 0 else {
            pos = start
            return nil
        }
        if peek() == 0x65 || peek() == 0x45 {
            let save = pos
            pos += 1
            if peek() == 0x2D || peek() == 0x2B { pos += 1 }
            var expDigits = 0
            while let b = peek(), b >= 0x30 && b <= 0x39 { pos += 1; expDigits += 1 }
            if expDigits == 0 { pos = save }
        }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    private mutating func consumeWord(_ word: String) -> Bool {
        let w = Array(word.utf8)
        guard pos + w.count <= bytes.count, Array(bytes[pos..<(pos + w.count)]) == w else { return false }
        if let after = bytes.indices.contains(pos + w.count) ? bytes[pos + w.count] : nil, USDAScanner.isIdentContinue(after) {
            return false
        }
        pos += w.count
        return true
    }

    mutating func expectDouble() throws -> Double {
        guard let text = numberText() else { throw error("expected a number") }
        return USDAScanner.double(text)
    }

    static func double(_ text: String) -> Double {
        if let d = Double(text) { return d }
        switch text {
        case "inf", "+inf": return .infinity
        case "-inf": return -.infinity
        default: return .nan
        }
    }

    // MARK: Strings

    /// True if a quoted string starts next.
    mutating func atString() -> Bool {
        skip()
        return peek() == 0x22 || peek() == 0x27
    }

    /// A single-, double- or triple-quoted string with escapes evaluated.
    mutating func quotedString() throws -> String {
        skip()
        guard let quote = peek(), quote == 0x22 || quote == 0x27 else { throw error("expected a string") }
        let triple = peek(1) == quote && peek(2) == quote
        pos += triple ? 3 : 1
        var out: [UInt8] = []
        while true {
            guard let b = peek() else { throw error("unterminated string") }
            if b == quote {
                if !triple {
                    pos += 1
                    break
                }
                if peek(1) == quote && peek(2) == quote {
                    pos += 3
                    break
                }
            }
            if b == 0x0A && !triple { throw error("newline in single-line string") }
            if b == 0x5C {
                pos += 1
                guard let e = peek() else { throw error("bad escape") }
                pos += 1
                switch e {
                case 0x6E: out.append(0x0A)
                case 0x74: out.append(0x09)
                case 0x72: out.append(0x0D)
                case 0x61: out.append(0x07)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x76: out.append(0x0B)
                case 0x78: // \xNN
                    var value: UInt8 = 0
                    for _ in 0..<2 {
                        guard let h = peek(), let v = USDAScanner.hexValue(h) else { break }
                        value = value &* 16 &+ v
                        pos += 1
                    }
                    out.append(value)
                case 0x30...0x37: // octal \NNN
                    var value = Int(e - 0x30)
                    for _ in 0..<2 {
                        guard let o = peek(), o >= 0x30 && o <= 0x37 else { break }
                        value = value * 8 + Int(o - 0x30)
                        pos += 1
                    }
                    out.append(UInt8(truncatingIfNeeded: value))
                default:
                    out.append(e)
                }
                continue
            }
            out.append(b)
            pos += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    // MARK: Asset and path references

    mutating func atAsset() -> Bool {
        skip()
        return peek() == 0x40
    }

    /// `@path@` or `@@@path@@@` (with `\@@@` escapes).
    mutating func assetRef() throws -> String {
        skip()
        guard peek() == 0x40 else { throw error("expected an asset path") }
        if peek(1) == 0x40 && peek(2) == 0x40 {
            pos += 3
            var out: [UInt8] = []
            while true {
                guard let b = peek(), b != 0x0A else { throw error("unterminated asset path") }
                if b == 0x5C, peek(1) == 0x40, peek(2) == 0x40, peek(3) == 0x40 {
                    out += [0x40, 0x40, 0x40]
                    pos += 4
                    continue
                }
                if b == 0x40, peek(1) == 0x40, peek(2) == 0x40 {
                    // Up to two extra '@' before the closing triple belong to the path.
                    var extra = 0
                    while peek(3 + extra) == 0x40 && extra < 2 { extra += 1 }
                    out += Array(repeating: 0x40, count: extra)
                    pos += 3 + extra
                    break
                }
                out.append(b)
                pos += 1
            }
            return String(decoding: out, as: UTF8.self)
        }
        pos += 1
        let start = pos
        while let b = peek(), b != 0x40 {
            if b == 0x0A { throw error("unterminated asset path") }
            pos += 1
        }
        guard peek() == 0x40 else { throw error("unterminated asset path") }
        let text = String(decoding: bytes[start..<pos], as: UTF8.self)
        pos += 1
        return text
    }

    mutating func atPathRef() -> Bool {
        skip()
        return peek() == 0x3C
    }

    /// `<path>` or `<>` (the empty path).
    mutating func pathRef() throws -> Path {
        skip()
        guard peek() == 0x3C else { throw error("expected a path reference") }
        pos += 1
        let start = pos
        while let b = peek(), b != 0x3E {
            if b == 0x0A { throw error("unterminated path") }
            pos += 1
        }
        guard peek() == 0x3E else { throw error("unterminated path") }
        let text = String(decoding: bytes[start..<pos], as: UTF8.self).trimmingSpaces
        pos += 1
        guard let path = Path(text) else { throw error("invalid path <\(text)>") }
        return path
    }
}

extension String {
    var trimmingSpaces: String {
        var s = Substring(self)
        while s.first == " " || s.first == "\t" { s.removeFirst() }
        while s.last == " " || s.last == "\t" { s.removeLast() }
        return String(s)
    }
}
