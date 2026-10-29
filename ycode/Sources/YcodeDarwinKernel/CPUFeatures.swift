import Foundation
import YcodeDarwinABI

// CPU feature publication (specs/simulator/cpu-features.md). One feature
// set, derived from the guest vCPU's ID registers with the Arm
// architecture's field thresholds and a deny list, feeds all three places
// guest code looks: the `hw.optional.arm.caps` bytes, the
// `hw.optional.*` names and the commpage capability word.

/// The ID registers the derivation reads (§4.1). KVM_GET_ONE_REG reads all
/// but `ctr` and `dczid`, which KVM passes through and the VMM reads at EL0.
public enum IDRegister: String, CaseIterable, Sendable {
    case midr = "MIDR_EL1"
    case pfr0 = "ID_AA64PFR0_EL1"
    case pfr1 = "ID_AA64PFR1_EL1"
    case zfr0 = "ID_AA64ZFR0_EL1"
    case smfr0 = "ID_AA64SMFR0_EL1"
    case isar0 = "ID_AA64ISAR0_EL1"
    case isar1 = "ID_AA64ISAR1_EL1"
    case isar2 = "ID_AA64ISAR2_EL1"
    case mmfr0 = "ID_AA64MMFR0_EL1"
    case mmfr1 = "ID_AA64MMFR1_EL1"
    case mmfr2 = "ID_AA64MMFR2_EL1"
    case ctr = "CTR_EL0"
    case dczid = "DCZID_EL0"

    /// The system-register encoding (op0, op1, CRn, CRm, op2).
    public var encoding: (op0: UInt32, op1: UInt32, crn: UInt32, crm: UInt32, op2: UInt32) {
        switch self {
        case .midr: (3, 0, 0, 0, 0)
        case .pfr0: (3, 0, 0, 4, 0)
        case .pfr1: (3, 0, 0, 4, 1)
        case .zfr0: (3, 0, 0, 4, 4)
        case .smfr0: (3, 0, 0, 4, 5)
        case .isar0: (3, 0, 0, 6, 0)
        case .isar1: (3, 0, 0, 6, 1)
        case .isar2: (3, 0, 0, 6, 2)
        case .mmfr0: (3, 0, 0, 7, 0)
        case .mmfr1: (3, 0, 0, 7, 1)
        case .mmfr2: (3, 0, 0, 7, 2)
        case .ctr: (3, 3, 0, 0, 1)
        case .dczid: (3, 3, 0, 0, 7)
        }
    }

    /// The registers read from the vCPU (the rest come from the host's EL0).
    public static let vcpuRead: [IDRegister] = [.midr, .pfr0, .pfr1, .zfr0, .smfr0, .isar0, .isar1, .isar2, .mmfr0, .mmfr1, .mmfr2]
}

/// Values of the ID registers (a missing one reads as 0: no feature).
public struct GuestIDRegisters: Equatable, Sendable, CustomStringConvertible {
    public var values: [IDRegister: UInt64]

    public init(_ values: [IDRegister: UInt64] = [:]) { self.values = values }

    public subscript(_ r: IDRegister) -> UInt64 {
        get { values[r] ?? 0 }
        set { values[r] = newValue }
    }

    /// The unsigned 4-bit field at bits [lsb+3:lsb].
    public func field(_ r: IDRegister, _ lsb: Int) -> UInt64 { (self[r] >> UInt64(lsb)) & 0xF }

    public var description: String {
        IDRegister.allCases.filter { values[$0] != nil }
            .map { "\($0.rawValue)=0x" + String(self[$0], radix: 16) }.joined(separator: " ")
    }
}

