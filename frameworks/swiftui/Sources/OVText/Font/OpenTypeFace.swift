import Foundation
import Synchronization

// An OpenType / TrueType font file reader: just the tables text layout needs
// (head, hhea, hmtx, maxp, OS/2, post, name, cmap formats 4 and 12, kern
// format 0, and GPOS pair adjustment for the `kern` feature). Written from
// the OpenType specification (Microsoft Typography, "OpenType font file",
// table chapters). Glyph outlines are not read (rendering is round R5).
//
// Every read is bounds-checked: a damaged or hostile file yields an error or
// zero values, never a crash.

/// Errors reading a font file.
public enum FontFileError: Error, Equatable {
    case notAFont
    case missingTable(String)
    case badCollectionIndex
}

/// Big-endian reads over a byte array.
struct FontBytes {
    /// The file (zero-based indices; a slice is rebased on creation).
    let bytes: Data

    init(_ data: Data) { bytes = data.startIndex == 0 ? data : Data(data) }

    func u8(_ o: Int) -> UInt8 { o >= 0 && o < bytes.count ? bytes[o] : 0 }
    func u16(_ o: Int) -> UInt16 { UInt16(u8(o)) << 8 | UInt16(u8(o + 1)) }
    func i16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) << 16 | UInt32(u16(o + 2)) }
    func tag(_ o: Int) -> String {
        String(decoding: (0..<4).map { u8(o + $0) }, as: UTF8.self)
    }
    func contains(_ o: Int, _ length: Int) -> Bool { o >= 0 && length >= 0 && o + length <= bytes.count }
}

/// A face read from an OpenType (TrueType or CFF-flavoured) font file.
public final class OpenTypeFace: FontFace, @unchecked Sendable {
    public let familyName: String
    public let styleName: String
    public let postScriptName: String
    public let traits: FontTraits
    public let unitsPerEm: Int
    /// Vertical metrics in font units (descender positive).
    public let ascender: Int
    public let descender: Int
    public let lineGap: Int
    public let capHeight: Int
    public let xHeight: Int
    public let glyphCount: Int

    private let data: FontBytes
    private let advances: [UInt16]
    private let cmap: CharacterMap
    private let kernPairs: [UInt32: Int16]
    private let gposKern: [PairAdjustment]
    private let kernCache = Mutex<[UInt64: Int32]>([:])

