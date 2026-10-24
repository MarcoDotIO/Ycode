import Foundation

/// Binary property lists (`bplist00`) read and written with the file's
/// dictionary key order (`specs/ide/plist-editor.md`, reference-ui-5.md
/// §11.2). The format is the public one of Core Foundation's open-source
/// binary plist code: a header, the objects, an offset table and a
/// 32-byte trailer.
///
/// The writer lays objects out as Foundation's writer does, so a list
/// Foundation wrote reads and writes back byte for byte: depth-first
/// (a dictionary, then its keys, then its values; an array, then its
/// items), strings, numbers, dates and data shared by value, and every
/// Boolean occurrence emitted while references point at the first one of
/// that value.
enum BinaryPropertyList {
    static let magic = Array("bplist00".utf8)

    // MARK: Reading

    static func read(_ data: Data) throws -> PropertyListItem {
        let b = [UInt8](data)
        func fail(_ s: String) -> PropertyListDocument.ParseError { .init(description: "binary property list: \(s)") }
        guard b.count >= magic.count + 32, Array(b[0..<6]) == Array(magic[0..<6]) else { throw fail("too short") }
        let t = b.count - 32
        let offsetSize = Int(b[t + 6]), refSize = Int(b[t + 7])
        func uint(_ at: Int, _ n: Int) throws -> UInt64 {
            guard n >= 1, n <= 8, at >= 0, at + n <= b.count else { throw fail("truncated") }
            var v: UInt64 = 0
            for i in 0..<n { v = v << 8 | UInt64(b[at + i]) }
            return v
        }
        let count = Int(try uint(t + 8, 8)), top = Int(try uint(t + 16, 8)), tableAt = Int(try uint(t + 24, 8))
        guard count > 0, top < count, tableAt + count * offsetSize <= t else { throw fail("bad trailer") }
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for i in 0..<count { offsets.append(Int(try uint(tableAt + i * offsetSize, offsetSize))) }

        var depth = 0
        func length(_ marker: UInt8, at p: inout Int) throws -> Int {
            let low = Int(marker & 0x0F)
            guard low == 0x0F else { return low }
            guard p < b.count, b[p] & 0xF0 == 0x10 else { throw fail("bad length") }
            let n = 1 << Int(b[p] & 0x0F)
            let v = try uint(p + 1, n)
            p += 1 + n
            return Int(v)
        }
        func object(_ ref: Int) throws -> PropertyListItem {
            guard ref >= 0, ref < count else { throw fail("bad reference") }
            depth += 1
            defer { depth -= 1 }
            guard depth < 512 else { throw fail("nesting too deep") }
            var p = offsets[ref]
            guard p < t else { throw fail("bad offset") }
            let m = b[p]
            p += 1
            switch m >> 4 {
            case 0x0:
                switch m {
                case 0x08: return .bool(false)
                case 0x09: return .bool(true)
                default: throw fail("unsupported marker \(m)")
                }
            case 0x1:
                let n = 1 << Int(m & 0x0F)
                guard n <= 8 else { throw fail("integer too large") }
                let v = try uint(p, n)
                return .integer(n == 8 ? Int(Int64(bitPattern: v)) : Int(v))
            case 0x2:
                let n = 1 << Int(m & 0x0F)
                let v = try uint(p, n)
                if n == 4 { return .real(Double(Float(bitPattern: UInt32(v)))) }
                guard n == 8 else { throw fail("bad real") }
                return .real(Double(bitPattern: v))
            case 0x3:
                guard m == 0x33 else { throw fail("bad date") }
                return .date(Date(timeIntervalSinceReferenceDate: Double(bitPattern: try uint(p, 8))))
            case 0x4:
                let n = try length(m, at: &p)
                guard p + n <= b.count else { throw fail("truncated data") }
                return .data(Data(b[p..<(p + n)]))
            case 0x5:
                let n = try length(m, at: &p)
                guard p + n <= b.count else { throw fail("truncated string") }
                return .string(String(decoding: b[p..<(p + n)], as: UTF8.self))
            case 0x6:
                let n = try length(m, at: &p)
                guard p + 2 * n <= b.count else { throw fail("truncated string") }
                var units: [UInt16] = []
                units.reserveCapacity(n)
                for i in 0..<n { units.append(UInt16(b[p + 2 * i]) << 8 | UInt16(b[p + 2 * i + 1])) }
                return .string(String(decoding: units, as: UTF16.self))
            case 0xA:
                let n = try length(m, at: &p)
                return .array(try (0..<n).map { try object(Int(try uint(p + $0 * refSize, refSize))) })
            case 0xD:
                let n = try length(m, at: &p)
                return .dictionary(try (0..<n).map { i in
                    guard case .string(let k) = try object(Int(try uint(p + i * refSize, refSize))) else { throw fail("non-string key") }
                    return PropertyListEntry(key: k, value: try object(Int(try uint(p + (n + i) * refSize, refSize))))
                })
            default:
                throw fail("unsupported marker \(m)")
            }
        }
        return try object(top)
    }

