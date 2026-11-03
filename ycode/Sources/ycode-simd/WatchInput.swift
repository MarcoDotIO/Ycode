// A watch's Digital Crown, buttons and gestures on the control socket
// (specs/simulator/watchos.md W-9, W-10, §5.1, §5.2; Ycode's decisions in §12, §13):
//
//   crown <delta> [count [interval-ms [x|y|z]]]   `count` crown messages (default 1)
//                                         of the signed `delta` each, `interval-ms`
//                                         apart (default 16): positive scrolls a
//                                         list forward and opens the Smart Stack
//                                         on the face, negative the other way
//   button crown|side|action|screen [hold-ms]     one press, held `hold-ms` (default
//                                         100; up to 10000): crown → the app grid /
//                                         the face (held 1.8 s: Siri), side →
//                                         Control Center (held 2.5 s: the power-off
//                                         sheet), action (Ultra only) → its sheet,
//                                         screen → the screen off / on (§5.2)
//   gesture double-tap|flick|tap|<0-5>     one watch gesture (§5.1's numbering)
//
// Crown and gestures go to the HID bundle as kinds 8 and 9, buttons as kind 3
// with the usage pair of DeviceButtonTable (YcodeDisplayStream), the table the
// display stream's buttons use too. The viewer's scroll wheel and trackpad send
// `crown` through the display stream's commands, and `ycode-simd --device D
// --crown <delta> [count]` / `--gesture <g>` (and `ycode-sim --device D
// --crown …`) send them from a shell.

#if os(Linux) && arch(arm64)
import Foundation
import YcodeDisplayStream
import YcodeHostServices

enum WatchInputCommand {
    static let verbs: Set<String> = ["crown", "gesture", "button"]
    static let maxCount = 500
    static let maxHold = 10_000

    /// The button family of a device type (DeviceButtonTable).
    static func buttonFamily(_ type: DeviceType) -> DeviceButtonTable.Family {
        guard type.features.contains("com.apple.hid.digital-crown") else { return .phone }
        return .watch(actionButton: type.features.contains(DeviceType.actionButtonFeature))
    }

    /// The reply to a `crown`, `button` or `gesture` command, or nil for another verb.
    static func handle(_ words: [String], hid: HIDHostService?, family: DeviceButtonTable.Family) -> String? {
        guard let verb = words.first, verbs.contains(verb) else { return nil }
        guard case .watch(let actionButton) = family else { return "error: \(verb): this device is not a watch" }
        guard let hid else { return "error: \(verb): this run has no HID bundle (--hid-bundle or --display-server)" }
        switch verb {
        case "crown":
            guard words.count >= 2, let delta = Double(words[1]), delta.isFinite else {
                return "error: crown <delta> [count [interval-ms [x|y|z]]]"
            }
            // Diagnostics: the scroll axis that carries the delta (the bundle's own by default).
            let axis: UInt32 = words.count > 4 ? ["x": 1, "y": 2, "z": 3][words[4]] ?? 0 : 0
            let count = words.count > 2 ? Int(words[2]) ?? 0 : 1
            let interval = words.count > 3 ? Int(words[3]) ?? -1 : 16
            guard (1...maxCount).contains(count), (0...1000).contains(interval) else {
                return "error: crown: count 1-\(maxCount), interval 0-1000 ms"
            }
            var sent = 0
            for i in 0..<count {
                if i > 0 && interval > 0 { usleep(UInt32(interval) * 1000) }
                if hid.send(.crownRotation(delta, axis: axis)) { sent += 1 }
            }
            return sent == count ? "ok crown \(words[1]) x \(count)"
                : "error: crown: \(sent) of \(count) sent (the guest's HID bundle is not registered)"
        case "button":
            guard (2...3).contains(words.count), let button = DeviceButtonTable.WatchButton(named: words[1]),
                  let hold = words.count == 3 ? Int(words[2]) : 100, (0...maxHold).contains(hold) else {
                return "error: button crown|side|action|screen [hold-ms 0-\(maxHold)]"
            }
            guard let pair = DeviceButtonTable.usage(of: button.displayButton, for: family) else {
                return "error: button: this watch has no \(button.rawValue) button" + (actionButton ? "" : " (Ultra types only)")
            }
            guard hid.send(.button(usagePage: pair.page, usage: pair.usage, down: true)) else {
                return "error: button: the guest's HID bundle is not registered"
            }
            if hold > 0 { usleep(UInt32(hold) * 1000) }
            let up = hid.send(.button(usagePage: pair.page, usage: pair.usage, down: false))
            return up ? "ok button \(button.rawValue) \(pair) held \(hold) ms" : "error: button: the release was not sent"
        default:
            guard words.count == 2, let g = HIDHostService.watchGesture(named: words[1]) else {
                return "error: gesture double-tap|flick|tap|<0-5>"
            }
            let note = HIDHostService.WatchGestureEvent.forGesture(g) == nil ? " (no event: the guest has no receiver for it)" : ""
            return hid.send(.watchGesture(g)) ? "ok gesture \(g)\(note)" : "error: gesture: the guest's HID bundle is not registered"
        }
    }
}
#endif
