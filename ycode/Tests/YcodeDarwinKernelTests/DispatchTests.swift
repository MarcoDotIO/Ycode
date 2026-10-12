import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

@Suite struct DispatchTests {
    @Test func decodeOrder() throws {
        let env = try Env()
        // Private range wins over the BSD low-16-bit decode (0x0003 would be `read`).
        var f = TrapFrame()
        try env.put([UInt8](repeating: 0xEE, count: 16), at: Env.scratch)
        #expect(env.svc(0x7963_0003, [Env.scratch, 64], frame: &f) == .resume)
        #expect(!f.carry && f.x[0] == Env.scratch)
        #expect(try env.string(Env.scratch) == "/")

        // Platform call: x3 = 2 sets TPIDRRO, x3 = 3 reads it back; x0 and carry untouched on set.
        f = TrapFrame(spsr: 0x2000_0000)
        env.svc(0x8000_0000, [0x3_2000_8000], x3: 2, frame: &f)
        #expect(f.tpidrro == 0x3_2000_8000 && f.x[0] == 0x3_2000_8000 && f.carry)
        f.x[0] = 0
        env.svc(0x8000_0000, [], x3: 3, frame: &f)
        #expect(f.x[0] == 0x3_2000_8000)
        env.svc(0x8000_0000, [0x77], x3: 9, frame: &f)  // other selectors: no-op
        #expect(f.x[0] == 0x77 && f.tpidrro == 0x3_2000_8000)

        // Negative: Mach. Upper 32 bits of x16 are ignored.
        let (o1, f1) = env.svc(0xFFFF_FFFF_FFFF_FFE4)  // -28 task_self_trap
        #expect(o1 == .resume && f1.x[0] == 0x103)
        let (_, f2) = env.svc(0x0000_0000_FFFF_FFE5)  // -27 thread_self_trap
        #expect(f2.x[0] == 0x203)

        // BSD by the low 16 bits.
        let (_, f3) = env.svc(0x0001_0014)  // 20 getpid
        #expect(f3.x[0] == 100 && !f3.carry)
    }

    @Test func indirectSyscall() throws {
        let env = try Env()
        try env.putString("hi\n", at: Env.scratch)
        var f = TrapFrame()
        // syscall(SYS_write, 1, buf, 3): number in x0, arguments shifted by one.
        env.svc(0, [4, 1, Env.scratch, 3], frame: &f)
        #expect(f.x[0] == 3 && !f.carry)
        #expect(env.sink.text(1) == "hi\n")
        let (_, g) = env.svc(0, [20])
        #expect(g.x[0] == 100)
        #expect(env.sink.lines.contains { $0.hasPrefix("trap bsd 0 (indirect 4) write(") })
    }

    @Test func bsdErrorConvention() throws {
        let env = try Env()
        var f = TrapFrame()
        f.x[1] = 0xDEAD
        env.svc(6, [99], frame: &f)  // close(99)
        #expect(f.carry && f.x[0] == 9 && f.x[1] == 0)
        // Success clears carry and x1.
        f.x[1] = 0xBEEF
        env.svc(24, [], frame: &f)  // getuid
        #expect(!f.carry && f.x[0] == 501 && f.x[1] == 0)
        #expect(env.svc(25).1.x[0] == 501 && env.svc(43).1.x[0] == 20 && env.svc(47).1.x[0] == 20)
        #expect(env.svc(327).1.x[0] == 0)
        let (_, ioctl) = env.svc(54, [1, 0x4004_7400, 0])
        #expect(ioctl.carry && ioctl.x[0] == 25)
        let (_, g) = env.svc(427)  // fsgetpath
        #expect(g.carry && g.x[0] == 45)
        #expect(env.sink.lines.contains("trap bsd 6 close(99) -> error 9 (EBADF)"))
    }

