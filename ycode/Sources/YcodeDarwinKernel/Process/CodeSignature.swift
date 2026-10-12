import Foundation
import YcodeDarwinABI

// `executable_cdhash=` and `executable_boothash=` in `apple[]`
// (`specs/simulator/darwin-process-start.md` §1.4 rows 9–10). The kernel
// provides them when the executable has a code signature. libmalloc's xzone
// allocator requires `executable_boothash` in processes it treats as security
// critical (launchd_sim among them) and aborts at its first allocation
// without it. Owner: agent P.
//
// File format (xnu `osfmk/kern/cs_blobs.h`, public): `LC_CODE_SIGNATURE`
// (0x1D) gives the offset and size of an embedded-signature SuperBlob
// (magic 0xFADE0CC0, big-endian `{magic, length, count}` then `count`
// `{type, offset}` index entries). Slot 0 and slots 0x1000…0x1004 hold
// CodeDirectories (magic 0xFADE0C02, `length` at +4, `hashType` at +37). The
// CDHash is the CodeDirectory's own hash (its `hashType`), truncated to 20
// bytes; the kernel uses the CodeDirectory with the strongest hash type.

enum CodeSignature {
    /// The 20-byte CDHash of the arm64 image in `hostPath`, or nil (no
    /// signature, or only hash types Ycode does not compute).
    static func cdHash(ofExecutableAt hostPath: String) -> [UInt8]? {
        guard let handle = FileHandle(forReadingAtPath: hostPath) else { return nil }
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) -> [UInt8] {
            guard count > 0, (try? handle.seek(toOffset: offset)) != nil else { return [] }
            return Array((try? handle.read(upToCount: count)) ?? Data())
        }
        func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
            UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
        }
        var slice: UInt64 = 0
        let head = read(0, 4096)
        guard head.count >= 32 else { return nil }
        let fat = be32(head, 0)
        if fat == 0xCAFE_BABE || fat == 0xCAFE_BABF {
            let is64 = fat == 0xCAFE_BABF, entry = is64 ? 32 : 20
            let n = Int(be32(head, 4))
            guard n > 0, n < 64, head.count >= 8 + n * entry else { return nil }
            var found: UInt64?
            for i in 0..<n where be32(head, 8 + i * entry) == 0x0100_000C {
                let o = 8 + i * entry
                found = is64 ? UInt64(be32(head, o + 8)) << 32 | UInt64(be32(head, o + 12)) : UInt64(be32(head, o + 8))
                break
            }
            guard let found else { return nil }
            slice = found
        }
        let header = slice == 0 ? head : read(slice, 32)
        guard header.count >= 32, header.readLE(UInt32.self, at: 0) == 0xFEED_FACF else { return nil }
        let ncmds = Int(header.readLE(UInt32.self, at: 16)), sizeofcmds = Int(header.readLE(UInt32.self, at: 20))
        guard sizeofcmds > 0, sizeofcmds <= 1 << 20 else { return nil }
        let commands = read(slice + 32, sizeofcmds)
        var at = 0
        var signature: (offset: UInt64, size: Int)?
        for _ in 0..<ncmds {
            guard at + 8 <= commands.count else { break }
            let cmd = commands.readLE(UInt32.self, at: at), size = Int(commands.readLE(UInt32.self, at: at + 4))
            if cmd == 0x1D, at + 16 <= commands.count {
                signature = (UInt64(commands.readLE(UInt32.self, at: at + 8)), Int(commands.readLE(UInt32.self, at: at + 12)))
            }
            guard size >= 8 else { break }
            at += size
        }
        guard let signature, signature.size >= 12, signature.size <= 16 << 20 else { return nil }
        let blob = read(slice + signature.offset, signature.size)
        guard blob.count == signature.size, be32(blob, 0) == 0xFADE_0CC0 else { return nil }
        let count = Int(be32(blob, 8))
        guard count < 64, 12 + count * 8 <= blob.count else { return nil }
        // The strongest hash type Ycode can compute: SHA-256 (2) and
        // truncated SHA-256 (3) rank above SHA-1 (1).
        let rank: [UInt8: Int] = [1: 1, 3: 2, 2: 3]
        var best: (rank: Int, bytes: ArraySlice<UInt8>, type: UInt8)?
        for i in 0..<count {
            let type = be32(blob, 12 + i * 8), offset = Int(be32(blob, 16 + i * 8))
            guard type == 0 || (0x1000...0x1004).contains(type), offset + 40 <= blob.count,
                  be32(blob, offset) == 0xFADE_0C02 else { continue }
            let length = Int(be32(blob, offset + 4))
            guard length >= 40, offset + length <= blob.count else { continue }
            let hashType = blob[offset + 37]
            guard let r = rank[hashType], r > (best?.rank ?? 0) else { continue }
            best = (r, blob[offset..<(offset + length)], hashType)
        }
        guard let best else { return nil }
        let digest = best.type == 1 ? SHA1Digest.hash(Array(best.bytes)) : SHA256Digest.hash(Array(best.bytes))
        return Array(digest.prefix(20))
    }

    /// `executable_cdhash=` and `executable_boothash=` for an image, or
    /// nothing when it has no usable signature.
    static func appleStrings(hostPath: String, bootSalt: UInt32, bootSessionUUID: String) -> [String] {
        guard let cd = cdHash(ofExecutableAt: hostPath) else { return [] }
        var input: [UInt8] = []
        input.appendLE(bootSalt)
        var uuid = Array(bootSessionUUID.utf8.prefix(36))
        uuid += [UInt8](repeating: 0, count: 37 - uuid.count)
        input += uuid + cd
        let boot = SHA256Digest.hash(input).prefix(20)
        return ["executable_cdhash=" + hexString(cd), "executable_boothash=" + hexString(Array(boot))]
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// SHA-256 (FIPS 180-4).
enum SHA256Digest {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let o = chunk + 4 * i
                w[i] = UInt32(data[o]) << 24 | UInt32(data[o + 1]) << 16 | UInt32(data[o + 2]) << 8 | UInt32(data[o + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            for (i, v) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ v }
        }
        return h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32($0))) } }
    }
}

/// SHA-1 (FIPS 180-4), for CodeDirectories that only carry SHA-1.
enum SHA1Digest {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let o = chunk + 4 * i
                w[i] = UInt32(data[o]) << 24 | UInt32(data[o + 1]) << 16 | UInt32(data[o + 2]) << 8 | UInt32(data[o + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32) = switch i {
                case 0..<20: ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (b ^ c ^ d, 0xCA62C1D6)
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, rotl(b, 30), a, t)
            }
            for (i, v) in [a, b, c, d, e].enumerated() { h[i] = h[i] &+ v }
        }
        return h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32($0))) } }
    }
}