/// Bit numbers of `hw.optional.arm.caps` (§2.3; ABI, never renumbered).
///
/// Each constant is the bit of the `FEAT_*` feature its name spells (`names`
/// gives the full list, including bits without a constant).
public enum CapsBit {
    public static let flagM = 0, flagM2 = 1, fhm = 2, dotProd = 3, sha3 = 4, rdm = 5, lse = 6, sha256 = 7
    public static let sha512 = 8, sha1 = 9, aes = 10, pmull = 11, specres = 12, sb = 13, frintts = 14, lrcpc = 15
    public static let lrcpc2 = 16, fcma = 17, jscvt = 18, pauth = 19, pauth2 = 20, fpac = 21, dpb = 22, dpb2 = 23
    public static let bf16 = 24, i8mm = 25, wfxt = 26, rpres = 27, ecv = 28, afp = 29, lse2 = 30, csv2 = 31
    public static let csv3 = 32, dit = 33, fp16 = 34, ssbs = 35, bti = 36
    public static let sme = 40, sme2 = 41
    public static let advSIMD = 49, advSIMDHPFPCvt = 50, crc32 = 51
    public static let pacimp = 58
    public static let mte = 60
    public static let hbc = 64, ebf16 = 65, specres2 = 66, cssc = 67, fpacCombine = 68
    public static let fpSyncExceptions = 73
    public static let sveB16B16 = 91

    /// `CAP_BIT_NB`: the number of bits; the vector is ⌈97 / 8⌉ = 13 bytes.
    public static let count = 97
    /// The size of the caps bit vector in bytes.
    public static let byteCount = (count + 7) / 8

    /// The `hw.optional.arm.<name>` of every bit that has a public name (§2.3).
    public static let names: [(bit: Int, name: String)] = [
        (0, "FEAT_FlagM"), (1, "FEAT_FlagM2"), (2, "FEAT_FHM"), (3, "FEAT_DotProd"), (4, "FEAT_SHA3"),
        (5, "FEAT_RDM"), (6, "FEAT_LSE"), (7, "FEAT_SHA256"), (8, "FEAT_SHA512"), (9, "FEAT_SHA1"),
        (10, "FEAT_AES"), (11, "FEAT_PMULL"), (12, "FEAT_SPECRES"), (13, "FEAT_SB"), (14, "FEAT_FRINTTS"),
        (15, "FEAT_LRCPC"), (16, "FEAT_LRCPC2"), (17, "FEAT_FCMA"), (18, "FEAT_JSCVT"), (19, "FEAT_PAuth"),
        (20, "FEAT_PAuth2"), (21, "FEAT_FPAC"), (22, "FEAT_DPB"), (23, "FEAT_DPB2"), (24, "FEAT_BF16"),
        (25, "FEAT_I8MM"), (26, "FEAT_WFxT"), (27, "FEAT_RPRES"), (28, "FEAT_ECV"), (29, "FEAT_AFP"),
        (30, "FEAT_LSE2"), (31, "FEAT_CSV2"), (32, "FEAT_CSV3"), (33, "FEAT_DIT"), (34, "FEAT_FP16"),
        (35, "FEAT_SSBS"), (36, "FEAT_BTI"),
        (40, "FEAT_SME"), (41, "FEAT_SME2"), (42, "FEAT_SME_F64F64"), (43, "FEAT_SME_I16I64"), (44, "FEAT_SME2p1"),
        (45, "FEAT_SME_F16F16"), (46, "FEAT_SME_B16B16"), (47, "FEAT_SME_F8F16"), (48, "FEAT_SME_F8F32"),
        (49, "AdvSIMD"), (50, "AdvSIMD_HPFPCvt"), (51, "FEAT_CRC32"),
        (52, "SME_F32F32"), (53, "SME_BI32I32"), (54, "SME_B16F32"), (55, "SME_F16F32"), (56, "SME_I8I32"),
        (57, "SME_I16I32"), (58, "FEAT_PACIMP"),
        (60, "FEAT_MTE"), (61, "FEAT_MTE2"), (62, "FEAT_MTE3"), (63, "FEAT_MTE4"),
        (64, "FEAT_HBC"), (65, "FEAT_EBF16"), (66, "FEAT_SPECRES2"), (67, "FEAT_CSSC"), (68, "FEAT_FPACCOMBINE"),
        (69, "FEAT_MTE_ASYNC"), (70, "FEAT_MTE_CANONICAL_TAGS"), (71, "FEAT_MTE_STORE_ONLY"),
        (72, "FEAT_MTE_NO_ADDRESS_TAGS"), (73, "FP_SyncExceptions"), (91, "FEAT_SVE_B16B16"),
    ]