    // MARK: Writing

    /// A value shared by the writer (strings, numbers, dates, data).
    private enum Shared: Hashable {
        case string(String), integer(Int), real(UInt64), date(UInt64), data(Data)
    }

    static func write(_ root: PropertyListItem) -> Data {
        // Flatten: the object list and each occurrence's reference.
        var objects: [PropertyListItem] = []
        var shared: [Shared: Int] = [:]
        var firstBool: [Bool: Int] = [:]
        /// References of each container's children, by object index.
        var children: [Int: [Int]] = [:]

        func flatten(_ v: PropertyListItem) -> Int {
            let key: Shared? = switch v {
            case .string(let s): .string(s)
            case .integer(let i): .integer(i)
            case .real(let r): .real(r.bitPattern)
            case .date(let d): .date(d.timeIntervalSinceReferenceDate.bitPattern)
            case .data(let d): .data(d)
            default: nil
            }
            if let key, let ref = shared[key] { return ref }
            let ref = objects.count
            objects.append(v)
            if let key { shared[key] = ref }
            switch v {
            case .bool(let x):
                // Every occurrence is emitted; references go to the first.
                if let first = firstBool[x] { return first }
                firstBool[x] = ref
            case .array(let a):
                children[ref] = a.map(flatten)
            case .dictionary(let d):
                let keys = d.map { flatten(.string($0.key)) }
                children[ref] = keys + d.map { flatten($0.value) }
            default: break
            }
            return ref
        }
        let top = flatten(root)

        let refSize = byteCount(UInt64(objects.count))
        var out = magic
        var offsets: [Int] = []
        offsets.reserveCapacity(objects.count)
        func appendUInt(_ v: UInt64, _ n: Int) {
            for i in stride(from: n - 1, through: 0, by: -1) { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
        }
        func appendInt(_ v: Int) {
            let u = UInt64(bitPattern: Int64(v))
            if u <= 0xFF { out.append(0x10); appendUInt(u, 1) }
            else if u <= 0xFFFF { out.append(0x11); appendUInt(u, 2) }
            else if u <= 0xFFFF_FFFF { out.append(0x12); appendUInt(u, 4) }
            else { out.append(0x13); appendUInt(u, 8) }
        }
        func marker(_ m: UInt8, _ n: Int) {
            if n < 15 { out.append(m | UInt8(n)) } else { out.append(m | 0x0F); appendInt(n) }
        }
        for (i, v) in objects.enumerated() {
            offsets.append(out.count)
            switch v {
            case .bool(let x): out.append(x ? 0x09 : 0x08)
            case .integer(let n): appendInt(n)
            case .real(let r): out.append(0x23); appendUInt(r.bitPattern, 8)
            case .date(let d): out.append(0x33); appendUInt(d.timeIntervalSinceReferenceDate.bitPattern, 8)
            case .data(let d): marker(0x40, d.count); out += d
            case .string(let s):
                if s.utf8.allSatisfy({ $0 < 0x80 }) {
                    marker(0x50, s.utf8.count); out += Array(s.utf8)
                } else {
                    let u = Array(s.utf16)
                    marker(0x60, u.count)
                    for c in u { appendUInt(UInt64(c), 2) }
                }
            case .array(let a):
                marker(0xA0, a.count)
                for r in children[i] ?? [] { appendUInt(UInt64(r), refSize) }
            case .dictionary(let d):
                marker(0xD0, d.count)
                for r in children[i] ?? [] { appendUInt(UInt64(r), refSize) }
            }
        }
        let tableAt = out.count
        let offsetSize = byteCount(UInt64(tableAt))
        for o in offsets { appendUInt(UInt64(o), offsetSize) }
        out += [0, 0, 0, 0, 0, 0, UInt8(offsetSize), UInt8(refSize)]
        appendUInt(UInt64(objects.count), 8)
        appendUInt(UInt64(top), 8)
        appendUInt(UInt64(tableAt), 8)
        return Data(out)
    }

    static func byteCount(_ v: UInt64) -> Int {
        v < 1 << 8 ? 1 : v < 1 << 16 ? 2 : v < 1 << 32 ? 4 : 8
    }
}
