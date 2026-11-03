import Foundation
import Testing
@testable import YcodeDarwinKernel
@testable import YcodeHostServices
import YcodeDisplayStream

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

    /// foldable.md §8.2 I3: hinge angle (kind 6) and device orientation (kind 7).
    @Test func deviceMotionBodies() {
        let h = HIDHostService.body(.hingeAngle(90), sequence: 3)
        #expect(h.count == 24 && u32(h, 4) == 6 && u32(h, 8) == 3 && u32(h, 16) == 90 && u32(h, 20) == 0)
        #expect(u32(HIDHostService.body(.hingeAngle(400), sequence: 1), 16) == 180)  // clamped
        let o = HIDHostService.body(.deviceOrientation(3), sequence: 4)
        #expect(o.count == 24 && u32(o, 4) == 7 && u32(o, 16) == 3)
    }

    /// watchos.md §5.1, §12: crown rotation (kind 8, the signed delta as a
    /// 64-bit float, unchanged) and a watch gesture (kind 9).
    @Test func watchInputBodies() {
        let c = HIDHostService.body(.crownRotation(-20.5), sequence: 9)
        #expect(c.count == 32 && u32(c, 0) == 1 && u32(c, 4) == 8 && u32(c, 8) == 9 && f64(c, 16) == -20.5 && u32(c, 24) == 0)
        #expect(f64(HIDHostService.body(.crownRotation(.nan), sequence: 1), 16) == 0)
        #expect(u32(HIDHostService.body(.crownRotation(1, axis: 3), sequence: 1), 24) == 3)
        let g = HIDHostService.body(.watchGesture(1), sequence: 2)
        #expect(g.count == 24 && u32(g, 4) == 9 && u32(g, 16) == 1)
        #expect(HIDHostService.watchGesture(named: "double-tap") == 0 && HIDHostService.watchGesture(named: "flick") == 1)
        #expect(HIDHostService.watchGesture(named: "tap") == 2 && HIDHostService.watchGesture(named: "9") == nil)
    }

    /// watchos.md §5.2: the GenericGesture event the bundle makes, and the
    /// button message carrying the Action button's vendor pair.
    @Test func visionBodies() {
        // visionos.md "Ycode implementation" (V-11): kind 10 pose, kind 11 selection.
        let pose = SpatialPose(position: SpatialVector(1, 0.5, 2), rotation: SpatialQuaternion(x: 0, y: 1, z: 0, w: 1))
        let p = HIDHostService.body(.visionPose(pose), sequence: 7)
        #expect(p.count == 16 + 56 && u32(p, 4) == 10)
        #expect(f64(p, 16) == 1 && f64(p, 24) == 0.5 && f64(p, 32) == 2)
        // The quaternion normalized, w first.
        #expect(abs(f64(p, 40) - 0.5.squareRoot()) < 1e-12 && f64(p, 48) == 0 && abs(f64(p, 56) - 0.5.squareRoot()) < 1e-12)
        let only = SpatialSelection(rayOrigin: SpatialVector(0, 1.6, 0), rayDirection: SpatialVector(0.05, 0.04, -1))
        let s = HIDHostService.body(.visionSelection(only), sequence: 8)
        #expect(s.count == 16 + 200 && u32(s, 4) == 11 && u32(s, 16) == 0)
        #expect(f64(s, 32) == 1.6 && f64(s, 48) == 0.05 && f64(s, 64) == -1)
        // Selection-only: the hands are zero-filled and not pinched.
        #expect(u32(s, 72) == 0 && u32(s, 72 + 72) == 0)
        var hands = only
        hands.left = SpatialHand(pinching: false, allowDirect: true, position: SpatialVector(-0.15, -0.35, -0.4))
        hands.right = SpatialHand(pinching: true, position: SpatialVector(0.15, -0.35, -0.4))
        let h = HIDHostService.body(.visionSelection(hands), sequence: 9)
        #expect(u32(h, 16) == 1)
        #expect(u32(h, 72) == 0 && u32(h, 76) == 1 && f64(h, 88) == -0.15 && f64(h, 112) == 1)  // left: direct, w = 1
        #expect(u32(h, 144) == 1 && u32(h, 148) == 0 && f64(h, 160) == 0.15)                    // right: pinching
        #expect(f64(HIDHostService.body(.visionPose(SpatialPose(position: SpatialVector(.nan, 0, 0))), sequence: 1), 16) == 0)
    }

    @Test func watchGestureEventsAndButtons() {
        typealias E = HIDHostService.WatchGestureEvent
        #expect(E.forGesture(0) == E(gestureType: 2, tapCount: 2))   // double tap: HandTap, two taps
        #expect(E.forGesture(1) == E(gestureType: 8, tapCount: nil)) // flick: HandFlick, no tap count
        #expect(E.forGesture(2) == nil, "single tap makes no event")
        for g: UInt32 in [3, 4, 5, 0x400002] { #expect(E.forGesture(g) == nil) }
        #expect(E.eventType == 39 && E.gestureTypeField == 0x27_0000 && E.tapCountField == 0x27_0001)
        #expect(E.eventFlags == 0x400_0000)
        let b = HIDHostService.body(.button(usagePage: 0xFF01, usage: 0x200, down: true), sequence: 4)
        #expect(b.count == 32 && u32(b, 4) == 3 && u32(b, 16) == 0xFF01 && u32(b, 20) == 0x200 && u32(b, 24) == 1)
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
