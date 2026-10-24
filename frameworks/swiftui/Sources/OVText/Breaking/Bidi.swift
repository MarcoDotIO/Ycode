// Bidirectional text: our implementation of the Unicode Bidirectional
// Algorithm (Unicode Standard Annex #9) for what OpenViews needs —
// paragraph direction, resolved embedding levels and the visual order of a
// line — operating on grapheme clusters.
//
// Coverage: P2–P3, W1–W7, N1–N2, I1–I2, L1–L2. Not covered: explicit
// embeddings, overrides and isolates (X1–X10; their control characters are
// treated as boundary neutrals and isolates as other neutrals), bracket
// pairs (N0) and mirrored glyphs (L4, a rendering concern). Bidi classes
// come from ranges of the right-to-left blocks and the general category.

/// UAX #9 bidi classes.
public enum BidiClass: Hashable, Sendable {
    case L, R, AL, EN, ES, ET, AN, CS, NSM, BN, B, S, WS, ON

    public init(_ s: Unicode.Scalar) { self = BidiClass.classify(s) }

    var isStrong: Bool { self == .L || self == .R || self == .AL }

    // swiftlint:disable:next cyclomatic_complexity
    private static func classify(_ s: Unicode.Scalar) -> BidiClass {
        let v = s.value
        switch v {
        case 0x0A, 0x0D, 0x1C...0x1E, 0x85, 0x2029: return .B
        case 0x09, 0x0B, 0x1F: return .S
        case 0x0C, 0x20, 0x1680, 0x2000...0x200A, 0x2028, 0x205F, 0x3000: return .WS
        case 0x30...0x39, 0xB2, 0xB3, 0xB9, 0x06F0...0x06F9, 0x2070, 0x2074...0x2079, 0x2080...0x2089,
             0x2488...0x249B, 0xFF10...0xFF19, 0x1D7CE...0x1D7FF:
            return .EN
        case 0x0600...0x0605, 0x0660...0x0669, 0x066B, 0x066C, 0x06DD, 0x0890, 0x0891, 0x08E2, 0x10E60...0x10E7E:
            return .AN
        case 0x2B, 0x2D, 0x207A, 0x207B, 0x208A, 0x208B, 0x2212, 0xFB29, 0xFE62, 0xFE63, 0xFF0B, 0xFF0D: return .ES
        case 0x23...0x25, 0xA2...0xA5, 0xB0, 0xB1, 0x0609, 0x060A, 0x066A, 0x09F2, 0x09F3, 0x0AF1, 0x0BF9,
             0x0E3F, 0x17DB, 0x2030...0x2034, 0x20A0...0x20CF, 0x212E, 0x2213, 0xFE5F, 0xFE69, 0xFE6A,
             0xFF03...0xFF05, 0xFFE0, 0xFFE1, 0xFFE5, 0xFFE6:
            return .ET
        case 0x2C, 0x2E, 0x2F, 0x3A, 0xA0, 0x060C, 0x202F, 0x2044, 0xFE50, 0xFE52, 0xFE55, 0xFF0C, 0xFF0E,
             0xFF0F, 0xFF1A:
            return .CS
        default: break
        }
        let category = s.properties.generalCategory
        if category == .nonspacingMark || category == .enclosingMark { return .NSM }
        if category == .control || category == .format { return .BN }
        switch v {
        case 0x0590...0x05FF, 0x07C0...0x085F, 0xFB1D...0xFB4F, 0x10800...0x10FFF, 0x1E800...0x1EDFF,
             0x1EF00...0x1EFFF:
            return .R
        case 0x0600...0x07BF, 0x0860...0x08FF, 0xFB50...0xFDCF, 0xFDF0...0xFDFF, 0xFE70...0xFEFF,
             0x1EE00...0x1EEFF:
            return .AL
        default: break
        }
        switch category {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .spacingMark, .decimalNumber, .letterNumber, .otherNumber:
            return .L
        case .spaceSeparator: return .WS
        case .lineSeparator: return .WS
        case .paragraphSeparator: return .B
        default: return .ON
        }
    }
}

/// Direction of a paragraph.
public enum TextDirection: Hashable, Sendable {
    case leftToRight, rightToLeft
}

/// Resolved levels of one paragraph.
public struct BidiParagraph: Sendable {
    /// Paragraph embedding level (0 = left-to-right, 1 = right-to-left).
    public let baseLevel: UInt8
    /// One level per cluster (before L1).
    public let levels: [UInt8]
    let classes: [BidiClass]

    public var direction: TextDirection { baseLevel & 1 == 0 ? .leftToRight : .rightToLeft }

