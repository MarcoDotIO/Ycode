// The device's settings features (specs/simulator/simulator-features.md,
// "Ycode implementation"): the host end of Ycode's settings channel, the
// control-socket commands, and the device files the host writes itself.
//
// Mechanism: Ycode's guest settings agent (SimGuestAgents/settings, a
// launchd daemon of the device whose plist ycode-simd writes at every cold
// boot) connects to the guest path /private/var/run/dev.ycode.settings,
// which the VMM serves (HostStreamSockets.serve). SimSettingsController
// sends it the plans of YcodeSimFeatures (preference writes through
// cfprefsd, setter notifications, location requests) and reads settings
// back. Audio settings are host files (written here) plus a notification
// the agent posts; Environment Overrides are a per-app file plus a
// notification. With no device running, `ycode-simd --device DEV --ui …`
// writes the persistent settings into the device's preference files for
// its next boot and queues them for the agent (DeviceSettingsFiles).

import Foundation
import YcodeDarwinABI
import YcodeDarwinKernel
import YcodeSimFeatures

// MARK: - The device's files

/// The settings files of a device directory.
struct DeviceSettingsFiles {
    let dev: String
    /// DEV/data as the guest sees it.
    let guestData: String

    init(dev: String, guestData: String? = nil) {
        self.dev = dev
        self.guestData = guestData ?? dev + "/data"
    }

    var data: String { dev + "/data" }
    func preferencesPath(_ domain: String) -> String { data + "/Library/Preferences/\(domain).plist" }
    var audioHostPath: String { data + "/var/run/com.apple.coresimulator.audio.plist" }
    var audioSettingsPath: String { data + "/var/run/simulatoraudio/audiosettings.plist" }
    var overridesDirectory: String { data + "/Library/Ycode/EnvironmentOverrides" }
    var overridesGuestDirectory: String { guestData + "/Library/Ycode/EnvironmentOverrides" }
    var scenarioPath: String { data + "/tmp/ycode-location-scenario.plist" }
    var scenarioGuestPath: String { guestData + "/tmp/ycode-location-scenario.plist" }
    /// Commands written while the device was stopped, for the agent to apply.
    var pendingPath: String { dev + "/ycode-pending-settings.txt" }

