import Foundation
import Testing
import YcodeSimFeatures
@testable import ycode_simd

/// FEAT (simulator-features.md "Ycode implementation"): the host end of the
/// settings channel against a stand-in agent, the control commands, the
/// device files (offline writes, the queue, audio, overrides), and the
/// agent's launchd job.
@Suite(.serialized) struct SimSettingsTests {
    /// A stand-in agent: keeps preferences in memory, records requests, answers.
    final class FakeAgent: SettingsAgentLink, @unchecked Sendable {
        weak var controller: SimSettingsController?
        let lock = NSLock()
        var prefs: [String: Any] = [:]
        var requests: [[String: Any]] = []
        var posted: [String] = []
        var closed = false
        var silent = false

        func send(_ bytes: [UInt8]) -> Bool {
            var b = bytes
            guard let frames = try? SettingsChannel.takeFrames(&b) else { return false }
            for m in frames {
                lock.withLock { requests.append(m) }
                if silent { continue }
                var reply: [String: Any] = ["id": m["id"]!, "ok": true]
                switch m["op"] as? String {
                case "apply":
                    lock.withLock {
                        for w in m["writes"] as? [[String: Any]] ?? [] {
                            prefs["\(w["domain"]!)|\(w["key"]!)"] = w["value"]
                        }
                        posted += m["notify"] as? [String] ?? []
                    }
                    if m["waitVoiceOver"] != nil { reply["voiceOverRunning"] = m["waitVoiceOver"] }
                case "read":
                    var values: [String: Any] = [:]
                    lock.withLock {
                        for r in m["reads"] as? [[String: Any]] ?? [] {
                            let tag = "\(r["domain"]!)|\(r["key"]!)"
                            if let v = prefs[tag] { values[tag] = v }
                        }
                    }
                    reply["values"] = values
                case "notify": lock.withLock { posted += m["notify"] as? [String] ?? [] }
                case "location":
                    let calls = (m["steps"] as? [[String: Any]] ?? []).compactMap { $0["call"] as? String }
                    if calls.contains("scenario"), let s = (m["steps"] as? [[String: Any]])?.first(where: { $0["call"] as? String == "scenario" }),
                       (s["path"] as? String)?.contains("Missing") == true {
                        reply = ["id": m["id"]!, "ok": false, "error": "no scenario file"]
                    }
                default: break
                }
                let frame = SettingsChannel.frame(reply)!
                DispatchQueue.global().async { [weak self] in
                    guard let self else { return }
                    self.controller?.received(frame, from: self)
                }
            }
            return true
        }

        func close() { closed = true }
    }

    func makeDevice() throws -> String {
        let dev = NSTemporaryDirectory() + "ycode-settings-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dev + "/data/Library/Preferences", withIntermediateDirectories: true)
        return dev
    }

    func connect(_ c: SimSettingsController, _ a: FakeAgent) {
        a.controller = c
        c.opened(a, pid: 42)
        c.received(SettingsChannel.frame(["event": "hello", "pid": 42, "version": 1])!, from: a)
    }

    @Test func commandsGoThroughTheAgent() throws {
        let dev = try makeDevice()
        defer { try? FileManager.default.removeItem(atPath: dev) }
        let c = SimSettingsController(files: DeviceSettingsFiles(dev: dev), runtimeRoot: dev, log: { _ in })
        c.replyTimeout = 5
        let a = FakeAgent()
        connect(c, a)
        #expect(c.handle(["ui", "appearance"]) == "ok light")
        #expect(c.handle(["ui", "appearance", "dark"]) == "ok")
        #expect(c.handle(["ui", "appearance"]) == "ok dark")
        #expect(c.handle(["ui", "appearance", "toggle"]) == "ok light")
        #expect(c.handle(["ui", "content_size", "increment"]) == "ok extra-large")
        #expect(c.handle(["ui", "content_size"]) == "ok extra-large")
        #expect(c.handle(["ui", "increase_contrast", "enabled"]) == "ok")
        #expect(c.handle(["ui", "increase_contrast"]) == "ok enabled")
        #expect(c.handle(["accessibility", "voiceover", "on"]) == "ok voiceover on (VoiceOver running)")
        #expect(c.handle(["ui", "color-filter", "protanopia", "0.5"]) == "ok")
        #expect(a.posted.contains("com.apple.accessibility.red-color-filter"))
        #expect(c.handle(["location", "set", "48.85,2.35"]) == "ok location 48.85,2.35")
        #expect(c.handle(["location", "start", "1,2", "3,4"]).hasPrefix("ok Parsed 2 waypoints"))
        let loc = a.requests.last { $0["op"] as? String == "location" }!
        #expect((loc["steps"] as? [[String: Any]])?.map { $0["call"] as! String } == ["stop", "clear", "interval", "speed", "append", "append", "start"])
        #expect(c.handle(["location", "run", "Missing Run"]).hasPrefix("error: no scenario 'Missing Run'"))
        let state = c.handle(["settings"])
        #expect(state.hasPrefix("ok appearance light\n") && state.contains("increase-contrast on") && state.contains("color-filter protanopia 0.50"))
        #expect(c.handle(["ui", "appearance", "blue"]).hasPrefix("error: ui appearance"))
    }