    /// The public name of `bit`, or nil when the bit has none.
    public static func name(_ bit: Int) -> String? { names.first { $0.bit == bit }?.name }

    /// The deny list (§4.3): never published, whatever the ID registers say.
    public static let denied: CPUFeatureSet = {
        var s = CPUFeatureSet()
        for b in 40...48 { s.insert(b) }                       // SME
        for b in 52...57 { s.insert(b) }                       // SME_*
        for b in 60...63 { s.insert(b) }                       // MTE
        for b in 69...72 { s.insert(b) }                       // MTE_*
        for b in [pauth, pauth2, fpac, fpacCombine, pacimp] { s.insert(b) }   // pointer authentication
        s.insert(wfxt)
        s.insert(ecv)                                          // deferred until the shim decodes CNTVCTSS/CNTPCTSS
        s.insert(specres); s.insert(specres2)
        for b in [37, 38, 39, 59] { s.insert(b) }              // no public meaning
        for b in 74...90 { s.insert(b) }
        for b in 92...96 { s.insert(b) }
        s.insert(sveB16B16)                                    // the vCPU has no SVE
        return s
    }()
}

/// A set of `hw.optional.arm.caps` bits.
public struct CPUFeatureSet: Hashable, Sendable, CustomStringConvertible {
    /// Bits 0…63 and 64…127.
    public var low: UInt64 = 0
    public var high: UInt64 = 0

    public init() {}
    public init(bits: [Int]) { for b in bits { insert(b) } }

    /// The 13-byte vector: bit n is bit n % 8 of byte n / 8.
    public init(capsBytes: [UInt8]) {
        for (i, byte) in capsBytes.prefix(16).enumerated() {
            for j in 0..<8 where byte & (1 << j) != 0 { insert(8 * i + j) }
        }
    }

    public func contains(_ bit: Int) -> Bool {
        guard bit >= 0, bit < 128 else { return false }
        return bit < 64 ? low & (1 << UInt64(bit)) != 0 : high & (1 << UInt64(bit - 64)) != 0
    }

    public mutating func insert(_ bit: Int) {
        guard bit >= 0, bit < 128 else { return }
        if bit < 64 { low |= 1 << UInt64(bit) } else { high |= 1 << UInt64(bit - 64) }
    }

    public mutating func remove(_ bit: Int) {
        guard bit >= 0, bit < 128 else { return }
        if bit < 64 { low &= ~(1 << UInt64(bit)) } else { high &= ~(1 << UInt64(bit - 64)) }
    }

    public func subtracting(_ other: CPUFeatureSet) -> CPUFeatureSet {
        var s = self
        s.low &= ~other.low
        s.high &= ~other.high
        return s
    }

    public func intersection(_ other: CPUFeatureSet) -> CPUFeatureSet {
        var s = self
        s.low &= other.low
        s.high &= other.high
        return s
    }

    public func isSubset(of other: CPUFeatureSet) -> Bool { subtracting(other).isEmpty }
    public var isEmpty: Bool { low == 0 && high == 0 }
    public var bits: [Int] { (0..<128).filter(contains) }

    /// `hw.optional.arm.caps`: ⌈CAP_BIT_NB / 8⌉ = 13 bytes.
    public var capsBytes: [UInt8] {
        (0..<CapsBit.byteCount).map { i in
            let word = i < 8 ? low : high
            return UInt8(truncatingIfNeeded: word >> UInt64(8 * (i % 8)))
        }
    }

    /// 16 bytes (low then high, little-endian): the snapshot record's form.
    public var storedBytes: [UInt8] {
        var b: [UInt8] = []
        b.appendLE(low)
        b.appendLE(high)
        return b
    }

    public init(storedBytes b: [UInt8]) {
        guard b.count >= 16 else { return }
        low = b.readLE(UInt64.self, at: 0)
        high = b.readLE(UInt64.self, at: 8)
    }

    /// The names of the bits, or `bit<n>` for an unnamed one.
    public var names: [String] { bits.map { CapsBit.name($0) ?? "bit\($0)" } }

