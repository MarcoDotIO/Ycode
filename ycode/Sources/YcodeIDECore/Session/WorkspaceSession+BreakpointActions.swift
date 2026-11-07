import Foundation
import YcodeSubprocess
import YcodeDebug

/// A log action's message (`specs/ide/debug.md` §Breakpoint editing): text
/// with `@expression@` or `{expression}` (a value of the stopped frame),
/// `%B` (the breakpoint) and `%H` (its hit count).
public enum BreakpointMessage {
    public enum Part: Equatable, Sendable {
        case text(String)
        case expression(String)
        case breakpointName
        case hitCount
    }

    /// The message's parts in order.
    public static func parts(_ message: String) -> [Part] {
        var out: [Part] = []
        var text = ""
        var i = message.startIndex
        func flush() {
            if !text.isEmpty { out.append(.text(text)); text = "" }
        }
        while i < message.endIndex {
            let ch = message[i]
            let next = message.index(after: i)
            if ch == "%", next < message.endIndex, message[next] == "B" || message[next] == "H" {
                flush()
                out.append(message[next] == "B" ? .breakpointName : .hitCount)
                i = message.index(after: next)
                continue
            }
            if ch == "@" || ch == "{", let close = message[next...].firstIndex(of: ch == "@" ? "@" : "}"), close > next {
                flush()
                out.append(.expression(String(message[next..<close]).trimmingCharacters(in: .whitespaces)))
                i = message.index(after: close)
                continue
            }
            text.append(ch)
            i = next
        }
        flush()
        return out
    }

    /// Whether only Ycode can show the message (`%B`, `%H`).
    public static func needsIDE(_ message: String) -> Bool {
        parts(message).contains { $0 == .breakpointName || $0 == .hitCount }
    }

    /// The message as lldb-dap's log point takes it: `{expression}`.
    public static func dapLogMessage(_ message: String) -> String {
        parts(message).map {
            switch $0 {
            case .text(let t): t
            case .expression(let e): "{\(e)}"
            case .breakpointName: "%B"
            case .hitCount: "%H"
            }
        }.joined()
    }
}

/// Ycode's half of breakpoint actions: when a breakpoint whose actions the
/// adapter cannot run stops (a log message that stops, a debugger command,
/// a sound, several actions, or "automatically continue" without a log
/// point), Ycode runs them in order in the stopped frame and continues
/// when asked to. Such stops are not shown.
extension WorkspaceSession {
    /// The line breakpoints a `stopped` event hit, with their adapter ids
    /// ("n.1"): `hitBreakpointIds`, else "breakpoint n.m" in the description.
    func hitLineBreakpoints(_ body: JSON) -> [(id: String, breakpoint: BreakpointStore.Breakpoint)] {
        var ids: [String] = []
        if case .array(let list)? = body["hitBreakpointIds"] {
            ids = list.compactMap(\.int).map { "\($0).1" }
        } else if body["reason"]?.string == "breakpoint", let d = body["description"]?.string, d.hasPrefix("breakpoint ") {
            let n = d.dropFirst("breakpoint ".count).prefix { $0.isNumber }
            if !n.isEmpty { ids = ["\(n).1"] }
        }
        var out: [(String, BreakpointStore.Breakpoint)] = []
        for id in ids {
            for (key, value) in breakpointIDs where value == id {
                guard let colon = key.lastIndex(of: ":"), let line = Int(key[key.index(after: colon)...]) else { continue }
                if let b = breakpoints.breakpoint(file: String(key[..<colon]), line: line) { out.append((id, b)) }
            }
        }
        return out
    }

