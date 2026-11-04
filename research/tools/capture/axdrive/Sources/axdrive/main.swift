// axdrive: drive one app, by PID, without taking over the screen.
//
// Menus and buttons are pressed through the Accessibility API. An app that
// is not frontmost ignores posted keys, clicks and scroll-wheel events (AppKit
// sends them nowhere without a key window), so `scroll --ax` scrolls by
// moving the scroll area's scroll bar through AX in --steps small steps
// instead: no focus needed, but no momentum or rubber-banding either.
// Timed input (scrolls, drags) runs on a fixed wall-clock schedule, so every
// app gets the same timing however fast it answers. Keys, clicks,
// scrolls, hovers and drags are CGEvents posted to that process alone
// (CGEventPostToPid): the real pointer does not move and no other app sees
// them. Every command prints one JSON object. Exit status 3 means the
// Accessibility permission is missing, 4 that nothing matched.
//
//   axdrive check
//   axdrive apps   [--bundle ID]                      running apps and PIDs
//   axdrive displays                                  displays, scale and refresh
//   axdrive tree   --pid N [--depth D] [--scope window|app] [--window T]
//   axdrive find   --pid N MATCH... [--index I] [--scope ...] [--window T]
//   axdrive press  --pid N MATCH... [--action AXPress]
//   axdrive set    --pid N MATCH... --attr AXSelected --value true|false|TEXT|NUMBER
//   axdrive menu   --pid N --path "View>Navigators>Show Navigator"
//   axdrive key    --pid N --keys cmd+shift+o [--text "abc"]
//   axdrive click  --pid N (MATCH... | --at X,Y) [--button left|right] [--count 2]
//   axdrive hover  --pid N (MATCH... | --at X,Y)
//   axdrive scroll --pid N (MATCH... | --at X,Y) --dy PT [--dx PT] [--steps N] [--interval S]
//                  [--phases] [--momentum [--momentum-tau S]] [--ax]
//   axdrive select --pid N MATCH...                   select an outline or table row (AXSelectedRows)
//   axdrive drag   --pid N --from X,Y --to X,Y [--duration S]
//   (click, hover, scroll and drag take --route pid|tap; see routeTap)
//   axdrive window --pid N [--window T] [--size W,H] [--position X,Y] [--main] [--raise]
//                  (--raise orders the window to the front of its app's windows
//                  without activating the app)
//   axdrive wait   --pid N --window T [--timeout S]
//   axdrive activate --pid N                         brings the app to the front (takes focus!)
//
// MATCH is --match KEY=VALUE (exact) or --match KEY~=VALUE (substring, any
// case); KEY is role, subrole, title, description, identifier, value, help,
// label (title, description or value) or text (label of the element or of a
// descendant up to three levels down, for rows whose text is in a cell).
// Several --match options must all hold.
// "A|B" in a value or a menu path accepts either text.
// --window TITLE or --window-origin X,Y picks the window (default: the main one).
// X,Y are window-relative points (from the top left of the chosen window)
// unless --global is given; positions found through AX are global already.

import AppKit
import ApplicationServices
import Foundation

// MARK: - Options and output

struct Options {
    var command = ""
    var pid: pid_t = 0
    var bundle: String?
    var matches: [(key: String, value: String, contains: Bool)] = []
    var index = 0
    var depth = 6
    var scope = "window"
    var window: String?
    var windowOrigin: CGPoint?
    var path: String?
    var keys: String?
    var text: String?
    var at: CGPoint?
    var from: CGPoint?
    var to: CGPoint?
    var global = false
    var button = "left"
    var count = 1
    var dx: Double = 0
    var dy: Double = 0
    var steps = 20
    var interval = 1.0 / 60
    var duration = 0.4
    var momentum = false
    var momentumTau = 0.33
    var phases = false
    var size: CGSize?
    var position: CGPoint?
    var main = false
    var raise = false
    var timeout = 30.0
    var action = "AXPress"
    var viaAX = false
    var route = "pid"
    var attr: String?
    var value: String?
}

/// Wall-clock time just before the first event or AX action was sent.
var actionStart: Double?

func markStart() { if actionStart == nil { actionStart = Date().timeIntervalSince1970 } }

