// Line break opportunities: our implementation of the Unicode Line Breaking
// Algorithm (Unicode Standard Annex #14), operating on grapheme clusters
// (Swift `Character`s, UAX #29), which already keep combining marks, ZWJ
// sequences, emoji modifiers and regional-indicator pairs together (LB8a,
// LB9, LB10, LB30a, LB30b).
//
// Coverage: the pair rules LB4–LB31 except the Brahmic rule LB28a and the
// East-Asian-width refinement of LB30; the full numeric regular expression
// of LB25 is approximated by its pair form. Line break classes come from a
// table of the characters the annex lists explicitly, with the remainder
// derived from the general category (letters → AL, decimal digits → NU,
// opening/closing/quotation punctuation → OP/CL/QU, marks → CM) and block
// ranges (CJK and kana → ID, Hangul syllables → H2/H3, Hebrew letters →
// HL). Complex-context (SA) scripts are treated as AL: there is no
// dictionary-based word breaking.

/// UAX #14 line break classes (the subset this implementation resolves to).
public enum LineBreakClass: Hashable, Sendable {
    case BK, CR, LF, NL, SP, ZW, ZWJ, CM, WJ, GL
    case BA, BB, B2, HY, CB, CL, CP, EX, IN, NS, OP, QU, IS, NU, PO, PR, SY
    case AL, HL, ID, EB, EM, RI, H2, H3, JL, JV, JT

    /// The class of a scalar.
    public init(_ s: Unicode.Scalar) {
        self = LineBreakClass.classify(s)
    }

    private static let smallKana: Set<UInt32> = [
        0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083, 0x3085, 0x3087, 0x308E, 0x3095, 0x3096,
        0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3, 0x30E3, 0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6, 0x30FC,
    ]

