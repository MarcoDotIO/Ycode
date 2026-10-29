import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Port traps reach the kernel's `MachIPC` (stage4a-contract.md §6, §8);
/// the port semantics are tested in the MachIPC*Tests suites.
@Suite struct PortTests {
    @Test func wellKnownAndDynamicNames() throws {
        let env = try Env()
        let ipc = try #require(env.kernel.machIPC as? MachIPC)
        #expect(env.svc(UInt64(bitPattern: -28)).1.x[0] == 0x103)
        #expect(env.svc(UInt64(bitPattern: -27)).1.x[0] == 0x203)
        #expect(env.svc(UInt64(bitPattern: -29)).1.x[0] == 0x303)
        let reply = UInt32(env.svc(UInt64(bitPattern: -26)).1.x[0])  // mach_reply_port
        #expect(reply & 3 == 3 && ipc.entry(reply) != nil)

        let slot = Env.scratch + 0x10
        let (_, a) = env.svc(UInt64(bitPattern: -16), [0x103, 1, slot])  // MACH_PORT_RIGHT_RECEIVE
        #expect(a.x[0] == 0)
        let name = try env.u32(slot)
        #expect(name & 3 == 3 && ipc.receiveTarget(of: name) == .port)
        #expect(env.svc(UInt64(bitPattern: -18), [0x103, 0x9903]).1.x[0] == 15)
        #expect(env.sink.lines.contains { $0.contains("-16") || $0.contains("mach_port_allocate") })
    }
}

@Suite struct SysctlTests {
    @Test func byName() throws {
        let env = try Env()
        let name = Env.scratch, old = Env.scratch + 0x100, lenp = Env.scratch + 0x200

        try env.putString("hw.pagesize", at: name)
        try env.put(leBytes(8), at: lenp)
        var (_, f) = env.svc(0x7963_0009, [name, old, lenp, 0, 0])
        #expect(!f.carry && f.x[0] == 0)
        #expect(try env.u64(old) == 16384 && env.u64(lenp) == 8)
        // A 4-byte buffer gets a 4-byte integer.
        try env.put(leBytes(0xFFFF_FFFF_FFFF_FFFF), at: old)
        try env.put(leBytes(4), at: lenp)
        (_, f) = env.svc(0x7963_0009, [name, old, lenp, 0, 0])
        #expect(try env.u64(old) == 0xFFFF_FFFF_0000_4000 && env.u64(lenp) == 4)

        // Size query (old = NULL).
        try env.putString("kern.osproductversion", at: name)
        (_, f) = env.svc(0x7963_0009, [name, 0, lenp, 0, 0])
        #expect(try !f.carry && env.u64(lenp) == 5)
        try env.put(leBytes(64), at: lenp)
        (_, f) = env.svc(0x7963_0009, [name, old, lenp, 0, 0])
        #expect(try env.string(old) == "27.1" && env.u64(lenp) == 5)
        // Too small: ENOMEM.
        try env.put(leBytes(2), at: lenp)
        (_, f) = env.svc(0x7963_0009, [name, old, lenp, 0, 0])
        #expect(f.carry && f.x[0] == 12)

        for (n, expected) in [("hw.ncpu", UInt64(GuestCPUs.count)), ("hw.activecpu", UInt64(GuestCPUs.count))] {
            try env.putString(n, at: name)
            try env.put(leBytes(0xAAAA_AAAA_AAAA_AAAA), at: old)
            try env.put(leBytes(8), at: lenp)
            (_, f) = env.svc(0x7963_0009, [name, old, lenp, 0, 0])
            // 4-byte integers stay 4 bytes in an 8-byte buffer (visionos.md §10.10.1).
            #expect(try !f.carry && env.u64(old) == 0xAAAA_AAAA_0000_0000 | expected && env.u64(lenp) == 4, "\(n)")
        }
        // hw.optional.arm.caps: 13 bytes (cpu-features.md §2.3; all 0
        // without an installed CPU profile); an 8-byte buffer gets the first
        // 8 and ENOMEM.
        try env.putString("hw.optional.arm.caps", at: name)
        try env.put([UInt8](repeating: 0xAA, count: 16), at: old)
        try env.put(leBytes(16), at: lenp)
        (_, f) = env.svc(0x7963_0009, [name, old, lenp, 0, 0])
        #expect(try !f.carry && env.u64(lenp) == 13 && env.space.read(va: old, count: 14) == [UInt8](repeating: 0, count: 13) + [0xAA])
        try env.put([UInt8](repeating: 0xAA, count: 16), at: old)
        try env.put(leBytes(8), at: lenp)
        (_, f) = env.svc(0x7963_0009, [name, old, lenp, 0, 0])
        #expect(try f.carry && f.x[0] == 12 && env.space.read(va: old, count: 9) == [UInt8](repeating: 0, count: 8) + [0xAA])
        for n in ["kern.grade_cputype", "kern.nonexistent"] {
            try env.putString(n, at: name)
            (_, f) = env.svc(0x7963_0009, [name, old, lenp, 0, 0])
            #expect(f.carry && f.x[0] == 2, "\(n)")
        }
        // BSD 274 takes an explicit length.
        try env.putString("hw.ncpu", at: name)
        try env.put(leBytes(4), at: lenp)
        (_, f) = env.svc(274, [name, 7, old, lenp, 0, 0])
        #expect(try !f.carry && env.u32(old) == UInt32(GuestCPUs.count))
    }

