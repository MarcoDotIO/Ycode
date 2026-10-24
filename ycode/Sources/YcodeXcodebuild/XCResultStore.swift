import Foundation

/// The object store of a `.xcresult` bundle (storage backend
/// `fileBacked2`): `Info.plist` and a `Data` directory of content-addressed
/// objects. See `specs/xcodebuild/result-bundle.md` §2–§3.
public struct XCResultStore {
    public let bundle: URL
    var data: URL { bundle.appendingPathComponent("Data") }

    /// Creates the bundle directory (it must not exist yet).
    public init(creating bundle: URL) throws {
        self.bundle = bundle
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Data"), withIntermediateDirectories: true)
    }

    /// Stores one object; returns its identifier (`0~<base64url digest>`).
    @discardableResult
    public func put(_ value: XCRValue) throws -> String {
        let payload = XCRValue.encode(value)
        let refs = Array(Set(value.referencedIDs)).sorted()
        return try putBlob(payload, refs: refs)
    }

    /// Stores a file's bytes (no references).
    public func putFile(_ bytes: [UInt8]) throws -> String { try putBlob(bytes, refs: []) }

    /// Stores a directory: a JSON listing `[{"name", "type": 1 file | 2
    /// directory}]` sorted by name, its references the entries' objects in
    /// listing order.
    public func putDirectory(_ entries: [(name: String, isDirectory: Bool, id: String)]) throws -> String {
        let sorted = entries.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
        let listing = sorted.map { ["name": $0.name, "type": $0.isDirectory ? 2 : 1] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: listing, options: [.sortedKeys, .withoutEscapingSlashes])
        return try putBlob([UInt8](data), refs: sorted.map(\.id))
    }

    /// Stores raw bytes with the given references.
    func putBlob(_ payload: [UInt8], refs: [String]) throws -> String {
        let stored = Zstd.rawFrame(payload)
        var refBytes: [UInt8] = []
        var hashed: [UInt8] = []
        for r in refs {
            guard let raw = Self.rawID(r) else { continue }
            refBytes += Self.length(raw.count) + raw
            hashed += raw
        }
        let refsFile = Self.length(refs.count) + refBytes
        let digest = BLAKE2b.digest512(hashed + stored)
        let id = "0~" + Self.base64url(digest)
        try Data(stored).write(to: data.appendingPathComponent("data." + id))
        try Data(refsFile).write(to: data.appendingPathComponent("refs." + id))
        return id
    }

    /// Writes `Info.plist` naming the root object.
    public func finish(root: String, created: Date = Date()) throws {
        let info: [String: Any] = [
            "dateCreated": created,
            "directoryImportMode": "concurrent",
            "externalLocations": [Any](),
            "rootId": ["hash": root],
            "storage": ["backend": "fileBacked2", "compression": "standard"],
            "version": ["major": 3, "minor": 60],
        ]
        let d = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try d.write(to: bundle.appendingPathComponent("Info.plist"))
    }

    /// Counts below 128 take one byte; larger ones `0x80 | n` and n
    /// big-endian bytes.
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// `0~xyz…` → the version byte followed by the digest.
    static func rawID(_ id: String) -> [UInt8]? {
        guard id.hasPrefix("0~"), let d = base64urlDecode(String(id.dropFirst(2))) else { return nil }
        return [0] + d
    }

    static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    static func base64urlDecode(_ s: String) -> [UInt8]? {
        Data(base64Encoded: s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")).map { [UInt8]($0) }
    }
}

/// A type of the result object model, with its supertypes (the names of
/// `xcresulttool formatDescription`).
public struct XCRType: Hashable, Sendable {
    /// The type first, then each supertype.
    public var chain: [String]
    public init(_ chain: String...) { self.chain = chain }
    public var name: String { chain[0] }

