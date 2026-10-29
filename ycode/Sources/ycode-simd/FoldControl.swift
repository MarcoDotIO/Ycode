// Folding a foldable device and the device's control socket
// (specs/simulator/foldable.md §8, "Ycode implementation").
//
// FoldController keeps the host's FoldModel and moves the hinge: every
// change of angle is a sweep of hinge-angle messages about 30 ms apart over
// about 0.5 s (I4), sent through the HID service to the guest's HID bundle,
// which dispatches them as vendor-defined events from its device-motion
// service. The model starts closed and portrait at every cold boot (§7, I5)
// and is kept in the memory directory's `fold.state`, which a warm-boot
// snapshot saves and restores with the device.
//
// The control socket: every device run serves a Unix-domain socket (mode
// 0600) at `<memory file system>/ycodectl-<uid>-<id>.sock`, one text
// command a connection, answered with lines that start with "ok" or
// "error". `ycode-simd --device DEV --control <command…>` (and the
// shorthands --fold, --orientation, --rotate, --fold-state) sends one:
//
//   fold closed|half|open|<degrees> [instant]   sweep (or jump) the hinge
//   orientation portrait|landscape-left|landscape-right|faceup|facedown
//   rotate left|right
//   state                                       the fold and the panel shown
//   screenshot LCD|LCD-1|active <path.png>      one panel, upright (D4)

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeHostServices

final class FoldController: @unchecked Sendable {
    let hid: HIDHostService
    let second: SecondDisplay
    let statePath: String
    /// The framebuffer library publishes the inner panel (the default; not with YCODE_FOLD_DISPLAYS=0).
    var innerPublished = true
    let log: (String) -> Void
    private let lock = NSLock()
    private var model: FoldModel
    /// The angle being swept to (nil: none).
    private var target: Int?
    private var generation = 0
    /// Called (on the sweep's thread) after every change of the model.
    var onChange: (@Sendable (FoldModel) -> Void)?
    /// Attempts per hinge message, 30 ms apart, while the guest's input
    /// queue is full.
    static let sendAttempts = 17

    init(hid: HIDHostService, second: SecondDisplay, statePath: String, restoring: Bool, log: @escaping (String) -> Void) {
        self.hid = hid
        self.second = second
        self.statePath = statePath
        self.log = log
        let saved = restoring ? FileManager.default.contents(atPath: statePath).flatMap { FoldModel(record: String(decoding: $0, as: UTF8.self)) } : nil
        model = saved ?? FoldModel()
        if !restoring { try? FileManager.default.removeItem(atPath: statePath) }
        log("fold: \(saved == nil ? "starts closed" : "restored") (\(model.summary))")
    }

    var state: FoldModel { lock.withLock { model } }
    var sweepTarget: Int? { lock.withLock { target } }

