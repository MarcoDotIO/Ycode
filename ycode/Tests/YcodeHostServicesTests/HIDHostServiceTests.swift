import Foundation
import Testing
@testable import YcodeDarwinKernel
@testable import YcodeHostServices

/// dev.ycode.simulator.hid (hid-input.md §7), driven by a second host task
/// acting as the guest's HID bundle.
@Suite(.serialized) struct HIDHostServiceTests {
    func u32(_ b: [UInt8], _ at: Int) -> UInt32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
    func f64(_ b: [UInt8], _ at: Int) -> Double { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: Double.self) } }

    @Test func touchBodyLayout() {
        let b = HIDHostService.body(.touch(display: 0, contacts: [
            .init(index: 1, phase: .began, edge: .bottom, x: 0.5, y: 1.2),
            .init(index: 2, phase: .moved, edge: .none, x: -1, y: 0.25),
        ]), sequence: 7)
        #expect(b.count == 24 + 64)
        #expect(u32(b, 0) == 1 && u32(b, 4) == 1 && u32(b, 8) == 7 && u32(b, 16) == 0 && u32(b, 20) == 2)
        #expect(u32(b, 24) == 1 && u32(b, 28) == 1 && u32(b, 32) == 3 && f64(b, 40) == 0.5 && f64(b, 48) == 1)  // clamped
        #expect(u32(b, 56) == 2 && u32(b, 60) == 2 && f64(b, 72) == 0 && f64(b, 80) == 0.25)
        let k = HIDHostService.body(.button(usagePage: 0x0C, usage: 0x40, down: true), sequence: 1)
        #expect(k.count == 32 && u32(k, 4) == 3 && u32(k, 16) == 0x0C && u32(k, 20) == 0x40 && u32(k, 24) == 1)
    }

    @Test func registerSendAndDeadPort() throws {
        let system = DarwinSystem()
        let host = system.hostTask
        let service = try HIDHostService(host: host, log: { _ in })
        service.start()
        defer { service.stop() }
        let guest = system.lock.withLock { MachHostTask(lock: system.lock, system: system.mach, log: { _ in }) }
        let server = try host.give(service.servicePort, disposition: MachMsgType.copySend, to: guest.ipc)
        #expect(!service.isRegistered)
        #expect(!service.send(.key(usagePage: 7, usage: 4, down: true)))
        let port = try guest.makePort()
        var body: [UInt8] = []
        withUnsafeBytes(of: UInt32(1).littleEndian) { body += $0 }
        body += [0, 0, 0, 0]
        try guest.send(MachHostOutgoingMessage(remotePort: server, id: 0x5948_0001,
                                               descriptors: [.port(name: port, disposition: MachMsgType.makeSend)], body: body))
        let deadline = Date().addingTimeInterval(5)
        while !service.isRegistered && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(service.isRegistered)
        #expect(service.send(.key(usagePage: 7, usage: 0x16, down: true)))
        let m = try guest.receive(on: port, timeout: 5_000_000_000)
        #expect(m.id == 0x5948_0002 && !m.isComplex && m.body.count == 32)
        #expect(u32(m.body, 4) == 2 && u32(m.body, 16) == 7 && u32(m.body, 20) == 0x16 && u32(m.body, 24) == 1)
        // The bundle's process exits: its port dies, and the registration goes.
        try guest.destroyPort(port)
        #expect(!service.send(.key(usagePage: 7, usage: 0x16, down: false)))
        #expect(!service.isRegistered)
    }

    /// hid-input.md §7 item 6: a snapshot records the registration (the
    /// host-task name of the bundle's port); the service of a restored run
    /// takes it back and delivers input without a new registration.
    @Test func registrationSurvivesRestore() throws {
        let system = DarwinSystem()
        let host = system.hostTask
        let saved = try HIDHostService(host: host, log: { _ in })
        saved.start()
        let guest = system.lock.withLock { MachHostTask(lock: system.lock, system: system.mach, log: { _ in }) }
        let server = try host.give(saved.servicePort, disposition: MachMsgType.copySend, to: guest.ipc)
        #expect(saved.snapshotClient == nil)
        let port = try guest.makePort()
        try guest.send(MachHostOutgoingMessage(remotePort: server, id: 0x5948_0001,
                                               descriptors: [.port(name: port, disposition: MachMsgType.makeSend)],
                                               body: [1, 0, 0, 0, 0, 0, 0, 0]))
        let deadline = Date().addingTimeInterval(5)
        while !saved.isRegistered && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let client = try #require(saved.snapshotClient)
        saved.stop()
        // The restored run: a new service over the same host-task names.
        let restored = try HIDHostService(host: host, log: { _ in })
        #expect(!restored.isRegistered)
        restored.restoreRegistration(client: client)
        #expect(restored.isRegistered && restored.snapshotClient == client)
        #expect(restored.send(.button(usagePage: 0x0C, usage: 0x40, down: true)))
        let m = try guest.receive(on: port, timeout: 5_000_000_000)
        #expect(m.id == 0x5948_0002 && u32(m.body, 4) == 3 && u32(m.body, 20) == 0x40)
    }
}