    @Test func noAgentAndTimeouts() throws {
        let dev = try makeDevice()
        defer { try? FileManager.default.removeItem(atPath: dev) }
        let c = SimSettingsController(files: DeviceSettingsFiles(dev: dev), runtimeRoot: dev, log: { _ in })
        c.connectTimeout = 0.1
        #expect(c.handle(["ui", "appearance", "dark"]).hasPrefix("error: the device's settings agent is not connected"))
        let a = FakeAgent()
        a.silent = true
        c.replyTimeout = 0.2
        connect(c, a)
        #expect(c.handle(["ui", "appearance", "dark"]) == "error: the settings agent did not answer in time")
        // A closed connection fails the waiting request at once.
        c.replyTimeout = 30
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { c.closed(a) }
        let t0 = Date()
        #expect(c.handle(["ui", "appearance", "dark"]) == "error: the settings agent's connection closed")
        #expect(Date().timeIntervalSince(t0) < 5)
        // A newer connection replaces the older one.
        let b = FakeAgent(), d = FakeAgent()
        connect(c, b)
        connect(c, d)
        #expect(b.closed && !d.closed)
    }

    @Test func audioWritesTheFilesAndNotifies() throws {
        let dev = try makeDevice()
        defer { try? FileManager.default.removeItem(atPath: dev) }
        let files = DeviceSettingsFiles(dev: dev)
        let c = SimSettingsController(files: files, runtimeRoot: dev, log: { _ in })
        var applied: SimAudioSettings?
        c.onAudio = { applied = $0 }
        let a = FakeAgent()
        connect(c, a)
        #expect(c.handle(["audio", "volume", "30"]) == "ok volume 30, output system, input system")
        #expect(DeviceSettingsFiles.readPlist(files.audioSettingsPath)?["sim_volume"] as? Int == 30)
        #expect(a.posted.last == "com.apple.springboard.volumestate")
        #expect(c.handle(["audio", "output", "none"]) == "ok volume 30, output none, input system")
        #expect(a.posted.last == "com.apple.CoreSimulator.audio.devices_changed")
        #expect(applied == SimAudioSettings(volume: 30, output: .none, input: .system))
        #expect(DeviceSettingsFiles.readPlist(files.audioHostPath)?["useHostDefaultOutputDevice"] as? Bool == false)
        #expect(c.handle(["audio", "volume", "down"]) == "ok volume 20, output none, input system")
        #expect(c.handle(["audio", "volume"]) == "ok 20")
        #expect(c.handle(["audio", "devices"]).contains("output dev.ycode.simulator.audio.output Ycode Simulator Output"))
    }

    @Test func environmentOverridesFile() throws {
        let dev = try makeDevice()
        defer { try? FileManager.default.removeItem(atPath: dev) }
        let files = DeviceSettingsFiles(dev: dev, guestData: "/g/data")
        let c = SimSettingsController(files: files, runtimeRoot: dev, log: { _ in })
        let a = FakeAgent()
        connect(c, a)
        #expect(c.handle(["overrides", "com.x", "appearance=dark", "reduce-motion=on"]) == "ok com.x: appearance=dark reduce-motion=on")
        #expect(a.posted.last == "dev.ycode.environment-overrides.changed")
        #expect(DeviceSettingsFiles.readPlist(files.overridesPath("com.x"))?["reduce-motion"] as? Bool == true)
        #expect(c.handle(["overrides", "com.x"]) == "ok com.x: appearance=dark reduce-motion=on")
        #expect(c.handle(["overrides", "com.x", "clear"]) == "ok com.x: no overrides")
        #expect(!FileManager.default.fileExists(atPath: files.overridesPath("com.x")))
        #expect(files.overridesGuestDirectory == "/g/data/Library/Ycode/EnvironmentOverrides")
    }