    public static let string = XCRType("String"), int = XCRType("Int"), bool = XCRType("Bool")
    public static let double = XCRType("Double"), date = XCRType("Date"), array = XCRType("Array")
}

/// A value of the result object model.
public indirect enum XCRValue {
    case object(XCRType, [(String, XCRValue)])
    case scalar(XCRType, String)
    case array([XCRValue])

    public static func string(_ s: String) -> XCRValue { .scalar(.string, s) }
    public static func int(_ i: Int) -> XCRValue { .scalar(.int, String(i)) }
    public static func bool(_ b: Bool) -> XCRValue { .scalar(.bool, b ? "true" : "false") }
    public static func double(_ d: Double) -> XCRValue { .scalar(.double, "\(d)") }
    public static func date(_ d: Date) -> XCRValue { .scalar(.date, dateText(d)) }

    /// A typed object; nil fields are left out.
    public static func obj(_ type: XCRType, _ fields: [String: XCRValue?]) -> XCRValue {
        .object(type, fields.compactMap { k, v in v.map { (k, $0) } })
    }

    /// `Reference` to a stored object of the given type.
    public static func reference(_ id: String, _ target: XCRType) -> XCRValue {
        .obj(XCRType("Reference"), ["id": .string(id), "targetType": typeDefinition(target.chain[...])])
    }

    /// `Reference` to a stored file or directory (no target type).
    public static func reference(_ id: String) -> XCRValue {
        .obj(XCRType("Reference"), ["id": .string(id)])
    }

    static func typeDefinition(_ chain: ArraySlice<String>) -> XCRValue {
        var fields: [String: XCRValue?] = ["name": .string(chain.first ?? "")]
        if chain.count > 1 { fields["supertype"] = typeDefinition(chain.dropFirst()) }
        return .obj(XCRType("TypeDefinition"), fields)
    }

    /// `2026-10-16T21:52:48.296-0400` (local time).
    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f.string(from: d)
    }

    /// Every `Reference` id inside the value.
    var referencedIDs: [String] {
        switch self {
        case .scalar: return []
        case .array(let items): return items.flatMap(\.referencedIDs)
        case .object(let t, let fields):
            if t.name == "Reference", case .scalar(_, let id)? = fields.first(where: { $0.0 == "id" })?.1 { return [id] }
            return fields.flatMap { $0.1.referencedIDs }
        }
    }

    /// The store's text encoding: `[` type fields `]`, keys sorted, a
    /// type spelled out (`T…`) the first time an object uses it and named
    /// (`S<n>:name`) after that; lengths count UTF-8 bytes.
    static func encode(_ v: XCRValue) -> [UInt8] {
        var out: [UInt8] = []
        var defined = Set<String>()
        encode(v, into: &out, defined: &defined)
        return out
    }

    static func counted(_ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        return Array("\(b.count):".utf8) + b
    }

    static func typeRef(_ t: XCRType, into out: inout [UInt8], defined: inout Set<String>) {
        if defined.contains(t.name) {
            out += Array("S".utf8) + counted(t.name)
            return
        }
        defined.insert(t.name)
        out += Array("T".utf8)
        typedef(t.chain[...], into: &out)
    }

    static func typedef(_ chain: ArraySlice<String>, into out: inout [UInt8]) {
        out += Array("[K2:_nV".utf8) + counted(chain.first ?? "")
        if chain.count > 1 {
            out += Array("K2:_s".utf8)
            typedef(chain.dropFirst(), into: &out)
        }
        out += Array("]".utf8)
    }

    static func encode(_ v: XCRValue, into out: inout [UInt8], defined: inout Set<String>) {
        out.append(UInt8(ascii: "["))
        switch v {
        case .scalar(let t, let s):
            typeRef(t, into: &out, defined: &defined)
            out += Array("K2:_vV".utf8) + counted(s)
        case .array(let items):
            typeRef(.array, into: &out, defined: &defined)
            for i in items { encode(i, into: &out, defined: &defined) }
        case .object(let t, let fields):
            typeRef(t, into: &out, defined: &defined)
            for (k, f) in fields.sorted(by: { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }) {
                out += Array("K".utf8) + counted(k)
                encode(f, into: &out, defined: &defined)
            }
        }
        out.append(UInt8(ascii: "]"))
    }
}