    // swiftlint:disable:next cyclomatic_complexity
    private static func classify(_ s: Unicode.Scalar) -> LineBreakClass {
        let v = s.value
        switch v {
        case 0x0A: return .LF
        case 0x0D: return .CR
        case 0x0B, 0x0C, 0x2028, 0x2029: return .BK
        case 0x85: return .NL
        case 0x20: return .SP
        case 0x200B: return .ZW
        case 0x200D: return .ZWJ
        case 0x2060, 0xFEFF: return .WJ
        case 0x00A0, 0x202F, 0x180E, 0x2007, 0x2011, 0x0F08, 0x0F0C, 0x0F12, 0x035C...0x0362: return .GL
        case 0x09, 0x00AD, 0x058A, 0x05BE, 0x0F0B, 0x1361, 0x1680, 0x17D8, 0x17DA, 0x2000...0x2006,
             0x2008...0x200A, 0x2010, 0x2012, 0x2013, 0x2027, 0x205F, 0x2E0E...0x2E15, 0x2E17, 0x2E19,
             0x2E2A...0x2E2D, 0x2E30, 0x2E31, 0x3000:
            return .BA
        case 0x2014, 0x2E3A, 0x2E3B: return .B2
        case 0x00B4, 0x02C8, 0x02CC, 0x02DF, 0x0F01...0x0F04, 0x0F06, 0x0F07, 0x0F09, 0x0F0A, 0x0FD0, 0x0FD1,
             0x0FD3, 0x1806, 0x1FFD, 0xA874, 0xA875:
            return .BB
        case 0x2D: return .HY
        case 0xFFFC: return .CB
        case 0x29, 0x5D: return .CP
        case 0x21, 0x3F, 0x05C6, 0x061B, 0x061D...0x061F, 0x06D4, 0x07F9, 0x0F0D...0x0F11, 0x0F14, 0x1802,
             0x1803, 0x1808, 0x1809, 0x1944, 0x1945, 0x2762, 0x2763, 0x2CF9, 0x2CFE, 0x2E2E, 0xA60E, 0xA876,
             0xA877, 0xFE15, 0xFE16, 0xFE56, 0xFE57, 0xFF01, 0xFF1F:
            return .EX
        case 0x2024...0x2026, 0x22EF, 0xFE19: return .IN
        case 0x2C, 0x2E, 0x3A, 0x3B, 0x037E, 0x0589, 0x060C, 0x060D, 0x07F8, 0x2044, 0xFE10, 0xFE13, 0xFE14:
            return .IS
        case 0x2F: return .SY
        case 0x25, 0xA2, 0xB0, 0x060B, 0x066A, 0x2030...0x2037, 0x20A7, 0x2103, 0x2109, 0x2116, 0xFDFC,
             0xFE6A, 0xFF05, 0xFFE0:
            return .PO
        case 0x24, 0x2B, 0x5C, 0xA3...0xA5, 0xB1, 0x058F, 0x09FB, 0x0AF1, 0x0BF9, 0x0E3F, 0x17DB,
             0x20A0...0x20A6, 0x20A8...0x20C0, 0x2212, 0x2213, 0xFE69, 0xFF04, 0xFFE1, 0xFFE5, 0xFFE6:
            return .PR
        case 0x22, 0x27, 0xAB, 0xBB, 0x2018, 0x2019, 0x201B...0x201D, 0x201F, 0x2039, 0x203A,
             0x275B...0x2760, 0x2E00...0x2E0D, 0x2E1C, 0x2E1D, 0x2E20, 0x2E21:
            return .QU
        case 0x17D6, 0x203C, 0x203D, 0x2047...0x2049, 0x3005, 0x301C, 0x303B, 0x303C, 0x309B...0x309E, 0x30A0,
             0x30FB, 0x30FD, 0x30FE, 0xA015, 0xFE54, 0xFE55, 0xFF1A, 0xFF1B, 0xFF65, 0xFF9E, 0xFF9F,
             0x31F0...0x31FF, 0xFF67...0xFF70:
            return .NS
        case 0x3001, 0x3002, 0xFE11, 0xFE12, 0xFE50, 0xFE52, 0xFF0C, 0xFF0E, 0xFF61, 0xFF64: return .CL
        case 0x1F1E6...0x1F1FF: return .RI
        case 0x1F3FB...0x1F3FF: return .EM
        case 0x05D0...0x05EA, 0x05EF...0x05F2, 0xFB1D, 0xFB1F...0xFB28, 0xFB2A...0xFB4F: return .HL
        case 0x1100...0x115F, 0xA960...0xA97C: return .JL
        case 0x1160...0x11A7, 0xD7B0...0xD7C6: return .JV
        case 0x11A8...0x11FF, 0xD7CB...0xD7FB: return .JT
        case 0xAC00...0xD7A3: return (v - 0xAC00) % 28 == 0 ? .H2 : .H3
        default: break
        }
        if smallKana.contains(v) { return .NS }
        let category = s.properties.generalCategory
        switch category {
        case .openPunctuation: return .OP
        case .closePunctuation: return .CL
        case .initialPunctuation, .finalPunctuation: return .QU
        case .nonspacingMark, .spacingMark, .enclosingMark: return .CM
        case .control, .format: return .CM
        case .spaceSeparator: return .BA
        default: break
        }
        switch v {
        case 0x2E80...0x2FFF, 0x3003...0x303F, 0x3040...0x30FF, 0x3100...0x31EF, 0x3200...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F000...0x1FAFF, 0x20000...0x3FFFD:
            return .ID
        default: break
        }
        if category == .decimalNumber { return .NU }
        return .AL
    }
}

/// What may happen between two clusters.
public enum LineBreakOpportunity: Hashable, Sendable {
    case prohibited
    case allowed
    case mandatory
}

public enum LineBreaker {
    /// The class of a grapheme cluster (its first scalar; a cluster that
    /// starts with a combining mark or ZWJ is AL, LB10).
    public static func lineBreakClass(of c: Character) -> LineBreakClass {
        guard let first = c.unicodeScalars.first else { return .AL }
        if c == "\r\n" { return .CR }
        let cls = LineBreakClass(first)
        return cls == .CM || cls == .ZWJ ? .AL : cls
    }

