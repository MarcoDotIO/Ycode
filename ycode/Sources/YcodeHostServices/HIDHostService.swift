// dev.ycode.simulator.hid: the host end of Ycode's input transport
// (specs/simulator/hid-input.md §7). The guest's HID bundle (SimGuestFrameworks/
// SimHID) registers a port with one message; the host then sends it touch,
// key, button, keyboard-attach, and orientation messages, and on a foldable
// device the hinge angle and the device orientation (foldable.md §8.2 I3).

import Foundation
import YcodeDarwinKernel
import YcodeDisplayStream

public final class HIDHostService: @unchecked Sendable {
    public static let serviceName = "dev.ycode.simulator.hid"
    static let registerID: Int32 = 0x5948_0001
    static let eventID: Int32 = 0x5948_0002

    public enum Kind: UInt32, Sendable {
        case touch = 1, key = 2, button = 3, keyboardAttach = 4, orientation = 5
        /// foldable.md §8.2 I3: u32 whole degrees 0…180.
        case hingeAngle = 6
        /// foldable.md §8.2 I3: u32 orientation code, the relay's own (§5.4):
        /// 0 ambiguous, 1 portrait, 3 landscape left, 4 landscape right,
        /// 5 face up, 6 face down.
        case deviceOrientation = 7
        /// watchos.md §5.1, §12: the Digital Crown's rotation, f64 signed
        /// delta (positive scrolls a list forward and opens the Smart Stack
        /// on the face), u32 axis (0: the bundle's own; 1 x, 2 y, 3 z for
        /// diagnostics), u32 0.
        case crownRotation = 8
        /// watchos.md §5.1, §12: a watch gesture, u32 number (0 double tap,
        /// 1 flick, 2 single tap), u32 0.
        case watchGesture = 9
        /// visionos.md "Ycode implementation" (§5.5.2, V-11): the camera pose
        /// in the stage frame, 7 f64: translation x, y, z, then the rotation
        /// quaternion w, x, y, z. Body size 72. On a Vision Pro the crown's
        /// kind 8 turns the Digital Crown (the DigitalDial service).
        case visionPose = 10
        /// The gaze ray and the hands: u32 flags (bit 0: hands present; 0 =
        /// selection-only), u32 0, ray origin 3 f64, ray direction 3 f64, then
        /// left and right hand, each u32 pinching, u32 allowDirect, u32
        /// extra (the 16-bit value of §5.5.2, sent 0), u32 0, translation
        /// 3 f64, quaternion w, x, y, z 4 f64. Body size 216.
        case visionSelection = 11
    }

    /// §7.3 touch record phase.
    public enum Phase: UInt32, Sendable {
        case began = 1, moved = 2, unchanged = 3, ended = 4, cancelled = 5
    }

    /// §7.3 touch record edge (§8.2).
    public enum Edge: UInt32, Sendable {
        case none = 0, top = 1, left = 2, bottom = 3, right = 4
    }

    public struct Contact: Equatable, Sendable {
        /// 1-based slot.
        public var index: UInt32
        public var phase: Phase
        public var edge: Edge
        /// Normalized 0…1, origin top-left (§5.3).
        public var x: Double, y: Double

        public init(index: UInt32, phase: Phase, edge: Edge, x: Double, y: Double) {
            (self.index, self.phase, self.edge, self.x, self.y) = (index, phase, edge, x, y)
        }
    }

    public enum Event: Equatable, Sendable {
        case touch(display: UInt32, contacts: [Contact])
        case key(usagePage: UInt32, usage: UInt32, down: Bool)
        case button(usagePage: UInt32, usage: UInt32, down: Bool)
        case keyboardAttach(Bool)
        case orientation(UInt32)
        /// Whole degrees, 0 closed … 180 open flat (clamped).
        case hingeAngle(UInt32)
        case deviceOrientation(UInt32)
        /// The crown's signed delta, unchanged (§5.1: the guest does the detents).
        case crownRotation(Double, axis: UInt32 = 0)
        case watchGesture(UInt32)
        /// The camera pose (stage frame).
        case visionPose(SpatialPose)
        /// The gaze ray and, unless selection-only, both hands.
        case visionSelection(SpatialSelection)
    }