    /// Reads face `index` of a font file or collection.
    public convenience init(contentsOf url: URL, index: Int = 0) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe), index: index)
    }

    public init(data: Data, index: Int = 0) throws {
        let d = FontBytes(data)
        var base = 0
        if d.tag(0) == "ttcf" {
            let n = Int(d.u32(8))
            guard index >= 0, index < n else { throw FontFileError.badCollectionIndex }
            base = Int(d.u32(12 + 4 * index))
        }
        let version = d.u32(base)
        guard version == 0x0001_0000 || d.tag(base) == "OTTO" || d.tag(base) == "true" else {
            throw FontFileError.notAFont
        }
        var tables: [String: (offset: Int, length: Int)] = [:]
        let numTables = Int(d.u16(base + 4))
        for i in 0..<numTables {
            let r = base + 12 + 16 * i
            let off = Int(d.u32(r + 8)), len = Int(d.u32(r + 12))
            if d.contains(off, len) { tables[d.tag(r)] = (off, len) }
        }
        func table(_ t: String) throws -> Int {
            guard let e = tables[t] else { throw FontFileError.missingTable(t) }
            return e.offset
        }
        self.data = d

        let head = try table("head")
        unitsPerEm = max(Int(d.u16(head + 18)), 1)
        let macStyle = d.u16(head + 44)

        let hhea = try table("hhea")
        var asc = Int(d.i16(hhea + 4)), desc = -Int(d.i16(hhea + 6)), gap = Int(d.i16(hhea + 8))
        let numHMetrics = Int(d.u16(hhea + 34))

        glyphCount = tables["maxp"].map { Int(d.u16($0.offset + 4)) } ?? numHMetrics
        let hmtx = try table("hmtx")
        let nh = min(numHMetrics, (tables["hmtx"]!.length) / 4)
        advances = (0..<nh).map { d.u16(hmtx + 4 * $0) }

        var weight = macStyle & 1 != 0 ? 700 : 400
        var width = 5
        var italic = macStyle & 2 != 0
        var cap = Int(Double(unitsPerEm) * 0.7), xh = Int(Double(unitsPerEm) * 0.5)
        if let os2 = tables["OS/2"]?.offset {
            let v = d.u16(os2)
            weight = Int(d.u16(os2 + 4))
            width = Int(d.u16(os2 + 6))
            let fsSelection = d.u16(os2 + 62)
            italic = italic || fsSelection & 1 != 0
            if fsSelection & 0x80 != 0 {
                // USE_TYPO_METRICS: the typographic values are the line metrics.
                asc = Int(d.i16(os2 + 68))
                desc = -Int(d.i16(os2 + 70))
                gap = Int(d.i16(os2 + 72))
            }
            if v >= 2 {
                xh = Int(d.i16(os2 + 86))
                cap = Int(d.i16(os2 + 88))
            }
        }
        ascender = asc
        descender = desc
        lineGap = gap
        capHeight = cap
        xHeight = xh
        let mono = tables["post"].map { d.u32($0.offset + 12) != 0 } ?? false
        traits = FontTraits(weight: weight, width: width, isItalic: italic, isMonospaced: mono)

        let names = tables["name"].map { NameTable(d, at: $0.offset) } ?? NameTable()
        familyName = names.string(16) ?? names.string(1) ?? "Unknown"
        styleName = names.string(17) ?? names.string(2) ?? "Regular"
        postScriptName = names.string(6) ?? familyName

        cmap = tables["cmap"].map { CharacterMap(d, at: $0.offset) } ?? CharacterMap()
        kernPairs = tables["kern"].map { OpenTypeFace.readKern(d, at: $0.offset) } ?? [:]
        gposKern = tables["GPOS"].map { OpenTypeFace.readGPOSKern(d, at: $0.offset) } ?? []
    }

    // MARK: FontFace

    public func lineMetrics(size: Double) -> LineMetrics {
        let s = size / Double(unitsPerEm)
        return LineMetrics(ascent: Double(ascender) * s, descent: Double(descender) * s,
                           leading: Double(lineGap) * s, capHeight: Double(capHeight) * s,
                           xHeight: Double(xHeight) * s)
    }

    public func glyph(for scalar: Unicode.Scalar) -> GlyphID? {
        let g = cmap.glyph(scalar.value)
        return g == 0 ? nil : g
    }

    /// Advance in font units.
    public func advanceUnits(of glyph: GlyphID) -> Int {
        guard !advances.isEmpty else { return 0 }
        return Int(advances[min(Int(glyph), advances.count - 1)])
    }

    public func advance(of glyph: GlyphID, size: Double) -> Double {
        Double(advanceUnits(of: glyph)) * size / Double(unitsPerEm)
    }

    /// Kerning in font units (GPOS `kern` feature, else the `kern` table).
    public func kerningUnits(_ left: GlyphID, _ right: GlyphID) -> Int {
        let key = UInt64(left) << 32 | UInt64(right)
        if let v = kernCache.withLock({ $0[key] }) { return Int(v) }
        var v = 0
        if !gposKern.isEmpty {
            for lookup in gposKern { v += lookup.value(data, left, right) }
        } else if let k = kernPairs[UInt32(left & 0xFFFF) << 16 | UInt32(right & 0xFFFF)] {
            v = Int(k)
        }
        kernCache.withLock { $0[key] = Int32(v) }
        return v
    }

    public func kerning(_ left: GlyphID, _ right: GlyphID, size: Double) -> Double {
        Double(kerningUnits(left, right)) * size / Double(unitsPerEm)
    }

    // MARK: kern table (format 0)

    private static func readKern(_ d: FontBytes, at o: Int) -> [UInt32: Int16] {
        var pairs: [UInt32: Int16] = [:]
        guard d.u16(o) == 0 else { return pairs } // Microsoft version 0 only
        var p = o + 4
        for _ in 0..<Int(d.u16(o + 2)) {
            let length = Int(d.u16(p + 2)), coverage = d.u16(p + 4)
            let format = coverage >> 8, horizontal = coverage & 1 != 0, minimum = coverage & 2 != 0
            if format == 0 && horizontal && !minimum {
                let n = Int(d.u16(p + 6))
                for i in 0..<n {
                    let r = p + 14 + 6 * i
                    pairs[UInt32(d.u16(r)) << 16 | UInt32(d.u16(r + 2))] = d.i16(r + 4)
                }
            }
            p += max(length, 6)
        }
        return pairs
    }

    // MARK: GPOS pair adjustment (kern feature)

    private static func readGPOSKern(_ d: FontBytes, at g: Int) -> [PairAdjustment] {
        let featureList = g + Int(d.u16(g + 6)), lookupList = g + Int(d.u16(g + 8))
        var lookupIndices = Set<Int>()
        for i in 0..<Int(d.u16(featureList)) {
            let r = featureList + 2 + 6 * i
            guard d.tag(r) == "kern" else { continue }
            let f = featureList + Int(d.u16(r + 4))
            for j in 0..<Int(d.u16(f + 2)) { lookupIndices.insert(Int(d.u16(f + 4 + 2 * j))) }
        }
        var result: [PairAdjustment] = []
        let lookupCount = Int(d.u16(lookupList))
        for li in lookupIndices.sorted() where li < lookupCount {
            let l = lookupList + Int(d.u16(lookupList + 2 + 2 * li))
            var type = d.u16(l)
            var subtables: [Int] = []
            for s in 0..<Int(d.u16(l + 4)) {
                var st = l + Int(d.u16(l + 6 + 2 * s))
                if type == 9 { // extension
                    let extType = d.u16(st + 2)
                    st += Int(d.u32(st + 4))
                    type = extType
                    if extType != 2 { continue }
                }
                if type == 2 { subtables.append(st) }
            }
            if !subtables.isEmpty { result.append(PairAdjustment(subtables: subtables)) }
        }
        return result
    }
}