    /// Opportunities *before* each cluster: element `i` describes the
    /// boundary between clusters `i − 1` and `i`; element 0 is `.prohibited`
    /// and element `count` (the end of text) is `.mandatory` (LB2, LB3).
    public static func opportunities(_ clusters: [Character]) -> [LineBreakOpportunity] {
        opportunities(classes: clusters.map(lineBreakClass(of:)))
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public static func opportunities(classes cls: [LineBreakClass]) -> [LineBreakOpportunity] {
        let n = cls.count
        var out = [LineBreakOpportunity](repeating: .prohibited, count: n + 1)
        guard n > 0 else { out[0] = .mandatory; return out }
        out[n] = .mandatory
        var lastNonSpace: LineBreakClass? = nil  // before the current run of spaces
        if cls[0] != .SP { lastNonSpace = cls[0] }
        for i in 1..<n {
            let a = cls[i - 1], b = cls[i]
            // The class before any spaces that end at i − 1.
            let beforeSpaces = a == .SP ? lastNonSpace : a
            defer { if b != .SP { lastNonSpace = b } }
            func set(_ o: LineBreakOpportunity) { out[i] = o }
            // LB4, LB5: hard breaks.
            if a == .BK || a == .LF || a == .NL { set(.mandatory); continue }
            if a == .CR { set(b == .LF ? .prohibited : .mandatory); continue }
            // LB6.
            if b == .BK || b == .CR || b == .LF || b == .NL { set(.prohibited); continue }
            // LB7.
            if b == .SP || b == .ZW { set(.prohibited); continue }
            // LB8: ZW SP* ÷.
            if beforeSpaces == .ZW { set(.allowed); continue }
            // LB8a.
            if a == .ZWJ { set(.prohibited); continue }
            // LB11.
            if a == .WJ || b == .WJ { set(.prohibited); continue }
            // LB12, LB12a.
            if a == .GL { set(.prohibited); continue }
            if b == .GL && a != .SP && a != .BA && a != .HY { set(.prohibited); continue }
            // LB13.
            if b == .CL || b == .CP || b == .EX || b == .IS || b == .SY { set(.prohibited); continue }
            // LB14: OP SP* ×.
            if beforeSpaces == .OP { set(.prohibited); continue }
            // LB15: QU SP* × OP.
            if beforeSpaces == .QU && b == .OP { set(.prohibited); continue }
            // LB16: (CL | CP) SP* × NS.
            if (beforeSpaces == .CL || beforeSpaces == .CP) && b == .NS { set(.prohibited); continue }
            // LB17: B2 SP* × B2.
            if beforeSpaces == .B2 && b == .B2 { set(.prohibited); continue }
            // LB18: SP ÷.
            if a == .SP { set(.allowed); continue }
            // LB19.
            if a == .QU || b == .QU { set(.prohibited); continue }
            // LB20.
            if a == .CB || b == .CB { set(.allowed); continue }
            // LB21, LB21a, LB21b.
            if b == .BA || b == .HY || b == .NS || a == .BB { set(.prohibited); continue }
            if i >= 2 && cls[i - 2] == .HL && (a == .HY || a == .BA) { set(.prohibited); continue }
            if a == .SY && b == .HL { set(.prohibited); continue }
            // LB22.
            if b == .IN { set(.prohibited); continue }
            let letter: Set<LineBreakClass> = [.AL, .HL]
            let ideo: Set<LineBreakClass> = [.ID, .EB, .EM]
            let hangul: Set<LineBreakClass> = [.JL, .JV, .JT, .H2, .H3]
            // LB23, LB23a, LB24.
            if letter.contains(a) && b == .NU || a == .NU && letter.contains(b) { set(.prohibited); continue }
            if a == .PR && ideo.contains(b) || ideo.contains(a) && b == .PO { set(.prohibited); continue }
            if (a == .PR || a == .PO) && letter.contains(b) || letter.contains(a) && (b == .PR || b == .PO) {
                set(.prohibited); continue
            }
            // LB25 (pair form).
            if [.CL, .CP, .NU].contains(a) && (b == .PO || b == .PR) { set(.prohibited); continue }
            if (a == .PO || a == .PR) && (b == .OP || b == .NU) { set(.prohibited); continue }
            if [.HY, .IS, .NU, .SY].contains(a) && b == .NU { set(.prohibited); continue }
            // LB26, LB27.
            if a == .JL && [.JL, .JV, .H2, .H3].contains(b) { set(.prohibited); continue }
            if (a == .JV || a == .H2) && (b == .JV || b == .JT) { set(.prohibited); continue }
            if (a == .JT || a == .H3) && b == .JT { set(.prohibited); continue }
            if hangul.contains(a) && b == .PO || a == .PR && hangul.contains(b) { set(.prohibited); continue }
            // LB28, LB29, LB30.
            if letter.contains(a) && letter.contains(b) { set(.prohibited); continue }
            if a == .IS && letter.contains(b) { set(.prohibited); continue }
            if (letter.contains(a) || a == .NU) && b == .OP { set(.prohibited); continue }
            if a == .CP && (letter.contains(b) || b == .NU) { set(.prohibited); continue }
            // LB30a/b are inside clusters; LB31.
            if a == .EB && b == .EM { set(.prohibited); continue }
            set(.allowed)
        }
        return out
    }
}
