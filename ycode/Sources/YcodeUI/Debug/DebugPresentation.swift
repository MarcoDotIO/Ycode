import AppKit
import Darwin
import YcodeDebug
import YcodeSubprocess

/// Text and grouping rules for the debugger UI (specs/ide/reference-ui-4.md
/// §5): activity titles, the stop annotation, Debug navigator rows, the
/// variables view's A/L badges. Pure functions so they can be tested.
public enum DebugPresentation {
    // MARK: Activity

    public static func runningTitle(_ product: String?) -> String { product.map { "Running \($0)" } ?? "Running" }
    public static func pausedTitle(_ product: String?) -> String { product.map { "Paused \($0)" } ?? "Paused" }
    public static func finishedTitle(_ product: String?) -> String { "Finished running" + (product.map { " " + $0 } ?? "") }

    // MARK: Stop annotation

    /// "Thread <n>: breakpoint <id> (<hits>)", or "Thread <n>: <reason>"
    /// for other stops.
    public static func stopAnnotation(thread: Int, breakpointID: String?, hits: Int?, reason: String?) -> String {
        if let id = breakpointID { return "Thread \(thread): breakpoint \(id)" + (hits.map { " (\($0))" } ?? "") }
        return "Thread \(thread)" + (reason.map { ": \($0)" } ?? "")
    }

    /// The thread's index from its adapter name ("Thread 3 …"), else its id.
    public static func threadIndex(_ t: DebugThread) -> Int {
        let name = t.name.trimmingCharacters(in: .whitespaces)
        guard name.hasPrefix("Thread ") else { return t.id }
        return Int(name.dropFirst(7).prefix { $0.isNumber }) ?? t.id
    }

    // MARK: Threads

    /// A queue's kind, best effort: the main queue and labelled private
    /// queues are serial; the global (root) queues are concurrent. lldb's
    /// thread format has no queue-kind variable.
    public static func queueKind(_ label: String) -> String {
        let l = label.lowercased()
        if l.contains(".root.") || l.contains("global") || l.contains("concurrent") || l.hasSuffix("-qos") { return "concurrent" }
        return "serial"
    }

    /// "Thread <n>  Queue: <label> (serial|concurrent)", or "Thread <n>"
    /// (plus the thread's name) without a queue.
    public static func threadRow(_ t: DebugThread) -> String {
        let n = threadIndex(t)
        if let q = t.queue, !q.isEmpty { return "Thread \(n)  Queue: \(q) (\(queueKind(q)))" }
        if let r = t.name.range(of: " name = ") { return "Thread \(n)  \(t.name[r.upperBound...])" }
        return "Thread \(n)"
    }

    /// Middle truncation of a string to `max` characters ("com.ex…queue").
    public static func truncateMiddle(_ s: String, max: Int) -> String {
        guard s.count > max, max > 1 else { return s }
        let keep = max - 1
        return String(s.prefix((keep + 1) / 2)) + "…" + String(s.suffix(keep / 2))
    }

    // MARK: Frames

    /// Whether a frame belongs to the user's code: it has a source file
    /// outside the system and toolchain directories.
    public static func isUserFrame(_ f: StackFrame) -> Bool {
        guard let file = f.file, !file.isEmpty else { return false }
        let prefixes = ["/usr/", "/System/", "/Library/Developer/", "/Applications/Xcode", "/AppleInternal/"]
        return !prefixes.contains { file.hasPrefix($0) } && !file.contains(".xctoolchain/") && !file.contains(".platform/Developer/")
    }

    public enum FrameRow: Equatable {
        case frame(index: Int, StackFrame, user: Bool)
        /// The dotted separator before a collapsed run of system frames.
        case separator
    }

    /// User frames, then for each run of system frames a separator and
    /// the run's first frame (greyed); the rest of the run is hidden.
    /// Without any user frame every frame is listed.
    public static func groupFrames(_ frames: [StackFrame]) -> [FrameRow] {
        let user = frames.map(isUserFrame)
        guard user.contains(true) else { return frames.enumerated().map { .frame(index: $0.offset, $0.element, user: false) } }
        var out: [FrameRow] = []
        var i = 0
        while i < frames.count {
            if user[i] { out.append(.frame(index: i, frames[i], user: true)); i += 1; continue }
            if i > 0 { out.append(.separator) }
            out.append(.frame(index: i, frames[i], user: false))
            while i < frames.count && !user[i] { i += 1 }
        }
        return out
    }

    // MARK: Variables

    /// "A" for arguments (including `self`), "L" for locals. A scope
    /// named "Arguments" marks its variables; otherwise argument names come
    /// from the frame's function signature (`f(a:b:)`, `f(int a, int b)`).
    public static func badge(name: String, scope: String, frameName: String?) -> String {
        if name == "self" || scope.localizedCaseInsensitiveContains("argument") { return "A" }
        return argumentNames(frameName ?? "").contains(name) ? "A" : "L"
    }

