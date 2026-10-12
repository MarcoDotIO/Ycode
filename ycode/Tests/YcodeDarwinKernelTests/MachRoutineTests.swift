import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// `host-libraries.md` §10: private Mach-routine traps and semaphore traps.
@Suite struct MachRoutineTests {
    let s = Env.scratch
    func m(_ n: Int) -> UInt64 { UInt64(bitPattern: Int64(n)) }

    @Test func clocks() throws {
        var ticks: UInt64 = 5_000
        let env = try Env(counter: { ticks }, frequency: 1_000)
        env.kernel.bootCounter = 5_000
        let (_, a) = env.svc(0x7963_2001, [0x303, 0, s])
        #expect(!a.carry && a.x[0] == 0)
        let system = try env.u32(s)
        #expect((env.kernel.machIPC as? MachIPC)?.entry(system) != nil)
        env.svc(0x7963_2001, [0x303, 1, s + 4])
        let calendar = try env.u32(s + 4)
        #expect((env.kernel.machIPC as? MachIPC)?.entry(calendar) != nil && calendar != system)
        #expect(env.svc(0x7963_2001, [0x303, 2, s]).1.x[0] == 4)
        #expect(env.svc(0x7963_2001, [0x303, 0, 0x10]).1.x[0] == 1)  // bad out pointer

        ticks = 5_000 + 2_500  // 2.5 s of uptime at 1 kHz
        #expect(env.svc(0x7963_2002, [UInt64(system), s + 0x10]).1.x[0] == 0)
        #expect(try env.u32(s + 0x10) == 2 && env.u32(s + 0x14) == 500_000_000)
        #expect(env.svc(0x7963_2002, [UInt64(calendar), s + 0x10]).1.x[0] == 0)
        #expect(try env.u32(s + 0x10) == 1_700_000_000 && env.u32(s + 0x14) == 250_000_000)
        #expect(env.svc(0x7963_2002, [0x103, s + 0x10]).1.x[0] == 4)  // not a clock
        #expect(env.svc(0x7963_2002, [UInt64(system), 0x10]).1.x[0] == 1)
        // Carry is not used.
        var f = TrapFrame(spsr: 0x2000_0000)
        env.svc(0x7963_2002, [UInt64(system), s + 0x10], frame: &f)
        #expect(f.x[0] == 0 && !f.carry)
    }

    @Test func semaphores() throws {
        // Stage 4a: waits really block (ThreadSyncTests covers waking them).
        let env = try Env()
        #expect(env.svc(0x7963_2003, [0x103, s, 0, UInt64(bitPattern: -1)]).1.x[0] == 4)
        #expect(env.svc(0x7963_2003, [0x103, s, 0, 1]).1.x[0] == 0)
        let sem = try env.u32(s)
        #expect(env.kernel.semaphore(named: sem)?.count == 1)
        #expect(env.svc(m(-36), [UInt64(sem)]).1.x[0] == 0)  // 1 → 0
        // Timed wait at 0: waits the timeout, then times out.
        #expect(env.svc(m(-38), [UInt64(sem), 0, 5_000_000]).1.x[0] == 49)
        // Signal, then the waits succeed. signal_thread: nobody waits.
        #expect(env.svc(m(-33), [UInt64(sem)]).1.x[0] == 0)
        #expect(env.svc(m(-33), [UInt64(sem)]).1.x[0] == 0)
        #expect(env.svc(m(-35), [UInt64(sem), 0x203]).1.x[0] == 24)
        #expect(env.svc(m(-35), [UInt64(sem), 0]).1.x[0] == 24)
        #expect(env.kernel.semaphore(named: sem)?.count == 2)
        #expect(env.svc(m(-38), [UInt64(sem), 0, 0]).1.x[0] == 0)
        #expect(env.svc(m(-36), [UInt64(sem)]).1.x[0] == 0)
        // wait_signal: the signal comes first, so waiting on the same semaphore succeeds.
        #expect(env.svc(m(-37), [UInt64(sem), UInt64(sem)]).1.x[0] == 0)
        #expect(env.kernel.semaphore(named: sem)?.count == 0)
        env.svc(0x7963_2003, [0x103, s + 4, 0, 0])
        let other = try env.u32(s + 4)
        #expect(env.svc(m(-39), [UInt64(sem), UInt64(other), 0, 10]).1.x[0] == 49)
        #expect(env.kernel.semaphore(named: other)?.count == 1)
        // signal_all with no waiter: nothing changes.
        #expect(env.svc(m(-34), [UInt64(other)]).1.x[0] == 0)
        #expect(env.kernel.semaphore(named: other)?.count == 1)
        // Not a semaphore.
        for n in [-33, -34, -36, -38] { #expect(env.svc(m(n), [0x103, 0, 0]).1.x[0] == 15) }
        #expect(env.svc(m(-37), [UInt64(sem), 0x9999]).1.x[0] == 15)
        // Destroy.
        #expect(env.svc(0x7963_2004, [0x103, UInt64(sem)]).1.x[0] == 0)
        #expect((env.kernel.machIPC as? MachIPC)?.entry(sem) == nil)
        #expect(env.svc(0x7963_2004, [0x103, UInt64(sem)]).1.x[0] == 15)
        #expect(env.svc(0x7963_2004, [0x103, 0x103]).1.x[0] == 15)
        #expect(env.svc(0x7963_2003, [0x103, 0x10, 0, 0]).1.x[0] == 1)
    }

    @Test func specialPorts() throws {
        let env = try Env()
        try env.put(leBytes(0xFFFF_FFFF), at: s)
        #expect(env.svc(0x7963_2005, [0x103, 4, s]).1.x[0] == 0)
        #expect(try env.u32(s) == 0x503)
        #expect((env.kernel.machIPC as? MachIPC)?.entry(0x503) != nil)
        // Stage 4b (processes.md §3.2): which = 1 is the task's control port.
        #expect(env.svc(0x7963_2005, [0x103, 1, s]).1.x[0] == 0)
        #expect(try env.u32(s) == 0x103)
        #expect(env.svc(0x7963_2005, [0x103, 7, s]).1.x[0] == 4)  // KERN_INVALID_ARGUMENT
        // (Stage 4a: the special ports hold real send rights in MachIPC.)
        #expect(env.svc(0x7963_2006, [0x103, 9, 0x303]).1.x[0] == 0)
        env.svc(0x7963_2005, [0x103, 9, s])
        #expect(try env.u32(s) == 0x303)
        #expect(env.svc(0x7963_2005, [0x103, 4, 0x10]).1.x[0] == 1)
        // mach_msg to the bootstrap port still fails.
        var header: [UInt8] = []
        for v: UInt32 in [0x13, 24, 0x503, 0, 0, 1] { header += (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        try env.put(header, at: s + 0x40)
        #expect(env.svc(m(-31), [s + 0x40, 1, 24, 0, 0, 0, 0]).1.x[0] == 0x1000_0003)
        // The bootstrap name is permanent and typed as a send right.
        #expect(env.svc(m(-76), [0x103, 0x503, s]).1.x[0] == 0)
        #expect(try env.u32(s) == 1 << 16)
    }
}