    @Test func offlineWritesAndTheQueue() throws {
        let dev = try makeDevice()
        defer { try? FileManager.default.removeItem(atPath: dev) }
        #expect(OfflineSettings.handle(["ui", "appearance", "dark"], dev: dev, runtimeRoot: nil).hasPrefix("ok (the device is not running"))
        #expect(OfflineSettings.handle(["ui", "appearance"], dev: dev, runtimeRoot: nil) == "ok dark")
        #expect(OfflineSettings.handle(["accessibility", "reduce-motion", "on"], dev: dev, runtimeRoot: nil).hasPrefix("ok"))
        #expect(OfflineSettings.handle(["ui", "content_size", "decrement"], dev: dev, runtimeRoot: nil).hasPrefix("ok"))
        #expect(OfflineSettings.handle(["ui", "content_size"], dev: dev, runtimeRoot: nil) == "ok medium")
        #expect(OfflineSettings.handle(["location", "clear"], dev: dev, runtimeRoot: nil).hasPrefix("error: the device is not running"))
        #expect(OfflineSettings.handle(["audio", "volume", "45"], dev: dev, runtimeRoot: nil).hasPrefix("ok volume 45"))
        let files = DeviceSettingsFiles(dev: dev)
        #expect(files.read(PreferenceRead(SimPrefs.accessibility, SimPrefs.reduceMotion)) == .int(1))
        #expect(files.read(PreferenceRead(SimPrefs.styleDomain, SimPrefs.styleKey)) == .int(2))
        // The files are binary property lists, as cfprefsd writes them.
        let raw = FileManager.default.contents(atPath: files.preferencesPath(SimPrefs.styleDomain))!
        #expect(raw.starts(with: Array("bplist00".utf8)))
        // The queue goes to the agent when it connects, once.
        let c = SimSettingsController(files: files, runtimeRoot: dev, log: { _ in })
        let a = FakeAgent()
        connect(c, a)
        let until = Date().addingTimeInterval(5)
        while Date() < until, a.lock.withLock({ a.requests.filter { $0["op"] as? String == "apply" }.count }) < 3 { usleep(20_000) }
        #expect(a.lock.withLock { a.requests.first?["op"] as? String } == "watch")
        #expect(a.lock.withLock { a.requests.filter { $0["op"] as? String == "apply" }.count } == 3)
        #expect(files.takePending().isEmpty)
    }

    @Test func coldBootResetsGrayscaleAndKeepsAudio() throws {
        let dev = try makeDevice()
        defer { try? FileManager.default.removeItem(atPath: dev) }
        let files = DeviceSettingsFiles(dev: dev)
        try files.writeOffline(SimFeatureMapping.plan(for: .colorFilter(.grayscale, intensity: nil)).writes)
        try files.writeOffline([PreferenceWrite(SimPrefs.accessibility, SimPrefs.reduceMotion, .int(1))])
        files.resetNonPersistentAtColdBoot()
        #expect(files.read(PreferenceRead(SimPrefs.accessibility, SimPrefs.grayscale)) == .int(0))
        #expect(files.read(PreferenceRead(SimPrefs.accessibility, SimPrefs.reduceMotion)) == .int(1))
        try files.writeAudio(SimAudioSettings(volume: 25, output: .none, input: .system))
        #expect(files.audio() == SimAudioSettings(volume: 25, output: .none, input: .system))
    }

    @Test func agentJob() {
        var layout = DeviceLayout(dev: "/d/dev", runtimeRoot: "/rr", udid: nil, jobPaths: [], runtimePaths: false, oneshots: [], runtimeJobs: [])
        layout.guestDev = "/g/dev"
        let p = layout.settingsAgentPlist
        #expect(p["Label"] as? String == "dev.ycode.simulator.settings")
        #expect(p["ProgramArguments"] as? [String] == ["/g/dev/data/Library/Ycode/bin/ycode-settings-agent"])
        #expect(p["KeepAlive"] as? Bool == true && p["RunAtLoad"] as? Bool == true && p["RootedSimulatorPath"] as? Bool == true)
        #expect(p["StandardErrorPath"] as? String == "/g/dev/data/tmp/ycode-settings-agent.log")
        #expect(layout.settingsAgentPlistPath == "/d/dev/data/Library/LaunchDaemons/dev.ycode.simulator.settings.plist")
        #expect(layout.overridesEnvironment.isEmpty)
        layout.overridesLibrary = "/x/lib.dylib"
        #expect(layout.overridesEnvironment == ["DYLD_INSERT_LIBRARIES=/g/dev/data/Library/Ycode/lib/libYcodeEnvironmentOverrides.dylib",
                                                "YCODE_ENV_OVERRIDES_DIR=/g/dev/data/Library/Ycode/EnvironmentOverrides"])
    }
}