    /// visionos.md §10.10.1: integers at their natural width whatever the
    /// buffer size; buffers prefilled with 0xAA.
    @Test func naturalWidths() throws {
        let env = try Env()
        let name = Env.scratch, old = Env.scratch + 0x100, lenp = Env.scratch + 0x200
        struct Outcome: Equatable { var errno: UInt64?; var length: UInt64; var bytes: [UInt8] }
        func read(_ n: String, buffer: UInt64) throws -> Outcome {
            try env.putString(n, at: name)
            try env.put([UInt8](repeating: 0xAA, count: 16), at: old)
            try env.put(leBytes(buffer), at: lenp)
            let (_, f) = env.svc(0x7963_0009, [name, old, lenp, 0, 0])
            return Outcome(errno: f.carry ? f.x[0] : nil, length: try env.u64(lenp), bytes: try env.space.read(va: old, count: 16))
        }
        func le(_ v: UInt64, _ width: Int) -> [UInt8] { (0..<width).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        let aa = { (k: Int) in [UInt8](repeating: 0xAA, count: k) }
        let cpus = UInt64(GuestCPUs.count)
        // 4-byte integers: 4 bytes and length 4 into 4, 8 and 16 bytes; ENOMEM,
        // nothing written and length 0 for 2 bytes; size query 4.
        for n in ["hw.ncpu", "hw.activecpu", "hw.logicalcpu", "hw.logicalcpu_max", "hw.physicalcpu", "hw.physicalcpu_max",
                  "hw.perflevel0.physicalcpu", "hw.nperflevels", "hw.byteorder", "kern.maxproc", "vm.pagesize", "hw.physmem"] {
            for buffer: UInt64 in [4, 8, 16] {
                let o = try read(n, buffer: buffer)
                #expect(o.errno == nil && o.length == 4 && Array(o.bytes[4...]) == aa(12), "\(n) \(buffer)")
            }
            #expect(try read(n, buffer: 2) == Outcome(errno: 12, length: 0, bytes: aa(16)), "\(n)")
            try env.putString(n, at: name)
            let (_, f) = env.svc(0x7963_0009, [name, 0, lenp, 0, 0])
            #expect(try !f.carry && env.u64(lenp) == 4, "\(n)")
        }
        #expect(try read("hw.physicalcpu", buffer: 8).bytes == le(cpus, 4) + aa(12))
        // 8-byte values narrowed for an exactly 4-byte buffer when they fit.
        #expect(try read("hw.pagesize", buffer: 8) == Outcome(errno: nil, length: 8, bytes: le(16384, 8) + aa(8)))
        #expect(try read("hw.pagesize", buffer: 16) == Outcome(errno: nil, length: 8, bytes: le(16384, 8) + aa(8)))
        #expect(try read("hw.pagesize", buffer: 4) == Outcome(errno: nil, length: 4, bytes: le(16384, 4) + aa(12)))
        #expect(try read("hw.pagesize", buffer: 2) == Outcome(errno: 12, length: 0, bytes: aa(16)))
        #expect(try read("hw.pagesize", buffer: 6) == Outcome(errno: 12, length: 0, bytes: aa(16)))
        // A value that does not fit an int: ERANGE, nothing written, length unchanged.
        #expect(try read("kern.usrstack64", buffer: 4) == Outcome(errno: 34, length: 4, bytes: aa(16)))
        #expect(try read("kern.usrstack64", buffer: 8).length == 8)
        // Never narrowed: ENOMEM for 4 bytes.
        for n in ["hw.cachelinesize", "hw.l2cachesize"] {
            #expect(try read(n, buffer: 4) == Outcome(errno: 12, length: 0, bytes: aa(16)), "\(n)")
            let o = try read(n, buffer: 16)
            #expect(o.errno == nil && o.length == 8 && Array(o.bytes[8...]) == aa(8), "\(n)")
        }
    }

    /// HW_PAGESIZE by number is a 4-byte integer; the name `hw.pagesize`
    /// translates to another MIB that answers 8 bytes (visionos.md §10.10.1).
    @Test func pagesizeByNumberAndByName() throws {
        let env = try Env()
        let mib = Env.scratch, old = Env.scratch + 0x100, lenp = Env.scratch + 0x200, name = Env.scratch + 0x300
        func putMIB(_ v: [Int32]) throws {
            try env.put(v.flatMap { x in (0..<4).map { UInt8(truncatingIfNeeded: x >> (8 * $0)) } }, at: mib)
        }
        try putMIB([6, 7])
        try env.put([UInt8](repeating: 0xAA, count: 8), at: old)
        try env.put(leBytes(8), at: lenp)
        var (_, f) = env.svc(202, [mib, 2, old, lenp, 0, 0])
        #expect(try !f.carry && env.u64(lenp) == 4 && env.u64(old) == 0xAAAA_AAAA_0000_4000)
        try putMIB([6, 3])
        try env.put([UInt8](repeating: 0xAA, count: 8), at: old)
        try env.put(leBytes(8), at: lenp)
        (_, f) = env.svc(202, [mib, 2, old, lenp, 0, 0])
        #expect(try !f.carry && env.u64(lenp) == 4 && env.u64(old) == 0xAAAA_AAAA_0000_0000 | UInt64(GuestCPUs.count))
        try putMIB([6, 24])
        try env.put(leBytes(8), at: lenp)
        (_, f) = env.svc(202, [mib, 2, old, lenp, 0, 0])
        #expect(try !f.carry && env.u64(lenp) == 8 && env.u64(old) == Stage3Layout.memorySize)
        // name2oid of "hw.pagesize", then a read by that OID: 8 bytes.
        try putMIB([0, 3])
        try env.putString("hw.pagesize", at: name)
        try env.put(leBytes(48), at: lenp)
        (_, f) = env.svc(202, [mib, 2, old, lenp, name, 11])
        #expect(try !f.carry && env.u64(lenp) == 8)
        let oid = try env.space.read(va: old, count: 8)
        #expect(oid != [6, 0, 0, 0, 7, 0, 0, 0])
        try env.put(oid, at: mib)
        try env.put([UInt8](repeating: 0xAA, count: 8), at: old)
        try env.put(leBytes(8), at: lenp)
        (_, f) = env.svc(202, [mib, 2, old, lenp, 0, 0])
        #expect(try !f.carry && env.u64(lenp) == 8 && env.u64(old) == 16384)
    }

    @Test func mibForm() throws {
        let env = try Env()
        let mib = Env.scratch, old = Env.scratch + 0x100, lenp = Env.scratch + 0x200, name = Env.scratch + 0x300
        func putMIB(_ v: [Int32]) throws {
            try env.put(v.flatMap { x in (0..<4).map { UInt8(truncatingIfNeeded: x >> (8 * $0)) } }, at: mib)
        }
        // {CTL_HW, HW_NCPU}
        try putMIB([6, 3])
        try env.put(leBytes(4), at: lenp)
        var (_, f) = env.svc(202, [mib, 2, old, lenp, 0, 0])
        #expect(try !f.carry && env.u32(old) == UInt32(GuestCPUs.count))

        // name2oid {0, 3} then a read by the returned OID.
        try putMIB([0, 3])
        try env.putString("kern.osproductversion", at: name)
        try env.put(leBytes(48), at: lenp)
        (_, f) = env.svc(202, [mib, 2, old, lenp, name, 21])
        #expect(try !f.carry && env.u64(lenp) == 8)
        let oid = try env.space.read(va: old, count: 8)
        try env.put(oid, at: mib)
        try env.put(leBytes(64), at: lenp)
        (_, f) = env.svc(202, [mib, 2, old + 0x40, lenp, 0, 0])
        #expect(try !f.carry && env.string(old + 0x40) == "27.1")

        // Unknown MIB: ENOENT; a write: EPERM.
        try putMIB([1, 999])
        (_, f) = env.svc(202, [mib, 2, old, lenp, 0, 0])
        #expect(f.carry && f.x[0] == 2)
        try putMIB([6, 7])
        (_, f) = env.svc(202, [mib, 2, 0, 0, name, 4])
        #expect(f.carry && f.x[0] == 1)
    }
}

@Suite struct VLogTests {
    func format(_ fmt: String, _ slots: [UInt64], strings: [UInt64: String] = [:]) -> String {
        VLogFormatter(
            slot: { i in
                guard i < slots.count else { throw DarwinErrnoError(14) }
                return slots[i]
            },
            string: { p in
                guard let s = strings[p] else { throw DarwinErrnoError(14) }
                return s
            }
        ).format(fmt)
    }