/// Zstandard frames (RFC 8878) made of raw (stored) blocks: valid input
/// for any decoder, without a compressor.
enum Zstd {
    static func rawFrame(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        // Single segment, 4-byte content size, no checksum, no dictionary.
        out.append(0xA0)
        let n = UInt32(bytes.count)
        for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: n >> (8 * UInt32(i)))) }
        let maxBlock = 128 * 1024
        var offset = 0
        repeat {
            let size = min(maxBlock, bytes.count - offset)
            let last: UInt32 = offset + size >= bytes.count ? 1 : 0
            let header = last | (0 << 1) | (UInt32(size) << 3)
            out += [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8((header >> 16) & 0xFF)]
            out += bytes[offset..<(offset + size)]
            offset += size
        } while offset < bytes.count
        return out
    }
}

/// BLAKE2b (RFC 7693) with a 64-byte digest and no key.
enum BLAKE2b {
    static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]
    static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    static func digest512(_ input: [UInt8]) -> [UInt8] {
        var h = iv
        h[0] ^= 0x0101_0000 ^ 64
        var counter: UInt64 = 0
        var offset = 0
        func compress(_ block: ArraySlice<UInt8>, last: Bool) {
            var m = [UInt64](repeating: 0, count: 16)
            for i in 0..<16 {
                var w: UInt64 = 0
                for j in 0..<8 {
                    let idx = block.startIndex + i * 8 + j
                    if idx < block.endIndex { w |= UInt64(block[idx]) << (8 * UInt64(j)) }
                }
                m[i] = w
            }
            var v = h + iv
            v[12] ^= counter
            if last { v[14] = ~v[14] }
            func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
                v[a] = v[a] &+ v[b] &+ x
                v[d] = (v[d] ^ v[a]).rotatedRight(32)
                v[c] = v[c] &+ v[d]
                v[b] = (v[b] ^ v[c]).rotatedRight(24)
                v[a] = v[a] &+ v[b] &+ y
                v[d] = (v[d] ^ v[a]).rotatedRight(16)
                v[c] = v[c] &+ v[d]
                v[b] = (v[b] ^ v[c]).rotatedRight(63)
            }
            for r in 0..<12 {
                let s = sigma[r % 10]
                g(0, 4, 8, 12, m[s[0]], m[s[1]])
                g(1, 5, 9, 13, m[s[2]], m[s[3]])
                g(2, 6, 10, 14, m[s[4]], m[s[5]])
                g(3, 7, 11, 15, m[s[6]], m[s[7]])
                g(0, 5, 10, 15, m[s[8]], m[s[9]])
                g(1, 6, 11, 12, m[s[10]], m[s[11]])
                g(2, 7, 8, 13, m[s[12]], m[s[13]])
                g(3, 4, 9, 14, m[s[14]], m[s[15]])
            }
            for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
        }
        while input.count - offset > 128 {
            counter &+= 128
            compress(input[offset..<(offset + 128)], last: false)
            offset += 128
        }
        counter &+= UInt64(input.count - offset)
        compress(input[offset...], last: true)
        var out: [UInt8] = []
        for w in h { for j in 0..<8 { out.append(UInt8(truncatingIfNeeded: w >> (8 * UInt64(j)))) } }
        return out
    }
}

/// SHA-256 (FIPS 180-4), for the argument hashes of test identifiers.
enum SHA256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ input: [UInt8]) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = input
        let bits = UInt64(input.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 { w[i] = msg[(chunk + 4 * i)..<(chunk + 4 * i + 4)].reduce(0) { $0 << 8 | UInt32($1) } }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let t1 = hh &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            h = [h[0] &+ a, h[1] &+ b, h[2] &+ c, h[3] &+ d, h[4] &+ e, h[5] &+ f, h[6] &+ g, h[7] &+ hh]
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}

extension UInt64 {
    func rotatedRight(_ n: UInt64) -> UInt64 { (self >> n) | (self << (64 - n)) }
}
