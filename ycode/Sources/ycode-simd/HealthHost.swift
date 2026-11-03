// The host end of Ycode's health agent channel and the `health …` commands
// of a running device (specs/simulator/health-simulation.md §8.1–§8.3,
// "Ycode implementation").
//
// The guest health agent (SimGuestAgents/health, staged by
// HealthAgentStaging.swift) connects to /private/var/run/dev.ycode.health,
// which the VMM serves (HostStreamSockets.serve). After its hello the host
// asks it to request share and read access for every writable type (the
// request writes the agent's authorization rows; Ycode answers them while
// the device is shut down, so from the next cold boot on the request
// completes at once). Commands on the control socket (`health …`, the words
// of HealthCommand) read files and generate scenarios here, validate every
// sample, and send the agent write, workout, delete and count requests.

import Foundation
import YcodeDarwinKernel
import YcodeSimFeatures
import YcodeHealthStore

final class HealthHost: HostChannelServer, @unchecked Sendable {
    let dev: String
    let isWatch: Bool
    let log: (String) -> Void
    var connectTimeout: TimeInterval = Double(ProcessInfo.processInfo.environment["YCODE_HEALTH_AGENT_WAIT_S"] ?? "") ?? 90
    var replyTimeout: TimeInterval = 180
    var timeZone = TimeZone.current

    private let lock = NSLock()
    private let connected = NSCondition()
    private var link: SettingsAgentLink?
    private var buffer: [UInt8] = []
    private var nextID = 1
    private var waiting: [Int: (semaphore: DispatchSemaphore, reply: [String: Any]?)] = [:]
    private(set) var hello: [String: Any]?
    /// The agent's authorization: nil until asked; true when its key types are authorized.
    private(set) var authorized: Bool?
    private(set) var authorizeError: String?
    /// Samples this host had the agent save in this run, per type.
    private(set) var written: [String: Int] = [:]
    private var stream: (generation: Int, description: String)?
    private var streamGeneration = 0

    init(dev: String, isWatch: Bool, log: @escaping (String) -> Void) {
        self.dev = dev
        self.isWatch = isWatch
        self.log = log
    }

    var isConnected: Bool { lock.withLock { link != nil && hello != nil } }

    // MARK: HostChannelServer

    func channelOpened(_ connection: HostChannelConnection) { opened(connection, pid: connection.pid) }
    func channel(_ connection: HostChannelConnection, received bytes: [UInt8]) { received(bytes, from: connection) }
    func channelClosed(_ connection: HostChannelConnection) { closed(connection) }

    func opened(_ l: SettingsAgentLink, pid: Int32) {
        let old = lock.withLock { () -> SettingsAgentLink? in
            let o = link
            link = l
            buffer = []
            hello = nil
            return o
        }
        if let old, old !== l { old.close() }
        log("health: the agent connected (pid \(pid))")
    }

    func closed(_ l: SettingsAgentLink) {
        let pending = lock.withLock { () -> [DispatchSemaphore] in
            guard link === l else { return [] }
            link = nil
            hello = nil
            return waiting.values.map(\.semaphore)
        }
        for s in pending { s.signal() }
        log("health: the agent's connection closed" + (pending.isEmpty ? "" : " (\(pending.count) requests unanswered)"))
    }

    func received(_ bytes: [UInt8], from l: SettingsAgentLink) {
        var messages: [[String: Any]] = []
        let bad: Bool = lock.withLock {
            guard link === l else { return false }
            buffer += bytes
            do { messages = try HealthChannel.takeFrames(&buffer) } catch { return true }
            return false
        }
        if bad {
            log("health: a malformed frame from the agent; closing")
            l.close()
            closed(l)
            return
        }
        for m in messages { handleMessage(m) }
    }

    private func handleMessage(_ m: [String: Any]) {
        if m["event"] as? String == "hello" {
            lock.withLock { hello = m }
            connected.lock()
            connected.broadcast()
            connected.unlock()
            log("health: agent pid \((m["pid"] as? NSNumber)?.intValue ?? -1), source \(m["source"] as? String ?? "?") "
                + "(\(m["bundleID"] as? String ?? "?")), health data \((m["available"] as? NSNumber)?.boolValue == true ? "available" : "unavailable")")
            DispatchQueue.global().async { [self] in _ = authorizeAgent() }
            return
        }
        guard let id = (m["id"] as? NSNumber)?.intValue else { return }
        let s: DispatchSemaphore? = lock.withLock {
            guard waiting[id] != nil else { return nil }
            waiting[id]!.reply = m
            return waiting[id]!.semaphore
        }
        s?.signal()
    }