    @Test func conversions() {
        #expect(format("plain 100%%", []) == "plain 100%")
        #expect(format("%s=%d", [0x10, UInt64(bitPattern: -5)], strings: [0x10: "x"]) == "x=-5")
        #expect(format("%i %u", [UInt64(UInt32.max), UInt64(UInt32.max)]) == "-1 4294967295")
        #expect(format("%x %llx %p", [0xFFFF_FFFF_0000_00AB, 0xFFFF_FFFF_0000_00AB, 0x1_0000_4000])
            == "ab ffffffff000000ab 0x100004000")
        #expect(format("%lu %ld %llu %lld", [UInt64.max, UInt64.max, 7, UInt64(bitPattern: -7)])
            == "18446744073709551615 -1 7 -7")
        #expect(format("%c%c", [0x41, 0x42]) == "AB")
        #expect(format("%s", [0]) == "(null)")
        #expect(format("%s", [0x99]) == "<fault>")
        #expect(format("[%8s][%-4d][%08x][%#x][%.3s][%zu]", [0x10, 42, 0xBEEF, 0xBEEF, 0x10, 9],
                       strings: [0x10: "dyld_sim"]) == "[dyld_sim][42  ][0000beef][0xbeef][dyl][9]")
        #expect(format("[%*d][%5.2f]%d", [6, 3, 0x4000_0000_0000_0000, 8]) == "[     3][%5.2f]8")
        #expect(format("trailing %", []) == "trailing %")
        #expect(format("%hhd %hd", [0x1FF, 0x1_FFFF]) == "-1 -1")
    }

    @Test func trapReadsGuestVaList() throws {
        let env = try Env()
        let fmt = Env.scratch, str = Env.scratch + 0x100, va = Env.scratch + 0x200
        try env.putString("dyld[%d]: <%s> loaded at %p (%llx)%c", at: fmt)
        try env.putString("/usr/lib/libSystem.B.dylib", at: str)
        try env.put(leBytes(100) + leBytes(str) + leBytes(0x1_C000_0000) + leBytes(0xABCD) + leBytes(0x21), at: va)
        let (o, f) = env.svc(0x7963_0001, [fmt, va])
        #expect(o == .resume && !f.carry)
        #expect(env.sink.text(2) == "dyld[100]: </usr/lib/libSystem.B.dylib> loaded at 0x1c0000000 (abcd)!\n")
    }
}