    static func readPlist(_ path: String) -> [String: Any]? {
        FileManager.default.contents(atPath: path).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        }
    }

    /// The guest path of a host path in DEV/data (nil: not in the guest's data tree).
    func guestPath(_ hostPath: String) -> String? {
        guard hostPath.hasPrefix(data + "/") else { return nil }
        return guestData + hostPath.dropFirst(data.count)
    }

    /// Written to a temporary file and renamed (audio-host.md §12), through
    /// the host-write hook (`HostDataWrites`): a running guest's kqueue
    /// vnode watches fire and its file-event service sees the change
    /// (`threads-and-events.md` §3.10).
    func writePlist(_ plist: [String: Any], to path: String, format: PropertyListSerialization.PropertyListFormat = .xml) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        try HostDataWrites.replace(hostPath: path, guestPath: guestPath(path) ?? path, data: [UInt8](data))
    }

    /// Removes a file of the data tree through the host-write hook.
    func remove(_ path: String) {
        HostDataWrites.remove(hostPath: path, guestPath: guestPath(path) ?? path)
    }

    // Preferences (only while the device is stopped: cfprefsd owns them while it runs).

    func read(_ r: PreferenceRead) -> PrefValue? {
        Self.readPlist(preferencesPath(r.domain))?[r.key].flatMap(PrefValue.init(plistObject:))
    }

    func readAll(_ reads: [PreferenceRead]) -> [String: PrefValue] {
        var out: [String: PrefValue] = [:]
        for r in reads { if let v = read(r) { out[r.tag] = v } }
        return out
    }

    /// Writes a plan's keys into the preference files (binary, as cfprefsd keeps them).
    func writeOffline(_ writes: [PreferenceWrite]) throws {
        var byDomain: [String: [PreferenceWrite]] = [:]
        for w in writes { byDomain[w.domain, default: []].append(w) }
        for (domain, list) in byDomain {
            let path = preferencesPath(domain)
            var plist = Self.readPlist(path) ?? [:]
            for w in list { plist[w.key] = w.value?.plistObject }
            try writePlist(plist, to: path, format: .binary)
        }
    }

    // Audio (§4.11–4.13).

    func audio() -> SimAudioSettings {
        SimAudio.settings(hostFile: Self.readPlist(audioHostPath), settingsFile: Self.readPlist(audioSettingsPath))
    }

    func writeAudio(_ s: SimAudioSettings) throws {
        try writePlist(SimAudio.hostFile(s), to: audioHostPath)
        try writePlist(SimAudio.settingsFile(s), to: audioSettingsPath)
    }

    // Environment overrides.

    func overridesPath(_ bundleID: String) -> String { overridesDirectory + "/\(bundleID).plist" }

    func overrides(_ bundleID: String) -> EnvironmentOverrides {
        EnvironmentOverrides(plist: Self.readPlist(overridesPath(bundleID)) ?? [:])
    }

    func writeOverrides(_ o: EnvironmentOverrides, for bundleID: String) throws {
        if o.isEmpty {
            remove(overridesPath(bundleID))
        } else {
            try writePlist(o.plist, to: overridesPath(bundleID))
        }
    }

    // The pending queue.

    func appendPending(_ line: String) throws {
        let old = (try? String(contentsOfFile: pendingPath, encoding: .utf8)) ?? ""
        try (old + line + "\n").write(toFile: pendingPath, atomically: true, encoding: .utf8)
    }

    func takePending() -> [String] {
        guard let text = try? String(contentsOfFile: pendingPath, encoding: .utf8) else { return [] }
        try? FileManager.default.removeItem(atPath: pendingPath)
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// Cold boot (§5): colour filters do not persist. The guest empties its
    /// media-accessibility domain itself; **Ycode decision**: the host also
    /// turns the grayscale key of the accessibility domain off, which would
    /// otherwise outlive the filter.
    func resetNonPersistentAtColdBoot() {
        let path = preferencesPath(SimPrefs.accessibility)
        guard var plist = Self.readPlist(path), (plist[SimPrefs.grayscale] as? NSNumber)?.intValue == 1 else { return }
        plist[SimPrefs.grayscale] = 0
        try? writePlist(plist, to: path, format: .binary)
    }

    /// The runtime's scenario names (file names in its scenario directory).
    static func scenarios(runtimeRoot: String) -> [String] {
        let dir = runtimeRoot + SimLocation.scenarioDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(6)) }.sorted {
            let a = SimLocation.builtInScenarios.firstIndex(of: $0) ?? 99, b = SimLocation.builtInScenarios.firstIndex(of: $1) ?? 99
            return a != b ? a < b : $0 < $1
        }
    }
}

// MARK: - The channel's host end

/// The agent's end of the channel (HostChannelConnection in a run, a stand-in in tests).
protocol SettingsAgentLink: AnyObject {
    @discardableResult func send(_ bytes: [UInt8]) -> Bool
    func close()
}

extension HostChannelConnection: SettingsAgentLink {}

final class SimSettingsController: HostChannelServer, @unchecked Sendable {
    let files: DeviceSettingsFiles
    let runtimeRoot: String
    let log: (String) -> Void
    /// Applies an audio change to the host audio service (volume, mute).
    var onAudio: ((SimAudioSettings) -> Void)?
    /// How long a command waits for the agent to connect (after a boot) and to answer.
    var connectTimeout: TimeInterval = Double(ProcessInfo.processInfo.environment["YCODE_SETTINGS_AGENT_WAIT_S"] ?? "") ?? 60
    var replyTimeout: TimeInterval = 15

    private let lock = NSLock()
    private let connected = NSCondition()
    private var link: SettingsAgentLink?
    private var buffer: [UInt8] = []
    private var nextID = 1
    private var waiting: [Int: (semaphore: DispatchSemaphore, reply: [String: Any]?)] = [:]
    /// The agent's pid (hello).
    private(set) var agentPID: Int?
    /// Guest notifications the agent reported (the watched names of §7.1).
    private(set) var events: [String] = []
    private(set) var changeCount = 0
    /// `YCODE_DEBUG_SETTINGS=1`: logs every guest notification the agent reports.
    static let debug = ProcessInfo.processInfo.environment["YCODE_DEBUG_SETTINGS"] == "1"