/// Every result carries the wall-clock times of the action (seconds since 1970),
/// so a recording's frames can be lined up with it.
func emit(_ object: [String: Any]) {
    var object = object
    object["wall"] = Date().timeIntervalSince1970
    if let s = actionStart { object["wall_start"] = s }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + "\n".data(using: .utf8)!)
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    emit(["ok": false, "error": message])
    exit(code)
}

func number<T: LosslessStringConvertible>(_ text: String, _ name: String) -> T {
    guard let v = T(text) else { fail("\(name) needs a number, not \(text)") }
    return v
}

func pair(_ text: String, _ name: String) -> (Double, Double) {
    let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2, let a = parts[0], let b = parts[1] else { fail("\(name) needs X,Y") }
    return (a, b)
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    guard let first = args.first else { fail("usage: axdrive COMMAND [options]; see the header of main.swift") }
    o.command = first
    var i = 1
    func value() -> String {
        i += 1
        guard i < args.count else { fail("\(args[i - 1]) needs a value") }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--pid": o.pid = number(value(), a)
        case "--bundle": o.bundle = value()
        case "--match":
            let m = value()
            if let r = m.range(of: "~=") {
                o.matches.append((String(m[..<r.lowerBound]), String(m[r.upperBound...]), true))
            } else if let r = m.range(of: "=") {
                o.matches.append((String(m[..<r.lowerBound]), String(m[r.upperBound...]), false))
            } else { fail("--match needs KEY=VALUE or KEY~=VALUE") }
        case "--index": o.index = number(value(), a)
        case "--depth": o.depth = number(value(), a)
        case "--scope": o.scope = value()
        case "--window": o.window = value()
        case "--window-origin": let p = pair(value(), a); o.windowOrigin = CGPoint(x: p.0, y: p.1)
        case "--path": o.path = value()
        case "--keys": o.keys = value()
        case "--text": o.text = value()
        case "--at": let p = pair(value(), a); o.at = CGPoint(x: p.0, y: p.1)
        case "--from": let p = pair(value(), a); o.from = CGPoint(x: p.0, y: p.1)
        case "--to": let p = pair(value(), a); o.to = CGPoint(x: p.0, y: p.1)
        case "--global": o.global = true
        case "--button": o.button = value()
        case "--count": o.count = number(value(), a)
        case "--dx": o.dx = number(value(), a)
        case "--dy": o.dy = number(value(), a)
        case "--steps": o.steps = max(1, number(value(), a))
        case "--interval": o.interval = number(value(), a)
        case "--duration": o.duration = number(value(), a)
        case "--momentum": o.momentum = true
        case "--momentum-tau": o.momentumTau = number(value(), a)
        case "--phases": o.phases = true
        case "--ax": o.viaAX = true
        case "--route": o.route = value()
        case "--size": let p = pair(value(), a); o.size = CGSize(width: p.0, height: p.1)
        case "--position": let p = pair(value(), a); o.position = CGPoint(x: p.0, y: p.1)
        case "--main": o.main = true
        case "--raise": o.raise = true
        case "--timeout": o.timeout = number(value(), a)
        case "--action": o.action = value()
        case "--attr": o.attr = value()
        case "--value": o.value = value()
        default: fail("unknown option \(a)")
        }
        i += 1
    }
    return o
}

// MARK: - AX helpers