    /// Runs the actions of the breakpoints a stop hit when Ycode runs them.
    /// Returns true when the program was continued (the stop is not shown).
    func runBreakpointActions(_ body: JSON) async -> Bool {
        guard ["breakpoint", "function breakpoint"].contains(body["reason"]?.string ?? ""), let client = debugClient else { return false }
        let hit = hitLineBreakpoints(body).filter { $0.breakpoint.runsActionsInIDE }
        guard !hit.isEmpty else { return false }
        var thread = body["threadId"]?.int
        if thread == nil { thread = try? await client.threads().first?.id }
        var frameID: Int?
        if let t = thread { frameID = (try? await client.stackTrace(threadID: t, levels: 1))?.first?.id }
        var continues = true
        for (id, b) in hit {
            // The hit count includes this stop.
            let hits = (breakpointHits[id] ?? 0) + 1
            for action in b.actions {
                switch action {
                case .log(let message):
                    let text = await interpolate(message, breakpoint: b, hits: hits, frameID: frameID)
                    appendConsole(text + "\n", kind: .debugger)
                case .debuggerCommand(let command):
                    let c = command.trimmingCharacters(in: .whitespaces)
                    guard !c.isEmpty else { continue }
                    do {
                        let r = try await client.evaluateFull(c, frameID: frameID, context: "repl")
                        if !r.result.isEmpty { appendConsole(r.result.hasSuffix("\n") ? r.result : r.result + "\n", kind: .debugger) }
                    } catch {
                        let m = (error as? DAPError)?.message ?? "\(error)"
                        appendConsole(m.hasPrefix("error:") ? m + "\n" : "error: \(m)\n", kind: .debugger)
                    }
                case .sound(let name):
                    BreakpointSound.play(name)
                }
            }
            continues = continues && b.autoContinue
            if b.autoContinue { breakpointHits[id] = hits }
        }
        guard continues, let t = thread else { return false }
        try? await client.continue(threadID: t)
        return true
    }

    /// A log message with its values: expressions in the frame, `%B` as
    /// "<file>:<line>" and `%H` as the hit count.
    func interpolate(_ message: String, breakpoint b: BreakpointStore.Breakpoint, hits: Int, frameID: Int?) async -> String {
        var out = ""
        for part in BreakpointMessage.parts(message) {
            switch part {
            case .text(let t): out += t
            case .breakpointName: out += "\(URL(fileURLWithPath: b.file).lastPathComponent):\(b.line)"
            case .hitCount: out += "\(hits)"
            case .expression(let e):
                if let r = try? await debugClient?.evaluateFull(e, frameID: frameID, context: "watch") { out += r.result } else { out += "<\(e): unavailable>" }
            }
        }
        return out
    }
}

/// The sounds a breakpoint's Sound action can play: the desktop's sound
/// theme on Linux (freedesktop's stereo sounds through PipeWire or
/// PulseAudio's player), the system sounds on macOS. Empty when there are
/// none or no player (the Sound action is then not offered).
public enum BreakpointSound {
    #if os(Linux)
    static let folders = ["/usr/share/sounds/freedesktop/stereo"]
    static let players = ["pw-play", "paplay", "canberra-gtk-play"]
    #else
    static let folders = ["/System/Library/Sounds"]
    static let players = ["/usr/bin/afplay"]
    #endif

    /// The sound files by name (no extension), sorted.
    public static let files: [String: String] = {
        var out: [String: String] = [:]
        for folder in folders {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where !f.hasPrefix(".") {
                let name = (f as NSString).deletingPathExtension
                if out[name] == nil { out[name] = (folder as NSString).appendingPathComponent(f) }
            }
        }
        return out
    }()

    static let player: String? = players.lazy.compactMap { p -> String? in
        if p.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: p) ? p : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return path.split(separator: ":").map { "\($0)/\(p)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }.first

    public static var names: [String] { player == nil ? [] : files.keys.sorted() }

    /// Plays a sound in the background (nothing when it is unknown).
    public static func play(_ name: String) {
        guard let player, let file = files[name] else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: player)
        p.arguments = player.hasSuffix("canberra-gtk-play") ? ["-f", file] : [file]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.runWithSignalsUnblocked()
    }
}
