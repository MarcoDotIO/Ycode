import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// `mach-ipc.md` §1: the name space, rights, user references, and the port traps.
@Suite struct MachIPCPortTests {
    let S = MachPortType.send, R = MachPortType.receive, SO = MachPortType.sendOnce
    let PS = MachPortType.portSet, DN = MachPortType.deadName

    @Test func wellKnownNamesAreRealEntries() throws {
        let env = try IPCEnv()
        #expect(env.ipc.kernelObjectKind(of: 0x103) == .task)
        #expect(env.ipc.kernelObjectKind(of: 0x203) == .thread(serial: 0))
        #expect(env.ipc.kernelObjectKind(of: 0x303) == .host)
        #expect(env.ipc.kernelObjectKind(of: 0x503) == .bootstrap)
        for name: UInt32 in [0x103, 0x203, 0x303, 0x503] {
            #expect(env.type(name) == (0, S))
            #expect(env.urefs(name) == 1)
        }
        // Index 4 is the first free slot, then 6, 7, ...
        #expect(env.allocate() == 0x403)
        #expect(env.allocate() == 0x603)
        #expect(env.allocate() == 0x703)
    }

    @Test func lastFreedFirstReuseAdvancesTheGeneration() throws {
        let env = try IPCEnv()
        let a = env.allocate(), b = env.allocate(), c = env.allocate()
        #expect([a, b, c] == [0x403, 0x603, 0x703])
        #expect(env.modRefs(b, MachPortRight.receive, -1) == 0)
        #expect(env.modRefs(a, MachPortRight.receive, -1) == 0)
        // a was freed last: its slot comes back first, with the next generation.
        #expect(env.allocate() == 0x407)
        #expect(env.allocate() == 0x607)
        #expect(env.allocate() == 0x803)
        // The old names are gone.
        #expect(env.type(a).0 == MachKern.invalidName)
        #expect(env.deallocate(b) == MachKern.invalidName)
        // Every name has the low bits 11.
        for _ in 0..<70 {
            let n = env.allocate()
            #expect(n & 3 == 3)
            #expect(env.modRefs(n, MachPortRight.receive, -1) == 0)
        }
    }

    @Test func allocateRights() throws {
        let env = try IPCEnv()
        let r = env.allocate(MachPortRight.receive)
        let set = env.allocate(MachPortRight.portSet)
        let dead = env.allocate(MachPortRight.deadName)
        #expect(env.type(r) == (0, R))
        #expect(env.type(set) == (0, PS))
        #expect(env.type(dead) == (0, DN))
        #expect(env.urefs(dead) == 1)
        #expect(env.kr(-16, [env.task, UInt64(MachPortRight.send), env.out]) == MachKern.invalidValue)
        #expect(env.kr(-16, [env.task, 6, env.out]) == MachKern.invalidValue)
        // A bad out pointer is the copyout error; the right stays allocated (as in xnu).
        let before = env.ipc.nameCount
        #expect(env.kr(-16, [env.task, 1, 0x10]) == MachKern.copyFault)
        #expect(env.ipc.nameCount == before + 1)
        // The target must be the task's own port.
        #expect(env.kr(-16, [0x303, 1, env.out]) == MachMsgReturn.sendInvalidDest)
        #expect(env.kr(-18, [0x999, UInt64(r)]) == MachMsgReturn.sendInvalidDest)
        // NULL/DEAD types.
        #expect(env.type(0).0 == MachKern.invalidName)
        #expect(env.type(MachPortName.dead) == (0, DN))
    }

    @Test func deallocateRules() throws {
        let env = try IPCEnv()
        #expect(env.deallocate(0) == 0)
        #expect(env.deallocate(MachPortName.dead) == 0)
        #expect(env.deallocate(0x12303) == MachKern.invalidName)
        let p = env.allocate()
        #expect(env.deallocate(p) == MachKern.invalidRight)  // receive only
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        #expect(env.type(p) == (0, S | R))
        #expect(env.urefs(p) == 2)
        #expect(env.ipc.portCounters(p)?.srights == 1)
        #expect(env.ipc.portCounters(p)?.mscount == 2)
        #expect(env.deallocate(p) == 0)
        #expect(env.urefs(p) == 1)
        #expect(env.deallocate(p) == 0)  // last send uref: only the send right goes
        #expect(env.type(p) == (0, R))
        #expect(env.ipc.portCounters(p)?.srights == 0)
        // A port set is destroyed by deallocate.
        let set = env.allocate(MachPortRight.portSet)
        #expect(env.deallocate(set) == 0)
        #expect(env.type(set).0 == MachKern.invalidName)
        // A dead name loses one reference.
        let dead = env.allocate(MachPortRight.deadName)
        #expect(env.modRefs(dead, MachPortRight.deadName, 2) == 0)
        #expect(env.urefs(dead) == 3)
        #expect(env.deallocate(dead) == 0)
        #expect(env.urefs(dead) == 2)
    }