/// One GPOS lookup of type 2 (pair adjustment): the first subtable that
/// covers the left glyph decides.
struct PairAdjustment {
    let subtables: [Int]

    func value(_ d: FontBytes, _ left: GlyphID, _ right: GlyphID) -> Int {
        for st in subtables {
            let format = d.u16(st)
            guard let covIndex = coverageIndex(d, st + Int(d.u16(st + 2)), left) else { continue }
            let vf1 = d.u16(st + 4), vf2 = d.u16(st + 6)
            let size1 = valueRecordSize(vf1), size2 = valueRecordSize(vf2)
            if format == 1 {
                let count = Int(d.u16(st + 8))
                guard covIndex < count else { continue }
                let set = st + Int(d.u16(st + 10 + 2 * covIndex))
                let n = Int(d.u16(set)), rec = 2 + size1 + size2
                // Binary search on the second glyph.
                var lo = 0, hi = n - 1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    let r = set + 2 + mid * rec
                    let g = GlyphID(d.u16(r))
                    if g == right { return xAdvance(d, r + 2, vf1) }
                    if g < right { lo = mid + 1 } else { hi = mid - 1 }
                }
                continue
            } else if format == 2 {
                let c1 = classOf(d, st + Int(d.u16(st + 8)), left)
                let c2 = classOf(d, st + Int(d.u16(st + 10)), right)
                let n1 = Int(d.u16(st + 12)), n2 = Int(d.u16(st + 14))
                guard c1 < n1, c2 < n2 else { return 0 }
                let r = st + 16 + (c1 * n2 + c2) * (size1 + size2)
                return xAdvance(d, r, vf1)
            }
        }
        return 0
    }

    private func valueRecordSize(_ f: UInt16) -> Int { 2 * f.nonzeroBitCount }

    private func xAdvance(_ d: FontBytes, _ r: Int, _ f: UInt16) -> Int {
        guard f & 0x4 != 0 else { return 0 }
        return Int(d.i16(r + 2 * (f & 0x3).nonzeroBitCount))
    }

    private func coverageIndex(_ d: FontBytes, _ c: Int, _ glyph: GlyphID) -> Int? {
        let format = d.u16(c), n = Int(d.u16(c + 2))
        var lo = 0, hi = n - 1
        if format == 1 {
            while lo <= hi {
                let mid = (lo + hi) / 2
                let g = GlyphID(d.u16(c + 4 + 2 * mid))
                if g == glyph { return mid }
                if g < glyph { lo = mid + 1 } else { hi = mid - 1 }
            }
        } else if format == 2 {
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = c + 4 + 6 * mid
                let start = GlyphID(d.u16(r)), end = GlyphID(d.u16(r + 2))
                if glyph < start { hi = mid - 1 } else if glyph > end { lo = mid + 1 } else {
                    return Int(d.u16(r + 4)) + Int(glyph - start)
                }
            }
        }
        return nil
    }

    private func classOf(_ d: FontBytes, _ c: Int, _ glyph: GlyphID) -> Int {
        let format = d.u16(c)
        if format == 1 {
            let start = GlyphID(d.u16(c + 2)), n = GlyphID(d.u16(c + 4))
            guard glyph >= start, glyph < start + n else { return 0 }
            return Int(d.u16(c + 6 + 2 * Int(glyph - start)))
        } else if format == 2 {
            var lo = 0, hi = Int(d.u16(c + 2)) - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = c + 4 + 6 * mid
                let start = GlyphID(d.u16(r)), end = GlyphID(d.u16(r + 2))
                if glyph < start { hi = mid - 1 } else if glyph > end { lo = mid + 1 } else { return Int(d.u16(r + 4)) }
            }
        }
        return 0
    }
}

