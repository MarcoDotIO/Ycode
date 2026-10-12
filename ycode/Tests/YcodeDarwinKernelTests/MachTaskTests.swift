import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Several tasks (kernels) in one `DarwinSystem`, each with its own address
/// space and `MachIPC` (stage 4b, `processes.md` §3–§4).
final class TaskWorld: @unchecked Sendable {
    static let scratch: UInt64 = 0x1_0000_0000
    static let scratchSize: UInt64 = 0x40000
    static let sendBuffer: UInt64 = scratch
    static let receiveBuffer: UInt64 = scratch + 0x8000
    static let out: UInt64 = scratch + 0x3F000

    final class Task: @unchecked Sendable {
        let kernel: DarwinKernel
        let ipc: MachIPC
        let space: GuestAddressSpace
        init(kernel: DarwinKernel, ipc: MachIPC, space: GuestAddressSpace) {
            self.kernel = kernel
            self.ipc = ipc
            self.space = space
        }
    }

    let system = DarwinSystem()
    let lines = LineBox()
    var tasks: [Task] = []

    /// Adds a task with `pid`.
    @discardableResult
    func add(pid: Int32) throws -> Task {
        let fs = DarwinFileSystem(prefixes: [], console: { _, _ in })
        let box = lines
        let kernel = DarwinKernel(fileSystem: fs, pid: pid, system: system, log: { box.append("[\(pid)] \($0)") })
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        _ = try space.mapAnonymous(at: Self.scratch, size: Self.scratchSize, protection: .readWrite, hint: nil)
        let t = Task(kernel: kernel, ipc: kernel.machIPC as! MachIPC, space: space)
        tasks.append(t)
        return t
    }

    /// A new task for `pid` that replaces `old` (exec, `processes.md` §4.7).
    func exec(_ old: Task) throws -> Task {
        let new = try add(pid: old.kernel.pid)
        new.kernel.pidVersion = old.kernel.pidVersion &+ 1
        new.ipc.inheritTaskPorts(from: old.ipc)
        old.ipc.terminateTask()
        return new
    }

    @discardableResult
    func trap(_ t: Task, _ n: Int64, _ args: [UInt64] = []) -> UInt64 {
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = UInt64(bitPattern: n)
        for (i, v) in args.enumerated() { f.x[i] = v }
        let outcome = t.ipc.handleTrap(x16: n, frame: &f, context: t.kernel.mainThread, memory: t.space)
        precondition(outcome != nil, "trap \(n) not handled")
        return f.x[0]
    }

    func kr(_ t: Task, _ n: Int64, _ args: [UInt64] = []) -> UInt32 { UInt32(truncatingIfNeeded: trap(t, n, args)) }

    func put(_ t: Task, _ bytes: [UInt8], at va: UInt64) { system.lock.withLock { try! t.space.write(va: va, bytes: bytes) } }
    func read(_ t: Task, _ va: UInt64, _ count: Int) -> [UInt8] {
        system.lock.withLock { try! t.space.read(va: va, count: count) }
    }
    func r32(_ t: Task, _ va: UInt64) -> UInt32 { read(t, va, 4).readLE(UInt32.self, at: 0) }

    func allocate(_ t: Task, _ right: UInt32 = MachPortRight.receive) -> UInt32 {
        precondition(kr(t, -16, [0x103, UInt64(right), Self.out]) == 0)
        return r32(t, Self.out)
    }

    func insertRight(_ t: Task, _ name: UInt32, _ poly: UInt32, _ disposition: UInt32) -> UInt32 {
        kr(t, -21, [0x103, UInt64(name), UInt64(poly), UInt64(disposition)])
    }

    /// Gives `to` a copy of the send right `name` of `from` (as a message
    /// would). Returns the name in `to`.
    func give(_ name: UInt32, from: Task, to: Task, disposition: UInt32 = MachMsgType.copySend) -> UInt32 {
        system.lock.withLock {
            guard case let .success(r) = from.ipc.copyin(name, disposition, slot: .body, apply: true) else {
                preconditionFailure("copyin failed")
            }
            return to.ipc.copyout(r).name
        }
    }

    func send(_ t: Task, _ msg: [UInt8]) -> UInt32 {
        put(t, msg, at: Self.sendBuffer)
        return kr(t, -31, [Self.sendBuffer, MachMsgOption.sendMsg, UInt64(msg.count), 0, 0, 0, 0])
    }