    private func saveLocked() {
        try? Data(model.record.utf8).write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    /// Moves the hinge to `angle` (0…180): a sweep, or one message with
    /// `instant`. A move in progress is replaced (the new sweep starts from
    /// the angle last sent). Fails while the guest's HID bundle has not
    /// registered.
    @discardableResult
    func fold(to angle: Int, instant: Bool = false) -> Result<String, FoldError> {
        let to = min(180, max(0, angle))
        guard hid.isRegistered else { return .failure(.notRegistered) }
        let (steps, gen, from) = lock.withLock { () -> ([Int], Int, Int) in
            generation += 1
            target = to
            return (FoldModel.sweep(from: model.angle, to: to, instant: instant), generation, model.angle)
        }
        log("fold: \(from)° → \(to)°" + (instant ? " (one message)" : " (sweep of \(steps.count) messages)"))
        let t = Thread { [self] in
            for (i, a) in steps.enumerated() {
                if i > 0 { usleep(UInt32(FoldModel.sweepStepMilliseconds * 1000)) }
                let current = lock.withLock { generation == gen }
                guard current else { return }
                // The guest's input queue can be full for a moment while it
                // is busy (seen once under load, FOLD2): try again for up
                // to about half a second before the sweep gives up.
                var sent = hid.send(.hingeAngle(UInt32(a)))
                var tries = 1
                while !sent, tries < FoldController.sendAttempts, lock.withLock({ generation == gen }) {
                    usleep(UInt32(FoldModel.sweepStepMilliseconds * 1000))
                    sent = hid.send(.hingeAngle(UInt32(a)))
                    tries += 1
                }
                if sent && tries > 1 { log("fold: the hinge angle \(a)° was taken at attempt \(tries)") }
                guard sent else {
                    log("fold: the guest did not take the hinge angle \(a)° (\(tries) attempts); the sweep stops")
                    lock.withLock { if generation == gen { target = nil } }
                    return
                }
                let m = lock.withLock { () -> FoldModel? in
                    guard generation == gen else { return nil }
                    model.moved(to: a)
                    if i == steps.count - 1 { target = nil }
                    saveLocked()
                    return model
                }
                if let m { onChange?(m) }
            }
            log("fold: at \(to)°: \(state.summary)")
        }
        t.name = "ycode-fold"
        t.start()
        let expected = lock.withLock { model.innerActive(after: to) }
        return .success("fold \(from) -> \(to) " + (instant ? "instant" : "sweep \(steps.count) steps") + ", "
            + (expected ? (innerPublished ? "\(second.name) expected" : "the inner display expected (not published: YCODE_FOLD_DISPLAYS=0)")
               : "LCD expected"))
    }

    /// Sends the device orientation (§5.3).
    @discardableResult
    func setOrientation(_ o: DeviceMotionOrientation) -> Result<String, FoldError> {
        guard hid.isRegistered else { return .failure(.notRegistered) }
        guard hid.send(.deviceOrientation(o.rawValue)) else { return .failure(.notDelivered) }
        let m = lock.withLock { () -> FoldModel in
            model.orientation = o
            saveLocked()
            return model
        }
        log("fold: orientation \(o.name)")
        onChange?(m)
        return .success("orientation \(o.name)")
    }

    func rotate(left: Bool) -> Result<String, FoldError> {
        let o = state.orientation
        return setOrientation(left ? o.rotatedLeft : o.rotatedRight)
    }

    enum FoldError: Error, CustomStringConvertible {
        case notRegistered, notDelivered
        var description: String {
            switch self {
            case .notRegistered: "the guest's HID bundle has not registered yet (the device is still booting)"
            case .notDelivered: "the guest did not take the message"
            }
        }
    }
}

// MARK: - The control socket

extension DeviceLayout {
    /// The control socket of the device at `dev` (short enough for a Unix
    /// socket path; independent of the device directory's volume).
    static func controlSocketPath(dev: String) -> String {
        let base = memoryBase ?? NSTemporaryDirectory()
        let id = stableUDID(for: dev).replacingOccurrences(of: "-", with: "").prefix(16)
        return (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/ycodectl-\(getuid())-\(id).sock"
    }
}

/// Serves the device's control socket (one thread in accept()).
final class DeviceControlServer: @unchecked Sendable {
    let path: String
    let fold: FoldController?
    let capture: (_ display: String, _ path: String) -> String
    let summary: () -> String
    /// More commands (the settings features, SimSettings.swift): the answer,
    /// or nil for a command it does not know.
    var moreCommands: (([String]) -> String?)?
    private var fd: Int32 = -1

    init(path: String, fold: FoldController?, summary: @escaping () -> String,
         capture: @escaping (_ display: String, _ path: String) -> String) {
        self.path = path
        self.fold = fold
        self.summary = summary
        self.capture = capture
    }

