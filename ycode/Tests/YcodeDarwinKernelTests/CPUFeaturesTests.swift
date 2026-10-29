import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// specs/simulator/cpu-features.md: derivation, deny list, the three
/// outputs and the §5 invariants. The registers are synthetic: fields set
/// as the §4.4 oracle expects the Thor's guest view to be, plus fields KVM
/// would hide, to check the deny list.
@Suite struct CPUFeaturesTests {
    static func reg(_ fields: [(lsb: Int, value: UInt64)]) -> UInt64 {
        fields.reduce(0) { $0 | ($1.value << UInt64($1.lsb)) }
    }

    /// A Thor-like guest view (§4.4 inputs).
    static var thor: GuestIDRegisters {
        var r = GuestIDRegisters()
        // TS 2, FHM 1, DP 1, SHA3 1, RDM 1, Atomic 2, CRC32 1, SHA2 2, SHA1 1, AES 2.
        r[.isar0] = reg([(52, 2), (48, 1), (44, 1), (32, 1), (28, 1), (20, 2), (16, 1), (12, 2), (8, 1), (4, 2)])
        // I8MM 1, BF16 1, SPECRES 0, SB 1, FRINTTS 1, GPI 0, LRCPC 2, FCMA 1, JSCVT 1, API/APA 0, DPB 2.
        r[.isar1] = reg([(52, 1), (44, 1), (36, 1), (32, 1), (20, 2), (16, 1), (12, 1), (0, 2)])
        r[.isar2] = reg([(0, 2)])                       // WFxT 2 (denied), RPRES 0
        r[.mmfr0] = reg([(60, 2)])                      // ECV 2 (deferred)
        r[.mmfr1] = reg([(44, 1)])                      // AFP 1
        r[.mmfr2] = reg([(32, 1)])                      // AT 1 (LSE2)
        r[.pfr0] = reg([(60, 1), (56, 1), (48, 1), (20, 1), (16, 1), (0, 1), (4, 1)])  // CSV3, CSV2, DIT, AdvSIMD 1, FP 1
        r[.pfr1] = reg([(4, 2), (0, 1)])                // SSBS 2, BT 1
        r[.ctr] = 0x8444_C004                           // CWG 4 (64 bytes), DminLine 4
        r[.dczid] = 0x4
        r[.midr] = 0x410F_D830
        return r
    }

    static func profile(_ r: GuestIDRegisters = thor, mode: GuestCPUProfile.Mode = .on, fpcr: UInt64 = 0) -> GuestCPUProfile {
        GuestCPUProfile.make(registers: r, fpcrTrapBits: fpcr, mode: mode, caches: .fallback, hostCounterFrequency: 1_000_000_000)
    }

    @Test func thorOracle() {
        let p = Self.profile()
        // §4.4: ff ef c7 e3 1f 00 0e 00 00 00 00 00 00.
        #expect(p.published.capsBytes == [0xFF, 0xEF, 0xC7, 0xE3, 0x1F, 0x00, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(p.published.capsBytes.count == 13)
        // WFxT and ECV were derived and then denied.
        #expect(p.derived.contains(CapsBit.wfxt) && p.derived.contains(CapsBit.ecv))
        #expect(!p.published.contains(CapsBit.wfxt) && !p.published.contains(CapsBit.ecv))
        // §4.4: 0x03f76f0787007fa8 before CPU count and kUP; N = 1 gives 0x03f76f078701ffa8.
        var c = CommpageBuilder()
        c.cpuCount = 1
        c.cacheLineSize = UInt16(p.cacheLineSize)
        c.optionalCapabilities = p.commpageOptionalBits
        #expect(c.capabilities == 0x03F7_6F07_8701_FFA8)
        c.cpuCount = 14
        #expect(c.capabilities == 0x03F7_6F07_8700_7FA8 | (14 << 16))
        let page = c.rwPage()
        #expect(page.readLE(UInt32.self, at: 0x020) == UInt32(truncatingIfNeeded: c.capabilities))
        #expect(p.cacheLineSize == 64)
        #expect(p.timebaseFrequency == 24_000_000)
        #expect(p.brand == "Ycode VM (Arm Neoverse V3AE)")
        #expect(!p.brand.contains("Apple"))
    }

