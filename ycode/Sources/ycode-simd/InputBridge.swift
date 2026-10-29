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
/// input (foldable.md §5, §8.2), and every boot starts closed.
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
    // Move coalescing (§7.4): at most one move-only message per 16 ms.
    private var pendingMove: [HIDHostService.Contact]?
    private var lastTouchSend: UInt64 = 0
    private var flushScheduled = false
    private let queue = DispatchQueue(label: "ycode-hid-input")
    private var lastPoint = [(x: Double, y: Double)](repeating: (0, 0), count: maxContacts + 1)
    private var keysDown = Set<UInt32>()      // page << 16 | usage
    private var buttonsDown = Set<UInt32>()

    init(hid: HIDHostService, pointWidth: Double, pointHeight: Double) {
        self.hid = hid
        panel = { (0, pointWidth, pointHeight) }
    }

    var acceptsTouch: Bool { true }
    var acceptsKeyboard: Bool { true }
    var buttons: [DisplayButton] { DisplayButton.allCases }

    static func edge(x: Double, y: Double, width: Double, height: Double) -> HIDHostService.Edge {
        // Nearest edge within the threshold; bottom before top on ties (§8.2).
        let candidates: [(HIDHostService.Edge, Double)] = [(.bottom, height - y), (.top, y), (.left, x), (.right, width - x)]
        var best: (HIDHostService.Edge, Double)?
        for c in candidates where c.1 <= edgePoints {
            if best == nil || c.1 < best!.1 { best = c }
        }
        return best?.0 ?? .none
    }

    static func usage(of button: DisplayButton) -> UInt32 {
        switch button {
        case .home: 0x40
        case .lock: 0x30
        case .side: 0x95
        case .volumeUp: 0xE9
        case .volumeDown: 0xEA
        }
    }

    func deliver(_ input: DisplayInput) -> Bool {
        switch input {
        case .touch(_, let contacts):
            return touch(contacts)
        case .key(_, let down, let page, let usage):
            let id = UInt32(page) << 16 | UInt32(usage)
            lock.withLock { if down { keysDown.insert(id) } else { keysDown.remove(id) } }
            return hid.send(.key(usagePage: UInt32(page), usage: UInt32(usage), down: down))
        case .button(_, let button, let down):
            let usage = Self.usage(of: button)
            lock.withLock { if down { buttonsDown.insert(usage) } else { buttonsDown.remove(usage) } }
            return hid.send(.button(usagePage: 0x0C, usage: usage, down: down))
        }
    }

    func reset() {
        flush()
        let (contacts, keys, buttons) = lock.withLock { () -> ([HIDHostService.Contact], Set<UInt32>, Set<UInt32>) in
            var c: [HIDHostService.Contact] = []
            for slot in 1...Self.maxContacts where down[slot] {
                down[slot] = false
                c.append(.init(index: UInt32(slot), phase: .cancelled, edge: edges[slot],
                               x: lastPoint[slot].x / pointWidth, y: lastPoint[slot].y / pointHeight))
            }
            defer { keysDown.removeAll(); buttonsDown.removeAll() }
            return (c, keysDown, buttonsDown)
        }
        if !contacts.isEmpty { _ = sendTouch(contacts) }
        for k in keys { hid.send(.key(usagePage: k >> 16, usage: k & 0xFFFF, down: false)) }
        for b in buttons { hid.send(.button(usagePage: 0x0C, usage: b, down: false)) }
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
        let moveOnly = records.allSatisfy { $0.phase == .moved }
        let now = Self.monotonicNanos()
        if moveOnly {
            let deferIt = lock.withLock { () -> Bool in
                if now - lastTouchSend < 16_000_000 {
                    pendingMove = records
                    if !flushScheduled {
                        flushScheduled = true
                        let wait = 16_000_000 - (now - lastTouchSend)
                        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) { [weak self] in self?.flush() }
                    }
                    return true
                }
                return false
            }
            if deferIt { return hid.isRegistered }
        } else {
            flush()
        }
        return sendTouch(records)
    }

    private func flush() {
        let pending = lock.withLock { () -> [HIDHostService.Contact]? in
            flushScheduled = false
            defer { pendingMove = nil }
            return pendingMove
        }
        if let pending { _ = sendTouch(pending) }
    }

    private func sendTouch(_ records: [HIDHostService.Contact]) -> Bool {
        lock.withLock { lastTouchSend = Self.monotonicNanos() }
        return hid.send(.touch(display: panel().display, contacts: records))
    }

    static func monotonicNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
}
#endif