    init(files: DeviceSettingsFiles, runtimeRoot: String, log: @escaping (String) -> Void) {
        self.files = files
        self.runtimeRoot = runtimeRoot
        self.log = log
    }

    var isConnected: Bool { lock.withLock { link != nil } }

    // HostChannelServer

    func channelOpened(_ connection: HostChannelConnection) { opened(connection, pid: connection.pid) }
    func channel(_ connection: HostChannelConnection, received bytes: [UInt8]) { received(bytes, from: connection) }
    func channelClosed(_ connection: HostChannelConnection) { closed(connection) }

    func opened(_ l: SettingsAgentLink, pid: Int32) {
        let old = lock.withLock { () -> SettingsAgentLink? in
            let o = link
            link = l
            buffer = []
            return o
        }
        // One agent: a newer connection replaces an older one.
        if let old, old !== l { old.close() }
        log("settings: the agent connected (pid \(pid))")
    }

    func closed(_ l: SettingsAgentLink) {
        let pending = lock.withLock { () -> [DispatchSemaphore] in
            guard link === l else { return [] }
            link = nil
            agentPID = nil
            let s = waiting.values.map(\.semaphore)
            return s
        }
        for s in pending { s.signal() }
        log("settings: the agent's connection closed" + (pending.isEmpty ? "" : " (\(pending.count) requests unanswered)"))
    }

    func received(_ bytes: [UInt8], from l: SettingsAgentLink) {
        var messages: [[String: Any]] = []
        let bad: Bool = lock.withLock {
            guard link === l else { return false }
            buffer += bytes
            do { messages = try SettingsChannel.takeFrames(&buffer) } catch { return true }
            return false
        }
        if bad {
            log("settings: a malformed frame from the agent; closing")
            l.close()
            closed(l)
            return
        }
        for m in messages { handleMessage(m) }
    }