    @Test func denyListWins() {
        var r = Self.thor
        // Pointer authentication, SME, MTE and SPECRES visible: never published.
        r[.isar1] |= Self.reg([(8, 5), (4, 5), (28, 1), (40, 2)])
        r[.pfr1] |= Self.reg([(24, 2), (8, 3)])
        let p = Self.profile(r)
        for bit in [CapsBit.pauth, CapsBit.pauth2, CapsBit.fpac, CapsBit.fpacCombine, CapsBit.pacimp, CapsBit.sme, CapsBit.sme2,
                    CapsBit.mte, CapsBit.specres, CapsBit.specres2] {
            #expect(p.derived.contains(bit), "derived \(bit)")
            #expect(!p.published.contains(bit), "published \(bit)")
        }
        // swiftlint:disable:next is_disjoint - CPUFeatureSet is not a SetAlgebra
        #expect(p.published.intersection(CapsBit.denied).isEmpty)
        #expect(p.published == Self.profile().published)
        // The commpage never carries PAuth, GPI, SME or SPECRES.
        let w = p.commpageOptionalBits
        for b: UInt64 in [44, 47, 51, 59, 60] { #expect(w & (1 << b) == 0) }
        // Bits without public meaning stay clear.
        for b: UInt64 in [29, 35, 36, 37, 38, 39, 61, 62, 63] { #expect(w & (1 << b) == 0) }
    }

    @Test func fpcrProbe() {
        #expect(!Self.profile(fpcr: 0).published.contains(CapsBit.fpSyncExceptions))
        #expect(!Self.profile(fpcr: 0x1F00).published.contains(CapsBit.fpSyncExceptions))
        let p = Self.profile(fpcr: 0x9F00)
        #expect(p.published.contains(CapsBit.fpSyncExceptions))
        #expect(p.commpageOptionalBits & (1 << 58) != 0)
    }

    @Test func offPublishesTheMinimalSet() {
        let p = Self.profile(mode: .off)
        #expect(p.published.isEmpty && !p.allowed.isEmpty)
        #expect(p.commpageOptionalBits == 0)
        let t = SysctlTable.make(profile: p, cpuCount: 1)
        #expect(t.lookup(name: "hw.optional.arm.caps")?.value == .bytes([UInt8](repeating: 0, count: 13)))
        #expect(t.lookup(name: "hw.optional.arm.FEAT_LSE")?.value == .integer(0, size: 4))
        #expect(t.lookup(name: "hw.optional.neon")?.value == .integer(0, size: 4))
        // The corrected values do not depend on the switch.
        #expect(t.lookup(name: "hw.tbfrequency")?.value == .integer(24_000_000, size: 8))
        #expect(t.lookup(name: "hw.l2cachesize")?.value == .quad(1 << 20))
    }

    /// §5 invariants 1–6 on the sysctl table and the commpage.
    @Test func invariants() {
        for cpus in [1, 4] {
            let p = Self.profile()
            let t = SysctlTable.make(profile: p, cpuCount: cpus)
            guard case let .bytes(caps)? = t.lookup(name: "hw.optional.arm.caps")?.value else {
                Issue.record("caps is not bytes"); return
            }
            let set = CPUFeatureSet(capsBytes: caps)
            #expect(set == p.published)
            // 1. Every named bit's sysctl equals the bit.
            for (bit, name) in CapsBit.names {
                #expect(t.lookup(name: "hw.optional.arm." + name)?.value == .integer(set.contains(bit) ? 1 : 0, size: 4), "\(name)")
            }
            // 2. Commpage bits equal their caps bits; crypto = AES ∧ PMULL ∧ SHA1 ∧ SHA256.
            var c = CommpageBuilder()
            c.cpuCount = UInt8(cpus)
            c.cacheLineSize = UInt16(p.cacheLineSize)
            c.optionalCapabilities = p.commpageOptionalBits
            let w = c.capabilities
            for (bit, mask) in CPUFeatureSet.commpagePairs { #expect((w & mask != 0) == set.contains(bit), "commpage \(bit)") }
            let crypto = [CapsBit.aes, CapsBit.pmull, CapsBit.sha1, CapsBit.sha256].allSatisfy(set.contains)
            #expect((w & 0x0100_0000 != 0) == crypto)
            // 3. Legacy names equal their modern counterparts.
            for (name, bit) in GuestCPUProfile.legacyNames {
                let want: Int64 = (bit.map(set.contains) ?? true) ? 1 : 0
                #expect(t.lookup(name: "hw.optional." + name)?.value == .integer(want, size: 4), "\(name)")
            }
            #expect(t.lookup(name: "hw.optional.armv8_gpi")?.value == .integer(0, size: 4))
            #expect(t.lookup(name: "hw.optional.watchpoint")?.value == .integer(0, size: 4))
            // 4. Cache line: commpage bit, commpage 0x026 and hw.cachelinesize.
            #expect(t.lookup(name: "hw.cachelinesize")?.value == .quad(Int64(p.cacheLineSize)))
            #expect(w & 0x20 != 0 && w & 0x50 == 0)
            #expect(c.rwPage().readLE(UInt16.self, at: 0x026) == UInt16(p.cacheLineSize))
            // 5. CPU counts.
            #expect((w >> 16) & 0xFF == UInt64(cpus))
            #expect((w & 0x8000 != 0) == (cpus == 1))
            for name in ["hw.ncpu", "hw.activecpu", "hw.logicalcpu", "hw.physicalcpu_max", "hw.perflevel0.logicalcpu",
                         "machdep.cpu.core_count", "machdep.cpu.thread_count", "machdep.cpu.logical_per_package"] {
                #expect(t.lookup(name: name)?.value == .integer(Int64(cpus), size: 4), "\(name)")
            }
            // 6. Nothing denied anywhere.
            // swiftlint:disable:next is_disjoint - CPUFeatureSet is not a SetAlgebra
            #expect(set.intersection(CapsBit.denied).isEmpty)
            // MIBs are unique and round-trip.
            var seen = Set<[Int32]>()
            for e in t.entries {
                #expect(seen.insert(e.mib).inserted, "duplicate MIB \(e.mib) (\(e.name))")
                #expect(t.lookup(mib: e.mib)?.name == e.name)
            }
        }
    }

    @Test func otherKeys() {
        let t = SysctlTable.make(profile: Self.profile(), cpuCount: 2)
        #expect(t.lookup(name: "hw.cpufamily")?.value == .integer(0, size: 4))
        #expect(t.lookup(name: "hw.cpusubfamily")?.value == .integer(0, size: 4))
        #expect(t.lookup(name: "hw.cpusubtype")?.value == .integer(0, size: 4))
        #expect(t.lookup(name: "hw.perflevel0.name")?.value == .string("Performance"))
        #expect(t.lookup(name: "hw.perflevel0.l2cachesize")?.value == .integer(1 << 20, size: 4))
        #expect(t.lookup(name: "hw.perflevel0.cpusperl2")?.value == .integer(1, size: 4))
        #expect(t.lookup(name: "hw.nperflevels")?.value == .integer(1, size: 4))
        #expect(t.lookup(name: "machdep.ptrauth_enabled")?.value == .integer(0, size: 4))
        #expect(t.lookup(name: "machdep.virtual_address_size")?.value == .integer(47, size: 4))
        #expect(t.lookup(name: "machdep.cpu.brand_string")?.value == .string("Ycode VM (Arm Neoverse V3AE)"))
        #expect(t.lookup(name: "kern.grade_cputype")?.value == .error(DarwinKernel.Errno.ENOENT))
        guard case let .bytes(config)? = t.lookup(name: "hw.cacheconfig")?.value,
              case let .bytes(sizes)? = t.lookup(name: "hw.cachesize")?.value else { Issue.record("cache structs"); return }
        #expect(config.count == 80 && sizes.count == 80)
        #expect(config.readLE(UInt64.self, at: 0) == 2 && config.readLE(UInt64.self, at: 16) == 1)
        #expect(sizes.readLE(UInt64.self, at: 8) == 64 << 10 && sizes.readLE(UInt64.self, at: 16) == 1 << 20)
        // tbfrequency × numer / denom = 10⁹ (invariant 8; numer/denom 125/3 at 24 MHz).
        #expect(24_000_000 * 125 / 3 == 1_000_000_000)
    }

    @Test func coherencyLine() {
        #expect(GuestCPUProfile.coherencyLineSize(ctr: 0x8444_C004) == 64)
        #expect(GuestCPUProfile.coherencyLineSize(ctr: 0x0005_0000) == 128)   // CWG 0: DminLine 5
        #expect(GuestCPUProfile.coherencyLineSize(ctr: 0) == 64)
    }

    @Test func cacheGeometryFromSysfs() throws {
        let dir = NSTemporaryDirectory() + "ycode-cpu-\(UUID().uuidString)"
        func put(_ index: Int, _ level: Int, _ type: String, _ size: String, _ shared: String) throws {
            let d = dir + "/cache/index\(index)"
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            for (f, v) in [("level", "\(level)"), ("type", type), ("size", size), ("shared_cpu_list", shared)] {
                try (v + "\n").write(toFile: d + "/" + f, atomically: true, encoding: .utf8)
            }
        }
        try put(0, 1, "Data", "64K", "0")
        try put(1, 1, "Instruction", "64K", "0")
        try put(2, 2, "Unified", "1024K", "0")
        try put(3, 3, "Unified", "16384K", "0-13")
        let g = CacheGeometry.read(cpuDirectory: dir)
        #expect(g == CacheGeometry(l1i: 64 << 10, l1d: 64 << 10, l2: 1 << 20, cpusPerL2: 1))
        #expect(CacheGeometry.read(cpuDirectory: dir + "/none") == .fallback)
        #expect(CacheGeometry.cpuCount("0-3,8") == 5)
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// The 13-byte caps through BSD 274: a size query, a 16-byte buffer
    /// (dyld), a 13-byte buffer (compiler-rt), and a short one (ENOMEM with
    /// what fits).
    @Test func capsThroughSysctlbyname() throws {
        let env = try Env()
        env.kernel.sysctl = SysctlTable.make(profile: Self.profile(), cpuCount: 1)
        let s = Env.scratch
        func byName(_ name: String, buffer: UInt64?) throws -> (TrapFrame, UInt64, [UInt8]) {
            try env.putString(name, at: s)
            try env.put([UInt8](repeating: 0xEE, count: 32), at: s + 0x200)
            try env.put(leBytes(buffer ?? 0), at: s + 0x100)
            let (_, f) = env.svc(274, [s, UInt64(name.utf8.count), buffer == nil ? 0 : s + 0x200, s + 0x100, 0, 0])
            return (f, try env.u64(s + 0x100), try env.space.read(va: s + 0x200, count: 16))
        }
        let expected: [UInt8] = [0xFF, 0xEF, 0xC7, 0xE3, 0x1F, 0x00, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let (f0, n0, _) = try byName("hw.optional.arm.caps", buffer: nil)
        #expect(!f0.carry && n0 == 13)
        for size: UInt64 in [16, 13] {
            let (f, n, b) = try byName("hw.optional.arm.caps", buffer: size)
            #expect(!f.carry && n == 13)
            #expect(Array(b.prefix(13)) == expected && b[13] == 0xEE)
        }
        let (f8, _, b8) = try byName("hw.optional.arm.caps", buffer: 8)
        #expect(f8.carry && f8.x[0] == UInt64(DarwinKernel.Errno.ENOMEM))
        #expect(Array(b8.prefix(8)) == Array(expected.prefix(8)) && b8[8] == 0xEE)
        let (fl, nl, bl) = try byName("hw.optional.arm.FEAT_LSE", buffer: 4)
        #expect(!fl.carry && nl == 4 && bl.readLE(UInt32.self, at: 0) == 1)
        let (fp, _, bp) = try byName("hw.optional.arm.FEAT_PAuth", buffer: 4)
        #expect(!fp.carry && bp.readLE(UInt32.self, at: 0) == 0)
    }

    @Test func featureSetStorage() {
        let p = Self.profile(fpcr: 0x9F00)
        let stored = p.published.storedBytes
        #expect(stored.count == 16)
        #expect(CPUFeatureSet(storedBytes: stored) == p.published)
        #expect(p.published.contains(CapsBit.fpSyncExceptions))   // a bit above 63 survives
        #expect(p.published.isSubset(of: p.allowed))
        var lacking = p.allowed
        lacking.remove(CapsBit.lse)
        #expect(!p.published.isSubset(of: lacking))
        #expect(p.published.subtracting(lacking).names == ["FEAT_LSE"])
    }

    /// §6: a snapshot records the features its guests were told; a restore
    /// on a host that does not offer one of them is refused (the launcher
    /// then boots cold). The test process has no profile installed, so
    /// `GuestCPUProfile.current.allowed` is empty here.
    @Test func snapshotRefusesMissingFeatures() throws {
        func records(_ features: CPUFeatureSet?) -> [SnapshotRecord] {
            var sys = SnapshotFields()
            if let features { sys.bytes(ST.System.cpuFeatures, features.storedBytes) }
            var clock = SnapshotFields()
            clock.u64(ST.Clock.frequency, 24_000_000)
            return [SnapshotRecord(kind: .system, id: KernelSnapshotCapture.systemID, fields: sys),
                    SnapshotRecord(kind: .clock, id: KernelSnapshotCapture.clockID, fields: clock)]
        }
        #expect(GuestCPUProfile.current.allowed.isEmpty)
        // Older snapshots (no field) and snapshots that used nothing restore.
        _ = try KernelSnapshotRestore(records: records(nil), system: DarwinSystem())
        _ = try KernelSnapshotRestore(records: records(CPUFeatureSet()), system: DarwinSystem())
        do {
            _ = try KernelSnapshotRestore(records: records(CPUFeatureSet(bits: [CapsBit.lse, CapsBit.jscvt])), system: DarwinSystem())
            Issue.record("restore with missing features was accepted")
        } catch let e as SnapshotError {
            #expect("\(e)".contains("FEAT_LSE") && "\(e)".contains("FEAT_JSCVT"))
        }
    }
}