    @Test func unimplementedTraps() throws {
        let env = try Env()
        let (o, f) = env.svc(2)  // fork
        guard case let .unimplemented(text) = o else { Issue.record("expected unimplemented"); return }
        #expect(text.hasPrefix("unimplemented bsd 2 fork("))
        #expect(f.carry && f.x[0] == 78)
        let (o2, _) = env.svc(600)  // beyond the table: nosys
        guard case let .unimplemented(t2) = o2 else { Issue.record("expected unimplemented"); return }
        #expect(t2.hasPrefix("unimplemented bsd 600 nosys("))
        let (o3, f3) = env.svc(UInt64(bitPattern: -62), [0x1003])  // clock_sleep_trap
        guard case let .unimplemented(t3) = o3 else { Issue.record("expected unimplemented"); return }
        #expect(t3.hasPrefix("unimplemented mach -62 clock_sleep_trap(clock_name=0x1003"))
        #expect(f3.x[0] == 5)
        let (o4, _) = env.svc(0x7963_0099)
        if case .unimplemented = o4 {} else { Issue.record("expected unimplemented private") }
    }

    @Test func exitAndAbort() throws {
        let env = try Env()
        #expect(env.svc(1, [0x1_0003]).0 == .exit(status: 3))
        try env.putString("dyld: missing symbol", at: Env.scratch)
        let (o, _) = env.svc(521, [6, 4, 0, 0, Env.scratch, 0])
        guard case let .fatal(status, message) = o else { Issue.record("expected fatal"); return }
        #expect(status == 134)
        #expect(message.contains("dyld: missing symbol"))
        // A non-SVC trap is fatal 70.
        var f = TrapFrame(kind: TrapFrame.Kind.el0Synchronous.rawValue)
        guard case let .fatal(s2, _) = env.kernel.handle(&f, memory: env.space) else { Issue.record("fatal"); return }
        #expect(s2 == 70)
    }

    @Test func clockTraps() throws {
        var ticks: UInt64 = 1000
        let env = try Env(counter: { ticks += 1; return ticks }, frequency: 24_000_000)
        var f = TrapFrame(spsr: 0x2000_0000)
        f.x[1] = 0x55
        env.svc(UInt64(bitPattern: -3), [], frame: &f)
        #expect(f.x[0] == 1001 && f.x[1] == 0x55 && f.carry)
        env.svc(UInt64(bitPattern: -4), [], frame: &f)
        #expect(f.x[0] == 1002)
        let (_, g) = env.svc(UInt64(bitPattern: -89), [Env.scratch])
        #expect(g.x[0] == 0)
        #expect(try env.u32(Env.scratch) == 125 && env.u32(Env.scratch + 4) == 3)
        env.kernel.counterFrequency = 1_000_000_000
        #expect(env.kernel.timebase.numer == 1 && env.kernel.timebase.denom == 1)
        env.kernel.counterFrequency = 19_200_000
        #expect(env.kernel.timebase.numer == 625 && env.kernel.timebase.denom == 12)
        #expect(env.svc(UInt64(bitPattern: -61), [0, 0, 0]).1.x[0] == 0)
    }

    @Test func gettimeofday() throws {
        let env = try Env()
        let (_, f) = env.svc(116, [Env.scratch, 0, Env.scratch + 0x100])
        #expect(f.x[0] == 0 && !f.carry)
        #expect(try env.u64(Env.scratch) == 1_700_000_000)
        #expect(try env.u32(Env.scratch + 8) == 250_000)
        #expect(try env.u64(Env.scratch + 0x100) == 0x1234)
    }

    @Test func resumeFlagsAndFlush() throws {
        var frame = TrapFrame()
        frame.flushTLB = true
        #expect(frame.resumeFlags == 1)
        #expect(u64(frame.encoded(), 312) == 1)
        #expect(TrapFrame.Offset.resumeFlags == 312)
        #expect(try TrapFrame(decoding: frame.encoded()).resumeFlags == 0)
        frame.flushTLB = false
        #expect(frame.resumeFlags == 0)

        let env = try Env()
        let (_, a) = env.svc(20)
        #expect(!a.flushTLB)
        let (_, b) = env.svc(197, [0, 0x4000, 3, 0x1002, UInt64(bitPattern: -1), 0])
        #expect(b.flushTLB)
    }
}