    public var description: String { capsBytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

    // MARK: Derivation (§4.2)

    /// The features the ID registers show, before the deny list.
    /// `fpcrTrapBits`: the trap-enable bits the FPCR probe read back as 1
    /// (FP_SyncExceptions needs all six).
    public static func derive(from r: GuestIDRegisters, fpcrTrapBits: UInt64) -> CPUFeatureSet {
        var s = CPUFeatureSet()
        func set(_ bit: Int, _ on: Bool) { if on { s.insert(bit) } }
        typealias C = CapsBit
        let isar0 = { (lsb: Int) in r.field(.isar0, lsb) }
        let isar1 = { (lsb: Int) in r.field(.isar1, lsb) }
        let isar2 = { (lsb: Int) in r.field(.isar2, lsb) }
        // ISAR0.
        set(C.flagM, isar0(52) >= 1); set(C.flagM2, isar0(52) >= 2)
        set(C.fhm, isar0(48) >= 1)
        set(C.dotProd, isar0(44) >= 1)
        set(C.sha3, isar0(32) >= 1)
        set(C.rdm, isar0(28) >= 1)
        set(C.lse, isar0(20) >= 2)
        set(C.crc32, isar0(16) >= 1)
        set(C.sha256, isar0(12) >= 1); set(C.sha512, isar0(12) >= 2)
        set(C.sha1, isar0(8) >= 1)
        set(C.aes, isar0(4) >= 1); set(C.pmull, isar0(4) >= 2)
        // ISAR1. SPECRES also needs SCTLR_EL1.EnRCTX, which the shim never
        // sets: it is denied below anyway.
        set(C.specres, isar1(40) >= 1); set(C.specres2, isar1(40) >= 2)
        set(C.sb, isar1(36) >= 1)
        set(C.frintts, isar1(32) >= 1)
        set(C.pacimp, isar1(28) >= 1)
        set(C.lrcpc, isar1(20) >= 1); set(C.lrcpc2, isar1(20) >= 2)
        set(C.fcma, isar1(16) >= 1)
        set(C.jscvt, isar1(12) >= 1)
        let pac = max(isar1(8), isar1(4))
        set(C.pauth, pac >= 1); set(C.pauth2, pac >= 3); set(C.fpac, pac >= 4); set(C.fpacCombine, pac >= 5)
        set(C.dpb, isar1(0) >= 1); set(C.dpb2, isar1(0) >= 2)
        set(C.bf16, isar1(44) >= 1); set(C.ebf16, isar1(44) >= 2)
        set(C.i8mm, isar1(52) >= 1)
        // ISAR2.
        set(C.wfxt, isar2(0) >= 2)
        set(C.rpres, isar2(4) >= 1)
        set(C.cssc, isar2(52) >= 1)
        set(C.hbc, isar2(20) >= 1)
        // MMFR0–2.
        set(C.ecv, r.field(.mmfr0, 60) >= 1)
        set(C.afp, r.field(.mmfr1, 44) == 1)
        set(C.lse2, r.field(.mmfr2, 32) >= 1)
        // PFR0, PFR1.
        set(C.csv3, r.field(.pfr0, 60) >= 1)
        set(C.csv2, r.field(.pfr0, 56) >= 1)
        set(C.dit, r.field(.pfr0, 48) >= 1)
        let simd = r.field(.pfr0, 20), fp = r.field(.pfr0, 16)
        set(C.advSIMD, simd != 0xF)
        set(C.advSIMDHPFPCvt, simd != 0xF)
        set(C.fp16, simd == 1 && fp == 1)
        set(C.ssbs, r.field(.pfr1, 4) >= 1)
        set(C.bti, r.field(.pfr1, 0) >= 1)
        set(C.sme, r.field(.pfr1, 24) >= 1); set(C.sme2, r.field(.pfr1, 24) >= 2)
        set(C.mte, r.field(.pfr1, 8) >= 1)
        // FPCR probe: IOE, DZE, OFE, UFE, IXE, IDE all read back as 1.
        set(C.fpSyncExceptions, fpcrTrapBits & CPUFeatureSet.fpcrTrapEnableBits == CPUFeatureSet.fpcrTrapEnableBits)
        return s
    }

    /// FPCR IOE (8), DZE (9), OFE (10), UFE (11), IXE (12), IDE (15).
    public static let fpcrTrapEnableBits: UInt64 = 0x9F00

    // MARK: Commpage (§2.5)

    /// Commpage capability masks and the caps bit each one mirrors.
    public static let commpagePairs: [(bit: Int, mask: UInt64)] = [
        (CapsBit.fp16, 0x8), (CapsBit.advSIMD, 0x100), (CapsBit.advSIMDHPFPCvt, 0x200),
        (CapsBit.fhm, 0x4000), (CapsBit.lse, 0x0200_0000), (CapsBit.crc32, 0x0400_0000), (CapsBit.sha512, 0x8000_0000),
        (CapsBit.sha3, 1 << 32), (CapsBit.fcma, 1 << 33), (CapsBit.afp, 1 << 34),
        (CapsBit.flagM, 1 << 40), (CapsBit.flagM2, 1 << 41), (CapsBit.dotProd, 1 << 42), (CapsBit.rdm, 1 << 43),
        (CapsBit.specres, 1 << 44), (CapsBit.sb, 1 << 45), (CapsBit.frintts, 1 << 46), (CapsBit.pacimp, 1 << 47),
        (CapsBit.lrcpc, 1 << 48), (CapsBit.lrcpc2, 1 << 49), (CapsBit.jscvt, 1 << 50), (CapsBit.pauth, 1 << 51),
        (CapsBit.dpb, 1 << 52), (CapsBit.dpb2, 1 << 53), (CapsBit.lse2, 1 << 54), (CapsBit.csv2, 1 << 55),
        (CapsBit.csv3, 1 << 56), (CapsBit.dit, 1 << 57), (CapsBit.fpSyncExceptions, 1 << 58),
        (CapsBit.sme, 1 << 59), (CapsBit.sme2, 1 << 60),
    ]
    /// kHasARMv8Crypto: AES, PMULL, SHA1 and SHA256 together.
    public static let commpageCrypto: UInt64 = 0x0100_0000
    /// kHasUCNormalMemory (a kernel memory-type capability; §4.4, Q4).
    public static let commpageUCNormalMemory: UInt64 = 0x800

    /// The commpage bits this set gives (no cache-line, CPU-count or kUP
    /// bits, no base bits; `CommpageBuilder` adds those).
    public var commpageBits: UInt64 {
        var w: UInt64 = 0
        for (bit, mask) in Self.commpagePairs where contains(bit) { w |= mask }
        if [CapsBit.aes, CapsBit.pmull, CapsBit.sha1, CapsBit.sha256].allSatisfy(contains) { w |= Self.commpageCrypto }
        return w
    }
}

/// The host's cache description (per core; §4.5).
public struct CacheGeometry: Equatable, Sendable {
    public var l1i: Int
    public var l1d: Int
    public var l2: Int
    /// CPUs that share one L2.
    public var cpusPerL2: Int