func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func string(_ e: AXUIElement, _ name: String) -> String? {
    guard let v = attribute(e, name) else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    (attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attribute(e, kAXPositionAttribute), let s = attribute(e, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func describe(_ e: AXUIElement) -> [String: Any] {
    var d: [String: Any] = [:]
    for (key, name) in [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("title", kAXTitleAttribute),
                        ("description", kAXDescriptionAttribute), ("identifier", kAXIdentifierAttribute),
                        ("help", kAXHelpAttribute), ("value", kAXValueAttribute)] {
        if let s = string(e, name), !s.isEmpty { d[key] = s.count > 120 ? String(s.prefix(120)) + "…" : s }
    }
    if let f = frame(e) { d["frame"] = [f.origin.x, f.origin.y, f.width, f.height] }
    var names: CFArray?
    if AXUIElementCopyActionNames(e, &names) == .success, let list = names as? [String], !list.isEmpty {
        d["actions"] = list.filter { $0 != "AXScrollToVisible" && $0 != "AXShowDefaultUI" && $0 != "AXShowAlternateUI" }
    }
    return d
}

func normalized(_ s: String) -> String {
    s.replacingOccurrences(of: "...", with: "…").lowercased()
}

func textMatches(_ actual: String?, _ wanted: String, contains: Bool) -> Bool {
    guard let actual else { return false }
    return wanted.split(separator: "|", omittingEmptySubsequences: false).contains { alt in
        let w = String(alt)
        return contains ? normalized(actual).contains(normalized(w)) : normalized(actual) == normalized(w)
    }
}

/// The labels of an element and of its descendants, for rows and cells whose
/// text sits in a child.
func descendantText(_ e: AXUIElement, depth: Int) -> [String] {
    let own = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { string(e, $0) }
    guard depth > 0 else { return own }
    return own + children(e).flatMap { descendantText($0, depth: depth - 1) }
}

func elementMatches(_ e: AXUIElement, _ o: Options) -> Bool {
    o.matches.allSatisfy { m in
        let names: [String]
        switch m.key {
        case "role": names = [kAXRoleAttribute]
        case "subrole": names = [kAXSubroleAttribute]
        case "title": names = [kAXTitleAttribute]
        case "description": names = [kAXDescriptionAttribute]
        case "identifier": names = [kAXIdentifierAttribute]
        case "value": names = [kAXValueAttribute]
        case "help": names = [kAXHelpAttribute]
        case "label": names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
        case "text": return descendantText(e, depth: 3).contains { textMatches($0, m.value, contains: m.contains) }
        default: fail("unknown match key \(m.key)")
        }
        return names.contains { textMatches(string(e, $0), m.value, contains: m.contains) }
    }
}

func appElement(_ o: Options) -> AXUIElement {
    guard o.pid > 0 else { fail("give --pid") }
    let app = AXUIElementCreateApplication(o.pid)
    AXUIElementSetMessagingTimeout(app, 3)
    return app
}

func windows(_ app: AXUIElement) -> [AXUIElement] {
    (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

/// The window commands act on: the one whose top-left corner is at
/// --window-origin, else the one whose title matches --window, else the main
/// window, else the first.
func chosenWindow(_ o: Options) -> AXUIElement? {
    let app = appElement(o)
    let all = windows(app)
    if let p = o.windowOrigin {
        return all.first { w in frame(w).map { abs($0.minX - p.x) <= 2 && abs($0.minY - p.y) <= 2 } ?? false }
    }
    if let t = o.window {
        return all.first { textMatches(string($0, kAXTitleAttribute), t, contains: true) }
    }
    if let m = attribute(app, kAXMainWindowAttribute), CFGetTypeID(m) == AXUIElementGetTypeID() {
        return (m as! AXUIElement)
    }
    return all.first
}

func searchRoots(_ o: Options) -> [AXUIElement] {
    if o.scope == "app" { return [appElement(o)] }
    guard let w = chosenWindow(o) else { fail("no window", code: 4) }
    return [w]
}

/// Breadth-first, so the shallowest match is index 0.
func findAll(_ o: Options, limit: Int = 30000) -> [AXUIElement] {
    var queue = searchRoots(o).map { ($0, 0) }
    var found: [AXUIElement] = []
    var visited = 0
    while !queue.isEmpty, visited < limit {
        let (e, depth) = queue.removeFirst()
        visited += 1
        if elementMatches(e, o) { found.append(e); if found.count > o.index { break } }
        if depth < 40 { queue += children(e).map { ($0, depth + 1) } }
    }
    return found
}

func findOne(_ o: Options) -> AXUIElement {
    guard !o.matches.isEmpty else { fail("give at least one --match") }
    let all = findAll(o)
    guard all.count > o.index else { fail("no element matches (found \(all.count))", code: 4) }
    return all[o.index]
}

func tree(_ e: AXUIElement, depth: Int) -> [String: Any] {
    var d = describe(e)
    if depth > 0 {
        let kids = children(e)
        if !kids.isEmpty { d["children"] = kids.map { tree($0, depth: depth - 1) } }
    }
    return d
}

// MARK: - Points

/// A point to act on: the centre of the matched element, or --at, which is
/// window-relative unless --global.
func targetPoint(_ o: Options, _ p: CGPoint? = nil) -> CGPoint {
    if let p = p ?? o.at {
        if o.global { return p }
        guard let w = chosenWindow(o), let f = frame(w) else { fail("no window for a relative point", code: 4) }
        return CGPoint(x: f.minX + p.x, y: f.minY + p.y)
    }
    let e = findOne(o)
    guard let f = frame(e) else { fail("the element has no frame") }
    return CGPoint(x: f.midX, y: f.midY)
}

/// The window server's number for the target app's topmost window under p,
/// so that AppKit routes a posted mouse event to it.
func windowNumber(at p: CGPoint, pid: pid_t) -> Int64 {
    let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in info where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        guard let b = w[kCGWindowBounds as String] as? [String: Double],
              CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(p)
        else { continue }
        return Int64(w[kCGWindowNumber as String] as? Int ?? 0)
    }
    return 0
}

// MARK: - Events

let source = CGEventSource(stateID: .privateState)

/// --route tap: pointer and scroll-wheel events go through the system's
/// event stream (the HID tap), so the window server routes them to the
/// window under the pointer, as a real mouse or trackpad does. AppKit drops
/// those event types when they are posted to a process directly, even to
/// the active app; keys posted to the process work. Routing through the tap
/// moves the pointer, so it is only done while the target app is frontmost
/// and owns the topmost window under the point (`checkRoutable`); the
/// pointer is put back afterwards.
var routeTap = false

func isPointerEvent(_ e: CGEvent) -> Bool {
    ![.keyDown, .keyUp, .flagsChanged].contains(e.type)
}

func post(_ event: CGEvent?, _ pid: pid_t, window: Int64 = 0) {
    guard let event else { return }
    markStart()
    if window != 0 {
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: window)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: window)
    }
    if routeTap && isPointerEvent(event) {
        event.post(tap: .cghidEventTap)
    } else {
        event.postToPid(pid)
    }
}

/// Refuses to route through the tap unless the target app is frontmost and
/// the system-wide accessibility hit test at p lands in that app, so no
/// other app gets the events. (The hit test, unlike the window list, skips
/// overlays that let the pointer through, such as the Dock's.)
func checkRoutable(_ p: CGPoint, _ o: Options) {
    guard NSRunningApplication(processIdentifier: o.pid)?.isActive == true else {
        fail("--route tap needs the app in the foreground (axdrive activate first)", code: 5)
    }
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
          let hit else { fail("nothing at \(p)", code: 5) }
    var owner: pid_t = 0
    AXUIElementGetPid(hit, &owner)
    guard owner == o.pid else {
        let name = NSRunningApplication(processIdentifier: owner)?.localizedName ?? "pid \(owner)"
        fail("\(name) is on top at \(p); not routing", code: 5)
    }
}

/// Runs body with the pointer events routed through the tap when asked,
/// putting the pointer back where it was afterwards.
func routed<T>(_ p: CGPoint, _ o: Options, _ body: () -> T) -> T {
    guard routeTap else { return body() }
    checkRoutable(p, o)
    let saved = CGEvent(source: nil)?.location
    let result = body()
    if let saved {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: saved, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
    return result
}

func pause(_ seconds: Double) { if seconds > 0 { usleep(UInt32(seconds * 1_000_000)) } }

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53, "esc": 53, "enter": 76,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
    "f10": 109, "f11": 103, "f12": 111, "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119,
    "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
]

func flags(_ names: [Substring]) -> CGEventFlags {
    var f: CGEventFlags = []
    for n in names {
        switch n.lowercased() {
        case "cmd", "command": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "opt", "option", "alt": f.insert(.maskAlternate)
        case "ctrl", "control": f.insert(.maskControl)
        case "fn": f.insert(.maskSecondaryFn)
        default: fail("unknown modifier \(n)")
        }
    }
    return f
}

/// "cmd+shift+o", or several chords separated by spaces.
func sendKeys(_ spec: String, pid: pid_t) {
    for chord in spec.split(separator: " ") {
        var parts = chord.split(separator: "+")
        guard let key = parts.popLast()?.lowercased(), let code = keyCodes[key] else { fail("unknown key in \(chord)") }
        let f = flags(parts)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = f
            post(e, pid)
            pause(0.02)
        }
    }
}

func sendText(_ text: String, pid: pid_t) {
    for scalar in text.utf16 {
        var c = scalar
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            post(e, pid)
        }
        pause(0.015)
    }
}

