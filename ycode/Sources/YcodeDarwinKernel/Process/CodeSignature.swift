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
        guard let blob = superBlob(ofExecutableAt: hostPath) else { return nil }
        return cdHash(superBlob: blob)
    }

    /// The embedded-signature SuperBlob of the arm64 image in `hostPath`.
    static func superBlob(ofExecutableAt hostPath: String) -> [UInt8]? {
        signatureParts(ofExecutableAt: hostPath).superBlob
    }

    /// The SuperBlob and the `__TEXT,__entitlements` section (simulator
    /// builds carry their entitlements there, as an XML plist;
    /// app-install-launch.md §4.5) of the arm64 image in `hostPath`.
    static func signatureParts(ofExecutableAt hostPath: String) -> (superBlob: [UInt8]?, entitlements: [UInt8]?) {
        guard let handle = FileHandle(forReadingAtPath: hostPath) else { return (nil, nil) }
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
        guard head.count >= 32 else { return (nil, nil) }
        let fat = be32(head, 0)
        if fat == 0xCAFE_BABE || fat == 0xCAFE_BABF {
            let is64 = fat == 0xCAFE_BABF, entry = is64 ? 32 : 20
            let n = Int(be32(head, 4))
            guard n > 0, n < 64, head.count >= 8 + n * entry else { return (nil, nil) }
            var found: UInt64?
            for i in 0..<n where be32(head, 8 + i * entry) == 0x0100_000C {
                let o = 8 + i * entry
                found = is64 ? UInt64(be32(head, o + 8)) << 32 | UInt64(be32(head, o + 12)) : UInt64(be32(head, o + 8))
                break
            }
            guard let found else { return (nil, nil) }
            slice = found
        }
        let header = slice == 0 ? head : read(slice, 32)
        guard header.count >= 32, header.readLE(UInt32.self, at: 0) == 0xFEED_FACF else { return (nil, nil) }
        let ncmds = Int(header.readLE(UInt32.self, at: 16)), sizeofcmds = Int(header.readLE(UInt32.self, at: 20))
        guard sizeofcmds > 0, sizeofcmds <= 1 << 20 else { return (nil, nil) }
        let commands = read(slice + 32, sizeofcmds)
        var at = 0
        var signature: (offset: UInt64, size: Int)?
        var section: (offset: UInt64, size: Int)?
        func name(_ o: Int) -> String {
            String(decoding: commands[o..<(o + 16)].prefix { $0 != 0 }, as: UTF8.self)
        }
        for _ in 0..<ncmds {
            guard at + 8 <= commands.count else { break }
            let cmd = commands.readLE(UInt32.self, at: at), size = Int(commands.readLE(UInt32.self, at: at + 4))
            if cmd == 0x1D, at + 16 <= commands.count {
                signature = (UInt64(commands.readLE(UInt32.self, at: at + 8)), Int(commands.readLE(UInt32.self, at: at + 12)))
            }
            // LC_SEGMENT_64 __TEXT: section_64 records of 80 bytes after the
            // 72-byte command (sectname, segname, addr, size, offset, …).
            if cmd == 0x19, at + 72 <= commands.count, name(at + 8) == "__TEXT" {
                let nsects = Int(commands.readLE(UInt32.self, at: at + 64))
                for i in 0..<nsects {
                    let o = at + 72 + 80 * i
                    guard o + 80 <= commands.count else { break }
                    if name(o) == "__entitlements" {
                        section = (UInt64(commands.readLE(UInt32.self, at: o + 48)), Int(commands.readLE(UInt64.self, at: o + 40)))
                    }
                }
            }
            guard size >= 8 else { break }
            at += size
        }
        var entitlements: [UInt8]?
        if let section, section.size > 0, section.size <= 1 << 20 {
            let bytes = read(slice + section.offset, section.size)
            if bytes.count == section.size { entitlements = bytes }
        }
        guard let signature, signature.size >= 12, signature.size <= 16 << 20 else { return (nil, entitlements) }
        let blob = read(slice + signature.offset, signature.size)
        guard blob.count == signature.size, be32(blob, 0) == 0xFADE_0CC0 else { return (nil, entitlements) }
        return (blob, entitlements)
    }

    static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    /// The CDHash of a SuperBlob (see the file comment).
    static func cdHash(superBlob blob: [UInt8]) -> [UInt8]? {
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

/// What `csops` reports about an image (stage 6). Parsed from the embedded
/// signature (xnu `osfmk/kern/cs_blobs.h`, public: CodeDirectory `flags`
/// @12, `identOffset` @20, `platform` @38, `teamOffset` @48 from version
/// 0x20200; entitlements slot 5 (magic 0xFADE7171, XML) and slot 7 (magic
/// 0xFADE7172, DER)). The status words are those the simulator's processes
/// show on the Mac (level 3, our own csops probe): a platform binary
/// 0x26004201 (CS_SIGNED | CS_PLATFORM_BINARY | CS_DYLD_PLATFORM |
/// CS_ENTITLEMENTS_VALIDATED | CS_KILL | CS_VALID), another signed image
/// 0x22000201 plus CS_LINKER_SIGNED when the CodeDirectory says so;
/// validation category 1 (platform) or 10 (another signed image).
struct CodeSigningInfo {
    var status: UInt32
    var identity: String?
    var teamID: String?
    var cdHash: [UInt8]
    var entitlements: [UInt8]?
    var derEntitlements: [UInt8]?
    var validationCategory: UInt32
    var signature: [UInt8]

    private static let cacheLock = RecursiveMutex(name: "code signature cache")
    nonisolated(unsafe) private static var cache: [String: CodeSigningInfo?] = [:]
    nonisolated(unsafe) private static var platformRoots: [String] = []

    /// Host directories whose executables are platform binaries. On the Mac
    /// every executable of the simulator runtime reports 0x26004201 although
    /// its CodeDirectory's `platform` byte is 0 (level 3: our `csprobe` of
    /// runningboardd, SpringBoard, backboardd and launchd_sim; the runtime
    /// image's code is trusted as the system's). With the status of an
    /// ordinary Apple-signed image (0x22000201) launchd_sim did not honor
    /// runningboardd's launchd entitlements (`com.apple.private.xpc.launchd.*`):
    /// runningboardd could not learn which job a process belongs to, named
    /// every daemon `anon<…>` and refused SpringBoard's launch requests
    /// (level 3; home-screen.md §3.4).
    static func setPlatformRoots(_ roots: [String]) {
        cacheLock.lock()
        platformRoots = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        cache.removeAll()
        cacheLock.unlock()
    }

    /// The image's signing information (cached per host path), or nil when
    /// it has no usable signature.
    static func of(hostPath: String) -> CodeSigningInfo? {
        cacheLock.lock()
        if let hit = cache[hostPath] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let parts = CodeSignature.signatureParts(ofExecutableAt: hostPath)
        var info = parts.superBlob.flatMap(parse)
        cacheLock.lock()
        let trusted = platformRoots.contains { hostPath.hasPrefix($0) }
        cacheLock.unlock()
        if trusted, info != nil {
            info?.status = 0x2600_4201
            info?.validationCategory = 1
        }
        // Simulator builds: the `__TEXT,__entitlements` plist is what the
        // simulator's libraries serve as the entitlements blob (op 7), with an
        // 8-byte blob header (app-install-launch.md §4.5; level 3).
        if let xml = parts.entitlements, info != nil {
            var blob: [UInt8] = []
            for v in [UInt32(0xFADE_7171), UInt32(xml.count + 8)] {
                blob += [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
            }
            info?.entitlements = blob + xml
        }
        cacheLock.lock()
        cache[hostPath] = info
        cacheLock.unlock()
        return info
    }

    static func parse(_ blob: [UInt8]) -> CodeSigningInfo? {
        let be32 = CodeSignature.be32
        guard let cd = CodeSignature.cdHash(superBlob: blob) else { return nil }
        let count = Int(be32(blob, 8))
        var slots: [UInt32: ArraySlice<UInt8>] = [:]
        for i in 0..<count {
            let type = be32(blob, 12 + i * 8), offset = Int(be32(blob, 16 + i * 8))
            guard offset + 8 <= blob.count else { continue }
            let length = Int(be32(blob, offset + 4))
            guard length >= 8, offset + length <= blob.count else { continue }
            slots[type] = blob[offset..<(offset + length)]
        }
        guard let dirSlice = slots[0], be32(Array(dirSlice), 0) == 0xFADE_0C02 else { return nil }
        let dir = Array(dirSlice)
        func string(at offset: Int) -> String? {
            guard offset > 0, offset < dir.count else { return nil }
            let bytes = dir[offset...].prefix { $0 != 0 }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
        let version = be32(dir, 8), flags = be32(dir, 12)
        let platform = dir.count > 38 ? dir[38] : 0
        let team = version >= 0x20200 && dir.count >= 52 ? string(at: Int(be32(dir, 48))) : nil
        let status: UInt32 = platform != 0 ? 0x2600_4201 : 0x2200_0201 | (flags & 0x2_0000)
        let xml = slots[5].flatMap { be32(Array($0), 0) == 0xFADE_7171 ? Array($0) : nil }
        let der = slots[7].flatMap { be32(Array($0), 0) == 0xFADE_7172 ? Array($0) : nil }
        return CodeSigningInfo(status: status, identity: string(at: Int(be32(dir, 20))), teamID: team, cdHash: cd,
                               entitlements: xml, derEntitlements: der,
                               validationCategory: platform != 0 ? 1 : 10, signature: blob)
    }
}

extension DarwinKernel {
    /// Executables below these host directories report the platform-binary
    /// code-signing status (`CodeSigningInfo.setPlatformRoots`).
    public static func setPlatformCodeRoots(_ roots: [String]) {
        CodeSigningInfo.setPlatformRoots(roots)
    }

    /// csops (169) / csops_audittoken (170), after xnu `bsd/kern/kern_proc.c`
    /// csops_internal (level 1): pid 0 is the caller; another pid must exist
    /// (ESRCH) and, with an audit token, match its pid (word 5) and
    /// pidversion (word 7) (ESRCH); STATUS, CDHASH, PIDOFFSET, the
    /// entitlement blobs, BLOB, IDENTITY, TEAMID, and VALIDATION_CATEGORY
    /// may target any process, the others only the caller (EPERM).
    func csopsCall(_ withToken: Bool, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let requested = Int32(truncatingIfNeeded: a[0]), ops = UInt32(truncatingIfNeeded: a[1])
        let addr = a[2], size = a[3]
        let targetPID = requested == 0 ? pid : requested
        let target: DarwinKernel
        if targetPID == pid {
            target = self
        } else {
            guard let other = system.processRecord(targetPID)?.kernel else { throw Failure(errno: Errno.ESRCH) }
            target = other
        }
        if withToken {
            guard a[4] != 0 else { throw Failure(errno: Errno.EINVAL) }
            let token = try mem.read(va: a[4], count: 32)
            guard token.readLE(Int32.self, at: 20) == targetPID, token.readLE(UInt32.self, at: 28) == target.pidVersion else {
                throw Failure(errno: Errno.ESRCH)
            }
        }
        let anyone: Set<UInt32> = [0, 5, 6, 7, 10, 11, 14, 15, 16, 17]
        guard targetPID == pid || anyone.contains(ops) else { throw Failure(errno: Errno.EPERM) }
        let info = target.executableHostPath.flatMap(CodeSigningInfo.of)
        let valid = (info?.status ?? 0) & 0x1 != 0
        call += " [\(info?.identity ?? "unsigned")]"
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
        // xnu csops_copy_token: a missing blob is an 8-byte zero header; a
        // short buffer gets the blob's length in a header and ERANGE.
        func copyBlob(_ blob: [UInt8]?) throws -> UInt64 {
            guard size >= 8 else { throw Failure(errno: Errno.ERANGE) }
            guard let blob else { try mem.write(va: addr, bytes: [UInt8](repeating: 0, count: 8)); return 0 }
            if size < UInt64(blob.count) {
                try mem.write(va: addr, bytes: Array(blob.prefix(4)) + be32(UInt32(blob.count)))
                throw Failure(errno: Errno.ERANGE)
            }
            try mem.write(va: addr, bytes: blob)
            return 0
        }
        switch ops {
        case 0:  // CS_OPS_STATUS
            if addr != 0 {
                var b: [UInt8] = []
                b.appendLE(info?.status ?? 0)
                try mem.write(va: addr, bytes: Array(b.prefix(Int(min(size, 4)))))
            }
            return 0
        case 1, 2, 3, 8, 12:  // MARKINVALID, MARKHARD, MARKKILL, MARKRESTRICT, CLEARINSTALLER
            if ops == 2 && !valid { throw Failure(errno: Errno.EINVAL) }
            return 0
        case 5:  // CS_OPS_CDHASH
            guard let info, size == 20 else { throw Failure(errno: Errno.EINVAL) }
            try mem.write(va: addr, bytes: info.cdHash)
            return 0
        case 6:  // CS_OPS_PIDOFFSET
            try mem.write(va: addr, bytes: [UInt8](repeating: 0, count: 8))
            return 0
        case 7, 10, 16:  // ENTITLEMENTS_BLOB, BLOB, DER_ENTITLEMENTS_BLOB
            guard valid, let info else { throw Failure(errno: Errno.EINVAL) }
            return try copyBlob(ops == 7 ? info.entitlements : ops == 10 ? info.signature : info.derEntitlements)
        case 11, 14:  // CS_OPS_IDENTITY, CS_OPS_TEAMID
            guard size >= 8 else { throw Failure(errno: Errno.ERANGE) }
            guard valid, let info else { throw Failure(errno: Errno.EINVAL) }
            guard let text = ops == 11 ? info.identity : info.teamID else { throw Failure(errno: Errno.ENOENT) }
            let bytes = Array(text.utf8) + [0]
            // A buffer short of the whole string gets the header and ERANGE
            // (also exactly 8 bytes; level 3, the Mac's simulator).
            try mem.write(va: addr, bytes: [0, 0, 0, 0] + be32(UInt32(bytes.count + 8)))
            guard size >= UInt64(bytes.count + 8) else { throw Failure(errno: Errno.ERANGE) }
            try mem.write(va: addr + 8, bytes: bytes)
            return 0
        case 9:  // CS_OPS_SET_STATUS
            guard size >= 4 else { throw Failure(errno: Errno.ERANGE) }
            guard valid else { throw Failure(errno: Errno.EINVAL) }
            return 0
        case 13, 15:  // CLEARPLATFORM, CLEAR_LV: not on this platform
            throw Failure(errno: targetPID == pid ? Errno.ENOTSUP : Errno.EPERM)
        case 17:  // CS_OPS_VALIDATION_CATEGORY
            var b: [UInt8] = []
            b.appendLE(info?.validationCategory ?? 0)
            try mem.write(va: addr, bytes: b)
            return 0
        default:
            throw Failure(errno: Errno.EINVAL)
        }
    }
}
