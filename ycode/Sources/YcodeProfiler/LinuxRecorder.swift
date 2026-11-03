import CYcodeGauge
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Records a Linux process (`specs/ide/profiler.md` §3.2): perf_event_open
/// sampling when the kernel allows it, else Gauge's LD_PRELOAD agent.
public struct LinuxRecordOptions: Sendable {
    public enum Backend: String, Sendable { case auto, perf, agent }
    /// The command to launch (argv); nil with `pid` set: attach.
    public var command: [String]?
    public var pid: Int?
    public var rate: Int = 1000
    public var seconds: Double?
    public var backend: Backend = .auto
    /// `libYcodeGaugeAgent.so` (agent back end).
    public var agentPath: String?
    /// Kernel frames (perf only; needs perf_event_paranoid ≤ 1).
    public var kernel = false

    public init(command: [String]? = nil, pid: Int? = nil) {
        self.command = command
        self.pid = pid
    }
}

public struct LinuxRecordError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

public enum LinuxRecorder {
    /// Records until the process exits or `seconds` pass (then a launched
    /// command gets SIGINT, and SIGKILL 2 s later). `log` gets progress lines.
    public static func record(_ o: LinuxRecordOptions, log: (String) -> Void = { _ in }) throws -> GaugeTrace {
        #if os(Linux)
        let rate = max(10, min(10_000, o.rate))
        let periodNs = UInt64(1_000_000_000 / rate)
        let paranoid = Int(ycg_perf_paranoid())
        var backend = o.backend
        if backend == .auto { backend = paranoid <= 2 ? .perf : .agent }
        if backend == .agent && o.command == nil { throw LinuxRecordError("attaching needs perf_event_open (perf_event_paranoid is \(paranoid); the agent back end only launches commands)") }

        var notes: [String] = []
        var samplesFile: String?
        var pid: Int32
        var gate: Int32 = -1
        var launched = false
        if let cmd = o.command, !cmd.isEmpty {
            var env = ProcessInfo.processInfo.environment
            if backend == .agent {
                guard let agent = o.agentPath, FileManager.default.fileExists(atPath: agent) else {
                    throw LinuxRecordError("perf_event_open is not allowed (perf_event_paranoid \(paranoid)) and libYcodeGaugeAgent.so was not found; pass --agent <path>")
                }
                let file = NSTemporaryDirectory() + "ycode-gauge-\(getpid())-\(UUID().uuidString.prefix(8)).samples"
                samplesFile = file
                env["LD_PRELOAD"] = [agent, env["LD_PRELOAD"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
                env["YCODE_GAUGE_SAMPLES"] = file
                env["YCODE_GAUGE_RATE"] = String(rate)
                notes.append("in-process sampler (LD_PRELOAD agent, ITIMER_PROF): perf_event_open is not allowed here (perf_event_paranoid \(paranoid))")
            }
            pid = try spawnHeld(cmd, env: env, gate: &gate)
            launched = true
        } else if let p = o.pid {
            pid = Int32(p)
        } else {
            throw LinuxRecordError("nothing to record: give a command or --pid")
        }

        var builder = GaugeTraceBuilder(recording: GaugeTrace.Recording(
            target: "linux", recorder: "ycode profile (\(backend == .perf ? "perf_event_open" : "LD_PRELOAD agent"))",
            host: hostDescription(), command: (o.command ?? ["pid \(pid)"]).joined(separator: " "), startDate: Date(),
            sampleIntervalNs: periodNs, clock: "monotonic", notes: notes))

        // perf events: one inherited event for a launched command, else one per thread.
        var events: [Int32: ycg_perf] = [:]
        if backend == .perf {
            if launched {
                // One inherited event per CPU (an inherited event for any CPU cannot be mapped).
                var failure: Int32 = 0
                for cpu in 0..<Int32(ycg_cpu_count()) {
                    var p = ycg_perf()
                    if ycg_perf_open(&p, pid, cpu, periodNs, 1, o.kernel ? 1 : 0, 32) == 0 { events[-1 - cpu] = p } else { failure = errno }
                }
                if events.isEmpty {
                    let e = failure
                    if o.backend == .auto, let agent = o.agentPath, FileManager.default.fileExists(atPath: agent) {
                        // Refused after all: start over with the agent.
                        _ = kill(pid, SIGKILL)
                        var st: Int32 = 0
                        _ = ycg_wait(pid, 0, &st)
                        var o2 = o
                        o2.backend = .agent
                        log("perf_event_open failed (\(String(cString: strerror(e)))); using the in-process sampler")
                        return try record(o2, log: log)
                    }
                    _ = kill(pid, SIGKILL)
                    throw LinuxRecordError("perf_event_open: \(String(cString: strerror(e)))")
                }
            } else {
                attachNewThreads(pid: pid, periodNs: periodNs, kernel: o.kernel, events: &events)
                if events.isEmpty { throw LinuxRecordError("perf_event_open on pid \(pid): \(String(cString: strerror(errno)))") }
            }
        }

        let t0 = monotonicNs()
        if launched { _ = ycg_release(gate) }
        log("recording pid \(pid) at \(rate) Hz with \(backend == .perf ? "perf_event_open" : "the in-process sampler")")

        var maps: Set<GaugeSymbolicator.Mapping> = []
        var names: [Int32: String] = [:]
        var buffer = [UInt64](repeating: 0, count: 1 << 16)
        var exitStatus: Int32 = 0
        var exited = false
        var lastPoll: UInt64 = 0
        var stopSentAt: UInt64?
        var raw: [(tid: UInt64, time: UInt64, kernel: Bool, frames: [UInt64])] = []

        func drain() {
            for (tid, var p) in events {
                while true {
                    let n = buffer.withUnsafeMutableBufferPointer { ycg_perf_read(&p, $0.baseAddress, $0.count) }
                    var i = 0
                    while i + 3 <= n {
                        let sampleTid = buffer[i], time = buffer[i + 1], count = Int(buffer[i + 2])
                        var frames: [UInt64] = []
                        var kernelSample = false
                        var context: UInt64 = 0
                        for j in 0..<count {
                            let ip = buffer[i + 3 + j]
                            if ip >= 0xFFFF_FFFF_FFFF_F000 { context = ip; continue }
                            if context == UInt64(bitPattern: -128) && frames.isEmpty { kernelSample = true }
                            if context == UInt64(bitPattern: -128) && !o.kernel { continue }
                            frames.append(ip)
                        }
                        raw.append((sampleTid, time, kernelSample, frames))
                        i += 3 + count
                    }
                    events[tid] = p
                    if n < buffer.count - 600 { break }
                }
            }
        }

        while true {
            let now = monotonicNs()
            // Every 10 ms in the first half second (short programs), then every 100 ms.
            if now &- lastPoll >= (now &- t0 < 500_000_000 ? 10_000_000 : 100_000_000) {
                lastPoll = now
                pollProcess(pid: pid, maps: &maps, names: &names, executable: launched ? o.command.flatMap { resolveExecutable($0.first ?? "") } : nil)
                if backend == .perf && !launched { attachNewThreads(pid: pid, periodNs: periodNs, kernel: o.kernel, events: &events) }
            }
            if backend == .perf { drain() }
            if launched {
                var st: Int32 = 0
                if ycg_wait(pid, 1, &st) == pid { exitStatus = st; exited = true; break }
            } else if kill(pid, 0) != 0 && errno == ESRCH {
                exited = true
                break
            }
            if let s = o.seconds, Double(now &- t0) / 1e9 >= s {
                if !launched { break }
                if stopSentAt == nil { _ = kill(pid, SIGINT); stopSentAt = now } else if let at = stopSentAt, now &- at > 2_000_000_000 { _ = kill(pid, SIGKILL) }
            }
            usleep(10_000)
        }
        if backend == .perf { drain() }
        let t1 = monotonicNs()
        var lost: UInt64 = 0
        for (_, var p) in events { lost += p.lost; ycg_perf_close(&p) }
        if lost > 0 { builder.update { $0.recording.notes.append("\(lost) samples lost (ring buffer full)") } }
        if launched { log("process \(pid) ended with status \(exitStatus)\(exited ? "" : " (stopped)")") }

        // Agent samples.
        if let file = samplesFile {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
            try? FileManager.default.removeItem(atPath: file)
            raw += parseAgentSamples([UInt8](data))
        }

        // Threads, samples and images.
        var threadIDs: Set<UInt64> = []
        for s in raw.sorted(by: { $0.time < $1.time }) where s.time >= t0 {
            threadIDs.insert(s.tid)
            // Frames leaf first → outermost first, as absolute addresses.
            let frames = s.frames.reversed().map { GaugeTrace.Frame(image: -1, offset: $0) }
            builder.addSample(time: s.time - t0, thread: s.tid, state: s.kernel ? .kernel : .user, frames: frames)
        }
        let exe = o.command.flatMap { resolveExecutable($0.first ?? "") } ?? ((try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")) ?? "")
        builder.update { tr in
            tr.recording.durationNs = t1 - t0
            tr.processes = [GaugeTrace.Process(pid: Int(pid), name: (exe as NSString).lastPathComponent, path: exe)]
            tr.threads = threadIDs.union([UInt64(pid)]).sorted().map {
                GaugeTrace.Thread(id: $0, pid: Int(pid), name: names[Int32($0)] ?? "", isMain: $0 == UInt64(pid), kind: $0 == UInt64(pid) ? "main" : "thread")
            }
        }
        if let dump = ProcessInfo.processInfo.environment["YCODE_GAUGE_DEBUG_MAPS"] {
            try? maps.sorted { $0.start < $1.start }.map { "\(String($0.start, radix: 16))-\(String($0.end, radix: 16)) \(String($0.offset, radix: 16)) \($0.path)" }
                .joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
        }
        let exeDir = (exe as NSString).deletingLastPathComponent
        GaugeSymbolicator.resolveELF(&builder, mappings: Array(maps), appPaths: [exe], appDirectories: exeDir.isEmpty ? [] : [exeDir])
        var trace = builder.finish()
        trace.hangs = GaugeTimeline.hangs(trace)
        GaugeSymbolicator.demangle(&trace)
        return trace
        #else
        _ = o
        _ = log
        throw LinuxRecordError("Linux recording runs on Linux only")
        #endif
    }

    /// Parses the agent's records (cycodegaugeagent.h): (tid, time, kernel, frames leaf first).
    public static func parseAgentSamples(_ b: [UInt8]) -> [(tid: UInt64, time: UInt64, kernel: Bool, frames: [UInt64])] {
        var out: [(UInt64, UInt64, Bool, [UInt64])] = []
        var c = ByteCursor(b)
        while c.pos + 32 <= b.count {
            let start = c.pos
            guard let magic = try? c.u32(), magic == 0x3141_4759, let size = try? c.u16(), let n = try? c.u16(),
                  Int(size) == 32 + 8 * Int(n), start + Int(size) <= b.count,
                  (try? c.u32()) != nil, let tid = try? c.u32(), let time = try? c.u64(), let pc = try? c.u64() else { break }
            var frames = [pc]
            for _ in 0..<Int(n) { if let ra = try? c.u64() { frames.append(ra) } }
            out.append((UInt64(tid), time, false, frames))
            c.pos = start + Int(size)
        }
        return out
    }

    #if os(Linux)
    static func monotonicNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }

    static func hostDescription() -> String {
        var u = utsname()
        uname(&u)
        func field<T>(_ v: T) -> String { withUnsafeBytes(of: v) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
        return "Linux \(field(u.release)) \(field(u.machine))"
    }

    static func resolveExecutable(_ name: String) -> String? {
        if name.contains("/") { return URL(fileURLWithPath: name).standardizedFileURL.resolvingSymlinksInPath().path }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        }
        return nil
    }

    static func spawnHeld(_ argv: [String], env: [String: String], gate: inout Int32) throws -> Int32 {
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in cArgs { free(p) }
            for p in cEnv { free(p) }
        }
        let pid = cArgs.withUnsafeBufferPointer { a in
            cEnv.withUnsafeBufferPointer { e in
                ycg_spawn_held(argv[0], a.baseAddress, e.baseAddress, &gate)
            }
        }
        guard pid > 0 else { throw LinuxRecordError("could not start \(argv[0]): \(String(cString: strerror(errno)))") }
        return pid
    }

    /// The whole of a /proc file (their size reads as 0, so a plain file
    /// read can stop early).
    static func readProcFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var out = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            out += chunk[0..<n]
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func attachNewThreads(pid: Int32, periodNs: UInt64, kernel: Bool, events: inout [Int32: ycg_perf]) {
        var tids = [Int32](repeating: 0, count: 4096)
        let n = Int(ycg_threads(pid, &tids, Int32(tids.count)))
        for tid in tids.prefix(n) where events[tid] == nil {
            var p = ycg_perf()
            if ycg_perf_open(&p, tid, -1, periodNs, 0, kernel ? 1 : 0, 64) == 0 { events[tid] = p }
        }
    }

    /// Mappings (only once the launched executable is mapped: before its
    /// exec the child still has the recorder's own image) and thread names.
    static func pollProcess(pid: Int32, maps: inout Set<GaugeSymbolicator.Mapping>, names: inout [Int32: String], executable: String?) {
        if let text = readProcFile("/proc/\(pid)/maps"), executable.map({ text.contains($0) }) ?? true {
            maps.formUnion(GaugeSymbolicator.parseMaps(text))
        }
        var tids = [Int32](repeating: 0, count: 4096)
        let n = Int(ycg_threads(pid, &tids, Int32(tids.count)))
        for tid in tids.prefix(n) {
            if let comm = readProcFile("/proc/\(pid)/task/\(tid)/comm") {
                names[tid] = comm.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    #endif
}