    public init(l1i: Int, l1d: Int, l2: Int, cpusPerL2: Int) {
        self.l1i = l1i; self.l1d = l1d; self.l2 = l2; self.cpusPerL2 = cpusPerL2
    }

    /// Used when the host does not describe its caches (64 KiB, 64 KiB, 1 MiB).
    public static let fallback = CacheGeometry(l1i: 64 << 10, l1d: 64 << 10, l2: 1 << 20, cpusPerL2: 1)

    /// Reads `<cpu>/cache/index*/{level,type,size,shared_cpu_list}` (Linux
    /// sysfs, e.g. `/sys/devices/system/cpu/cpu0`). Missing values keep the
    /// fallback's.
    public static func read(cpuDirectory: String) -> CacheGeometry {
        var g = fallback
        let fm = FileManager.default
        let base = cpuDirectory + "/cache"
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return g }
        func text(_ path: String) -> String? {
            (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for e in entries.sorted() where e.hasPrefix("index") {
            let d = base + "/" + e
            guard let level = text(d + "/level").flatMap(Int.init), let type = text(d + "/type"),
                  let size = text(d + "/size").flatMap(parseSize) else { continue }
            switch (level, type) {
            case (1, "Instruction"): g.l1i = size
            case (1, "Data"): g.l1d = size
            case (2, _):
                g.l2 = size
                if let list = text(d + "/shared_cpu_list") { g.cpusPerL2 = max(1, cpuCount(list)) }
            default: break
            }
        }
        return g
    }

    /// "64K", "1024K", "2M", "512" → bytes.
    static func parseSize(_ s: String) -> Int? {
        guard let last = s.last else { return nil }
        let scale: Int = switch last { case "K": 1 << 10; case "M": 1 << 20; case "G": 1 << 30; default: 1 }
        let digits = scale == 1 ? s : String(s.dropLast())
        return Int(digits).map { $0 * scale }
    }

    /// The number of CPUs in a list such as "0-3,8".
    static func cpuCount(_ list: String) -> Int {
        list.split(separator: ",").reduce(0) { n, part in
            let ends = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if ends.count == 2 { return n + max(0, ends[1] - ends[0] + 1) }
            return n + (ends.count == 1 ? 1 : 0)
        }
    }
}

/// What the guest is told about its CPU (§4): the feature set, and the
/// CPU values that do not depend on it. `install` it before the first
/// image (the sysctl table and the commpage read `current`).
public struct GuestCPUProfile: Equatable, Sendable {
    /// `YCODE_CPU_FEATURES`: `on` publishes the derived set, `off` the
    /// minimal one (caps all 0, no feature names, the base commpage bits).
    public enum Mode: String, Sendable {
        case off, on
        public static let defaultMode = Mode.on
        public static func fromEnvironment() -> Mode {
            guard let raw = getenv("YCODE_CPU_FEATURES") else { return defaultMode }
            return Mode(rawValue: String(cString: raw).lowercased()) ?? defaultMode
        }
    }

