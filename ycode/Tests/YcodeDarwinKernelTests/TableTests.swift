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

        for (n, expected) in [("hw.ncpu", UInt64(GuestCPUs.count)), ("hw.activecpu", UInt64(GuestCPUs.count)), ("hw.optional.arm.caps", 0)] {
            try env.putString(n, at: name)
            try env.put(leBytes(0xAAAA_AAAA_AAAA_AAAA), at: old)
            try env.put(leBytes(8), at: lenp)
            (_, f) = env.svc(0x7963_0009, [name, old, lenp, 0, 0])
            #expect(try !f.carry && env.u64(old) == expected, "\(n)")
        }
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
