import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The host task (stage4c-contract.md §3): Swift code in the VMM talking Mach
/// to guest tasks of the same system.
@Suite struct MachHostTests {
    let S = MachPortType.send, R = MachPortType.receive, SO = MachPortType.sendOnce, DN = MachPortType.deadName
    let out = TaskWorld.out

    /// A world in device mode: the host task exists and is the default bootstrap.
    func deviceWorld() -> (TaskWorld, MachHostTask) {
        let w = TaskWorld()
        let host = w.system.hostTask
        w.system.mach.hostBootstrapIsDefault = true
        return (w, host)
    }

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

    @Test func guestSendsToHostBootstrapAndGetsAReply() throws {
        let (w, host) = deviceWorld()
        #expect(w.system.mach.hostBootstrapPort == host.bootstrapPort && w.system.hostTask === host)
        let g = try w.add(pid: 100)
        g.kernel.pidVersion = 4
        // The root's bootstrap special port is a send right to the host bootstrap port, named 0x503.
        #expect(g.ipc.kernelObjectKind(of: 0x503) == nil && w.entry(g, 0x503)?.type == S)
        #expect(w.kr(g, 0x7963_2005, [0x103, 4, out]) == 0 && w.r32(g, out) == 0x503)
        let reply = w.allocate(g)
        #expect(w.send(g, TestMessage(remote: 0x503, remoteDisposition: MachMsgType.copySend, local: reply,
                                      localDisposition: MachMsgType.makeSendOnce, id: 400,
                                      inline: le32(7) + le32(8)).bytes) == 0)
        let m = try host.receive(on: host.bootstrapPort, timeout: 0)
        #expect(m.id == 400 && m.body == le32(7) + le32(8) && m.size == 32 && !m.isComplex)
        #expect(m.localPort == host.bootstrapPort && m.replyType == MachMsgType.portSendOnce)
        #expect(m.sender?.pid == 100 && m.sender?.pidVersion == 4 && m.sender?.euid == 501)
        #expect(host.rights(of: m.replyPort)?.type == SO)
        #expect(m.wireImage.count == 32 && m.wireImage.readLE(UInt32.self, at: 20) == 400)
        try host.reply(to: m, body: le32(0) + le32(42))
        #expect(host.rights(of: m.replyPort) == nil)  // the send-once right was used
        let (k, r) = w.receive(g, reply)
        #expect(k == 0 && r.id == 500 && r.local == reply && r.u32(24) == 0 && r.u32(28) == 42)
        #expect(r.trailer(20 + 4 * 5) == 0)  // the host's pid
        // Nothing left: a poll times out.
        #expect(throws: MachHostError.timedOut) { try host.receive(on: host.bootstrapPort, timeout: 0) }
    }

    @Test func execModeKeepsTheBootstrapKernelObject() throws {
        let w = TaskWorld()
        _ = w.system.hostTask  // the host task exists, but is not the default
        let g = try w.add(pid: 100)
        #expect(g.ipc.kernelObjectKind(of: 0x503) == .bootstrap)
        #expect(w.send(g, TestMessage(remote: 0x503, remoteDisposition: MachMsgType.copySend).bytes)
            == MachMsgReturn.sendInvalidDest)
        // Explicitly, before the task runs: the host bootstrap port as its special port.
        let g2 = try w.add(pid: 101)
        try w.system.hostTask.setSpecialPort(of: g2.ipc, which: TaskSpecialPort.bootstrap,
                                             to: w.system.hostTask.bootstrapPort)
        #expect(g2.ipc.kernelObjectKind(of: 0x503) == nil && w.entry(g2, 0x503)?.type == S)
        #expect(w.send(g2, TestMessage(remote: 0x503, remoteDisposition: MachMsgType.copySend, id: 3).bytes) == 0)
        #expect(try w.system.hostTask.receive(on: w.system.hostTask.bootstrapPort, timeout: 0).sender?.pid == 101)
    }

    @Test func descriptorsInBothDirections() throws {
        let (w, host) = deviceWorld()
        let g = try w.add(pid: 100)
        // Guest → host: a send right, OOL bytes, and an OOL port array.
        let gp = w.allocate(g)
        let data = TaskWorld.scratch + 0x10000
        let payload = Array("guest bytes".utf8)
        w.put(g, payload, at: data)
        w.put(g, le32(gp), at: data + 0x100)
        let msg = TestMessage(remote: 0x503, remoteDisposition: MachMsgType.copySend, id: 1,
                              descriptors: [TestMessage.port(gp, MachMsgType.makeSend),
                                            TestMessage.ool(data, size: UInt32(payload.count)),
                                            TestMessage.oolPorts(data + 0x100, count: 1, disposition: MachMsgType.makeSend)],
                              inline: le32(0xFEED))
        #expect(w.send(g, msg.bytes) == 0)
        let m = try host.receive(on: host.bootstrapPort, timeout: 0)
        #expect(m.isComplex && m.descriptors.count == 3 && m.body == le32(0xFEED))
        guard case let .port(gpInHost, type) = m.descriptors[0] else { Issue.record("no port"); return }
        #expect(type == MachMsgType.portSend && host.rights(of: gpInHost)?.type == S)
        #expect(host.rights(of: gpInHost)?.urefs == 2)  // merged with the OOL array's right
        #expect(m.descriptors[1] == .ool(data: payload, copy: 0, volatile: false))
        #expect(m.descriptors[2] == .oolPorts(names: [gpInHost], type: MachMsgType.portSend))
        // Host → guest (not a reply): a send right to a host port, a receive
        // right, OOL bytes, and an OOL port array.
        let hp = try host.makePort()
        let moved = try host.makePort(sendRight: true)
        let back = Array("host bytes!!".utf8)
        try host.send(MachHostOutgoingMessage(remotePort: gpInHost, remoteDisposition: MachMsgType.copySend, id: 2,
                                              descriptors: [.port(name: hp, disposition: MachMsgType.makeSend),
                                                            .port(name: moved, disposition: MachMsgType.moveReceive),
                                                            .ool(data: back),
                                                            .oolPorts(names: [hp, 0], disposition: MachMsgType.makeSend)],
                                              body: le32(9)))
        #expect(host.rights(of: moved)?.type == S)  // the host keeps its send right
        let (k, r) = w.receive(g, gp)
        #expect(k == 0 && r.id == 2 && r.u32(24) == 4)
        let hpInGuest = r.u32(28), movedInGuest = r.u32(40)
        #expect(w.entry(g, hpInGuest)?.type == S && w.entry(g, movedInGuest)?.type == R)
        let oolAddress = r.u64(52)
        #expect(r.u32(64) == UInt32(back.count) && w.read(g, oolAddress, back.count) == back)
        let arrayAddress = r.u64(68)
        #expect(r.u32(80) == 2 && w.r32(g, arrayAddress) == hpInGuest && w.r32(g, arrayAddress + 4) == 0)
        #expect(r.u32(84) == 9)
        // The guest uses both: a message on the host port, and one on the moved port from the host.
        #expect(w.send(g, TestMessage(remote: hpInGuest, remoteDisposition: MachMsgType.copySend, id: 3).bytes) == 0)
        #expect(try host.receive(on: hp, timeout: 0).id == 3)
        try host.send(MachHostOutgoingMessage(remotePort: moved, id: 4))
        #expect(w.receive(g, movedInGuest).1.id == 4)
        // Errors: a bad name, an odd body, a dead destination.
        #expect(throws: MachHostError(MachMsgReturn.sendInvalidDest)) {
            try host.send(MachHostOutgoingMessage(remotePort: 0x77703, id: 5))
        }
        #expect(throws: MachHostError(MachMsgReturn.sendMsgTooSmall)) {
            try host.send(MachHostOutgoingMessage(remotePort: gpInHost, id: 5, body: [1, 2]))
        }
        #expect(throws: MachHostError(MachMsgReturn.sendInvalidRight)) {
            try host.send(MachHostOutgoingMessage(remotePort: gpInHost, id: 5,
                                                  descriptors: [.port(name: 0x77703, disposition: MachMsgType.copySend)]))
        }
    }

    @Test func deadNameAndNoSendersForHostPorts() throws {
        let (w, host) = deviceWorld()
        let g = try w.add(pid: 100)
        let notify = try host.makePort()
        // The host holds a send right to a guest port, with a dead-name request.
        let gp = w.allocate(g)
        #expect(w.insertRight(g, gp, gp, MachMsgType.makeSend) == 0)
        let gpInHost = w.system.lock.withLock { () -> UInt32 in
            guard case let .success(r) = g.ipc.copyin(gp, MachMsgType.copySend, slot: .body, apply: true) else { return 0 }
            return host.ipc.copyout(r).name
        }
        #expect(try host.requestNotification(gpInHost, id: MachNotify.deadName, notifyPort: notify) == 0)
        #expect(host.rights(of: gpInHost)?.type == S | MachPortType.dnRequest)
        // A host port whose only send right is in the guest, with no-senders armed.
        let hp = try host.makePort()
        let hpInGuest = try host.give(hp, disposition: MachMsgType.makeSend, to: g.ipc)
        #expect(w.entry(g, hpInGuest)?.type == S)
        #expect(try host.requestNotification(hp, id: MachNotify.noSenders, sync: 1, notifyPort: notify) == 0)
        g.ipc.terminateTask()
        let first = try host.receive(on: notify, timeout: 0)
        #expect(first.id == MachNotify.deadName && first.body == machNDRRecord + le32(gpInHost) && first.isFromKernel)
        #expect(host.rights(of: gpInHost)?.type == DN)
        let second = try host.receive(on: notify, timeout: 0)
        #expect(second.id == MachNotify.noSenders && second.body == machNDRRecord + le32(1))
        // The host's own dead name goes with one deallocate (two references: right + notification).
        try host.deallocate(gpInHost)
        try host.deallocate(gpInHost)
        #expect(host.rights(of: gpInHost) == nil)
    }

    @Test func guestSeesHostPortDeathAndHostShutdown() throws {
        let (w, host) = deviceWorld()
        let g = try w.add(pid: 100)
        let hp = try host.makePort()
        let hpInGuest = try host.give(hp, disposition: MachMsgType.makeSend, to: g.ipc)
        let gNotify = w.allocate(g)
        #expect(w.kr(g, -77, [0x103, UInt64(hpInGuest), UInt64(MachNotify.deadName), 0, UInt64(gNotify),
                              UInt64(MachMsgType.makeSendOnce), out]) == 0)
        try host.destroyPort(hp)
        let (k, n) = w.receive(g, gNotify)
        #expect(k == 0 && n.id == MachNotify.deadName && n.u32(32) == hpInGuest)
        // Shutdown: the bootstrap port dies; the guest's 0x503 becomes a dead name.
        host.shutdown()
        #expect(w.entry(g, 0x503)?.type == DN)
        #expect(w.system.mach.hostTask == nil && w.system.mach.hostBootstrapPort == nil)
    }

    @Test func blockingReceiveOnAPortSetFromAHostThread() throws {
        let (w, host) = deviceWorld()
        let g = try w.add(pid: 100)
        let set = try host.makePortSet()
        let other = try host.makePort()
        try host.addMember(host.bootstrapPort, to: set)
        try host.addMember(other, to: set)
        let wait = spawn { () -> Int32 in (try? host.receive(on: set, timeout: 5_000_000_000))?.id ?? -1 }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(w.send(g, TestMessage(remote: 0x503, remoteDisposition: MachMsgType.copySend, id: 61).bytes) == 0)
        #expect(wait() == 61)
        // A timeout, then a receiver woken by the destruction of its port.
        #expect(throws: MachHostError.timedOut) { try host.receive(on: other, timeout: 10_000_000) }
        let changed = spawn { () -> UInt32 in
            do { _ = try host.receive(on: other, timeout: nil); return 0 } catch let e as MachHostError { return e.code } catch { return 1 }
        }
        Thread.sleep(forTimeInterval: 0.05)
        try host.destroyPort(other)
        #expect(changed() == MachMsgReturn.rcvPortChanged)
        #expect(throws: MachHostError.invalidName) { try host.receive(on: other, timeout: 0) }
        // A request the host drops: its reply right gives the guest a send-once notification.
        let reply = w.allocate(g)
        #expect(w.send(g, TestMessage(remote: 0x503, remoteDisposition: MachMsgType.copySend, local: reply,
                                      localDisposition: MachMsgType.makeSendOnce, id: 62).bytes) == 0)
        host.discard(try host.receive(on: set, timeout: 0))
        #expect(w.receive(g, reply).1.id == MachNotify.sendOnce)
    }
}