    private func waitForAgent() -> SettingsAgentLink? {
        let deadline = Date().addingTimeInterval(connectTimeout)
        connected.lock()
        defer { connected.unlock() }
        while true {
            if let l = lock.withLock({ hello != nil ? link : nil }) { return l }
            if !connected.wait(until: deadline) { return nil }
        }
    }

    enum HealthError: Error, CustomStringConvertible {
        case noAgent, sendFailed, timedOut, connectionClosed, agent(String, saved: Int)
        var description: String {
            switch self {
            case .noAgent: "the device's health agent is not connected (see the device's data/tmp/ycode-health-agent.log)"
            case .sendFailed: "the request could not be sent to the health agent"
            case .timedOut: "the health agent did not answer in time"
            case .connectionClosed: "the health agent's connection closed"
            case .agent(let e, _): e
            }
        }
    }

    /// One request and its reply.
    func request(_ message: [String: Any], timeout: TimeInterval? = nil) -> Result<[String: Any], HealthError> {
        guard let l = waitForAgent() else { return .failure(.noAgent) }
        let s = DispatchSemaphore(value: 0)
        let id = lock.withLock { () -> Int in
            let i = nextID
            nextID += 1
            waiting[i] = (s, nil)
            return i
        }
        defer { _ = lock.withLock { waiting.removeValue(forKey: id) } }
        var m = message
        m["id"] = id
        guard let frame = HealthChannel.frame(m), l.send(frame) else { return .failure(.sendFailed) }
        guard s.wait(timeout: .now() + (timeout ?? replyTimeout)) == .success else { return .failure(.timedOut) }
        guard let reply = lock.withLock({ waiting[id]?.reply }) else { return .failure(.connectionClosed) }
        if (reply["ok"] as? NSNumber)?.boolValue ?? false { return .success(reply) }
        return .failure(.agent(reply["error"] as? String ?? "failed", saved: (reply["saved"] as? NSNumber)?.intValue ?? 0))
    }

    // MARK: Authorization

    /// The types every scenario writes; asked for alone if the full list is refused.
    static let coreTypes = [HealthScenarios.hr, HealthScenarios.restingHR, HealthScenarios.hrv, HealthScenarios.spo2,
                            HealthScenarios.respiratory, HealthScenarios.steps, HealthScenarios.distance, HealthScenarios.activeEnergy,
                            HealthScenarios.basalEnergy, HealthScenarios.flights, HealthScenarios.sleep, HealthTypes.workout,
                            HealthTypes.workoutRoute]

