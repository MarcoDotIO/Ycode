// visionOS input on the host (specs/simulator/visionos.md §5.5; Ycode's
// choices in "Ycode implementation" there): the camera pose, the gaze ray
// and the hands go to the HID bundle (kinds 10 and 11 of hid-input.md §7.3),
// the Digital Crown as kind 8, and every camera pose also to vhmdd's
// `set_pose` (§5.5.3: ARKit's DeviceAnchor follows vhmdd, the rendered view
// follows the HID pose; the matrices agree). The room is chosen before the
// boot by the preference of §5.5.4 and live by `set_active_environment`.
//
// Sources of input: the display stream's pose, selection and dial messages
// (a viewer runs SpatialInteraction itself and sends stage-frame values), and
// the control socket's `vision …` commands (the scripted driver; the same
// SpatialInteraction runs here):
//
//   vision state                         camera, pointer, vhmdd, rooms
//   vision pose <x> <y> <z> [yaw [pitch]] the camera, absolute (metres, degrees;
//                                        positive yaw turns left, pitch looks up)
//   vision move <forward> <right> <up>   the camera moved (metres, its own frame)
//   vision turn <yaw> [pitch]            the camera turned (degrees)
//   vision reset                         the camera back to the default eye
//   vision gaze <x> <y>                  look at the point (display points)
//   vision tap <x> <y> [hold-ms]         look and pinch (right hand), release
//   vision pinch <x> <y>                 look and pinch, held
//   vision drag <x> <y> [steps [ms]] [depth]  the pinched hand moved with the pointer
//                                        (depth: forward/back, as Shift-drag)
//   vision release                       open the hands
//   vision magnify <x> <y> <factor> [steps [ms]]   both hands pinched, spread by factor
//   vision rotate <x> <y> <degrees> [steps [ms]]   both hands pinched, turned (counter-clockwise)
//   vision dial <delta> [count [ms]]     the Digital Crown
//   vision home                          the Home button
//   vision type <text>                   keys (letters, digits, space, - . , /)
//   vision immersion <amount>            vhmdd's change_immersion_level, absolute (0…1; §5.5.9)
//   vision get-pose                      vhmdd's pose (the matrix ARKit reads)
//   vision rooms                         vhmdd's room list
//   vision room <key>                    switch the room live (waits for the load)

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeDarwinKernel
import YcodeDisplayStream
import YcodeHostServices

final class VisionInputController: @unchecked Sendable {
    let hid: HIDHostService
    let vhmd: VisionHMDClient
    let log: (String) -> Void
    private let lock = NSLock()
    private var interaction: SpatialInteraction
    // Coalescing (§5.5.7 item 4: about once per frame while they change):
    // a selection whose pinch state equals the last one sent waits up to
    // 16 ms and is replaced by a newer one; pinch changes are never dropped.
    private var lastSelectionSend: UInt64 = 0
    private var lastPinch: (Bool, Bool) = (false, false)
    private var pendingSelection: SpatialSelection?
    private var flushScheduled = false
    private var pendingImmersion: Double?
    private let immersionQueue = DispatchQueue(label: "ycode-vision-immersion")
    private let queue = DispatchQueue(label: "ycode-vision-input")
    /// Counters (state, tests).
    private(set) var posesSent = 0, selectionsSent = 0, dialsSent = 0

    init(hid: HIDHostService, vhmd: VisionHMDClient, pointWidth: Double, pointHeight: Double, log: @escaping (String) -> Void) {
        self.hid = hid
        self.vhmd = vhmd
        self.log = log
        interaction = SpatialInteraction(width: pointWidth, height: pointHeight)
    }

    // MARK: Delivery

    /// A camera pose: the HID pose and vhmdd's `set_pose`, same matrix.
    @discardableResult
    func send(pose: SpatialPose) -> Bool {
        lock.withLock {
            interaction.setCamera(pose)
            posesSent += 1
        }
        vhmd.setPose(pose)
        return hid.send(.visionPose(pose))
    }

    /// The headset mode (xr-viewer.md §4): the rendered camera is an eye's
    /// pose (or the head's), vhmdd gets the head (ARKit's device pose).
    @discardableResult
    func send(pose viewPose: SpatialPose, devicePose: SpatialPose) -> Bool {
        lock.withLock {
            interaction.setCamera(devicePose)
            posesSent += 1
        }
        vhmd.setPose(devicePose)
        return hid.send(.visionPose(viewPose))
    }

