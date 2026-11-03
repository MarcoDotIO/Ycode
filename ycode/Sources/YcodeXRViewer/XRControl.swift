// The viewer's small control interface for switching (xr-viewer.md §7.2,
// device-hub.md §I.12): `--state-file <path>` gets one JSON object,
// rewritten whole (waitingForHeadset → streaming → stopped), SIGTERM and
// SIGINT end the viewer cleanly, and a takeover by another viewer of the
// same device ends it too (it never fights for the display).

import Foundation

public final class XRControl: @unchecked Sendable {
    public static let shared = XRControl()
    private let lock = NSLock()
    private var path: String?
    private var stop = false
    private var phase = ""
    private var sources: [DispatchSourceSignal] = []

    /// Where the state goes (nil: nowhere) and the signals that end the viewer.
    public func configure(stateFile: String?) {
        lock.withLock { path = stateFile }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig)
            s.setEventHandler { [weak self] in self?.requestStop("asked to stop") }
            s.resume()
            sources.append(s)
        }
        write("waitingForHeadset", message: nil)
    }

    public var stopRequested: Bool { lock.withLock { stop } }

    public func requestStop(_ why: String) {
        let first = lock.withLock { () -> Bool in defer { stop = true }; return !stop }
        if first { FileHandle.standardError.write(Data("ycode-xr-viewer: stopping (\(why))\n".utf8)) }
    }

    /// The display is ours: the first picture arrived.
    public func streaming() { write("streaming", message: nil) }

    public func stopped(_ message: String?) { write("stopped", message: message) }

    private func write(_ p: String, message: String?) {
        let target = lock.withLock { () -> String? in
            guard phase != p else { return nil }
            phase = p
            return path
        }
        guard let target else { return }
        var o: [String: Any] = ["phase": p, "pid": Int(getpid())]
        if let message { o["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        let tmp = target + ".tmp"
        FileManager.default.createFile(atPath: tmp, contents: data + Data("\n".utf8))
        _ = rename(tmp, target)
    }
}