    /// Parameter names from a function name with a parameter list.
    public static func argumentNames(_ function: String) -> Set<String> {
        guard let open = function.firstIndex(of: "("), let close = function.lastIndex(of: ")"), open < close else { return [] }
        let inside = function[function.index(after: open)..<close]
        var out = Set<String>()
        for part in inside.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if let colon = p.firstIndex(of: ":") {
                // Swift: `label:` or `label name: Type`.
                let words = p[..<colon].split(separator: " ")
                if let w = words.last, w != "_" { out.insert(String(w)) }
                if !p[p.index(after: colon)...].trimmingCharacters(in: .whitespaces).isEmpty, let f = words.first, f != "_" { out.insert(String(f)) }
            } else {
                // C: the last identifier of `type name`.
                let ident = p.reversed().drop { !($0.isLetter || $0.isNumber || $0 == "_") }.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !ident.isEmpty { out.insert(String(ident.reversed())) }
            }
        }
        return out
    }

    /// "A name: Type = value" (the type left out when unknown).
    public static func variableRow(badge: String, _ v: Variable) -> String {
        let type = v.type.flatMap { $0.isEmpty || $0 == "<no-type>" ? nil : $0 }
        return "\(badge) \(v.name)" + (type.map { ": \($0)" } ?? "") + " = \(v.value)"
    }

    // MARK: Console

    public static let killedLine = "Debug session ended with code 9: killed"
}

/// One sample of the debugged process's gauges (Debug navigator).
public struct ProcessGauges: Equatable, Sendable {
    public var cpuPercent: Double = 0
    public var memoryBytes: UInt64 = 0
    public var diskBytesPerSecond: Double = 0
    public var networkBytesPerSecond: Double = 0
    public init() {}

    /// Energy impact from CPU use (Ycode's approximation).
    public var energyImpact: String {
        switch cpuPercent {
        case ..<0.5: "Zero"
        case ..<20: "Low"
        case ..<60: "High"
        default: "Very High"
        }
    }

    /// The Energy Impact bar's fill (reference-ui-5.md §11.6, D3): one
    /// quarter per level from Zero (empty) to Very High (full).
    public var energyLevel: Double {
        switch energyImpact {
        case "Low": 0.25
        case "High": 0.6
        case "Very High": 1
        default: 0
        }
    }

    /// "Zero KB", "512 KB", "12.3 MB", "1.2 GB".
    public static func bytes(_ b: Double) -> String {
        if b < 1024 { return "Zero KB" }
        let units = ["KB", "MB", "GB", "TB"]
        var v = b / 1024
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return (v < 10 && i > 0 ? String(format: "%.1f", v) : String(Int(v.rounded()))) + " " + units[i]
    }

    /// Gauge rows: (title, value).
    public var rows: [(String, String)] {
        [("CPU", "\(Int(cpuPercent.rounded()))%"), ("Memory", Self.bytes(Double(memoryBytes))), ("Energy Impact", energyImpact),
         ("Disk", Self.bytes(diskBytesPerSecond) + "/s"), ("Network", Self.bytes(networkBytesPerSecond) + "/s")]
    }
}

/// Samples a process with `proc_pid_rusage` (public libproc): CPU time,
/// physical footprint and disk I/O; rates come from the previous sample.
/// Per-process network counters have no cheap public API, so Network stays
/// zero.
public final class ProcessGaugeSampler {
    public let pid: Int32
    private var last: (time: UInt64, cpu: UInt64, disk: UInt64, wall: Date)?
    private let timebase: (numer: UInt32, denom: UInt32) = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return (t.numer, max(1, t.denom))
    }()

    public init(pid: Int32) { self.pid = pid }

    /// Reads the counters; nil when the process is gone or not readable.
    public func sample() -> ProcessGauges? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard r == 0 else { return nil }
        // CPU times are in Mach time units.
        let cpuNanos = (info.ri_user_time + info.ri_system_time) &* UInt64(timebase.numer) / UInt64(timebase.denom)
        let disk = info.ri_diskio_bytesread + info.ri_diskio_byteswritten
        let now = Date()
        var g = ProcessGauges()
        g.memoryBytes = info.ri_phys_footprint
        if let last {
            let wall = max(0.001, now.timeIntervalSince(last.wall))
            g.cpuPercent = max(0, Double(cpuNanos &- last.cpu) / 1e9 / wall * 100)
            g.diskBytesPerSecond = max(0, Double(disk &- last.disk) / wall)
        }
        last = (0, cpuNanos, disk, now)
        return g
    }
}

/// The current git branch of a folder (`git rev-parse --abbrev-ref HEAD`),
/// for the debug bar.
public enum GitBranchLookup {
    public static func current(at path: String) -> String? {
        MainThreadGuard.blockingCall("git rev-parse --abbrev-ref HEAD")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s == "HEAD" ? nil : s
    }
}