func click(at p: CGPoint, _ o: Options) {
    let right = o.button == "right"
    let window = windowNumber(at: p, pid: o.pid)
    let (downType, upType): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
    let button: CGMouseButton = right ? .right : .left
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button), o.pid, window: window)
    for n in 1...max(1, o.count) {
        for type in [downType, upType] {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            post(e, o.pid, window: window)
            pause(0.03)
        }
    }
}

/// Runs body(i) for i in 0..<count at fixed wall-clock deadlines, start +
/// i * interval, so the input's timing does not depend on how quickly the
/// app answers: both apps get the same schedule. A late tick is not made up
/// by sleeping less later; it simply runs as soon as possible.
func onSchedule(_ count: Int, interval: Double, _ body: (Int) -> Void) -> (start: Double, end: Double) {
    let start = Date().timeIntervalSince1970
    for i in 0..<count {
        let wait = start + Double(i) * interval - Date().timeIntervalSince1970
        if wait > 0 { pause(wait) }
        body(i)
    }
    return (start, Date().timeIntervalSince1970)
}

/// Precise (trackpad-style) scrolling in points, with the gesture phases
/// (may-begin, began, changed, ended): --dy and --dx spread evenly over
/// --steps events --interval apart. --momentum adds the momentum phase of a
/// flick after the fingers lift: events continue at the same interval with
/// the release velocity decaying exponentially (time constant
/// --momentum-tau, default 0.33 s) until under half a point per event. On a
/// Mac the momentum events come from the system, not the app, so both apps
/// get the same coasting input and the capture shows how each follows it.
func scroll(at p: CGPoint, _ o: Options) -> [String: Any] {
    let window = windowNumber(at: p, pid: o.pid)
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left), o.pid, window: window)
    func wheel(_ dy: Double, _ dx: Double, phase: Int64, momentum: Int64) {
        let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                        wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
        e?.location = p
        e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e?.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        e?.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        e?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        e?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        post(e, o.pid, window: window)
    }
    // CGScrollPhase: began 1, changed 2, ended 4, may-begin 128 (not
    // NSEvent.Phase's values). CGMomentumScrollPhase: begin 1, continue 2, end 3.
    // Without --phases (and without --momentum) the events carry no phase,
    // like a smooth scroll wheel: they move the content exactly by their
    // deltas. A phased trackpad gesture is scaled by the system (about 1.2x
    // at 600 pt/s), so the travel actually made is measured and reported.
    let phased = o.phases || o.momentum
    let ddy = o.dy / Double(o.steps), ddx = o.dx / Double(o.steps)
    if phased { wheel(0, 0, phase: 128, momentum: 0) }
    let gesture = onSchedule(o.steps, interval: o.interval) { i in
        wheel(ddy, ddx, phase: phased ? (i == 0 ? 1 : 2) : 0, momentum: 0)
    }
    if phased { wheel(0, 0, phase: 4, momentum: 0) }
    var result: [String: Any] = ["ok": true, "at": [p.x, p.y], "gesture_s": gesture.end - gesture.start,
                                 "gesture_events": o.steps, "interval_s": o.interval]
    if o.momentum {
        let decay = exp(-o.interval / o.momentumTau)
        var deltas: [(Double, Double)] = []
        var vy = ddy * decay, vx = ddx * decay
        while abs(vy) >= 0.5 || abs(vx) >= 0.5, deltas.count < 2000 {
            deltas.append((vy, vx)); vy *= decay; vx *= decay
        }
        let coast = onSchedule(deltas.count, interval: o.interval) { i in
            wheel(deltas[i].0, deltas[i].1, phase: 0, momentum: i == 0 ? 1 : 2)
        }
        wheel(0, 0, phase: 0, momentum: 3)
        result["momentum_events"] = deltas.count
        result["momentum_s"] = coast.end - coast.start
        result["momentum_dy"] = deltas.map(\.0).reduce(0, +)
        result["momentum_dx"] = deltas.map(\.1).reduce(0, +)
    }
    return result
}