    /// Receives on `name` (no wait) with the audit trailer.
    func receive(_ t: Task, _ name: UInt32, size: UInt64 = 0x400) -> (UInt32, Received) {
        put(t, [UInt8](repeating: 0xEE, count: Int(size)), at: Self.receiveBuffer)
        let options = MachMsgOption.rcvMsg | MachMsgOption.rcvTimeout | 3 << 24
        let k = kr(t, -31, [Self.receiveBuffer, options, 0, size, UInt64(name), 0, 0])
        return (k, Received(read(t, Self.receiveBuffer, Int(size))))
    }

    func note(_ t: Task, _ name: UInt32) -> Received? {
        let (k, r) = receive(t, name)
        return k == 0 ? r : nil
    }

    func entry(_ t: Task, _ name: UInt32) -> (type: UInt32, urefs: UInt32)? { t.ipc.entry(name) }
}

@Suite struct MachTaskTests {
    let S = MachPortType.send, R = MachPortType.receive, SO = MachPortType.sendOnce, DN = MachPortType.deadName
    let out = TaskWorld.out

    @Test func eachTaskHasItsOwnSpaceAndSharedHostAndBootstrap() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        // Same well-known names, different task ports, one host and bootstrap object.
        #expect(a.ipc.kernelObjectKind(of: 0x103) == .task && b.ipc.kernelObjectKind(of: 0x103) == .task)
        #expect(a.ipc.kernelObjectKind(of: 0x303) == .host && b.ipc.kernelObjectKind(of: 0x303) == .host)
        #expect(a.ipc.kernelObjectKind(of: 0x503) == .bootstrap)
        #expect(a.ipc.portCounters(0x303)?.srights == b.ipc.portCounters(0x303)?.srights)
        // Names are allocated per space, deterministically.
        let pa = w.allocate(a), pb = w.allocate(b)
        #expect(pa == pb && pa == 0x403)
        #expect(a.ipc.system === b.ipc.system && a.ipc.system === w.system.mach)
        // Port routine traps on another task's control port keep failing.
        let bTaskInA = w.give(0x103, from: b, to: a)
        #expect(bTaskInA != 0x103 && a.ipc.kernelObjectKind(of: bTaskInA) == .task)
        #expect(w.kr(a, -16, [UInt64(bTaskInA), 1, out]) == MachMsgReturn.sendInvalidDest)
    }

    @Test func messageAcrossTasksCarriesSenderIdentity() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        b.kernel.pidVersion = 7
        let port = w.allocate(a)
        #expect(w.insertRight(a, port, port, MachMsgType.makeSend) == 0)
        let dest = w.give(port, from: a, to: b)
        #expect(dest == 0x403 && w.entry(b, dest)?.type == S)
        #expect(w.send(b, TestMessage(remote: dest, remoteDisposition: MachMsgType.copySend, id: 4242,
                                      inline: le32(0xABCD)).bytes) == 0)
        // The receiver's kevent hook fires with the receiver's name.
        let (k, r) = w.receive(a, port)
        #expect(k == 0 && r.id == 4242 && r.local == port && r.u32(24) == 0xABCD)
        #expect(r.trailer(12) == 501 && r.trailer(16) == 20)
        #expect(r.trailer(20 + 4 * 5) == 101)  // audit pid = the sender
        #expect(r.trailer(20 + 4 * 7) == 7)  // pid version of the sender
        // A's own message carries A's pid.
        #expect(w.send(a, TestMessage(remote: port, remoteDisposition: MachMsgType.makeSend).bytes) == 0)
        #expect(w.receive(a, port).1.trailer(20 + 4 * 5) == 100)
        // A message queued before the sender's exec keeps the old pid version.
        #expect(w.send(b, TestMessage(remote: dest, remoteDisposition: MachMsgType.copySend).bytes) == 0)
        let b2 = try w.exec(b)
        #expect(b2.kernel.pidVersion == 8)
        #expect(w.receive(a, port).1.trailer(20 + 4 * 7) == 7)
    }

    @Test func receiveRightMovesBetweenTasks() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        var queued: [UInt32] = []
        b.ipc.messageQueuedHandler = { queued.append($0) }
        // B's inbox; A gets a send right to it.
        let inbox = w.allocate(b)
        #expect(w.insertRight(b, inbox, inbox, MachMsgType.makeSend) == 0)
        let toB = w.give(inbox, from: b, to: a)
        // A moves a receive right (with one queued message) to B, keeping a send right.
        let r = w.allocate(a)
        #expect(w.insertRight(a, r, r, MachMsgType.makeSend) == 0)
        #expect(w.send(a, TestMessage(remote: r, remoteDisposition: MachMsgType.copySend, id: 1).bytes) == 0)
        #expect(w.send(a, TestMessage(remote: toB, remoteDisposition: MachMsgType.copySend, id: 2,
                                      descriptors: [TestMessage.port(r, MachMsgType.moveReceive)]).bytes) == 0)
        #expect(w.entry(a, r)?.type == S)  // A keeps its send right
        #expect(queued == [inbox])
        let (k, m) = w.receive(b, inbox)
        #expect(k == 0 && m.id == 2)
        let rInB = m.u32(28)
        #expect(m.u32(36) >> 24 == UInt32(MachMsgDescriptor.port) && w.entry(b, rInB)?.type == R)
        // The queued message traveled with the port; new sends from A reach B.
        #expect(w.receive(b, rInB).1.id == 1)
        #expect(w.send(a, TestMessage(remote: r, remoteDisposition: MachMsgType.copySend, id: 3).bytes) == 0)
        #expect(queued.last == rInB)
        #expect(w.receive(b, rInB).1.id == 3)
        // A can no longer receive on it.
        #expect(w.receive(a, r).0 == MachMsgReturn.rcvInvalidName)
    }

    @Test func outOfLineMemoryIsASnapshot() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        let port = w.allocate(a)
        #expect(w.insertRight(a, port, port, MachMsgType.makeSend) == 0)
        let dest = w.give(port, from: a, to: b)
        let data = TaskWorld.scratch + 0x10000
        let payload = Array("out of line from pid 101".utf8)
        w.put(b, payload, at: data)
        let msg = TestMessage(remote: dest, remoteDisposition: MachMsgType.copySend,
                              descriptors: [TestMessage.ool(data, size: UInt32(payload.count))])
        #expect(w.send(b, msg.bytes) == 0)
        w.put(b, [UInt8](repeating: 0x55, count: payload.count), at: data)  // later writes are invisible
        let (k, m) = w.receive(a, port)
        #expect(k == 0)
        let address = m.u64(28)
        #expect(m.u32(40) == UInt32(payload.count))
        #expect(address != 0 && w.read(a, address, payload.count) == payload)
        // The region is A's; B's memory there is untouched by the receive.
        #expect(w.read(b, data, 4) == [0x55, 0x55, 0x55, 0x55])
    }

    @Test func spawnPortActionsAndInheritance() throws {
        let w = TaskWorld()
        let parent = try w.add(pid: 100)
        // The parent's bootstrap slot is the system object (0x503).
        let srv = w.allocate(parent)
        #expect(w.insertRight(parent, srv, srv, MachMsgType.makeSend) == 0)
        let reg = w.allocate(parent)
        #expect(w.insertRight(parent, reg, reg, MachMsgType.makeSend) == 0)
        // Registered ports and an access port in the parent are inherited.
        #expect(w.kr(parent, 0x7963_2008, [0x103, UInt64(reg), 0, UInt64(MachPortName.dead)]) == 0)
        let child = try w.add(pid: 101)
        child.ipc.inheritTaskPorts(from: parent.ipc)
        let actions = [SpawnPortAction(kind: .special, port: srv, which: TaskSpecialPort.bootstrap),
                       SpawnPortAction(kind: .exception, mask: 1 << 6, port: srv, behavior: 0x8000_0001, flavor: 6)]
        let before = parent.ipc.portCounters(srv)!.srights
        try child.ipc.applySpawnPortActions(actions, from: parent.ipc)
        // COPY_SEND: the parent keeps its right; the child's bootstrap and
        // exception slots and its name 0x503 hold three more.
        #expect(w.entry(parent, srv)?.urefs == 1)
        #expect(parent.ipc.portCounters(srv)!.srights == before + 3)
        // The child's 0x503 is the parent's port: sends from the child arrive at the parent.
        #expect(child.ipc.kernelObjectKind(of: 0x503) == nil && w.entry(child, 0x503)?.type == S)
        #expect(w.kr(child, 0x7963_2005, [0x103, 4, out]) == 0 && w.r32(child, out) == 0x503)
        #expect(w.send(child, TestMessage(remote: 0x503, remoteDisposition: MachMsgType.copySend, id: 77).bytes) == 0)
        let (k, m) = w.receive(parent, srv)
        #expect(k == 0 && m.id == 77 && m.trailer(20 + 4 * 5) == 101)
        // Registered ports: inherited, NULL and DEAD kept.
        #expect(w.kr(child, 0x7963_2009, [0x103, out, out + 4, out + 8]) == 0)
        let r0 = w.r32(child, out)
        #expect(w.entry(child, r0)?.type == S && w.r32(child, out + 4) == 0 && w.r32(child, out + 8) == MachPortName.dead)
        // Exception ports are stored only.
        #expect(child.ipc.exceptionPort(type: 6)?.behavior == 0x8000_0001)
        #expect(child.ipc.exceptionPort(type: 6)?.flavor == 6)
        #expect(child.ipc.exceptionPort(type: 5) == nil)
        // REGISTERED_PORTS replaces all three, in action order.
        let child2 = try w.add(pid: 102)
        child2.ipc.inheritTaskPorts(from: parent.ipc)
        try child2.ipc.applySpawnPortActions([SpawnPortAction(kind: .registered, port: srv)], from: parent.ipc)
        #expect(w.kr(child2, 0x7963_2009, [0x103, out, out + 4, out + 8]) == 0)
        #expect(w.entry(child2, w.r32(child2, out))?.type == S && w.r32(child2, out + 4) == 0)
        // Errors: EINVAL, and nothing is kept.
        let child3 = try w.add(pid: 103)
        let count = parent.ipc.portCounters(srv)!.srights
        for bad in [[SpawnPortAction(type: 9, port: srv)],
                    [SpawnPortAction(kind: .special, port: srv, which: TaskSpecialPort.host)],
                    [SpawnPortAction(kind: .special, port: srv, which: TaskSpecialPort.bootstrap),
                     SpawnPortAction(kind: .special, port: 0x99903, which: TaskSpecialPort.bootstrap)],
                    [SpawnPortAction](repeating: SpawnPortAction(kind: .registered, port: 0), count: 4),
                    [SpawnPortAction(kind: .exception, mask: 1, port: srv, behavior: 1)]] {
            #expect(throws: DarwinErrnoError(DarwinErrnoCode.EINVAL)) {
                try child3.ipc.applySpawnPortActions(bad, from: parent.ipc)
            }
            #expect(parent.ipc.portCounters(srv)!.srights == count)
        }
        // A receive-only name is not a send right.
        let ro = w.allocate(parent)
        #expect(throws: DarwinErrnoError(DarwinErrnoCode.EINVAL)) {
            try child3.ipc.applySpawnPortActions([SpawnPortAction(kind: .special, port: ro, which: 4)], from: parent.ipc)
        }
        // Record round trip.
        let a = SpawnPortAction(kind: .exception, mask: 0x3FFE, port: 0x1203, behavior: 3, flavor: 9, which: -1)
        #expect(SpawnPortAction(record: a.record) == a)
        #expect(try SpawnPortAction.parseBlock(le32(4) + le32(1) + a.record) == [a])
    }

    @Test func inheritedNullBootstrapLeavesNoWellKnownName() throws {
        let w = TaskWorld()
        let parent = try w.add(pid: 100)
        #expect(w.kr(parent, 0x7963_2006, [0x103, 4, 0]) == 0)
        let child = try w.add(pid: 101)
        child.ipc.inheritTaskPorts(from: parent.ipc)
        #expect(w.entry(child, 0x503) == nil && w.entry(child, 0x303)?.type == S)
        #expect(w.kr(child, 0x7963_2005, [0x103, 4, out]) == 0 && w.r32(child, out) == 0)
    }

    @Test func routinesOnAnotherTasksControlPort() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        let bTask = w.give(0x103, from: b, to: a)
        let p = w.allocate(a)
        #expect(w.insertRight(a, p, p, MachMsgType.makeSend) == 0)
        // task_set_special_port(B, BOOTSTRAP, p) from A; B reads it back.
        #expect(w.kr(a, 0x7963_2006, [UInt64(bTask), 4, UInt64(p)]) == 0)
        #expect(w.kr(b, 0x7963_2005, [0x103, 4, out]) == 0)
        let inB = w.r32(b, out)
        #expect(inB != 0x503 && w.entry(b, inB)?.type == S)
        // task_get_special_port(B, BOOTSTRAP) from A: A's own name for p.
        #expect(w.kr(a, 0x7963_2005, [UInt64(bTask), 4, out]) == 0 && w.r32(a, out) == p)
        // The task and name ports of B, from A.
        #expect(w.kr(a, 0x7963_2005, [UInt64(bTask), 1, out]) == 0 && w.r32(a, out) == bTask)
        #expect(w.kr(a, 0x7963_2005, [UInt64(bTask), 3, out]) == 0)
        let bName = w.r32(a, out)
        #expect(a.ipc.kernelObjectKind(of: bName) == .taskName)
        // register3 / lookup3 on B from A.
        #expect(w.kr(a, 0x7963_2008, [UInt64(bTask), 0, UInt64(p), 0]) == 0)
        #expect(w.kr(b, 0x7963_2009, [0x103, out, out + 4, out + 8]) == 0)
        #expect(w.r32(b, out) == 0 && w.r32(b, out + 4) == inB && w.r32(b, out + 8) == 0)
        #expect(w.kr(a, 0x7963_2009, [UInt64(bTask), out, out + 4, out + 8]) == 0 && w.r32(a, out + 4) == p)
        #expect(w.kr(a, 0x7963_2009, [UInt64(bTask), out, 0x10, out + 8]) == MachKern.invalidAddress)
        #expect(w.kr(a, 0x7963_2008, [UInt64(bTask), 0x77703, 0, 0]) == MachMsgReturn.sendInvalidRight)
        #expect(w.kr(a, 0x7963_2008, [UInt64(bName), 0, 0, 0]) == MachKern.invalidArgument)
        // pid_for_task on any flavor.
        #expect(w.kr(a, -46, [UInt64(bTask), out]) == 0 && w.r32(a, out) == 101)
        #expect(w.kr(a, -46, [UInt64(bName), out]) == 0 && w.r32(a, out) == 101)
        #expect(w.kr(a, -46, [0x303, out]) == MachKern.failure && w.r32(a, out) == UInt32(bitPattern: -1))
        // MIG mach_port_allocate (3204) sent to B's task port runs in B's space.
        let reply = w.allocate(a)
        let mig = TestMessage(remote: bTask, remoteDisposition: MachMsgType.copySend, local: reply,
                              localDisposition: MachMsgType.makeSendOnce, id: 3204,
                              inline: machNDRRecord + le32(MachPortRight.receive))
        #expect(w.send(a, mig.bytes) == 0)
        let (k, rep) = w.receive(a, reply)
        #expect(k == 0 && rep.id == 3304 && rep.u32(32) == 0)
        let allocatedInB = rep.u32(36)
        #expect(w.entry(b, allocatedInB)?.type == R && w.entry(a, allocatedInB)?.type != R)
    }

    @Test func taskPortTraps() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        _ = b
        // task_for_pid: self only.
        #expect(w.kr(a, -45, [0x103, 100, out]) == 0 && w.r32(a, out) == 0x103)
        #expect(w.kr(a, -45, [0x103, 101, out]) == MachKern.failure && w.r32(a, out) == 0)
        #expect(w.kr(a, -45, [0x103, 0, out]) == MachKern.failure)
        #expect(w.kr(a, -45, [0x303, 100, out]) == MachKern.failure)
        // task_name_for_pid on self.
        #expect(w.kr(a, -44, [0x103, 100, out]) == 0)
        #expect(a.ipc.kernelObjectKind(of: w.r32(a, out)) == .taskName)
        #expect(w.kr(a, -44, [0x103, 4242, out]) == MachKern.failure && w.r32(a, out) == 0)
        // Another pid, when the process table can find it (agent P's lookup).
        if w.system.kernel(forPID: 101) != nil {
            #expect(w.kr(a, -44, [0x103, 101, out]) == 0)
            let name = w.r32(a, out)
            #expect(w.kr(a, -46, [UInt64(name), out]) == 0 && w.r32(a, out) == 101)
        }
        // pid_for_task on self.
        #expect(w.kr(a, -46, [0x103, out]) == 0 && w.r32(a, out) == 100)
    }

    @Test func terminationOrderAndNotifications() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        let notify = w.allocate(a)
        // 1. B's receive right; A holds a send right with a dead-name request.
        let rb = w.allocate(b)
        #expect(w.insertRight(b, rb, rb, MachMsgType.makeSend) == 0)
        let rbInA = w.give(rb, from: b, to: a)
        #expect(w.kr(a, -77, [0x103, UInt64(rbInA), UInt64(MachNotify.deadName), 0, UInt64(notify),
                              UInt64(MachMsgType.makeSendOnce), out]) == 0)
        // 2. A's port with no-senders armed; B holds the only send right.
        let ns = w.allocate(a)
        #expect(w.insertRight(a, ns, ns, MachMsgType.makeSend) == 0)
        _ = w.give(ns, from: a, to: b, disposition: MachMsgType.moveSend)
        #expect(w.entry(a, ns)?.type == R)
        #expect(w.kr(a, -77, [0x103, UInt64(ns), UInt64(MachNotify.noSenders), 0, UInt64(notify),
                              UInt64(MachMsgType.makeSendOnce), out]) == 0)
        // 3. B holds a send-once right to A's port (a pending reply).
        let reply = w.allocate(a)
        _ = w.give(reply, from: a, to: b, disposition: MachMsgType.makeSendOnce)
        // 4. B armed a dead-name request on its send right to A's port, notify in A.
        let watched = w.allocate(a)
        #expect(w.insertRight(a, watched, watched, MachMsgType.makeSend) == 0)
        let watchedInB = w.give(watched, from: a, to: b)
        let notifyInB = w.give(notify, from: a, to: b, disposition: MachMsgType.makeSendOnce)
        #expect(w.kr(b, -77, [0x103, UInt64(watchedInB), UInt64(MachNotify.deadName), 0, UInt64(notifyInB),
                              UInt64(MachMsgType.moveSendOnce), out]) == 0)
        // 5. A holds B's task port.
        let bTask = w.give(0x103, from: b, to: a)
        // A message queued on B's receive right, carrying a send right to A's port: destroyed with it.
        let carried = w.allocate(a)
        #expect(w.send(a, TestMessage(remote: rbInA, remoteDisposition: MachMsgType.copySend,
                                      descriptors: [TestMessage.port(carried, MachMsgType.makeSend)]).bytes) == 0)
        #expect(a.ipc.portCounters(carried)?.srights == 1)

        b.ipc.terminateTask()
        #expect(b.ipc.nameCount == 0)
        // Receive rights died first: A's dead-name notification.
        let n1 = try #require(w.note(a, notify))
        #expect(n1.id == MachNotify.deadName && n1.u32(32) == rbInA)
        #expect(w.entry(a, rbInA)?.type == DN)
        // Then the other entries: no-senders, send-once, port-deleted.
        var ids: [Int32] = []
        while let n = w.note(a, notify) { ids.append(n.id) }
        #expect(ids == [MachNotify.noSenders, MachNotify.portDeleted])
        #expect(w.note(a, reply)?.id == MachNotify.sendOnce)
        #expect(a.ipc.portCounters(carried)?.srights == 0)
        // Special ports released; B's task port is a dead name in A.
        #expect(w.entry(a, bTask)?.type == DN)
        #expect(w.kr(a, -46, [UInt64(bTask), out]) == MachKern.failure)
        #expect(w.kr(a, 0x7963_2005, [UInt64(bTask), 4, out]) == MachMsgReturn.sendInvalidDest)
        // Idempotent.
        b.ipc.terminateTask()
    }

    @Test func portDestroyedRequestDivertsAtTermination() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        let backup = w.allocate(a)
        let rb = w.allocate(b)
        let backupInB = w.give(backup, from: a, to: b, disposition: MachMsgType.makeSendOnce)
        #expect(w.kr(b, -77, [0x103, UInt64(rb), UInt64(MachNotify.portDestroyed), 0, UInt64(backupInB),
                              UInt64(MachMsgType.moveSendOnce), out]) == 0)
        b.ipc.terminateTask()
        let n = try #require(w.note(a, backup))
        #expect(n.id == MachNotify.portDestroyed)
        let rescued = n.u32(28)
        #expect(w.entry(a, rescued)?.type == R)
    }

    @Test func execCarriesSpecialPortsAndKillsOldTaskPort() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        let srv = w.allocate(a)
        #expect(w.insertRight(a, srv, srv, MachMsgType.makeSend) == 0)
        let child = try w.add(pid: 102)
        child.ipc.inheritTaskPorts(from: a.ipc)
        try child.ipc.applySpawnPortActions([SpawnPortAction(kind: .special, port: srv, which: 4),
                                             SpawnPortAction(kind: .registered, port: srv)], from: a.ipc)
        let oldTaskInB = w.give(0x103, from: child, to: b)
        let mine = w.allocate(child)
        let mineInA = w.give(mine, from: child, to: a, disposition: MachMsgType.makeSend)
        let execed = try w.exec(child)
        // The new space is empty except for the carried ports.
        #expect(w.entry(execed, mine) == nil || w.entry(execed, mine)?.type != R)
        #expect(w.entry(execed, 0x503)?.type == S)
        #expect(w.send(execed, TestMessage(remote: 0x503, remoteDisposition: MachMsgType.copySend, id: 9).bytes) == 0)
        let (k, m) = w.receive(a, srv)
        #expect(k == 0 && m.id == 9 && m.trailer(20 + 4 * 5) == 102 && m.trailer(20 + 4 * 7) == 1)
        #expect(w.kr(execed, 0x7963_2009, [0x103, out, out + 4, out + 8]) == 0 && w.r32(execed, out) == 0x503)
        // Holders of the old task port and of the old receive rights see dead names.
        #expect(w.entry(b, oldTaskInB)?.type == DN)
        #expect(w.entry(a, mineInA)?.type == DN)
        #expect(execed.ipc.kernelObjectKind(of: 0x103) == .task)
    }

    @Test func fileportErrors() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100)
        let fs = DarwinFileSystem(prefixes: [], console: { _, _ in })
        try w.system.lock.withLock {
            // makefd on a name that is not a fileport.
            #expect(throws: DarwinErrnoError(DarwinErrnoCode.EINVAL)) {
                _ = try a.ipc.fileportCall(431, [0x103], fileSystem: fs, memory: a.space)
            }
            // makeport on a closed descriptor fails without making a port.
            let names = a.ipc.nameCount
            #expect(throws: (any Error).self) {
                _ = try a.ipc.fileportCall(430, [77, TaskWorld.out], fileSystem: fs, memory: a.space)
            }
            #expect(a.ipc.nameCount == names)
            let other = try a.ipc.fileportCall(5, [], fileSystem: fs, memory: a.space)
            #expect(other == nil)
        }
    }

    final class Pipe: DarwinDescriptorObject {
        var closed = 0
        let confined: Bool
        init(confined: Bool = false) { self.confined = confined }
        var fileType: UInt16 { 0o010000 }
        var isConfined: Bool { confined }
        func lastReferenceClosed() { closed += 1 }
    }

    @Test func fileportRoundTripAcrossTasks() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        let fsA = DarwinFileSystem(prefixes: [], console: { _, _ in })
        let fsB = DarwinFileSystem(prefixes: [], console: { _, _ in })
        let object = Pipe()
        try w.system.lock.withLock {
            let fd = try fsA.installObject(object, statusFlags: 2, closeOnExec: false)
            #expect(try a.ipc.fileportCall(430, [UInt64(fd), TaskWorld.out], fileSystem: fsA, memory: a.space) == 0)
            let name = try a.space.read(va: TaskWorld.out, count: 4).readLE(UInt32.self, at: 0)
            if case .fileport = a.ipc.kernelObject(named: name)?.1 {} else { Issue.record("not a fileport") }
            // A new port every call.
            #expect(try a.ipc.fileportCall(430, [UInt64(fd), TaskWorld.out], fileSystem: fsA, memory: a.space) == 0)
            let second = try a.space.read(va: TaskWorld.out, count: 4).readLE(UInt32.self, at: 0)
            #expect(second != name)
            _ = a.ipc.portDeallocate(second)
            // The send right moves to B; A closes its descriptor.
            guard case let .success(r) = a.ipc.copyin(name, MachMsgType.moveSend, slot: .body, apply: true) else {
                Issue.record("copyin")
                return
            }
            let inB = b.ipc.copyout(r).name
            try fsA.close(fd)
            #expect(object.closed == 0)  // the fileport holds the description
            let newFD = try b.ipc.fileportCall(431, [UInt64(inB)], fileSystem: fsB, memory: b.space)
            #expect(newFD != nil)
            let fdB = Int32(truncatingIfNeeded: newFD!)
            #expect(try fsB.object(for: fdB) === object)
            #expect(try fsB.closeOnExec(fdB))
            #expect(b.ipc.fileportFile(named: inB) != nil)
            // Last send right gone: the port dies and drops the description.
            #expect(b.ipc.portDeallocate(inB) == 0)
            #expect(object.closed == 0)
            try fsB.close(fdB)
            #expect(object.closed == 1)
            // A confined description cannot become a fileport.
            let kq = try fsA.installObject(Pipe(confined: true), statusFlags: 2, closeOnExec: false)
            #expect(throws: DarwinErrnoError(DarwinErrnoCode.EINVAL)) {
                _ = try a.ipc.fileportCall(430, [UInt64(kq), TaskWorld.out], fileSystem: fsA, memory: a.space)
            }
            #expect(throws: DarwinErrnoError(DarwinErrnoCode.EBADF)) {
                _ = try a.ipc.fileportCall(430, [99, TaskWorld.out], fileSystem: fsA, memory: a.space)
            }
        }
    }

    /// Runs `body` on a new host thread; returns a way to wait for its result.
    func spawn<T: Sendable>(_ body: @escaping @Sendable () -> T) -> () -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.start()
        return { done.wait(timeout: .now() + 10) == .success ? box.value : nil }
    }

    @Test func blockedReceiverWakesOnASendFromAnotherTask() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        let port = w.allocate(a)
        #expect(w.insertRight(a, port, port, MachMsgType.makeSend) == 0)
        let dest = w.give(port, from: a, to: b)
        let buffer = TaskWorld.scratch + 0x10000
        let wait = spawn { w.kr(a, -31, [buffer, MachMsgOption.rcvMsg | 3 << 24, 0, 0x100, UInt64(port), 0, 0]) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(w.send(b, TestMessage(remote: dest, remoteDisposition: MachMsgType.copySend, id: 5150).bytes) == 0)
        #expect(wait() == 0)
        let m = Received(w.read(a, buffer, 0x100))
        #expect(m.id == 5150 && m.trailer(20 + 4 * 5) == 101)
    }

    @Test func blockedSenderWakesWhenTheReceiverTaskDies() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100), b = try w.add(pid: 101)
        put(w, b, flags: MachPortConstruct.qlimit, qlimit: 1)
        let (k, full) = (w.kr(b, -24, [0x103, TaskWorld.out + 0x100, 0, TaskWorld.out]), w.r32(b, TaskWorld.out))
        #expect(k == 0)
        #expect(w.insertRight(b, full, full, MachMsgType.makeSend) == 0)
        let dest = w.give(full, from: b, to: a)
        #expect(w.send(a, TestMessage(remote: dest, remoteDisposition: MachMsgType.copySend, id: 1).bytes) == 0)
        let sendBuffer = TaskWorld.scratch + 0x10000
        w.put(a, TestMessage(remote: dest, remoteDisposition: MachMsgType.copySend, id: 2).bytes, at: sendBuffer)
        let wait = spawn { w.kr(a, -31, [sendBuffer, MachMsgOption.sendMsg, 24, 0, 0, 0, 0]) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(b.ipc.portCounters(full)?.msgcount == 1)
        b.ipc.terminateTask()
        #expect(wait() == 0)  // the message is destroyed with the dead port
        #expect(w.entry(a, dest)?.type == DN)
    }

    func put(_ w: TaskWorld, _ t: TaskWorld.Task, flags: UInt32, qlimit: UInt32) {
        w.put(t, le32(flags) + le32(qlimit) + [UInt8](repeating: 0, count: 24), at: TaskWorld.out + 0x100)
    }

    @Test func spaceOutlivesItsKernelSafely() throws {
        let w = TaskWorld()
        let a = try w.add(pid: 100)
        weak var freed: DarwinKernel?
        var ipc: MachIPC?
        var port: UInt32 = 0, dest: UInt32 = 0
        do {
            let fs = DarwinFileSystem(prefixes: [], console: { _, _ in })
            let k = DarwinKernel(fileSystem: fs, pid: 101, system: w.system)
            k.pidVersion = 3
            let space = GuestAddressSpace(backing: FakePhysicalBacking())
            _ = try space.mapAnonymous(at: TaskWorld.scratch, size: TaskWorld.scratchSize, protection: .readWrite, hint: nil)
            let b = TaskWorld.Task(kernel: k, ipc: k.machIPC as! MachIPC, space: space)
            port = w.allocate(b)
            #expect(w.insertRight(b, port, port, MachMsgType.makeSend) == 0)
            dest = w.give(port, from: b, to: a)
            ipc = b.ipc
            freed = k
        }
        // Whether or not the kernel is freed now, nothing below may touch a dead kernel.
        let b = try #require(ipc)
        if freed == nil {
            #expect(b.kernel == nil && b.messageQueuedHandler == nil && b.receiveRightGoneHandler == nil)
            #expect(b.systemClock() == (0, 0))
            #expect(b.calendarClock().seconds > 1_600_000_000)
            b.log("no kernel")
        }
        #expect(w.send(a, TestMessage(remote: dest, remoteDisposition: MachMsgType.copySend, id: 8).bytes) == 0)
        #expect(b.messageQueued(on: port))
        b.terminateTask()
        #expect(w.entry(a, dest)?.type == DN)
    }
}
