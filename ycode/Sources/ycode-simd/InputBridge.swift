// Viewer input → guest (specs/simulator/hid-input.md). The display
// server's input events become messages of Ycode's HID transport (§7) to
// the HID bundle in backboardd (SimGuestFrameworks/SimHID): touches in
// normalized coordinates with edge marks (§8.2), page-7 keys, and
// consumer-page buttons (§5.5). Enabled with --display-server (or
// --hid-bundle); otherwise SIMULATOR_HID_SYSTEM_MANAGER stays empty and the
// boot is unchanged.

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeDarwinKernel
import YcodeDisplayStream
import YcodeHostServices

/// The HID bundle directory for this run, or nil (no input). A foldable
/// device type has it by default, display server or not: its hinge is HID
/// input (foldable.md §5, §8.2), and every boot starts closed. So does a
/// watch: its crown is (`ycode-sim --crown`, watchos.md §12).
func hidBundlePath(_ options: Options, foldable: Bool = false) -> String? {
    if options.hidBundle == "none" { return nil }
    if let explicit = options.hidBundle { return absolutePath(explicit) }
    guard options.displayServer != nil || foldable, let shim = options.shimPath else { return nil }
    let simShim = ((absolutePath(shim) as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    let built = ((simShim as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent("SimGuestFrameworks/out/SimHID.framework")
    guard FileManager.default.fileExists(atPath: built + "/SimHID") else {
        stderrLine("ycode-simd: no HID bundle at \(built) (SimGuestFrameworks/build.sh); the device takes no input")
        return nil
    }
    return built
}

/// Starts dev.ycode.simulator.hid and offers it in the guest bootstrap,
/// when the device has the HID bundle.
func startHIDService(config: ExecConfiguration, session: DeviceSession, host: MachHostTask) -> HIDHostService? {
    guard let device = config.device, device.hidBundle != nil else { return nil }
    do {
        let service = try HIDHostService(host: host, log: { stderrLine("ycode-simd: " + $0) })
        service.start()
        session.hostServices.append((HIDHostService.serviceName, service.servicePort))
        stderrLine("ycode-simd: HID: bundle \(device.hidGuestPath ?? "?"), host service \(HIDHostService.serviceName)")
        return service
    } catch {
        stderrLine("ycode-simd: warning: cannot start the HID service: \(error)")
        return nil
    }
}

/// Display-stream input → HID transport messages. Touches go to the panel
/// the viewer shows (`panel`; foldable.md §8.2 I1), in that panel's points.
final class HIDInputBridge: GuestInputSink, @unchecked Sendable {
    let hid: HIDHostService
    /// The panel touches are for: its touch-message display index and its
    /// size in points (native portrait orientation).
    var panel: () -> (display: UInt32, pointWidth: Double, pointHeight: Double)
    private var pointWidth: Double { panel().pointWidth }
    private var pointHeight: Double { panel().pointHeight }
    /// §8.2: a contact that begins within this many points of an edge is an edge contact.
    static let edgePoints = 10.0
    static let maxContacts = 5
    private let lock = NSLock()
    private var edges = [HIDHostService.Edge](repeating: .none, count: maxContacts + 1)
    private var down = [Bool](repeating: false, count: maxContacts + 1)
    private var lastPoint = [(x: Double, y: Double)](repeating: (0, 0), count: maxContacts + 1)
    private var keysDown = Set<UInt32>()      // page << 16 | usage
    private var buttonsDown = Set<HIDUsagePair>()
    /// The panel's pixels per point (a resting contact's one-pixel step).
    var pixelScale = 3.0
    /// The device's buttons (DeviceButtonTable; watchos.md §5.2 on a watch).
    var family: DeviceButtonTable.Family = .phone
    /// A Vision Pro's pose, selection and dial (VisionInput.swift); nil elsewhere.
    weak var vision: VisionInputController?

    // Delivery (TouchPacing; uikit-feel-ycode.md §4.0): touches, keys and
    // buttons are stamped on receipt and sent, in order, by one thread with
    // their age, so the display server's receive thread never waits for the
    // guest and a held-up delivery keeps its timing.
    private struct Outgoing {
        var event: HIDHostService.Event
        var received: UInt64
        var moveOnly: Bool
    }
    private var outbox: [Outgoing] = []
    private let outboxCondition = NSCondition()
    private var senderStarted = false
    /// When the last touch message went out, and how many rest reports since (sender thread only).
    private var lastTouchSent: UInt64 = 0
    private var restReports = 0
    /// What a resting contact sends every 16.7 ms: "off" (the default:
    /// nothing, as the reference; uikit-feel-ycode.md §3.3), "pixel" (one
    /// device pixel apart, alternately, as a digitizer's noise: UIKit then
    /// sees the finger stop) or "unchanged" (phase 3 records). An experiment's switch.
    static let restMode = ProcessInfo.processInfo.environment["YCODE_HID_REST"] ?? "off"

    init(hid: HIDHostService, pointWidth: Double, pointHeight: Double) {
        self.hid = hid
        panel = { (0, pointWidth, pointHeight) }
    }

    var acceptsTouch: Bool { true }
    var acceptsKeyboard: Bool { true }
    var buttons: [DisplayButton] { DeviceButtonTable.buttons(for: family) }

    static func edge(x: Double, y: Double, width: Double, height: Double) -> HIDHostService.Edge {
        // Nearest edge within the threshold; bottom before top on ties (§8.2).
        let candidates: [(HIDHostService.Edge, Double)] = [(.bottom, height - y), (.top, y), (.left, x), (.right, width - x)]
        var best: (HIDHostService.Edge, Double)?
        for c in candidates where c.1 <= edgePoints {
            if best == nil || c.1 < best!.1 { best = c }
        }
        return best?.0 ?? .none
    }

    func deliver(_ input: DisplayInput) -> Bool {
        switch input {
        case .touch(_, let contacts):
            return touch(contacts)
        case .key(_, let down, let page, let usage):
            let id = UInt32(page) << 16 | UInt32(usage)
            lock.withLock { if down { keysDown.insert(id) } else { keysDown.remove(id) } }
            enqueue(.key(usagePage: UInt32(page), usage: UInt32(usage), down: down), moveOnly: false)
            return hid.isRegistered
        case .button(_, let button, let down):
            // A button this device lacks (a watch's volume, a non-Ultra's
            // Action) is dropped (watchos.md §5.2).
            guard let pair = DeviceButtonTable.usage(of: button, for: family) else { return false }
            lock.withLock { if down { buttonsDown.insert(pair) } else { buttonsDown.remove(pair) } }
            enqueue(.button(usagePage: pair.page, usage: pair.usage, down: down), moveOnly: false)
            return hid.isRegistered
        case .pose(_, let pose):
            return vision?.send(pose: pose) ?? false
        case .selection(_, let selection):
            return vision?.send(selection: selection) ?? false
        case .dial(_, let delta):
            return vision?.send(dial: delta) ?? false
        case .fovea:
            return true   // the server's foveated streaming only; never the guest
        case .views(_, let v):
            return vision?.send(pose: v.head) ?? false
        }
    }

    func deliver(viewPose: SpatialPose, devicePose: SpatialPose) -> Bool {
        vision?.send(pose: viewPose, devicePose: devicePose) ?? false
    }

    func reset() {
        vision?.reset()
        let (contacts, keys, buttons) = lock.withLock { () -> ([HIDHostService.Contact], Set<UInt32>, Set<HIDUsagePair>) in
            var c: [HIDHostService.Contact] = []
            for slot in 1...Self.maxContacts where down[slot] {
                down[slot] = false
                c.append(.init(index: UInt32(slot), phase: .cancelled, edge: edges[slot],
                               x: lastPoint[slot].x / pointWidth, y: lastPoint[slot].y / pointHeight))
            }
            defer { keysDown.removeAll(); buttonsDown.removeAll() }
            return (c, keysDown, buttonsDown)
        }
        if !contacts.isEmpty { enqueue(.touch(display: panel().display, contacts: contacts), moveOnly: false) }
        for k in keys { enqueue(.key(usagePage: k >> 16, usage: k & 0xFFFF, down: false), moveOnly: false) }
        for b in buttons { enqueue(.button(usagePage: b.page, usage: b.usage, down: false), moveOnly: false) }
    }

    private func touch(_ contacts: [TouchContact]) -> Bool {
        let records: [HIDHostService.Contact] = lock.withLock {
            contacts.compactMap { c -> HIDHostService.Contact? in
                let slot = Int(c.finger) + 1
                guard slot <= Self.maxContacts else { return nil }
                let x = Double(c.x), y = Double(c.y)
                lastPoint[slot] = (x, y)
                let phase: HIDHostService.Phase
                switch c.phase {
                case .began:
                    if down[slot] { return nil }  // a second began for a slot that is down
                    edges[slot] = Self.edge(x: x, y: y, width: pointWidth, height: pointHeight)
                    down[slot] = true
                    phase = .began
                case .moved:
                    guard down[slot] else { return nil }
                    phase = .moved
                case .ended, .cancelled:
                    guard down[slot] else { return nil }
                    down[slot] = false
                    phase = c.phase == .ended ? .ended : .cancelled
                }
                return HIDHostService.Contact(index: UInt32(slot), phase: phase, edge: edges[slot],
                                              x: x / pointWidth, y: y / pointHeight)
            }
        }
        guard !records.isEmpty else { return hid.isRegistered }
        enqueue(.touch(display: panel().display, contacts: records), moveOnly: records.allSatisfy { $0.phase == .moved })
        return hid.isRegistered
    }

    private func enqueue(_ event: HIDHostService.Event, moveOnly: Bool) {
        let item = Outgoing(event: event, received: Self.monotonicNanos(), moveOnly: moveOnly)
        outboxCondition.withLock {
            outbox.append(item)
            if !senderStarted {
                senderStarted = true
                let t = Thread { [self] in senderLoop() }
                t.name = "ycode-hid-input"
                t.qualityOfService = .userInteractive
                t.start()
            }
            outboxCondition.signal()
        }
    }

    /// The sender thread: the outbox in order (a move another move replaces
    /// within 8 ms is dropped), each with its age; while a contact rests,
    /// a report every 16.7 ms.
    private func senderLoop() {
        while true {
            outboxCondition.lock()
            var item: Outgoing?
            while item == nil {
                if !outbox.isEmpty {
                    let first = outbox.removeFirst()
                    let next = outbox.first.map { (moveOnly: $0.moveOnly, received: $0.received) }
                    if TouchPacing.isSuperseded(moveOnly: first.moveOnly, received: first.received, next: next) { continue }
                    item = first
                    break
                }
                let anyDown = lock.withLock { down.contains(true) }
                let now = Self.monotonicNanos()
                if Self.restMode != "off", TouchPacing.restReportDue(anyDown: anyDown, lastTouchSent: lastTouchSent, now: now) { break }
                let wait = anyDown ? TouchPacing.restInterval - min(TouchPacing.restInterval, now &- lastTouchSent) : 1_000_000_000
                _ = outboxCondition.wait(until: Date(timeIntervalSinceNow: Double(max(wait, 1_000_000)) / 1e9))
            }
            outboxCondition.unlock()
            if let item {
                _ = hid.send(item.event, age: TouchPacing.ageMicroseconds(received: item.received, now: Self.monotonicNanos()))
                if case .touch = item.event {
                    lastTouchSent = Self.monotonicNanos()
                    restReports = 0
                }
            } else {
                sendRestReport()
            }
        }
    }

    /// Every resting contact again, as a digitizer reports a still finger.
    private func sendRestReport() {
        let p = panel()
        restReports += 1
        let contacts: [HIDHostService.Contact] = lock.withLock {
            (1...Self.maxContacts).filter { down[$0] }.map { slot in
                let x = lastPoint[slot].x / p.pointWidth, y = lastPoint[slot].y / p.pointHeight
                if Self.restMode == "unchanged" {
                    return .init(index: UInt32(slot), phase: .unchanged, edge: edges[slot], x: x, y: y)
                }
                let r = TouchPacing.restPosition(x: x, y: y, count: restReports, pixelWidth: p.pointWidth * pixelScale)
                return .init(index: UInt32(slot), phase: .moved, edge: edges[slot], x: r.x, y: r.y)
            }
        }
        lastTouchSent = Self.monotonicNanos()
        guard !contacts.isEmpty else { return }
        _ = hid.send(.touch(display: p.display, contacts: contacts))
    }

    static func monotonicNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
}
#endif