    /// The immersion amount, absolute (visionos.md §5.5.9: the crown's turn
    /// is vhmdd's change_immersion_level; amounts, never relative steps).
    /// Latest wins on its own queue: a thumbstick never waits for the guest.
    func send(immersion amount: Double) {
        let a = min(max(amount, 0), 1)
        let first = lock.withLock { () -> Bool in
            defer { pendingImmersion = a }
            return pendingImmersion == nil
        }
        guard first else { return }
        immersionQueue.async { [weak self] in
            guard let self else { return }
            while let next = self.lock.withLock({ () -> Double? in defer { self.pendingImmersion = nil }; return self.pendingImmersion }) {
                do {
                    _ = try self.vhmd.request("change_immersion_level", [("immersion_level", .double(next)), ("absolute", .bool(true))])
                } catch {
                    self.log("vhmdd: change_immersion_level failed: \(error)")
                }
            }
        }
    }

    @discardableResult
    func send(selection: SpatialSelection) -> Bool {
        let pinch = (selection.left?.pinching ?? false, selection.right?.pinching ?? false)
        let now = HIDInputBridge.monotonicNanos()
        let deferIt = lock.withLock { () -> Bool in
            if pinch == lastPinch && now - lastSelectionSend < 16_000_000 {
                pendingSelection = selection
                if !flushScheduled {
                    flushScheduled = true
                    let wait = 16_000_000 - (now - lastSelectionSend)
                    queue.asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) { [weak self] in self?.flush() }
                }
                return true
            }
            pendingSelection = nil
            return false
        }
        if deferIt { return hid.isRegistered }
        return sendSelectionNow(selection)
    }

    private func flush() {
        let s = lock.withLock { () -> SpatialSelection? in
            flushScheduled = false
            defer { pendingSelection = nil }
            return pendingSelection
        }
        if let s { _ = sendSelectionNow(s) }
    }

    private func sendSelectionNow(_ s: SpatialSelection) -> Bool {
        lock.withLock {
            lastSelectionSend = HIDInputBridge.monotonicNanos()
            lastPinch = (s.left?.pinching ?? false, s.right?.pinching ?? false)
            selectionsSent += 1
        }
        return hid.send(.visionSelection(s))
    }

    @discardableResult
    func send(dial delta: Double) -> Bool {
        lock.withLock { dialsSent += 1 }
        return hid.send(.crownRotation(delta))
    }

    /// The viewer went away: an open pinch is released (no stuck hands).
    func reset() {
        let s = lock.withLock { interaction.release() }
        if let s { _ = sendSelectionNow(s) }
    }

    // MARK: Commands

    static let verb = "vision"

    func handle(_ words: [String]) -> String? {
        guard words.first == Self.verb else { return nil }
        let w = Array(words.dropFirst())
        guard let sub = w.first else { return usage }
        func number(_ i: Int) -> Double? { i < w.count ? Double(w[i]).flatMap { $0.isFinite ? $0 : nil } : nil }
        func int(_ i: Int, _ d: Int) -> Int { i < w.count ? Int(w[i]) ?? d : d }
        switch sub {
        case "state":
            return "ok " + state()
        case "pose":
            guard let x = number(1), let y = number(2), let z = number(3) else { return "error: vision pose <x> <y> <z> [yaw [pitch]]" }
            let camera = SpatialCamera(position: SpatialVector(x, y, z), yaw: (number(4) ?? 0) * .pi / 180, pitch: (number(5) ?? 0) * .pi / 180)
            return cameraMoved(camera.pose)
        case "move":
            guard let f = number(1), let r = number(2) else { return "error: vision move <forward> <right> [up]" }
            var c = lock.withLock { interaction.camera }
            c.move(forward: f, right: r, up: number(3) ?? 0)
            return cameraMoved(c.pose)
        case "turn":
            guard let yaw = number(1) else { return "error: vision turn <yaw> [pitch] (degrees)" }
            var c = lock.withLock { interaction.camera }
            c.turn(yaw: yaw * .pi / 180, pitch: (number(2) ?? 0) * .pi / 180)
            return cameraMoved(c.pose)
        case "reset":
            return cameraMoved(.identity)
        case "gaze":
            guard let x = number(1), let y = number(2) else { return "error: vision gaze <x> <y>" }
            let s = lock.withLock { interaction.hover(x: x, y: y) }
            return sent(send(selection: s), "gaze \(fmt(x)) \(fmt(y)) ray \(s.rayDirection)")
        case "tap":
            guard let x = number(1), let y = number(2) else { return "error: vision tap <x> <y> [hold-ms]" }
            let hold = min(max(int(3, 100), 0), 10_000)
            let gaze = lock.withLock { interaction.hover(x: x, y: y) }
            _ = sendSelectionNow(gaze)
            usleep(30_000)
            let down = lock.withLock { interaction.press(x: x, y: y) }
            let ok = sendSelectionNow(down)
            usleep(UInt32(hold) * 1000)
            let up = lock.withLock { interaction.release() }
            let ok2 = up.map { sendSelectionNow($0) } ?? false
            return sent(ok && ok2, "tap \(fmt(x)) \(fmt(y)) held \(hold) ms")
        case "pinch":
            guard let x = number(1), let y = number(2) else { return "error: vision pinch <x> <y>" }
            _ = sendSelectionNow(lock.withLock { interaction.hover(x: x, y: y) })
            usleep(30_000)
            return sent(sendSelectionNow(lock.withLock { interaction.press(x: x, y: y) }), "pinch \(fmt(x)) \(fmt(y))")
        case "drag":
            guard let x = number(1), let y = number(2) else { return "error: vision drag <x> <y> [steps [ms]] [depth]" }
            guard lock.withLock({ interaction.isPinching }) else { return "error: vision drag: no pinch is held (vision pinch first)" }
            let depth = w.contains("depth")
            let steps = min(max(int(3, 10), 1), 500), ms = min(max(int(4, 16), 0), 1000)
            let from = lock.withLock { interaction.pointerPosition }
            var ok = true
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let s = lock.withLock { interaction.drag(x: from.x + (x - from.x) * t, y: from.y + (y - from.y) * t, depth: depth) }
                ok = sendSelectionNow(s) && ok
                if ms > 0 { usleep(UInt32(ms) * 1000) }
            }
            return sent(ok, "drag to \(fmt(x)) \(fmt(y)) in \(steps) steps" + (depth ? " (depth)" : ""))
        case "release":
            guard let s = lock.withLock({ interaction.release() }) else { return "ok release (nothing was pinched)" }
            return sent(sendSelectionNow(s), "release")
        case "magnify", "rotate":
            guard let x = number(1), let y = number(2), let amount = number(3) else {
                return "error: vision \(sub) <x> <y> <\(sub == "magnify" ? "factor" : "degrees")> [steps [ms]]"
            }
            if sub == "magnify" && amount <= 0 { return "error: vision magnify: the factor must be positive" }
            let steps = min(max(int(4, 20), 1), 500), ms = min(max(int(5, 16), 0), 1000)
            _ = sendSelectionNow(lock.withLock { interaction.hover(x: x, y: y) })
            usleep(30_000)
            var ok = sendSelectionNow(lock.withLock { interaction.press(x: x, y: y, twoHands: true) })
            usleep(50_000)
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let s = lock.withLock { () -> SpatialSelection in
                    let o = sub == "magnify" ? interaction.twoHandOffset(scale: 1 + (amount - 1) * t, radians: 0)
                        : interaction.twoHandOffset(scale: 1, radians: amount * t * .pi / 180)
                    return interaction.drag(x: x + o.dx, y: y + o.dy)
                }
                ok = sendSelectionNow(s) && ok
                if ms > 0 { usleep(UInt32(ms) * 1000) }
            }
            usleep(50_000)
            if let up = lock.withLock({ interaction.release() }) { ok = sendSelectionNow(up) && ok }
            return sent(ok, "\(sub) \(fmt(amount)) at \(fmt(x)) \(fmt(y)) in \(steps) steps")
        case "dial":
            guard let d = number(1) else { return "error: vision dial <delta> [count [ms]]" }
            let count = min(max(int(2, 1), 1), 500), ms = min(max(int(3, 16), 0), 1000)
            var n = 0
            for i in 0..<count {
                if i > 0 && ms > 0 { usleep(UInt32(ms) * 1000) }
                if send(dial: d) { n += 1 }
            }
            return sent(n == count, "dial \(fmt(d)) x \(count)")
        case "home":
            let pair = DeviceButtonTable.usage(of: .home, for: .phone)!
            guard hid.send(.button(usagePage: pair.page, usage: pair.usage, down: true)) else { return notRegistered }
            usleep(100_000)
            return sent(hid.send(.button(usagePage: pair.page, usage: pair.usage, down: false)), "home")
        case "type":
            let text = w.dropFirst().joined(separator: " ")
            guard !text.isEmpty else { return "error: vision type <text>" }
            var ok = true
            for ch in text {
                guard let (usage, shift) = Self.keyUsage(ch) else { return "error: vision type: no key for '\(ch)'" }
                if shift { ok = hid.send(.key(usagePage: 7, usage: 0xE1, down: true)) && ok }
                ok = hid.send(.key(usagePage: 7, usage: usage, down: true)) && ok
                usleep(20_000)
                ok = hid.send(.key(usagePage: 7, usage: usage, down: false)) && ok
                if shift { ok = hid.send(.key(usagePage: 7, usage: 0xE1, down: false)) && ok }
                usleep(20_000)
            }
            return sent(ok, "typed \(text.count) characters")
        case "immersion":
            guard let a = number(1), a >= 0, a <= 1 else { return "error: vision immersion <amount 0…1>" }
            send(immersion: a)
            return "ok immersion \(fmt(a))"
        case "get-pose":
            do { return "ok vhmdd pose \(try vhmd.getPose())" } catch { return "error: \(error)" }
        case "rooms":
            do {
                let rooms = try vhmd.requestEnvironments()
                return "ok rooms " + rooms.map { "\($0.key) (\($0.displayName))" }.joined(separator: ", ")
                    + (vhmd.activeRoom.map { "; active \($0)" } ?? "")
            } catch { return "error: \(error)" }
        case "room":
            guard w.count == 2, VisionRooms.isValidKey(w[1]) else {
                return "error: vision room <key> (" + VisionRooms.known.joined(separator: ", ") + ")"
            }
            do {
                guard let result = try vhmd.setActiveEnvironment(w[1]) else {
                    return "error: vision room \(w[1]): no synthetic_environment_did_load within 15 s"
                }
                return result.isEmpty ? "ok room \(w[1]) loaded" : "error: room \(w[1]): \(result)"
            } catch { return "error: \(error)" }
        default:
            return usage
        }
    }

    private var usage: String {
        "error: vision state|pose|move|turn|reset|gaze|tap|pinch|drag|release|magnify|rotate|dial|immersion|home|type|get-pose|rooms|room"
    }

    private var notRegistered: String { "error: the guest's HID bundle is not registered" }

    private func sent(_ ok: Bool, _ what: String) -> String { ok ? "ok " + what : notRegistered + " (\(what))" }

    private func fmt(_ v: Double) -> String { String(format: "%g", v) }

    /// A camera move: the pose to both paths, then the gaze again (the ray
    /// is in the stage frame and moves with the camera).
    private func cameraMoved(_ pose: SpatialPose) -> String {
        let ok = send(pose: pose)
        let gaze = lock.withLock { interaction.gazeSelection }
        _ = sendSelectionNow(gaze)
        return sent(ok, "camera \(pose)")
    }

    func state() -> String {
        let (camera, pointer, p, s, d) = lock.withLock { (interaction.camera, interaction.pointerPosition, posesSent, selectionsSent, dialsSent) }
        return "camera \(camera.pose); pointer \(fmt(pointer.x)) \(fmt(pointer.y)); sent poses \(p), selections \(s), dials \(d); "
            + "vhmdd \(vhmd.isConnected ? "connected" : "not connected") (set_pose sent \(vhmd.posesSent))"
            + (vhmd.activeRoom.map { "; room \($0)" } ?? "")
    }

    /// A character's page-7 usage and whether Shift is needed (US layout).
    static func keyUsage(_ c: Character) -> (UInt32, Bool)? {
        guard let a = c.asciiValue else { return nil }
        switch a {
        case 0x61...0x7A: return (UInt32(a - 0x61) + 0x04, false)
        case 0x41...0x5A: return (UInt32(a - 0x41) + 0x04, true)
        case 0x31...0x39: return (UInt32(a - 0x31) + 0x1E, false)
        case 0x30: return (0x27, false)
        case 0x20: return (0x2C, false)
        case 0x2D: return (0x2D, false)
        case 0x2E: return (0x37, false)
        case 0x2C: return (0x36, false)
        case 0x2F: return (0x38, false)
        case 0x0A: return (0x28, false)
        default: return nil
        }
    }
}

/// The rooms (visionos.md §2.6, §5.5.4) and the preference that picks one
/// before the boot (V-13).
enum VisionRooms {
    static let known = VisionHMDClient.knownRooms
    static let preferenceDomain = "com.apple.RealityEnvironment"
    static let preferenceKey = "activeSyntheticEnvironment"

    /// A room key: one of the runtime's, or another plain identifier (a
    /// later runtime may add rooms; vhmdd reports an unknown one).
    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 64 && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    static func preferencePath(dev: String) -> String {
        dev + "/data/Library/Preferences/\(preferenceDomain).plist"
    }

    /// Writes the room into the device's preference file (other keys kept).
    static func writePreference(dev: String, room: String) throws {
        let path = preferencePath(dev: dev)
        var plist: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            plist = existing
        }
        plist[preferenceKey] = room
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The room the preference names, or nil.
    static func preference(dev: String) -> String? {
        guard let data = FileManager.default.contents(atPath: preferencePath(dev: dev)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist[preferenceKey] as? String
    }
}
#endif