    public var mode: Mode
    /// The ID registers it was derived from (nil: none were read).
    public var registers: GuestIDRegisters?
    /// The features the registers show, before the deny list.
    public var derived: CPUFeatureSet
    /// `derived` minus the deny list: what this host may publish.
    public var allowed: CPUFeatureSet
    /// The coherency line size (`hw.cachelinesize`, commpage 0x026).
    public var cacheLineSize: Int
    public var caches: CacheGeometry
    /// `hw.tbfrequency`: the guest's mach timebase frequency.
    public var timebaseFrequency: UInt64
    /// `machdep.cpu.brand_string`.
    public var brand: String

    /// What the guest is told: `allowed` with the switch on, nothing off.
    public var published: CPUFeatureSet { mode == .on ? allowed : CPUFeatureSet() }

    /// Optional commpage bits beyond `CommpageBuilder`'s base bits.
    public var commpageOptionalBits: UInt64 {
        guard mode == .on, !published.isEmpty else { return 0 }
        return published.commpageBits | CPUFeatureSet.commpageUCNormalMemory
    }

    public init(mode: Mode, registers: GuestIDRegisters?, derived: CPUFeatureSet, cacheLineSize: Int,
                caches: CacheGeometry, timebaseFrequency: UInt64, brand: String) {
        self.mode = mode
        self.registers = registers
        self.derived = derived
        self.allowed = derived.subtracting(CapsBit.denied)
        self.cacheLineSize = cacheLineSize
        self.caches = caches
        self.timebaseFrequency = timebaseFrequency
        self.brand = brand
    }

    /// No registers read (no KVM, unit tests): nothing published.
    public static let minimal = GuestCPUProfile(
        mode: .off, registers: nil, derived: CPUFeatureSet(), cacheLineSize: 64, caches: .fallback,
        timebaseFrequency: GuestTimebase.appleFrequency, brand: "Ycode VM")

    /// The profile for these registers (§4.1 steps 2–5).
    public static func make(registers: GuestIDRegisters, fpcrTrapBits: UInt64, mode: Mode, caches: CacheGeometry,
                            hostCounterFrequency: UInt64) -> GuestCPUProfile {
        GuestCPUProfile(mode: mode, registers: registers,
                        derived: CPUFeatureSet.derive(from: registers, fpcrTrapBits: fpcrTrapBits),
                        cacheLineSize: coherencyLineSize(ctr: registers[.ctr]), caches: caches,
                        timebaseFrequency: GuestTimebase.frequency(hostFrequency: hostCounterFrequency),
                        brand: brandString(midr: registers[.midr]))
    }