    /// watchos.md §5.2: the GenericGesture event (IOHIDFamily event type 39)
    /// that the HID bundle makes for a host gesture message (kind 9) and
    /// dispatches from its watch-gestures service. The bundle
    /// (SimGuestFrameworks/SimHID/simhid.c) carries the same values.
    public struct WatchGestureEvent: Equatable, Sendable {
        /// IOHIDFamily's GenericGesture event type.
        public static let eventType: UInt32 = 39
        /// The gesture-type field, (39 << 16) + 0.
        public static let gestureTypeField: UInt32 = 39 << 16
        /// The tap-count field, (39 << 16) + 1.
        public static let tapCountField: UInt32 = 39 << 16 | 1
        /// IOHIDEventPhaseBits Ended.
        public static let phaseEnded: UInt32 = 4
        /// The event flags the reference's event carries: phase Ended in the
        /// phase bits (shift 24); relative (no absolute flag).
        public static let eventFlags: UInt32 = phaseEnded << 24

        /// HandTap 2, HandFlick 8 (§5.2).
        public var gestureType: UInt32
        /// 2 for a double tap; nil: the field is not set (flick).
        public var tapCount: UInt32?

        public init(gestureType: UInt32, tapCount: UInt32?) { (self.gestureType, self.tapCount) = (gestureType, tapCount) }

        /// The event for a host gesture number (0 double tap, 1 flick), or
        /// nil: single tap (2) makes no event, as in the reference, and other
        /// numbers are ignored.
        public static func forGesture(_ gesture: UInt32) -> WatchGestureEvent? {
            switch gesture {
            case 0: WatchGestureEvent(gestureType: 2, tapCount: 2)
            case 1: WatchGestureEvent(gestureType: 8, tapCount: nil)
            default: nil
            }
        }
    }

    /// The watch gestures by name (§5.1's numbering).
    public static func watchGesture(named name: String) -> UInt32? {
        switch name.lowercased() {
        case "double-tap", "doubletap", "0": 0
        case "flick", "1": 1
        case "tap", "single-tap", "2": 2
        default: UInt32(name).flatMap { $0 <= 5 ? $0 : nil }
        }
    }

    let host: MachHostTask
    let log: (String) -> Void
    public let servicePort: UInt32
    private let lock = NSLock()
    private var client: UInt32?
    private var sequence: UInt64 = 0
    private var stopping = false
    /// Registrations seen (tests, logs).
    public private(set) var registrations = 0

    public init(host: MachHostTask, log: @escaping (String) -> Void) throws {
        self.host = host
        self.log = log
        servicePort = try host.makePort(sendRight: true, qlimit: 64)
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "ycode-hid"
        t.start()
    }

    public func stop() { lock.withLock { stopping = true } }

    /// The sequence number of the last event sent (timing traces).
    public var lastSequence: UInt64 { lock.withLock { sequence } }

    /// A guest bundle is registered (input can be delivered).
    public var isRegistered: Bool { lock.withLock { client != nil } }

    /// The registration as a snapshot keeps it (hid-input.md §7 item 6,
    /// snapshot.md §2.6): the host-task name of the send right to the
    /// bundle's port, or nil while no bundle is registered. The host task's
    /// Mach space is captured with its names, so after a restore the same
    /// name holds the same right.
    public var snapshotClient: UInt32? { lock.withLock { client } }

    /// After a restore: the registration recorded by the snapshot. The
    /// guest's bundle registered once, in the run that was saved, and does
    /// not register again; without this the restored device takes no input.
    public func restoreRegistration(client name: UInt32) {
        let old = lock.withLock { () -> UInt32? in
            defer { client = name; registrations += 1 }
            return client
        }
        if let old, old != name { try? host.deallocate(old) }
        log("hid: the registration of the saved run is used again (port 0x\(String(name, radix: 16)))")
    }

    private func run() {
        while !lock.withLock({ stopping }) {
            let m: MachHostReceivedMessage
            do {
                m = try host.receive(on: servicePort, timeout: 200_000_000, tracked: true)
            } catch let e as MachHostError where e == .timedOut || e == .interrupted {
                continue
            } catch {
                if !lock.withLock({ stopping }) { log("hid: receive failed: \(error); stopping") }
                return
            }
            handle(m)
            host.finishedMessage()
        }
    }

    func handle(_ m: MachHostReceivedMessage) {
        guard m.id == Self.registerID, m.descriptors.count == 1, case let .port(port, type) = m.descriptors[0],
              type == MachMsgType.portSend, m.body.count >= 8 else {
            log("hid: unexpected message \(m.id) on the service port; dropped")
            drop(m)
            return
        }
        let version = m.body.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard version == 1 else {
            log("hid: registration with protocol version \(version); dropped")
            drop(m)
            return
        }
        let old = lock.withLock { () -> UInt32? in
            defer { client = port; registrations += 1 }
            return client
        }
        if let old, old != port { try? host.deallocate(old) }
        log("hid: the guest's HID bundle registered (pid \(m.sender?.pid ?? -1))")
    }