/// The scroll area that holds the matched element, or the one at a point.
func scrollArea(_ o: Options) -> AXUIElement? {
    var e: AXUIElement?
    if o.matches.isEmpty {
        let p = targetPoint(o)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(appElement(o), Float(p.x), Float(p.y), &hit) == .success { e = hit }
    } else {
        e = findOne(o)
    }
    var depth = 0
    while let current = e, depth < 30 {
        if string(current, kAXRoleAttribute) == kAXScrollAreaRole { return current }
        guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
        e = (parent as! AXUIElement)
        depth += 1
    }
    return nil
}

/// Scrolls by points through the vertical scroll bar's AXValue (0...1) in
/// --steps steps on the --interval schedule. The bar's value range does not
/// map exactly onto points (content insets), so the travel is measured from
/// the document's position after each step and the points-per-value scale
/// corrected, which keeps the travel within a point of --dy.
func scrollViaAX(_ area: AXUIElement, _ o: Options) -> [String: Any] {
    guard let view = frame(area) else { fail("the scroll area has no frame") }
    let documents = children(area).filter { string($0, kAXRoleAttribute) != kAXScrollBarRole }
    let document = documents.max { (frame($0)?.height ?? 0) < (frame($1)?.height ?? 0) }
    let docHeight = document.flatMap(frame)?.height ?? view.height
    guard o.dy != 0 else { fail("scroll --ax moves vertically: give --dy") }
    guard let barRef = attribute(area, "AXVerticalScrollBar"), CFGetTypeID(barRef) == AXUIElementGetTypeID() else {
        fail("the scroll area has no vertical scroll bar", code: 4)
    }
    let bar = barRef as! AXUIElement
    let y0 = document.flatMap(frame)?.minY
    func travelled() -> Double? { y0.flatMap { y0 in document.flatMap(frame).map { Double(y0 - $0.minY) } } }
    let v0 = (attribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue ?? 0
    var perPoint = 1 / max(1, Double(docHeight - view.height))
    let total = -o.dy   // points of travel down the document
    var value = v0
    let run = onSchedule(o.steps, interval: o.interval) { i in
        let target = total * Double(i + 1) / Double(o.steps)
        value = min(1, max(0, v0 + target * perPoint))
        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: value))
        if let moved = travelled(), abs(moved) > 2, moved * target > 0 { perPoint = (value - v0) / moved }
    }
    return ["ok": true, "scroll_area": describe(area), "requested_dy": o.dy,
            "dy_points": -(travelled() ?? total), "duration_s": run.end - run.start, "steps": o.steps,
            "interval_s": o.interval]
}

