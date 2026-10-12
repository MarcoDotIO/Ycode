import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The Ycode-private Mach routines (`host-libraries.md` §10, stage4a-contract
/// §7) and the voucher traps, served by `MachIPC`.
@Suite struct MachIPCRoutineTests {
    let s = IPCEnv.scratch + 0x30000

    @Test func clockService() throws {
        let env = try IPCEnv()
        env.ipc.systemClock = { (2, 500_000_000) }
        env.ipc.calendarClock = { (1_700_000_000, 250_000_000) }
        #expect(env.kr(0x7963_2001, [0x303, 0, s]) == 0)
        let system = env.r32(s)
        #expect(env.ipc.kernelObjectKind(of: system) == .clock(id: 0))
        #expect(env.kr(0x7963_2001, [0x303, 1, s + 4]) == 0)
        let calendar = env.r32(s + 4)
        #expect(env.ipc.kernelObjectKind(of: calendar) == .clock(id: 1) && calendar != system)
        // The same clock again: one name, one more reference.
        #expect(env.kr(0x7963_2001, [0x303, 0, s + 8]) == 0)
        #expect(env.r32(s + 8) == system && env.urefs(system) == 2)
        #expect(env.kr(0x7963_2001, [0x303, 2, s]) == MachKern.invalidArgument)
        #expect(env.kr(0x7963_2001, [0x303, 0, 0x10]) == MachKern.invalidAddress)
        #expect(env.urefs(system) == 2)
        #expect(env.kr(0x7963_2002, [UInt64(system), s + 0x10]) == 0)
        #expect(env.r32(s + 0x10) == 2 && env.r32(s + 0x14) == 500_000_000)
        #expect(env.kr(0x7963_2002, [UInt64(calendar), s + 0x10]) == 0)
        #expect(env.r32(s + 0x10) == 1_700_000_000 && env.r32(s + 0x14) == 250_000_000)
        #expect(env.kr(0x7963_2002, [0x103, s + 0x10]) == MachKern.invalidArgument)
        #expect(env.kr(0x7963_2002, [UInt64(system), 0x10]) == MachKern.invalidAddress)
        // Carry is clear.
        var f = TrapFrame(spsr: 0x2000_0000)
        f.x[0] = UInt64(system)
        f.x[1] = s
        _ = env.ipc.handleTrap(x16: 0x7963_2002, frame: &f, context: env.main, memory: env.space)
        #expect(f.x[0] == 0 && !f.carry)
    }

    @Test func semaphores() throws {
        let env = try IPCEnv()
        #expect(env.kr(0x7963_2003, [0x103, s, 0, UInt64(UInt32(bitPattern: -1))]) == MachKern.invalidArgument)
        #expect(env.kr(0x7963_2003, [0x103, s, 0, 3]) == 0)
        let sem = env.r32(s)
        if case .semaphore = env.ipc.kernelObjectKind(of: sem) {} else { Issue.record("not a semaphore port") }
        let object = try #require(env.ipc.semaphore(named: sem))
        #expect(object.count == 3)
        #expect(env.ipc.semaphore(named: 0x103) == nil)
        #expect(env.kr(0x7963_2003, [0x103, 0x10, 0, 0]) == MachKern.invalidAddress)
        #expect(env.kr(0x7963_2004, [0x103, 0x103]) == MachKern.invalidName)
        #expect(env.kr(0x7963_2004, [0x103, UInt64(sem)]) == 0)
        #expect(object.isDestroyed)
        #expect(env.ipc.semaphore(named: sem) == nil)
        #expect(env.kr(0x7963_2004, [0x103, UInt64(sem)]) == MachKern.invalidName)
    }

    @Test func specialPorts() throws {
        let env = try IPCEnv()
        #expect(env.kr(0x7963_2005, [0x103, 4, s]) == 0)
        #expect(env.r32(s) == 0x503)
        #expect(env.urefs(0x503) == 2)
        // Stage 4b (processes.md §3.2): which = 3 is the task's name port.
        #expect(env.kr(0x7963_2005, [0x103, 3, s]) == 0)
        let namePort = env.r32(s)
        #expect(namePort != 0 && env.ipc.kernelObjectKind(of: namePort) == .taskName)
        #expect(env.kr(0x7963_2005, [0x103, 7, s]) == MachKern.invalidArgument)
        let p = env.allocate()
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        #expect(env.kr(0x7963_2006, [0x103, 10, UInt64(p)]) == 0)
        #expect(env.ipc.portCounters(p)?.srights == 2)  // the kernel holds a send right
        #expect(env.kr(0x7963_2005, [0x103, 10, s]) == 0)
        #expect(env.r32(s) == p && env.urefs(p) == 2)
        #expect(env.kr(0x7963_2006, [0x103, 10, 0x55503]) == MachMsgReturn.sendInvalidRight)
        #expect(env.kr(0x7963_2006, [0x103, 10, 0]) == 0)
        #expect(env.ipc.portCounters(p)?.srights == 1)
        #expect(env.kr(0x7963_2005, [0x103, 10, s]) == 0)
        #expect(env.r32(s) == 0)
        // The access port (9) is set once; host and control cannot be set.
        #expect(env.kr(0x7963_2006, [0x103, 9, UInt64(p)]) == 0)
        #expect(env.kr(0x7963_2006, [0x103, 9, 0]) == MachKern.noAccess)
        #expect(env.kr(0x7963_2006, [0x103, 2, UInt64(p)]) == MachKern.noAccess)
        #expect(env.kr(0x7963_2006, [0x103, 1, UInt64(p)]) == MachKern.noAccess)
        #expect(env.kr(0x7963_2006, [0x103, 3, UInt64(p)]) == MachKern.invalidArgument)
        #expect(env.ipc.portCounters(p)?.srights == 2)  // only the access slot holds one
        // A task argument that is not a task control port.
        #expect(env.kr(0x7963_2005, [0x303, 4, s]) == MachKern.invalidArgument)
        #expect(env.kr(0x7963_2005, [0, 4, s]) == MachMsgReturn.sendInvalidDest)
        #expect(env.kr(0x7963_2005, [0x103, 4, 0x10]) == MachKern.invalidAddress)
    }

    @Test func vouchers() throws {
        let env = try IPCEnv()
        env.put(le32(0xFFFF_FFFF), at: s)
        #expect(env.kr(0x7963_2007, [0x303, 0, 0, s]) == 0)
        #expect(env.r32(s) == 0)
        #expect(env.kr(0x7963_2007, [0x303, 0, 0, 0x10]) == MachKern.invalidAddress)
        env.put(le32(0xFFFF_FFFF), at: s)
        #expect(env.kr(-70, [0x303, 0, 16, s]) == 0)
        #expect(env.r32(s) == 0)
        #expect(env.kr(-70, [0x303, 0, UInt64(UInt32(bitPattern: -1)), s]) == MachKern.invalidArgument)
        #expect(env.kr(-70, [0x303, 0, 100_000, s]) == MachKern.migArrayTooLarge)
        #expect(env.kr(-72, [0, 1, s, s + 8]) == MachMsgReturn.sendInvalidDest)
        // Unknown routines in the range.
        var f = TrapFrame()
        let outcome = env.ipc.handleTrap(x16: 0x7963_20AB, frame: &f, context: env.main, memory: env.space)
        if case .unimplemented = outcome {} else { Issue.record("expected unimplemented, got \(String(describing: outcome))") }
        #expect(f.carry)
    }

    @Test func attachedToADarwinKernel() throws {
        let env = try Env()
        let ipc = MachIPC(kernel: env.kernel)
        env.kernel.machIPC = ipc
        // A port trap through DarwinKernel.handle reaches MachIPC.
        let (outcome, f) = env.svc(UInt64(bitPattern: -16), [0x103, 1, Env.scratch])
        #expect(outcome == .resume && f.x[0] == 0)
        let name = try env.u32(Env.scratch)
        #expect(ipc.entry(name)?.type == MachPortType.receive)
        #expect(env.sink.lines.contains { $0.hasPrefix("trap mach -16 mach_port_allocate") })
        // The clock routine through the kernel, with the kernel's clocks.
        let (_, g) = env.svc(0x7963_2001, [0x303, 1, Env.scratch + 8])
        #expect(g.x[0] == 0)
        let clock = try env.u32(Env.scratch + 8)
        let (_, h) = env.svc(0x7963_2002, [UInt64(clock), Env.scratch + 0x10])
        let seconds = try env.u32(Env.scratch + 0x10)
        #expect(h.x[0] == 0 && seconds == 1_700_000_000)
        // Semaphores made here are the kernel's semaphores.
        let (_, k) = env.svc(0x7963_2003, [0x103, Env.scratch + 0x20, 0, 2])
        #expect(k.x[0] == 0)
        let semName = try env.u32(Env.scratch + 0x20)
        #expect(env.kernel.semaphore(named: semName)?.count == 2)
        // The kevent hook was installed by the kernel.
        #expect(ipc.messageQueuedHandler != nil)
    }

    /// launchd_sim's `mach_port_set_attributes`: MIG 3218 to the task port via
    /// `mach_msg2` with SEND|RCV|MQ_CALL (options 0x4_0000_0003), and 3217.
    @Test func portAttributesAsMIGMessages() throws {
        let env = try IPCEnv()
        let reply = env.allocate()
        let p = env.allocate()
        let data = IPCEnv.sendBuffer
        func rpc(_ id: Int32, _ args: [UInt32], options: UInt64 = 0x4_0000_0003) -> (UInt32, Received) {
            let size = 32 + 4 * args.count
            env.put([UInt8](repeating: 0, count: 24) + machNDRRecord + args.flatMap(le32), at: data)
            let k = env.kr(-47, [data, options, 0x1513 | UInt64(size) << 32, 0x103 | UInt64(reply) << 32,
                                 UInt64(UInt32(bitPattern: id)) << 32, UInt64(reply) << 32, 0x100, 0])
            return (k, Received(env.read(data, 0x100)))
        }
        // set LIMITS_INFO (qlimit 9), then get it back.
        var (k, r) = rpc(3218, [p, 1, 1, 9])
        #expect(k == 0 && r.id == 3318 && r.size == 36 && r.u32(32) == 0)
        #expect(env.ipc.portCounters(p)?.qlimit == 9)
        (k, r) = rpc(3217, [p, 1, 17])
        #expect(k == 0 && r.id == 3317 && r.u32(32) == 0 && r.u32(36) == 1 && r.u32(40) == 9)
        // The same with KOBJECT_CALL.
        (k, r) = rpc(3218, [p, 1, 1, 5], options: 0x2_0000_0003)
        #expect(k == 0 && r.u32(32) == 0 && env.ipc.portCounters(p)?.qlimit == 5)
        // Accepted, no effect: DNREQUESTS_SIZE, TEMPOWNER, IMPORTANCE_RECEIVER, DENAP_RECEIVER.
        for flavor: UInt32 in [3, 4, 5, 6] {
            (k, r) = rpc(3218, [p, flavor, 1, 0])
            #expect(k == 0 && r.u32(32) == 0)
        }
        (k, r) = rpc(3218, [p, 4, 0])
        #expect(r.u32(32) == 0)
        // Errors in xnu order.
        #expect(rpc(3218, [p, 1, 1, 1025]).1.u32(32) == MachKern.invalidValue)
        #expect(rpc(3218, [p, 1, 0]).1.u32(32) == MachKern.failure)
        #expect(rpc(3218, [0, 4, 0]).1.u32(32) == MachKern.invalidRight)
        #expect(rpc(3218, [0x77703, 4, 0]).1.u32(32) == MachKern.invalidName)
        #expect(rpc(3218, [0x103, 4, 0]).1.u32(32) == MachKern.invalidRight)
        #expect(rpc(3218, [p, 9, 1, 1]).1.u32(32) == MachKern.invalidCapability)
        #expect(rpc(3218, [p, 8, 0]).1.u32(32) == MachKern.invalidArgument)
        #expect(rpc(3218, [p, 77, 0]).1.u32(32) == MachKern.invalidArgument)
        // get: RECEIVE_STATUS (10 words), INFO_EXT (17), DNREQUESTS_SIZE, GUARD_INFO refused.
        (k, r) = rpc(3217, [p, 2, 17])
        #expect(r.u32(32) == 0 && r.u32(36) == 10 && r.u32(36 + 4 * 4) == 5)  // mps_qlimit
        (k, r) = rpc(3217, [p, 7, 17])
        #expect(r.u32(32) == 0 && r.u32(36) == 17)
        #expect(rpc(3217, [p, 3, 17]).1.u32(40) == 0)
        #expect(rpc(3217, [p, 8, 17]).1.u32(32) == MachKern.invalidArgument)
        #expect(rpc(3217, [p, 2, 3]).1.u32(32) == MachKern.failure)
        #expect(rpc(3217, [0, 2, 17]).1.u32(32) == MachKern.invalidRight)
        #expect(rpc(3217, [p, 9, 1]).1.u32(32) == MachKern.invalidCapability)
    }
}