/// Character → glyph mapping from the `cmap` table (formats 4 and 12).
struct CharacterMap {
    private struct Segment { let start: UInt32, end: UInt32, compute: (UInt32) -> GlyphID }
    private var segments: [Segment] = []

    init() {}

    init(_ d: FontBytes, at o: Int) {
        var best: (rank: Int, offset: Int)?
        for i in 0..<Int(d.u16(o + 2)) {
            let r = o + 4 + 8 * i
            let pid = d.u16(r), eid = d.u16(r + 2), sub = o + Int(d.u32(r + 4))
            let format = d.u16(sub)
            let rank: Int
            switch (pid, eid, format) {
            case (3, 10, 12), (0, 4, 12), (0, 6, 12): rank = 4
            case (3, 1, 4), (0, 3, 4), (0, 1, 4), (0, 0, 4): rank = 3
            case (3, 0, 4): rank = 1
            default: rank = 0
            }
            if rank > 0, rank > (best?.rank ?? 0) { best = (rank, sub) }
        }
        guard let sub = best?.offset else { return }
        let bytes = d
        if d.u16(sub) == 12 {
            let n = Int(d.u32(sub + 12))
            for i in 0..<n {
                let r = sub + 16 + 12 * i
                let start = d.u32(r), end = d.u32(r + 4), glyph = d.u32(r + 8)
                guard end >= start else { continue }
                segments.append(Segment(start: start, end: end, compute: { glyph + ($0 - start) }))
            }
        } else {
            let segX2 = Int(d.u16(sub + 6)), n = segX2 / 2
            let ends = sub + 14, starts = ends + segX2 + 2, deltas = starts + segX2, ranges = deltas + segX2
            for s in 0..<n {
                let end = UInt32(d.u16(ends + 2 * s)), start = UInt32(d.u16(starts + 2 * s))
                guard end >= start, start != 0xFFFF else { continue }
                let delta = UInt32(d.u16(deltas + 2 * s))
                let rangeOffset = Int(d.u16(ranges + 2 * s))
                let rangeAt = ranges + 2 * s
                if rangeOffset == 0 {
                    segments.append(Segment(start: start, end: end, compute: { ($0 &+ delta) & 0xFFFF }))
                } else {
                    segments.append(Segment(start: start, end: end, compute: { c in
                        let g = UInt32(bytes.u16(rangeAt + rangeOffset + 2 * Int(c - start)))
                        return g == 0 ? 0 : (g &+ delta) & 0xFFFF
                    }))
                }
            }
        }
        segments.sort { $0.start < $1.start }
    }

    func glyph(_ c: UInt32) -> GlyphID {
        var lo = 0, hi = segments.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = segments[mid]
            if c < s.start { hi = mid - 1 } else if c > s.end { lo = mid + 1 } else { return s.compute(c) }
        }
        return 0
    }
}

/// Strings of the `name` table.
struct NameTable {
    private var strings: [Int: String] = [:]

    init() {}

    init(_ d: FontBytes, at o: Int) {
        let count = Int(d.u16(o + 2)), storage = o + Int(d.u16(o + 4))
        var ranks: [Int: Int] = [:]
        for i in 0..<count {
            let r = o + 6 + 12 * i
            let pid = d.u16(r), eid = d.u16(r + 2), lang = d.u16(r + 4), nid = Int(d.u16(r + 6))
            let len = Int(d.u16(r + 8)), off = storage + Int(d.u16(r + 10))
            guard d.contains(off, len) else { continue }
            let raw = Array(d.bytes[off..<off + len])
            let s: String
            let rank: Int
            if pid == 3 || pid == 0 {
                var units: [UInt16] = []
                for k in stride(from: 0, to: raw.count - 1, by: 2) { units.append(UInt16(raw[k]) << 8 | UInt16(raw[k + 1])) }
                s = String(decoding: units, as: UTF16.self)
                rank = (pid == 3 && eid == 1 && lang == 0x409) ? 3 : 2
            } else if pid == 1 && eid == 0 {
                s = String(decoding: raw.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
                rank = 1
            } else { continue }
            if rank > (ranks[nid] ?? 0) {
                ranks[nid] = rank
                strings[nid] = s
            }
        }
    }

    func string(_ id: Int) -> String? { strings[id].flatMap { $0.isEmpty ? nil : $0 } }
}