    private func handleMessage(_ m: [String: Any]) {
        if let event = m["event"] as? String {
            switch event {
            case "hello":
                let pid = (m["pid"] as? NSNumber)?.intValue
                lock.withLock { agentPID = pid }
                connected.lock()
                connected.broadcast()
                connected.unlock()
                log("settings: agent pid \(pid ?? -1), protocol \((m["version"] as? NSNumber)?.intValue ?? 0)")
                DispatchQueue.global().async { [self] in agentReady() }
            case "notification":
                let name = m["name"] as? String ?? "?"
                if Self.debug { log("settings: guest notification \(name)") }
                lock.withLock {
                    events.append(name)
                    if events.count > 50 { events.removeFirst(events.count - 50) }
                    changeCount += 1
                }
            default: break
            }
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

    /// After the hello: watch the guest's notifications, then apply what was
    /// queued while the device was stopped.
    private func agentReady() {
        _ = request(SettingsChannel.watch(SimNotifications.watched))
        if case .success(let state) = readState(), let plan = SimFeatureMapping.bootPlan(state) {
            let what = plan.startServices.isEmpty ? "removed a left-over VoiceOver running key"
                : "started \(plan.startServices.joined(separator: ", "))"
            log("settings: boot: \(request(SettingsChannel.apply(plan)).map { _ in what })")
        }
        for line in files.takePending() {
            let reply = handle(line.split(separator: " ").map(String.init), pending: true)
            log("settings: queued '\(line)': \(reply)")
        }
    }

    /// Waits for an agent that has said hello.
    private func waitForAgent() -> SettingsAgentLink? {
        let deadline = Date().addingTimeInterval(connectTimeout)
        connected.lock()
        defer { connected.unlock() }
        while true {
            if let l = lock.withLock({ agentPID != nil ? link : nil }) { return l }
            if !connected.wait(until: deadline) { return nil }
        }
    }

    /// One request and its reply (or an error text).
    func request(_ message: [String: Any], timeout: TimeInterval? = nil) -> Result<[String: Any], SettingsError> {
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
        guard let frame = SettingsChannel.frame(m), l.send(frame) else { return .failure(.sendFailed) }
        guard s.wait(timeout: .now() + (timeout ?? replyTimeout)) == .success else { return .failure(.timedOut) }
        guard let reply = lock.withLock({ waiting[id]?.reply }) else { return .failure(.connectionClosed) }
        if (reply["ok"] as? NSNumber)?.boolValue ?? (reply["ok"] as? Bool) ?? false { return .success(reply) }
        return .failure(.agent(reply["error"] as? String ?? "failed"))
    }

    enum SettingsError: Error, CustomStringConvertible {
        case noAgent, sendFailed, timedOut, connectionClosed
        case agent(String)
        case other(String)
        var description: String {
            switch self {
            case .noAgent: "the device's settings agent is not connected (is it installed? see the device's data/tmp/ycode-settings-agent.log)"
            case .sendFailed: "the settings agent's connection failed"
            case .timedOut: "the settings agent did not answer in time"
            case .connectionClosed: "the settings agent's connection closed"
            case .agent(let s): s
            case .other(let s): s
            }
        }
    }

    // MARK: Commands

    func readState() -> Result<SimSettingsState, SettingsError> {
        request(SettingsChannel.read(SimFeatureMapping.stateReads)).map { SimSettingsState(values: SettingsChannel.values(of: $0)) }
    }

    func apply(_ setting: SimSetting) -> Result<[String: Any], SettingsError> {
        let plan = SimFeatureMapping.plan(for: setting)
        let started = Date()
        let r = request(SettingsChannel.apply(plan), timeout: plan.waitForVoiceOver != nil ? 20 : nil)
        log("settings: \(setting) -> \(r.map { _ in "ok" }) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return r
    }

    /// A control-socket command → its answer ("ok …" or "error: …").
    func handle(_ words: [String], pending: Bool = false) -> String {
        // Diagnostics: `settings write <domain> <key> int:N|real:X|bool:B|string:S|remove`,
        // `settings notify <name>…`, `settings events` (the last guest notifications).
        if words.count >= 2, words[0] == "settings", let d = debugCommand(Array(words.dropFirst())) { return d }
        let command: SimSettingsCommand
        do { command = try SimSettingsCommand.parse(words) } catch { return "error: \(error)" }
        func answer(_ r: Result<String, SettingsError>) -> String {
            switch r {
            case .success(let s): s.isEmpty ? "ok" : "ok " + s
            case .failure(let e): "error: \(e)"
            }
        }
        func state(_ body: (SimSettingsState) -> String) -> String { answer(readState().map(body)) }
        switch command {
        case .set(let s):
            return answer(apply(s).map { reply in
                if case .accessibility(.voiceOver, let on) = s {
                    let running = (reply["voiceOverRunning"] as? NSNumber)?.boolValue ?? false
                    return "voiceover \(on ? "on" : "off") (VoiceOver \(running ? "running" : "not running"))"
                }
                return ""
            })
        case .getAppearance: return state { $0.appearance.rawValue }
        case .toggleAppearance:
            return answer(readState().flatMap { st in
                let next: Appearance = st.appearance == .dark ? .light : .dark
                return apply(.appearance(next)).map { _ in next.rawValue }
            })
        case .getContentSize: return state { $0.contentSize.rawValue }
        case .stepContentSize(let d):
            return answer(readState().flatMap { st in
                let next = st.contentSize.stepped(by: d)
                return apply(.contentSize(next)).map { _ in next.rawValue }
            })
        case .getIncreaseContrast: return state { $0.isOn(.increaseContrast) ? "enabled" : "disabled" }
        case .getSwitch(let s):
            return state { s == .voiceOver ? "\($0.isOn(s) ? "on" : "off") (VoiceOver \($0.voiceOverRunning ? "running" : "not running"))" : ($0.isOn(s) ? "on" : "off") }
        case .state:
            return answer(readState().map { st in
                let a = files.audio()
                return (st.lines + ["volume \(a.volume)", "output \(a.output.argument)", "input \(a.input.argument)",
                                    "agent pid \(agentPID.map(String.init) ?? "-")", "changes \(changeCount)"]).joined(separator: "\n")
            })
        case .location(let c): return answer(runLocation(c))
        case .locationFile(let path):
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "error: cannot read \(path)" }
            do { return answer(runLocation(try SimLocation.parseFile(text))) } catch { return "error: \(path): \(error)" }
        case .locationList:
            return "ok " + DeviceSettingsFiles.scenarios(runtimeRoot: runtimeRoot).joined(separator: "\n")
        case .volume, .stepVolume, .output, .input, .getVolume, .getOutput, .getInput, .audioDevices:
            return answer(audio(command))
        case .overrides(let id, let req): return answer(overrides(id, req))
        }
    }

    private func debugCommand(_ w: [String]) -> String? {
        switch w[0] {
        case "events":
            return "ok " + lock.withLock { events.suffix(30).joined(separator: "\n") }
        case "notify":
            guard w.count >= 2 else { return "error: settings notify <name>…" }
            switch request(SettingsChannel.notify(Array(w.dropFirst()))) {
            case .success: return "ok"
            case .failure(let e): return "error: \(e)"
            }
        case "write":
            guard w.count == 4 else { return "error: settings write <domain> <key> int:N|real:X|bool:B|string:S|remove" }
            let parts = w[3].split(separator: ":", maxSplits: 1).map(String.init)
            let value: PrefValue?
            switch parts[0] {
            case "int": value = parts.count == 2 ? Int(parts[1]).map(PrefValue.int) : nil
            case "real": value = parts.count == 2 ? Double(parts[1]).map(PrefValue.real) : nil
            case "bool": value = parts.count == 2 ? .bool(parts[1] == "true" || parts[1] == "1") : nil
            case "string": value = parts.count == 2 ? .string(parts[1]) : nil
            case "remove": value = nil
            default: return "error: settings write: int:N|real:X|bool:B|string:S|remove"
            }
            if value == nil && parts[0] != "remove" { return "error: settings write: bad value \(w[3])" }
            switch request(SettingsChannel.apply(SettingsPlan(writes: [PreferenceWrite(w[1], w[2], value)]))) {
            case .success: return "ok"
            case .failure(let e): return "error: \(e)"
            }
        case "notify-state":
            guard w.count == 3, let v = UInt64(w[2]) else { return "error: settings notify-state <name> <uint64>" }
            var m = SettingsChannel.notify([w[1]])
            m["states"] = [w[1]: v]
            switch request(m) {
            case .success: return "ok"
            case .failure(let e): return "error: \(e)"
            }
        case "read":
            guard w.count == 3 else { return "error: settings read <domain> <key>" }
            let r = PreferenceRead(w[1], w[2])
            switch request(SettingsChannel.read([r])) {
            case .success(let reply): return "ok " + (SettingsChannel.values(of: reply)[r.tag]?.description ?? "(absent)")
            case .failure(let e): return "error: \(e)"
            }
        default: return nil
        }
    }

    private func runLocation(_ c: LocationCommand) -> Result<String, SettingsError> {
        if case .scenario(let name) = c, !name.hasPrefix("/") {
            let names = DeviceSettingsFiles.scenarios(runtimeRoot: runtimeRoot)
            guard names.contains(name) else {
                return .failure(.other("no scenario '\(name)' in the runtime (\(names.joined(separator: ", ")))"))
            }
        }
        let steps = SimLocation.steps(for: c, ycodeScenarioPath: files.scenarioGuestPath)
        return request(SettingsChannel.location(steps)).map { _ in
            switch c {
            case .set(let p): "location \(p)"
            case .route(let w, let speed, let spacing):
                "Parsed \(w.count) waypoints; speed \(speed) m/s, " + {
                    switch spacing {
                    case .interval(let s): "every \(s) s"
                    case .distance(let m): "every \(m) m"
                    }
                }()
            case .scenario(let n): "scenario \(n)"
            case .points(let p, _): "Parsed \(p.count) waypoints (a recorded track)"
            case .clear: "cleared"
            }
        }
    }

    /// Audio: the host files, the audio service, then the agent's notification.
    func audio(_ command: SimSettingsCommand) -> Result<String, SettingsError> {
        var s = files.audio()
        var notification: String?
        switch command {
        case .getVolume: return .success(String(s.volume))
        case .getOutput: return .success(s.output.argument)
        case .getInput: return .success(s.input.argument)
        case .audioDevices:
            return .success((["output none", "output system"] + SimAudio.outputDevices.map { "output \($0.uid) \($0.name)" }
                + ["input none", "input system"] + SimAudio.inputDevices.map { "input \($0.uid) \($0.name)" }).joined(separator: "\n"))
        case .volume(let v): s.volume = v; notification = SimNotifications.volume
        case .stepVolume(let d): s.volume = min(100, max(0, s.volume + d)); notification = SimNotifications.volume
        case .output(let c): s.output = c; notification = SimNotifications.audioDevices
        case .input(let c): s.input = c; notification = SimNotifications.audioDevices
        default: return .failure(.other("not an audio command"))
        }
        do { try files.writeAudio(s) } catch { return .failure(.other("cannot write the audio settings: \(error)")) }
        onAudio?(s)
        let summary = "volume \(s.volume), output \(s.output.argument), input \(s.input.argument)"
        // The files hold the setting even when no agent runs; the notification needs one.
        guard let n = notification else { return .success(summary) }
        return request(SettingsChannel.notify([n])).map { _ in summary }
    }

    private func overrides(_ id: String, _ req: EnvironmentOverrides.Request) -> Result<String, SettingsError> {
        var o = files.overrides(id)
        o.apply(req)
        if req != .show {
            do { try files.writeOverrides(o, for: id) } catch { return .failure(.other("cannot write the overrides: \(error)")) }
            if case .failure(let e) = request(SettingsChannel.notify([EnvironmentOverrides.changedNotification])) {
                return .failure(e)
            }
        }
        return .success(o.isEmpty ? "\(id): no overrides" : "\(id): " + o.words.joined(separator: " "))
    }
}

// MARK: - A stopped device (`ycode-simd --device DEV --ui …` with no run)

enum OfflineSettings {
    /// The answer for a command when the device is not running: persistent
    /// settings go into its files (and the queue), getters read the files.
    static func handle(_ words: [String], dev: String, runtimeRoot: String?) -> String {
        let files = DeviceSettingsFiles(dev: dev)
        let command: SimSettingsCommand
        do { command = try SimSettingsCommand.parse(words) } catch { return "error: \(error)" }
        guard command.worksOffline else {
            return "error: the device is not running (location and colour filters apply to a running device only; they do not persist)"
        }
        let note = " (the device is not running; written for its next boot)"
        let state = SimSettingsState(values: files.readAll(SimFeatureMapping.stateReads))
        func write(_ s: SimSetting, _ line: String) -> String {
            do {
                try files.writeOffline(SimFeatureMapping.plan(for: s).writes)
                try files.appendPending(line)
            } catch { return "error: \(error)" }
            return "ok" + note
        }
        switch command {
        case .set(let s): return write(s, words.joined(separator: " "))
        case .toggleAppearance:
            let next: Appearance = state.appearance == .dark ? .light : .dark
            return write(.appearance(next), "ui appearance \(next.rawValue)")
        case .stepContentSize(let d):
            let next = state.contentSize.stepped(by: d)
            return write(.contentSize(next), "ui content_size \(next.rawValue)")
        case .getAppearance: return "ok " + state.appearance.rawValue
        case .getContentSize: return "ok " + state.contentSize.rawValue
        case .getIncreaseContrast: return "ok " + (state.isOn(.increaseContrast) ? "enabled" : "disabled")
        case .getSwitch(let s): return "ok " + (state.isOn(s) ? "on" : "off")
        case .state:
            let a = files.audio()
            return "ok " + (state.lines + ["volume \(a.volume)", "output \(a.output.argument)", "input \(a.input.argument)",
                                           "agent not running"]).joined(separator: "\n")
        case .locationList:
            return "ok " + (runtimeRoot.map { DeviceSettingsFiles.scenarios(runtimeRoot: $0) } ?? SimLocation.builtInScenarios).joined(separator: "\n")
        case .overrides(let id, let req):
            var o = files.overrides(id)
            o.apply(req)
            if req != .show { do { try files.writeOverrides(o, for: id) } catch { return "error: \(error)" } }
            return "ok " + (o.isEmpty ? "\(id): no overrides" : "\(id): " + o.words.joined(separator: " "))
        case .volume, .stepVolume, .output, .input, .getVolume, .getOutput, .getInput, .audioDevices:
            // The files are the setting; the controller's audio path without an agent.
            let c = SimSettingsController(files: files, runtimeRoot: runtimeRoot ?? "/", log: { _ in })
            c.connectTimeout = 0
            switch c.audio(command) {
            case .success(let s): return "ok " + s
            case .failure(.noAgent):
                let a = files.audio()
                return "ok volume \(a.volume), output \(a.output.argument), input \(a.input.argument)" + note
            case .failure(let e): return "error: \(e)"
            }
        case .location, .locationFile: return "error: unreachable"
        }
    }
}