func drag(from a: CGPoint, to b: CGPoint, _ o: Options) -> [String: Any] {
    let window = windowNumber(at: a, pid: o.pid)
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: a, mouseButton: .left), o.pid, window: window)
    post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left), o.pid, window: window)
    let n = max(2, Int(o.duration / o.interval))
    let run = onSchedule(n, interval: o.interval) { i in
        let t = Double(i + 1) / Double(n)
        let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left), o.pid, window: window)
    }
    post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left), o.pid, window: window)
    return ["ok": true, "from": [a.x, a.y], "to": [b.x, b.y], "duration_s": run.end - run.start]
}

/// Selects a row of an outline or table through its AXSelectedRows, the way
/// a click on the row would (no focus needed).
func selectRow(_ o: Options) -> [String: Any] {
    let row = findOne(o)
    var e: AXUIElement? = row
    var depth = 0
    while let current = e, depth < 10 {
        let role = string(current, kAXRoleAttribute)
        if role == kAXOutlineRole || role == kAXTableRole {
            markStart()
            let r = AXUIElementSetAttributeValue(current, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
            guard r == .success else { fail("setting AXSelectedRows failed: AXError \(r.rawValue)") }
            return ["ok": true, "row": describe(row)]
        }
        e = attribute(current, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        depth += 1
    }
    fail("the element is not in an outline or table", code: 4)
}

// MARK: - Menus

func pressMenu(_ o: Options) -> [String: Any] {
    guard let path = o.path else { fail("menu needs --path A>B>C") }
    let titles = path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let bar = attribute(appElement(o), kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else {
        fail("the app has no menu bar", code: 4)
    }
    var current = bar as! AXUIElement
    var trail: [String] = []
    for (i, t) in titles.enumerated() {
        // A menu bar item or a menu item holds its items in one AXMenu child.
        var items = children(current)
        if items.count == 1, string(items[0], kAXRoleAttribute) == kAXMenuRole { items = children(items[0]) }
        guard let next = items.first(where: { textMatches(string($0, kAXTitleAttribute), t, contains: false) }) else {
            let seen = items.compactMap { string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
            fail("no menu item \"\(t)\" after \(trail); found \(seen)", code: 4)
        }
        trail.append(string(next, kAXTitleAttribute) ?? t)
        current = next
        if i == titles.count - 1 {
            if let enabled = attribute(next, kAXEnabledAttribute) as? Bool, !enabled {
                fail("menu item \(trail) is disabled", code: 4)
            }
            markStart()
            let r = AXUIElementPerformAction(next, kAXPressAction as CFString)
            guard r == .success else { fail("pressing \(trail) failed: AXError \(r.rawValue)") }
        }
    }
    return ["ok": true, "menu": trail]
}

// MARK: - Commands

func requireTrust() {
    guard AXIsProcessTrusted() else {
        emit(["ok": false, "accessibility": false, "process_chain": ancestry(),
              "how_to_grant": "System Settings > Privacy & Security > Accessibility: turn on the app that "
                + "runs this command (the terminal or agent host in process_chain), then restart that app."])
        exit(3)
    }
}

func ancestry() -> [String] {
    var chain: [String] = []
    var pid = getpid()
    while pid > 1, chain.count < 12 {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        chain.append("\(pid) \(n > 0 ? String(cString: buffer) : "?")")
        pid = info.kp_eproc.e_ppid
    }
    return chain
}

let o = parse(Array(CommandLine.arguments.dropFirst()))
routeTap = o.route == "tap"
switch o.command {
case "check":
    let trusted = AXIsProcessTrusted()
    emit(["ok": trusted, "accessibility": trusted, "process_chain": ancestry()])
    exit(trusted ? 0 : 3)
case "apps":
    let apps = NSWorkspace.shared.runningApplications.filter { o.bundle == nil || $0.bundleIdentifier == o.bundle }
    emit(["ok": true, "apps": apps.map { ["pid": Int($0.processIdentifier), "bundle_id": $0.bundleIdentifier ?? "",
                                          "name": $0.localizedName ?? "", "path": $0.executableURL?.path ?? "",
                                          "launched": $0.launchDate?.timeIntervalSince1970 ?? 0,
                                          "active": $0.isActive] }])
    exit(0)
case "displays":
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &count)
    // A normal window that covers a whole display means that display shows a
    // full-screen Space: a window moved there would be on another Space,
    // invisible to AX and to input.
    let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]) ?? []
    emit(["ok": true, "displays": ids.prefix(Int(count)).map { id -> [String: Any] in
        let b = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        let cover = onScreen.first { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let r = w[kCGWindowBounds as String] as? [String: Double]
            else { return false }
            let covered = CGRect(x: r["X"] ?? 0, y: r["Y"] ?? 0, width: r["Width"] ?? 0, height: r["Height"] ?? 0)
                .intersection(b)
            return covered.width * covered.height >= 0.9 * b.width * b.height
        }
        return ["id": Int(id), "frame": [b.minX, b.minY, b.width, b.height],
                "full_screen_app": cover?[kCGWindowOwnerName as String] as? String ?? NSNull(),
                "scale": Double(mode?.pixelWidth ?? 0) / max(1, Double(b.width)),
                "refresh_hz": mode?.refreshRate ?? 0, "main": CGDisplayIsMain(id) != 0,
                "builtin": CGDisplayIsBuiltin(id) != 0]
    }])
    exit(0)
default:
    break
}
requireTrust()
switch o.command {
case "tree":
    let roots = o.scope == "app" ? [appElement(o)] : (o.window == nil ? windows(appElement(o)) : chosenWindow(o).map { [$0] } ?? [])
    emit(["ok": true, "tree": roots.map { tree($0, depth: o.depth) }])
case "find":
    let e = findOne(o)
    emit(["ok": true, "element": describe(e)])
case "press":
    let e = findOne(o)
    markStart()
    let r = AXUIElementPerformAction(e, o.action as CFString)
    guard r == .success else { fail("\(o.action) failed: AXError \(r.rawValue)") }
    emit(["ok": true, "element": describe(e)])
case "set":
    guard let name = o.attr, let text = o.value else { fail("set needs --attr and --value") }
    let e = findOne(o)
    let v: CFTypeRef = text == "true" ? kCFBooleanTrue : text == "false" ? kCFBooleanFalse
        : (Double(text).map { NSNumber(value: $0) } ?? text as NSString)
    markStart()
    let r = AXUIElementSetAttributeValue(e, name as CFString, v)
    guard r == .success else { fail("setting \(name) failed: AXError \(r.rawValue)") }
    emit(["ok": true, "element": describe(e)])
case "menu":
    emit(pressMenu(o))
case "key":
    if let k = o.keys { sendKeys(k, pid: o.pid) }
    if let t = o.text { sendText(t, pid: o.pid) }
    emit(["ok": true])
case "click":
    let p = targetPoint(o)
    routed(p, o) { click(at: p, o) }
    emit(["ok": true, "at": [p.x, p.y], "route": o.route])
case "hover":
    let p = targetPoint(o)
    if routeTap { checkRoutable(p, o) }   // the pointer stays there: that is the hover
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left),
         o.pid, window: windowNumber(at: p, pid: o.pid))
    emit(["ok": true, "at": [p.x, p.y]])