    /// CTR_EL0.CWG (log2 words; 0 = not reported), else DminLine; 64 when
    /// neither is set.
    public static func coherencyLineSize(ctr: UInt64) -> Int {
        let cwg = Int((ctr >> 24) & 0xF), dminLine = Int((ctr >> 16) & 0xF)
        if cwg != 0 { return 4 << cwg }
        if dminLine != 0 { return 4 << dminLine }
        return 64
    }

    /// A Ycode name from MIDR_EL1 (no Apple product name, AGENTS.md rule 5).
    public static func brandString(midr: UInt64) -> String {
        let implementer = (midr >> 24) & 0xFF, part = (midr >> 4) & 0xFFF
        guard midr != 0 else { return "Ycode VM" }
        let armParts: [UInt64: String] = [
            0xD0C: "Neoverse N1", 0xD40: "Neoverse V1", 0xD49: "Neoverse N2", 0xD4F: "Neoverse V2",
            0xD83: "Neoverse V3AE", 0xD84: "Neoverse V3", 0xD8E: "Neoverse N3",
        ]
        if implementer == 0x41, let name = armParts[part] { return "Ycode VM (Arm \(name))" }
        return "Ycode VM (implementer 0x\(String(implementer, radix: 16)) part 0x\(String(part, radix: 16)))"
    }

    // MARK: The process-wide profile

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = GuestCPUProfile.minimal
    nonisolated(unsafe) private static var table: SysctlTable?

    /// The profile every new image uses.
    public static var current: GuestCPUProfile { lock.withLock { installed } }

    /// Sets `current` (the VMM, once, before the first image).
    public static func install(_ profile: GuestCPUProfile) {
        lock.withLock {
            installed = profile
            table = nil
        }
    }

    /// The sysctl table for `current` and `GuestCPUs.count` (built once per install).
    static var currentTable: SysctlTable {
        lock.withLock {
            if let table { return table }
            let t = SysctlTable.make(profile: installed, cpuCount: GuestCPUs.count)
            table = t
            return t
        }
    }

    /// One line for the log: mode, caps, commpage bits, registers.
    public var summary: String {
        var line = "CPU features \(mode.rawValue): caps [\(published)] commpage +0x\(String(commpageOptionalBits, radix: 16))"
        line += " (allowed [\(allowed)], derived [\(derived)]); line \(cacheLineSize); L1I \(caches.l1i) L1D \(caches.l1d) L2 \(caches.l2)"
        line += "; tbfrequency \(timebaseFrequency); \"\(brand)\""
        if let registers { line += "; " + registers.description }
        return line
    }

    // MARK: sysctl names