    /// Asks the agent to request its access: every writable type, share and read.
    @discardableResult
    func authorizeAgent() -> String {
        var types = HealthTypes.agentShareTypes
        var result = request(HealthChannel.authorize(share: types, read: types))
        if case .failure(.agent(let e, _)) = result, e.contains("Exception") {
            log("health: the full type list was refused (\(e)); asking for the core types")
            types = Self.coreTypes
            result = request(HealthChannel.authorize(share: types, read: types))
        }
        let text: String
        switch result {
        case .success(let r):
            let statuses = (r["statuses"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
            let ok = statuses[HealthScenarios.hr] == 2
            lock.withLock {
                authorized = ok
                authorizeError = nil
            }
            text = "authorized for \(statuses.values.filter { $0 == 2 }.count) of \(types.count) types"
        case .failure(let e):
            lock.withLock {
                authorized = false
                authorizeError = e.description
            }
            text = "not authorized yet (\(e)); Ycode grants its agent at the next cold boot"
        }
        log("health: agent: " + text)
        return text
    }

    // MARK: Commands

    /// `health …` words (the control socket). Answers "ok …" or "error …".
    func handle(_ words: [String]) -> String {
        let command: HealthCommand
        do { command = try HealthCommand.parse(words) } catch { return "error \(error)" }
        switch command {
        case .status: return status()
        case .authorize: return "ok " + authorizeAgent()
        case .importFile(let path, let open): return importFile(path, open: open)
        case let .scenario(name, date, days, seed, steps, start, withReadOnly):
            // Without --date: the last complete day (and the night that ended this morning), so no sample lies in the future.
            let yesterday = Date().addingTimeInterval(-86400 * Double(days))
            var o = HealthScenarioOptions(date: date.flatMap { HealthCommand.parseDay($0, timeZone: timeZone) } ?? yesterday, timeZone: timeZone)
            o.days = days
            o.seed = seed
            o.steps = steps
            o.start = start.flatMap { HealthImport.time($0, now: Date()) }
            o.withReadOnly = withReadOnly
            if name == "workout", date == nil, start == nil { o.start = Date().addingTimeInterval(-1830) }
            do {
                let out = try HealthScenarios.generate(name, o)
                return write(out.samples, workouts: out.workouts, what: "scenario \(name)",
                             note: out.seeded.isEmpty ? nil : "\(out.seeded.count) read-only samples not written (health seed scenario on a shut-down device)")
            } catch {
                return "error \(error)"
            }
        case let .stream(kind, range, every, duration): return startStream(kind, range: range, every: every, duration: duration)
        case .stop: return stopStream()
        case .clear: return clear()
        case .grant(var id), .revoke(var id):
            let verb = { if case .grant = command { return "grant" } else { return "revoke" } }()
            // A watch app's rows are its companion's (health-simulation.md §12.1).
            let watchApp = id
            if let companion = HealthWatchApps.companion(of: id, deviceData: dev + "/data") { id = companion }
            HealthDeviceFiles(dev: dev).queue(verb, id)
            return "ok \(verb) \(id) queued for the next cold boot: the device's health store belongs to healthd while it runs "
                + "(stop the device, or run it again without a warm restore)"
                + (watchApp == id ? "" : " (\(watchApp) is a watch app: its HealthKit access is recorded under its companion \(id))")
        case .seedFile, .seedScenario:
            return "error health seed needs a shut-down device (it writes the store healthd owns while the device runs)"
        }
    }

    func status() -> String {
        let (h, auth, authErr, w, s) = lock.withLock { (hello, authorized, authorizeError, written, stream) }
        var lines: [String] = []
        if let h {
            lines.append("agent: connected (pid \((h["pid"] as? NSNumber)?.intValue ?? -1), source \(h["source"] as? String ?? "?"), "
                + "\(h["bundleID"] as? String ?? "?"))")
        } else {
            lines.append("agent: not connected")
        }
        lines.append("authorization: " + (auth == nil ? "not asked yet" : auth! ? "granted" : "not granted yet" + (authErr.map { " (\($0))" } ?? "")))
        if h != nil, case .success(let r) = request(HealthChannel.count(HealthTypes.agentShareTypes), timeout: 120) {
            let counts = HealthChannel.counts(of: r)
            lines.append("samples by Ycode in the store: " + (counts.isEmpty ? "none"
                : counts.sorted { $0.key < $1.key }.map { "\(HealthTypes.all[$0.key]?.shortName ?? $0.key) \($0.value)" }.joined(separator: ", ")))
        }
        if !w.isEmpty { lines.append("written in this run: \(w.values.reduce(0, +)) samples") }
        lines.append("stream: " + (s?.description ?? "none"))
        let pending = HealthDeviceFiles(dev: dev).pending()
        if !pending.isEmpty { lines.append("queued for the next cold boot: " + pending.joined(separator: "; ")) }
        return "ok " + lines.joined(separator: "\n")
    }

    func importFile(_ path: String, open: String?) -> String {
        let file: HealthImportFile
        do { file = try HealthImport.read(path: path) } catch let f as HealthImport.Failure {
            return "error \(path): " + f.description
        } catch {
            return "error \(path): \(error)"
        }
        var note: String?
        if let d = file.device, d != (isWatch ? "watch" : "phone") {
            note = "the file is for the \(d); written on this \(isWatch ? "watch" : "phone")"
        }
        if let open {
            note = [note, "open \(open) on the paired phone to pull the samples: ycode-simd --device <phone> --control pairing agent openApp bundleID=\(open)"]
                .compactMap { $0 }.joined(separator: "; ")
        }
        return write(file.samples, workouts: file.workouts, what: (path as NSString).lastPathComponent, note: note)
    }

    /// Writes samples (and workouts) through the agent; one line of counts.
    func write(_ samples: [HealthSample], workouts: [HealthWorkout], what: String, note: String?) -> String {
        let t0 = Date()
        var saved = 0, savedWorkouts = 0, workoutSamples = 0
        var errors: [String] = []
        var perType: [String: Int] = [:]
        for req in HealthChannel.writes(samples) {
            switch request(req) {
            case .success(let r): saved += (r["saved"] as? NSNumber)?.intValue ?? 0
            case .failure(let e):
                if case .agent(_, let n) = e { saved += n }
                errors.append(e.description)
            }
        }
        if errors.isEmpty { for s in samples { perType[s.type, default: 0] += 1 } }
        for w in workouts {
            switch request(HealthChannel.workout(w)) {
            case .success(let r):
                savedWorkouts += 1
                workoutSamples += (r["saved"] as? NSNumber)?.intValue ?? 0
                for s in w.samples { perType[s.type, default: 0] += 1 }
            case .failure(let e): errors.append("workout: \(e)")
            }
        }
        lock.withLock { for (k, v) in perType { written[k, default: 0] += v } }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        var line = "\(what): wrote \(saved) of \(samples.count) samples"
            + (workouts.isEmpty ? "" : ", \(savedWorkouts) of \(workouts.count) workouts with \(workoutSamples) samples") + " in \(ms) ms"
        if !perType.isEmpty {
            line += " (" + perType.sorted { $0.key < $1.key }.map { "\(HealthTypes.all[$0.key]?.shortName ?? $0.key) \($0.value)" }.joined(separator: ", ") + ")"
        }
        if isWatch && errors.isEmpty {
            line += workouts.isEmpty
                ? "; the paired phone pulls them when one of its apps that runs HealthKit queries comes to the foreground (health-simulation.md §12.2, about 3 s), or at the next workout or boot"
                : "; the workout starts a sync to the paired phone"
        }
        if let note { line += "; " + note }
        log("health: " + line + (errors.isEmpty ? "" : "; errors: " + errors.joined(separator: "; ")))
        return errors.isEmpty ? "ok " + line : "error " + line + "; first error: " + errors[0]
    }

    func clear() -> String {
        switch request(HealthChannel.delete(HealthTypes.agentShareTypes), timeout: 600) {
        case .success(let r):
            lock.withLock { written = [:] }
            return "ok deleted \((r["deleted"] as? NSNumber)?.intValue ?? 0) samples written by Ycode's agent"
        case .failure(let e): return "error \(e)"
        }
    }

    // MARK: Streams (H-12)

    func startStream(_ kind: HealthCommand.StreamKind, range: ClosedRange<Double>, every: TimeInterval, duration: TimeInterval?) -> String {
        guard waitForAgent() != nil else { return "error \(HealthError.noAgent)" }
        let shown = kind == .spo2 ? "\(Int(range.lowerBound * 100))–\(Int(range.upperBound * 100)) %"
            : "\(Int(range.lowerBound))–\(Int(range.upperBound))" + (kind == .heartRate ? " bpm" : " per minute")
        let description = "\(kind.rawValue) \(shown) every \(Int(every)) s" + (duration.map { " for \(Int($0)) s" } ?? " until stop")
        let generation: Int = lock.withLock {
            streamGeneration += 1
            stream = (streamGeneration, description)
            return streamGeneration
        }
        let end = duration.map { Date().addingTimeInterval($0) }
        Thread.detachNewThread { [self] in
            var r = HealthRandom(seed: UInt64(Date().timeIntervalSince1970))
            var previous: Double?
            var n = 0
            while lock.withLock({ stream?.generation == generation }) {
                if let end, Date() >= end { break }
                let raw = HealthScenarios.streamValue(previous: previous, range: range, &r)
                previous = raw
                let v = kind == .spo2 ? (raw * 100).rounded() / 100 : kind == .respiratoryRate ? (raw * 2).rounded() / 2 : raw.rounded()
                var meta: [String: HealthMetadataValue] = [:]
                if kind == .heartRate { meta["HKMetadataKeyHeartRateMotionContext"] = .number(v > 100 ? 2 : 1) }
                let s = HealthSample(type: kind.type, start: Date(), value: v, unit: kind.unit, metadata: meta)
                if case .failure(let e) = request(HealthChannel.writes([s])[0], timeout: 30) {
                    log("health: stream: \(e)")
                } else {
                    n += 1
                    lock.withLock { written[kind.type, default: 0] += 1 }
                }
                Thread.sleep(forTimeInterval: every)
            }
            lock.withLock { if stream?.generation == generation { stream = nil } }
            log("health: stream \(description) ended after \(n) samples")
        }
        var line = "ok streaming " + description
        if isWatch && kind == .heartRate {
            line += "; an app's live workout builder collects only the watch's own samples unless it widens its data source (health-simulation.md §4.3)"
        }
        return line
    }

    func stopStream() -> String {
        let s = lock.withLock { () -> String? in
            let d = stream?.description
            stream = nil
            return d
        }
        return s.map { "ok stopped the stream (\($0))" } ?? "ok no stream was running"
    }
}