    @Test func modRefsRules() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        #expect(env.modRefs(p, 6, 0) == MachKern.invalidValue)
        #expect(env.modRefs(0, MachPortRight.send, 1) == 0)
        #expect(env.modRefs(MachPortName.dead, MachPortRight.sendOnce, -1) == 0)
        #expect(env.modRefs(0, MachPortRight.receive, -1) == MachKern.invalidName)
        #expect(env.modRefs(0x55503, MachPortRight.send, 1) == MachKern.invalidName)
        #expect(env.modRefs(p, MachPortRight.send, 1) == MachKern.invalidRight)  // no send right
        #expect(env.modRefs(p, MachPortRight.receive, -2) == MachKern.invalidValue)
        #expect(env.modRefs(p, MachPortRight.receive, 1) == MachKern.invalidValue)
        #expect(env.modRefs(p, MachPortRight.receive, 0) == 0)
        #expect(env.modRefs(p, MachPortRight.portSet, 0) == MachKern.invalidRight)
        #expect(env.modRefs(p, MachPortRight.labelh, 0) == MachKern.invalidRight)
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        #expect(env.modRefs(p, MachPortRight.send, 10) == 0)
        #expect(env.urefs(p) == 11)
        #expect(env.modRefs(p, MachPortRight.send, -12) == MachKern.invalidValue)  // underflow
        #expect(env.modRefs(p, MachPortRight.send, 0x10000) == MachKern.invalidValue)
        #expect(env.urefs(p) == 11)
        // Pegging at 0xFFFF.
        #expect(env.modRefs(p, MachPortRight.send, 0xFFFF) == 0)
        #expect(env.urefs(p) == 0xFFFF)
        #expect(env.modRefs(p, MachPortRight.send, -5) == 0)  // no effect on a pegged count
        #expect(env.urefs(p) == 0xFFFF)
        #expect(env.deallocate(p) == 0)
        #expect(env.urefs(p) == 0xFFFF)
        #expect(env.modRefs(p, MachPortRight.send, -0xFFFF) == 0)  // only -0xFFFF changes it
        #expect(env.type(p) == (0, R))
        // Receive −1 destroys the port; the name goes.
        #expect(env.modRefs(p, MachPortRight.receive, -1) == 0)
        #expect(env.type(p).0 == MachKern.invalidName)
        // Port set and dead-name deltas.
        let set = env.allocate(MachPortRight.portSet)
        #expect(env.modRefs(set, MachPortRight.portSet, 1) == MachKern.invalidValue)
        #expect(env.modRefs(set, MachPortRight.portSet, -1) == 0)
        let dead = env.allocate(MachPortRight.deadName)
        #expect(env.modRefs(dead, MachPortRight.send, -1) == MachKern.invalidRight)
        #expect(env.modRefs(dead, MachPortRight.deadName, -1) == 0)
        #expect(env.type(dead).0 == MachKern.invalidName)
    }

    @Test func insertRightRules() throws {
        let env = try IPCEnv()
        let p = env.allocate(), q = env.allocate()
        #expect(env.insertRight(0, p, MachMsgType.makeSend) == MachKern.invalidValue)
        #expect(env.insertRight(p, p, 22) == MachKern.invalidValue)
        #expect(env.insertRight(p, 0, MachMsgType.makeSend) == MachKern.invalidCapability)
        #expect(env.insertRight(p, MachPortName.dead, MachMsgType.makeSend) == MachKern.invalidCapability)
        #expect(env.insertRight(p, 0x77703, MachMsgType.makeSend) == MachKern.invalidName)
        #expect(env.insertRight(p, p, MachMsgType.copySend) == MachKern.invalidRight)  // no send right yet
        // The space names the port under p: another name is RIGHT_EXISTS.
        #expect(env.insertRight(0x9903, p, MachMsgType.makeSend) == MachKern.rightExists)
        // A name used by another port.
        #expect(env.insertRight(q, p, MachMsgType.makeSend) == MachKern.rightExists)
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        #expect(env.insertRight(p, p, MachMsgType.copySend) == 0)
        #expect(env.urefs(p) == 2)
        #expect(env.ipc.portCounters(p)?.srights == 1)
        // Send-once rights never coalesce: a caller-chosen fresh name.
        #expect(env.insertRight(0x9903, p, MachMsgType.makeSendOnce) == 0)
        #expect(env.type(0x9903) == (0, SO))
        #expect(env.ipc.portCounters(p)?.sorights == 1)
        #expect(env.insertRight(0x9903, p, MachMsgType.makeSendOnce) == MachKern.nameExists)
        #expect(env.insertRight(q, p, MachMsgType.makeSendOnce) == MachKern.nameExists)
        // Name rules: low bits must be 11; index 0 fails; another generation fails.
        #expect(env.insertRight(0x9900, p, MachMsgType.makeSendOnce) == MachKern.invalidValue)
        #expect(env.insertRight(0x03, p, MachMsgType.makeSendOnce) == MachKern.failure)
        #expect(env.insertRight(0x9907, p, MachMsgType.makeSendOnce) == MachKern.failure)
        // A dead name as poly.
        let dead = env.allocate(MachPortRight.deadName)
        #expect(env.insertRight(0xA003, dead, MachMsgType.copySend) == MachKern.invalidCapability)
    }

    @Test func constructAndDestruct() throws {
        let env = try IPCEnv()
        let (k, p) = env.construct(flags: MachPortConstruct.insertSendRight | MachPortConstruct.qlimit, qlimit: 7)
        #expect(k == 0)
        #expect(env.type(p) == (0, S | R))
        #expect(env.urefs(p) == 1)
        let c = env.ipc.portCounters(p)!
        #expect(c.srights == 1 && c.mscount == 1 && c.qlimit == 7)
        #expect(env.construct(flags: MachPortConstruct.qlimit, qlimit: 1025).0 == MachKern.invalidValue)
        #expect(env.construct(flags: 0x4000_0000).0 == MachKern.invalidArgument)
        #expect(env.construct(flags: 0x400 | 0x800).0 == MachKern.invalidArgument)  // two type values (0xC00)
        #expect(env.construct(flags: MachPortConstruct.tgBlockTracking).0 == MachKern.denied)
        #expect(env.construct(flags: MachPortConstruct.connectionPort).0 == MachKern.invalidArgument)
        #expect(env.construct(flags: MachPortConstruct.replyPort).0 == 0)  // a weak reply port in the simulator
        #expect(env.kr(-24, [env.task, 0x10, 0, env.out]) == MachKern.copyFault)

        // Guarded construction; destruct checks the guard.
        let (k2, g) = env.construct(flags: MachPortConstruct.contextAsGuard | MachPortConstruct.strict
                                        | MachPortConstruct.insertSendRight, context: 0xFEED)
        #expect(k2 == 0)
        #expect(env.kr(-25, [env.task, UInt64(g), 1, 0xFEED]) == MachKern.invalidValue)
        #expect(env.kr(-25, [env.task, UInt64(g), UInt64(UInt32(bitPattern: -2)), 0xFEED]) == MachKern.invalidValue)
        #expect(env.kr(-25, [env.task, UInt64(g), UInt64(UInt32(bitPattern: -1)), 0xBAD]) == MachKern.invalidArgument)
        #expect(env.modRefs(g, MachPortRight.receive, -1) == MachKern.invalidRight)  // guarded
        #expect(env.kr(-25, [env.task, UInt64(g), UInt64(UInt32(bitPattern: -1)), 0xFEED]) == 0)
        #expect(env.type(g).0 == MachKern.invalidName)
        // srdelta without a send right.
        let plain = env.allocate()
        #expect(env.kr(-25, [env.task, UInt64(plain), UInt64(UInt32(bitPattern: -1)), 0]) == MachKern.invalidRight)
        #expect(env.kr(-25, [env.task, 0, 0, 0]) == MachKern.invalidName)
        #expect(env.kr(-25, [env.task, 0x103, 0, 0]) == MachKern.invalidRight)
        #expect(env.kr(-25, [env.task, UInt64(plain), 0, 0]) == 0)
    }

    @Test func guards() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        #expect(env.kr(-41, [env.task, UInt64(p), 0x1234, 1]) == 0)
        #expect(env.kr(-41, [env.task, UInt64(p), 0x5678, 0]) == MachKern.invalidArgument)
        #expect(env.kr(-42, [env.task, UInt64(p), 0x9999]) == MachKern.invalidArgument)
        #expect(env.kr(-42, [env.task, UInt64(p), 0x1234]) == 0)
        #expect(env.kr(-42, [env.task, UInt64(p), 0x1234]) == MachKern.invalidArgument)
        #expect(env.kr(-41, [env.task, 0x103, 1, 0]) == MachKern.invalidRight)
        #expect(env.kr(-41, [env.task, 0x88803, 1, 0]) == MachKern.invalidName)
    }

    @Test func attributes() throws {
        let env = try IPCEnv()
        let p = env.allocate()
        let info = env.out + 0x400, count = env.out + 0x500
        func get(_ name: UInt32, _ flavor: UInt32, _ n: UInt32) -> (UInt32, [UInt32]) {
            env.put(le32(n), at: count)
            let k = env.kr(-40, [env.task, UInt64(name), UInt64(flavor), info, count])
            let c = env.r32(count)
            return (k, (0..<Int(c)).map { env.r32(info + UInt64(4 * $0)) })
        }
        #expect(get(p, 1, 1) == (0, [5]))
        #expect(get(p, 1, 0).0 == MachKern.failure)
        #expect(get(0, 1, 1) == (0, []))
        #expect(get(p, 99, 17).0 == MachKern.invalidArgument)
        #expect(get(0x103, 2, 10).0 == MachKern.invalidRight)
        #expect(env.insertRight(p, p, MachMsgType.makeSend) == 0)
        let set = env.allocate(MachPortRight.portSet)
        #expect(env.kr(-22, [env.task, UInt64(p), UInt64(set)]) == 0)
        let (k, status) = get(p, 2, 17)
        #expect(k == 0)
        // pset, seqno, mscount, qlimit, msgcount, sorights, srights, pdrequest, nsrequest, flags
        #expect(status == [1, 0, 1, 5, 0, 0, 1, 0, 0, 0])
        #expect(get(p, 7, 17).1.count == 17)
        #expect(get(p, 7, 16).0 == MachKern.failure)
        #expect(get(p, 3, 1) == (0, [0]))
        #expect(get(p, 9, 1).0 == MachKern.invalidCapability)
    }

    @Test func portSets() throws {
        let env = try IPCEnv()
        let a = env.allocate(), b = env.allocate()
        let s1 = env.allocate(MachPortRight.portSet), s2 = env.allocate(MachPortRight.portSet)
        #expect(env.kr(-22, [env.task, UInt64(a), UInt64(s1)]) == 0)
        #expect(env.kr(-22, [env.task, UInt64(a), UInt64(s1)]) == MachKern.alreadyInSet)
        #expect(env.kr(-22, [env.task, UInt64(a), UInt64(s2)]) == 0)  // a port may be in several sets
        #expect(env.kr(-22, [env.task, 0, UInt64(s2)]) == MachKern.invalidRight)
        #expect(env.kr(-22, [env.task, UInt64(s1), UInt64(s2)]) == MachKern.invalidRight)
        #expect(env.kr(-22, [env.task, UInt64(a), UInt64(b)]) == MachKern.invalidRight)
        #expect(env.kr(-23, [env.task, UInt64(b), UInt64(s1)]) == MachKern.notInSet)
        #expect(env.kr(-23, [env.task, UInt64(a), UInt64(s2)]) == 0)
        // move_member leaves every other set.
        #expect(env.kr(-20, [env.task, UInt64(a), UInt64(s2)]) == 0)
        #expect(env.kr(-23, [env.task, UInt64(a), UInt64(s1)]) == MachKern.notInSet)
        #expect(env.kr(-20, [env.task, UInt64(a), 0]) == 0)
        #expect(env.kr(-20, [env.task, UInt64(a), 0]) == MachKern.notInSet)
        #expect(env.kr(-20, [env.task, UInt64(a), UInt64(MachPortName.dead)]) == MachKern.invalidRight)
        #expect(env.kr(-20, [env.task, 0, UInt64(s1)]) == MachKern.invalidRight)
        #expect(env.kr(-20, [env.task, UInt64(a), UInt64(b)]) == MachKern.invalidRight)
    }

    @Test func typeReportsDeadNameRequests() throws {
        let env = try IPCEnv()
        let p = env.allocate(), n = env.allocate()
        #expect(env.requestNotification(p, MachNotify.deadName, notify: n) == (0, 0))
        #expect(env.type(p) == (0, R | MachPortType.dnRequest))
        // Cancel with NULL: the previous send-once right comes back.
        let (k, previous) = env.requestNotification(p, MachNotify.deadName, notify: 0)
        #expect(k == 0)
        #expect(env.type(previous) == (0, SO))
        #expect(env.type(p) == (0, R))
    }

    @Test func lazyDeadNameConversion() throws {
        let env = try IPCEnv()
        // A send right whose receive right leaves the space and is destroyed.
        let a = env.allocate(), carrier = env.allocate()
        #expect(env.insertRight(a, a, MachMsgType.makeSend) == 0)
        #expect(env.modRefs(a, MachPortRight.send, 1) == 0)
        let n = env.allocate()
        #expect(env.requestNotification(a, MachNotify.deadName, notify: n).0 == 0)
        // Move a's receive right into a message queued on `carrier`.
        let msg = TestMessage(remote: carrier, remoteDisposition: MachMsgType.makeSend,
                              descriptors: [TestMessage.port(a, MachMsgType.moveReceive)])
        #expect(env.send(msg.bytes) == 0)
        #expect(env.type(a) == (0, S | MachPortType.dnRequest))
        #expect(env.urefs(a) == 2)
        // Destroying carrier destroys the message, the receive right, and a's port.
        #expect(env.modRefs(carrier, MachPortRight.receive, -1) == 0)
        // Lazy conversion: same name, urefs 2 + 1 for the dead-name notification.
        #expect(env.type(a) == (0, DN))
        #expect(env.urefs(a) == 3)
        let (code, raw) = env.receive(n)
        #expect(code == 0)
        let r = Received(raw)
        #expect(r.id == MachNotify.deadName && r.size == 36 && r.u32(32) == a)
        // mod_refs with SEND on the converted entry is INVALID_RIGHT.
        #expect(env.modRefs(a, MachPortRight.send, -1) == MachKern.invalidRight)
        #expect(env.modRefs(a, MachPortRight.deadName, -3) == 0)
        #expect(env.type(a).0 == MachKern.invalidName)
    }

    @Test func threadPorts() throws {
        let env = try IPCEnv()
        let t = env.ipc.allocateThreadPort()
        #expect(t & 3 == 3)
        if case .thread = env.ipc.kernelObjectKind(of: t) {} else { Issue.record("not a thread port") }
        #expect(env.type(t) == (0, S))
        // thread_self_trap adds a reference to the calling thread's name.
        let context = ThreadContext(threadID: 7, portName: t, vcpuIndex: 1, kind: .pthread)
        #expect(UInt32(env.trap(-27, context: context)) == t)
        #expect(env.urefs(t) == 2)
        env.ipc.threadTerminated(context)
        // The thread's port died: the remaining reference is a dead name.
        #expect(env.type(t) == (0, DN))
        #expect(env.urefs(t) == 1)
        env.ipc.deallocate(name: t)
        #expect(env.type(t).0 == MachKern.invalidName)
    }

    @Test func selfTraps() throws {
        let env = try IPCEnv()
        #expect(env.trap(-28) == 0x103)
        #expect(env.trap(-28) == 0x103)
        #expect(env.urefs(0x103) == 3)
        #expect(env.trap(-29) == 0x303)
        #expect(env.trap(-27) == 0x203)
        #expect(env.urefs(0x203) == 2)
        // If the task drops every reference, the next call names it afresh.
        #expect(env.modRefs(0x303, MachPortRight.send, -2) == 0)
        #expect(env.type(0x303).0 == MachKern.invalidName)
        let host = UInt32(env.trap(-29))
        #expect(host != 0x303 && env.ipc.kernelObjectKind(of: host) == .host)
        // mach_reply_port: a plain receive right.
        let reply = UInt32(env.trap(-26))
        #expect(env.type(reply) == (0, R))
    }

    @Test func untrappedNumbersAreNotHandled() throws {
        let env = try IPCEnv()
        var f = TrapFrame()
        #expect(env.ipc.handleTrap(x16: -3, frame: &f, context: env.main, memory: env.space) == nil)
        #expect(env.ipc.handleTrap(x16: -36, frame: &f, context: env.main, memory: env.space) == nil)
        #expect(env.ipc.handleTrap(x16: -89, frame: &f, context: env.main, memory: env.space) == nil)
        #expect(env.ipc.handleTrap(x16: 0x7963_0001, frame: &f, context: env.main, memory: env.space) == nil)
    }
}