    func start() -> Bool {
        unlink(path)
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return false }
        guard withUnixAddress(path, { bind(fd, $0, $1) }) == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd)
            fd = -1
            return false
        }
        let t = Thread { [self] in acceptLoop() }
        t.name = "ycode-control"
        t.start()
        return true
    }

    func stop() {
        if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)); close(fd); fd = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while fd >= 0 {
            let c = accept(fd, nil, nil)
            if c < 0 { if errno == EINTR { continue }; return }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            // Each connection on its own thread: a settings command can wait
            // for the guest (VoiceOver starting, an agent after a boot).
            let t = Thread { [self] in
                var line = [UInt8]()
                var b: UInt8 = 0
                while line.count < 4096, read(c, &b, 1) == 1, b != 10 { line.append(b) }
                let reply = handle(String(decoding: line, as: UTF8.self)) + "\n"
                _ = reply.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
            t.name = "ycode-control-command"
            t.start()
        }
    }

    /// One command → the reply (first word "ok" or "error").
    func handle(_ line: String) -> String {
        let w = line.split(separator: " ").map(String.init)
        guard let command = w.first else { return "error: empty command" }
        func result(_ r: Result<String, FoldController.FoldError>) -> String {
            switch r {
            case .success(let s): "ok " + s
            case .failure(let e): "error: \(e)"
            }
        }
        switch command {
        case "state":
            return "ok " + summary()
        case "camera", "privacy":
            return deviceCameraControl?(w) ?? "error: no camera control in this run"
        case "screenshot":
            guard w.count == 3 else { return "error: screenshot LCD|LCD-1|active <path.png>" }
            let text = capture(w[1], w[2])
            return (text.hasPrefix(w[2] + ":") ? "ok " : "error: ") + text
        case "fold", "orientation", "rotate":
            guard let fold else { return "error: this device type does not fold" }
            if command == "fold" {
                guard w.count >= 2, let angle = FoldPosture.angle(argument: w[1]) else {
                    return "error: fold closed|half|open|<degrees 0-180> [instant]"
                }
                return result(fold.fold(to: angle, instant: w.dropFirst(2).contains("instant")))
            }
            if command == "rotate" {
                guard w.count == 2, w[1] == "left" || w[1] == "right" else { return "error: rotate left|right" }
                return result(fold.rotate(left: w[1] == "left"))
            }
            guard w.count == 2, let o = DeviceMotionOrientation(name: w[1]) else {
                return "error: orientation " + DeviceMotionOrientation.allCases.map(\.name).joined(separator: "|")
            }
            return result(fold.setOrientation(o))
        default:
            if let answer = moreCommands?(w) { return answer }
            return "error: unknown command '\(command)' (fold, orientation, rotate, state, screenshot, ui, accessibility, location, audio, overrides, settings)"
        }
    }
}

/// Calls `body` with a sockaddr_un for `path`.
func withUnixAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
    }
    return withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

// MARK: - The client (`ycode-simd --device DEV --control …`)

/// Whether these arguments ask for the control client.
func isControlClient(_ arguments: [String]) -> Bool {
    arguments.contains { ["--control", "--fold", "--orientation", "--rotate", "--fold-state"].contains($0) }
}

/// Sends one command to the running device's control socket, prints the
/// reply and exits (0 for "ok", 1 for "error", 69 when no device runs).
func runControlClient(_ arguments: [String]) -> Never {
    var dev: String?
    var words: [String] = []
    var i = 1
    let help = "usage: ycode-simd --device <dir> --control <command…> | --fold closed|half|open|<degrees> [--instant]"
        + " | --orientation <name> | --rotate left|right | --fold-state"
    func next() -> String {
        i += 1
        guard i < arguments.count else { die("\(arguments[i - 1]) needs a value\n\(help)", status: 64) }
        return arguments[i]
    }
    while i < arguments.count {
        let a = arguments[i]
        switch a {
        case "--device": dev = next()
        case "--control": words = Array(arguments[(i + 1)...]); i = arguments.count
        case "--fold": words = ["fold", next()] + words.filter { $0 == "instant" }
        case "--instant": words.append("instant")
        case "--orientation": words = ["orientation", next()]
        case "--rotate": words = ["rotate", next()]
        case "--fold-state": words = ["state"]
        default: die("unknown argument '\(a)'\n\(help)", status: 64)
        }
        i += 1
    }
    guard let dev, !words.isEmpty else { die(help, status: 64) }
    if words.first == "screenshot", words.count == 3, !words[2].hasPrefix("/") {
        words[2] = FileManager.default.currentDirectoryPath + "/" + words[2]
    }
    let path = DeviceLayout.controlSocketPath(dev: absolutePath(dev))
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    guard fd >= 0, withUnixAddress(path, { connect(fd, $0, $1) }) == 0 else {
        stderrLine("ycode-simd: no running device at \(dev) (\(path): \(String(cString: strerror(errno))))")
        exit(69)
    }
    let line = words.joined(separator: " ") + "\n"
    _ = line.withCString { write(fd, $0, strlen($0)) }
    var reply = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        reply += buf[0..<n]
    }
    close(fd)
    let text = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    print(text)
    exit(text.hasPrefix("ok") ? 0 : 1)
}
#endif