case "scroll" where o.viaAX:
    guard let area = scrollArea(o) else { fail("no scroll area there", code: 4) }
    emit(scrollViaAX(area, o))
case "scroll":
    let p = targetPoint(o)
    // The document's position before and after gives the travel the app made.
    let area = scrollArea(o)
    let document = area.flatMap { a in
        children(a).filter { string($0, kAXRoleAttribute) != kAXScrollBarRole }
            .max { (frame($0)?.height ?? 0) < (frame($1)?.height ?? 0) }
    }
    let before = document.flatMap(frame)
    var r = routed(p, o) { scroll(at: p, o) }
    usleep(100_000)
    if let before, let after = document.flatMap(frame) {
        r["measured_dy"] = Double(after.minY - before.minY)
        r["measured_dx"] = Double(after.minX - before.minX)
    }
    r["route"] = o.route
    emit(r)
case "select":
    emit(selectRow(o))
case "drag":
    guard let a = o.from, let b = o.to else { fail("drag needs --from and --to") }
    let pa = targetPoint(o, a), pb = targetPoint(o, b)
    emit(routed(pa, o) { drag(from: pa, to: pb, o) })
case "window":
    guard let w = chosenWindow(o) else { fail("no window", code: 4) }
    markStart()
    if var p = o.position, let v = AXValueCreate(.cgPoint, &p) {
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
    }
    if var s = o.size, let v = AXValueCreate(.cgSize, &s) {
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v)
    }
    if o.main { AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue) }
    if o.raise { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
    usleep(150_000)
    emit(["ok": true, "window": describe(w)])
case "wait":
    guard let t = o.window else { fail("wait needs --window TITLE") }
    let deadline = Date().addingTimeInterval(o.timeout)
    while Date() < deadline {
        if let w = windows(appElement(o)).first(where: { textMatches(string($0, kAXTitleAttribute), t, contains: true) }) {
            emit(["ok": true, "window": describe(w)])
            exit(0)
        }
        usleep(200_000)
    }
    fail("no window titled \(t) within \(o.timeout) s", code: 4)
case "activate":
    // Activation requested by a background process is refused under
    // cooperative activation, so ask through AX (AXFrontmost) and, failing
    // that, through Launch Services (`open -a`), as a user's click would.
    guard let app = NSRunningApplication(processIdentifier: o.pid) else { fail("no app with that PID", code: 4) }
    markStart()
    AXUIElementSetAttributeValue(appElement(o), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    var method = "AXFrontmost"
    for attempt in 0..<20 {
        if app.isActive { break }
        if attempt == 5, let url = app.bundleURL {
            method = "open -a"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", url.path]
            try? p.run()
            p.waitUntilExit()
        }
        usleep(100_000)
    }
    emit(["ok": app.isActive, "active": app.isActive, "method": method])
    exit(app.isActive ? 0 : 4)
default:
    fail("unknown command \(o.command)")
}