    /// The legacy `hw.optional.*` names and the caps bit each one equals
    /// (§2.4). `nil`: always 1 while features are published.
    public static let legacyNames: [(name: String, bit: Int?)] = [
        ("floatingpoint", CapsBit.advSIMD), ("neon", CapsBit.advSIMD), ("neon_hpfp", CapsBit.advSIMDHPFPCvt),
        ("neon_fp16", CapsBit.fp16), ("armv8_crc32", CapsBit.crc32), ("armv8_gpi", CapsBit.pacimp),
        ("armv8_1_atomics", CapsBit.lse), ("armv8_2_fhm", CapsBit.fhm), ("armv8_2_sha512", CapsBit.sha512),
        ("armv8_2_sha3", CapsBit.sha3), ("armv8_3_compnum", CapsBit.fcma), ("ucnormal_mem", nil), ("arm64", nil),
    ]
    /// MIB numbers of the named feature entries (below the hashed range of
    /// `SysctlTable.optionalMIBBase`).
    static let featureMIBBase: Int32 = 0x3000
    static let legacyMIBBase: Int32 = 0x3100
}

extension SysctlTable {
    /// The table for `profile` with `cpuCount` guest CPUs (stage3-contract.md
    /// §8 plus cpu-features.md §4.4–4.5).
    static func make(profile p: GuestCPUProfile, cpuCount: Int) -> SysctlTable {
        let n = Int64(cpuCount)
        var e = baseEntries(cpuCount: cpuCount)
        e.append(Entry(name: "hw.optional.arm.caps", mib: [6, 1000], value: .bytes(p.published.capsBytes)))
        e.append(Entry(name: "hw.cachelinesize", mib: [6, 16], value: .quad(Int64(p.cacheLineSize))))
        e.append(Entry(name: "hw.l1icachesize", mib: [6, 17], value: .quad(Int64(p.caches.l1i))))
        e.append(Entry(name: "hw.l1dcachesize", mib: [6, 18], value: .quad(Int64(p.caches.l1d))))
        e.append(Entry(name: "hw.l2cachesize", mib: [6, 20], value: .quad(Int64(p.caches.l2))))
        e.append(Entry(name: "hw.tbfrequency", mib: [6, 23], value: .integer(Int64(p.timebaseFrequency), size: 8)))
        e.append(Entry(name: "hw.cpusubfamily", mib: [6, 1017], value: .integer(0, size: 4)))
        e.append(Entry(name: "hw.perflevel0.l1icachesize", mib: [6, 1018], value: .integer(Int64(p.caches.l1i), size: 4)))
        e.append(Entry(name: "hw.perflevel0.l1dcachesize", mib: [6, 1019], value: .integer(Int64(p.caches.l1d), size: 4)))
        e.append(Entry(name: "hw.perflevel0.l2cachesize", mib: [6, 1020], value: .integer(Int64(p.caches.l2), size: 4)))
        e.append(Entry(name: "hw.perflevel0.cpusperl2", mib: [6, 1021], value: .integer(Int64(p.caches.cpusPerL2), size: 4)))
        e.append(Entry(name: "hw.perflevel0.name", mib: [6, 1022], value: .string("Performance")))
        // {CPUs sharing memory, L1, L2, 0 ×7} and {memory, L1D, L2, 0 ×7}.
        var config: [UInt8] = [], sizes: [UInt8] = []
        for v in [UInt64(cpuCount), 1, UInt64(p.caches.cpusPerL2)] + [UInt64](repeating: 0, count: 7) { config.appendLE(v) }
        for v in [Stage3Layout.memorySize, UInt64(p.caches.l1d), UInt64(p.caches.l2)] + [UInt64](repeating: 0, count: 7) { sizes.appendLE(v) }
        e.append(Entry(name: "hw.cacheconfig", mib: [6, 1023], value: .bytes(config)))
        e.append(Entry(name: "hw.cachesize", mib: [6, 1024], value: .bytes(sizes)))
        e.append(Entry(name: "machdep.cpu.brand_string", mib: [7, 1000], value: .string(p.brand)))
        for (i, name) in ["core_count", "thread_count", "cores_per_package", "logical_per_package"].enumerated() {
            e.append(Entry(name: "machdep.cpu." + name, mib: [7, 1001 + Int32(i)], value: .integer(n, size: 4)))
        }
        e.append(Entry(name: "machdep.virtual_address_size", mib: [7, 1005], value: .integer(Int64(VMLayout.virtualAddressBits), size: 4)))
        e.append(Entry(name: "machdep.ptrauth_enabled", mib: [7, 1006], value: .integer(0, size: 4)))
        if p.mode == .on {
            let s = p.published
            for (bit, name) in CapsBit.names {
                e.append(Entry(name: "hw.optional.arm." + name, mib: [6, GuestCPUProfile.featureMIBBase + Int32(bit)],
                               value: .integer(s.contains(bit) ? 1 : 0, size: 4)))
            }
            for (i, legacy) in GuestCPUProfile.legacyNames.enumerated() {
                let on = legacy.bit.map(s.contains) ?? true
                e.append(Entry(name: "hw.optional." + legacy.name, mib: [6, GuestCPUProfile.legacyMIBBase + Int32(i)],
                               value: .integer(on ? 1 : 0, size: 4)))
            }
        }
        return SysctlTable(entries: e)
    }
}