    private func drop(_ m: MachHostReceivedMessage) {
        var names: [UInt32] = []
        if MachPortName.isValid(m.replyPort) { names.append(m.replyPort) }
        for d in m.descriptors { if case let .port(name, _) = d { names.append(name) } }
        for name in names where MachPortName.isValid(name) { try? host.deallocate(name) }
    }

    /// The message body of one event (§7.3).
    /// `age`: microseconds since the host received the input (touch, key
    /// and button records' reserved word, uikit-feel-ycode.md §4.0): the
    /// bundle stamps the event that much earlier than its arrival, so a
    /// delivery held up on the way keeps the time the input was made.
    /// 0 (older hosts): the arrival time.
    public static func body(_ event: Event, sequence: UInt64, age: UInt32 = 0) -> [UInt8] {
        var b: [UInt8] = []
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { b += $0 } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { b += $0 } }
        func f64(_ v: Double) { u64(v.bitPattern) }
        let kind: Kind
        switch event {
        case .touch: kind = .touch
        case .key: kind = .key
        case .button: kind = .button
        case .keyboardAttach: kind = .keyboardAttach
        case .orientation: kind = .orientation
        case .hingeAngle: kind = .hingeAngle
        case .deviceOrientation: kind = .deviceOrientation
        case .crownRotation: kind = .crownRotation
        case .watchGesture: kind = .watchGesture
        case .visionPose: kind = .visionPose
        case .visionSelection: kind = .visionSelection
        }
        u32(1)
        u32(kind.rawValue)
        u64(sequence)
        switch event {
        case .touch(let display, let contacts):
            u32(display)
            u32(UInt32(contacts.count))
            for c in contacts {
                u32(c.index)
                u32(c.phase.rawValue)
                u32(c.edge.rawValue)
                u32(age)
                f64(min(1, max(0, c.x)))
                f64(min(1, max(0, c.y)))
            }
        case .key(let page, let usage, let down), .button(let page, let usage, let down):
            u32(page)
            u32(usage)
            u32(down ? 1 : 0)
            u32(age)
        case .keyboardAttach(let attached):
            u32(attached ? 1 : 0)
            u32(0)
        case .orientation(let o):
            u32(o)
            u32(0)
        case .hingeAngle(let degrees):
            u32(min(180, degrees))
            u32(0)
        case .deviceOrientation(let o):
            u32(o)
            u32(0)
        case .crownRotation(let delta, let axis):
            f64(delta.isFinite ? delta : 0)
            u32(axis <= 3 ? axis : 0)
            u32(0)
        case .watchGesture(let g):
            u32(g)
            u32(0)
        case .visionPose(let pose):
            func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }
            let q = pose.rotation.normalized
            for v in [pose.position.x, pose.position.y, pose.position.z, q.w, q.x, q.y, q.z] { f64(finite(v)) }
        case .visionSelection(let sel):
            func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }
            let hands = sel.hasHands
            u32(hands ? 1 : 0)
            u32(0)
            for v in [sel.rayOrigin.x, sel.rayOrigin.y, sel.rayOrigin.z, sel.rayDirection.x, sel.rayDirection.y, sel.rayDirection.z] { f64(finite(v)) }
            for h in [sel.left ?? SpatialHand(), sel.right ?? SpatialHand()] {
                let q = h.rotation.normalized
                u32(hands && h.pinching ? 1 : 0)
                u32(hands && h.allowDirect ? 1 : 0)
                u32(0)
                u32(0)
                for v in [h.position.x, h.position.y, h.position.z, q.w, q.x, q.y, q.z] { f64(finite(v)) }
            }
        }
        return b
    }

    /// Sends one event to the registered bundle. False when none is
    /// registered or the send failed (a dead port clears the registration, §7.5).
    @discardableResult
    public func send(_ event: Event, age: UInt32 = 0) -> Bool {
        // One sender at a time keeps the order (§7.4).
        lock.lock()
        defer { lock.unlock() }
        guard let port = client else { return false }
        sequence += 1
        let message = MachHostOutgoingMessage(remotePort: port, remoteDisposition: MachMsgType.copySend, id: Self.eventID,
                                              body: Self.body(event, sequence: sequence, age: age))
        do {
            try host.send(message, timeout: 250_000_000)
            if sequence <= 5 { log("hid: event \(sequence) sent (\(message.body.count) bytes)") }
            return true
        } catch let e as MachHostError where e == MachHostError(MachMsgReturn.sendTimedOut) {
            log("hid: the guest is not taking input (queue full); event dropped")
            return false
        } catch {
            log("hid: send failed (\(error)); the bundle must register again")
            try? host.deallocate(port)
            client = nil
            return false
        }
    }
}