    /// Resolves a paragraph of clusters. `base`: nil = from the first strong
    /// character (P2–P3), falling back to `fallback`.
    public init(_ clusters: [Character], base: TextDirection? = nil, fallback: TextDirection = .leftToRight) {
        let original = clusters.map { $0.unicodeScalars.first.map(BidiClass.init) ?? .ON }
        classes = original
        var base8: UInt8 = fallback == .rightToLeft ? 1 : 0
        if let b = base {
            base8 = b == .rightToLeft ? 1 : 0
        } else if let strong = original.first(where: { $0.isStrong }) {
            base8 = strong == .L ? 0 : 1
        }
        baseLevel = base8
        levels = BidiParagraph.resolve(original, base: base8)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func resolve(_ original: [BidiClass], base: UInt8) -> [UInt8] {
        let n = original.count
        guard n > 0 else { return [] }
        let sos: BidiClass = base & 1 == 0 ? .L : .R
        var t = original
        // X9 (simplified): boundary neutrals take the class of what precedes.
        for i in 0..<n where t[i] == .BN { t[i] = i > 0 ? t[i - 1] : sos }
        // W1.
        for i in 0..<n where t[i] == .NSM { t[i] = i > 0 ? t[i - 1] : sos }
        // W2.
        var lastStrong = sos
        for i in 0..<n {
            if t[i].isStrong { lastStrong = t[i] }
            if t[i] == .EN && lastStrong == .AL { t[i] = .AN }
        }
        // W3.
        for i in 0..<n where t[i] == .AL { t[i] = .R }
        // W4.
        if n >= 3 {
            for i in 1..<(n - 1) {
                if t[i] == .ES && t[i - 1] == .EN && t[i + 1] == .EN { t[i] = .EN }
                if t[i] == .CS && t[i - 1] == t[i + 1] && (t[i - 1] == .EN || t[i - 1] == .AN) { t[i] = t[i - 1] }
            }
        }
        // W5.
        var i = 0
        while i < n {
            guard t[i] == .ET else { i += 1; continue }
            var j = i
            while j < n && t[j] == .ET { j += 1 }
            let touchesEN = (i > 0 && t[i - 1] == .EN) || (j < n && t[j] == .EN)
            if touchesEN { for k in i..<j { t[k] = .EN } }
            i = j
        }
        // W6.
        for k in 0..<n where t[k] == .ES || t[k] == .ET || t[k] == .CS { t[k] = .ON }
        // W7.
        lastStrong = sos
        for k in 0..<n {
            if t[k] == .L || t[k] == .R { lastStrong = t[k] }
            if t[k] == .EN && lastStrong == .L { t[k] = .L }
        }
        // N1, N2.
        func strongDir(_ c: BidiClass) -> BidiClass? {
            switch c {
            case .L: return .L
            case .R, .AN, .EN: return .R
            default: return nil
            }
        }
        i = 0
        while i < n {
            guard strongDir(t[i]) == nil else { i += 1; continue }
            var j = i
            while j < n && strongDir(t[j]) == nil { j += 1 }
            let before = i > 0 ? strongDir(t[i - 1])! : sos
            let after = j < n ? strongDir(t[j])! : sos
            let dir: BidiClass = before == after ? before : (base & 1 == 0 ? .L : .R)
            for k in i..<j { t[k] = dir }
            i = j
        }
        // I1, I2.
        var levels = [UInt8](repeating: base, count: n)
        for k in 0..<n {
            if base & 1 == 0 {
                if t[k] == .R { levels[k] = base + 1 } else if t[k] == .AN || t[k] == .EN { levels[k] = base + 2 }
            } else if t[k] == .L || t[k] == .EN || t[k] == .AN {
                levels[k] = base + 1
            }
        }
        return levels
    }

    /// Visual order (logical cluster indices, left to right) of the clusters
    /// `range` forming one line (L1 trailing-whitespace reset, then L2).
    public func visualOrder(_ range: Range<Int>) -> [Int] {
        guard !range.isEmpty else { return [] }
        var lv = Array(levels[range])
        // L1: separators and trailing whitespace go to the paragraph level.
        var k = lv.count - 1
        while k >= 0 {
            let c = classes[range.lowerBound + k]
            guard c == .WS || c == .S || c == .B || c == .BN else { break }
            lv[k] = baseLevel
            k -= 1
        }
        for j in 0..<lv.count {
            let c = classes[range.lowerBound + j]
            if c == .S || c == .B { lv[j] = baseLevel }
        }
        var order = Array(range)
        guard let maxLevel = lv.max() else { return order }
        let minOdd = lv.filter { $0 & 1 == 1 }.min() ?? (maxLevel + 1)
        if maxLevel >= minOdd {
            for level in stride(from: Int(maxLevel), through: Int(minOdd), by: -1) {
                var s = 0
                while s < order.count {
                    guard lv[s] >= level else { s += 1; continue }
                    var e = s
                    while e < order.count && lv[e] >= level { e += 1 }
                    order[s..<e].reverse()
                    lv[s..<e].reverse()
                    s = e
                }
            }
        }
        return order
    }
}
