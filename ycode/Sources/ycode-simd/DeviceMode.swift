// ycode-simd --device: the simulated device's directory, its bootstrap
// plist, and launchd_sim's start parameters (specs/simulator/stage4c-contract.md
// §2; specs/simulator/launchd-sim.md §2, §3, §7.1). Plain Foundation, so the
// layout code also builds where the VMM does not run.

import Foundation

/// The device directory and everything derived from it.
struct DeviceLayout {
    /// DEV: the device directory (guest path = host path).
    let dev: String
    /// RR: the runtime root (guest path = host path).
    let runtimeRoot: String
    let udid: String
    let jobPaths: [String]
    let bootTime: Int
    /// Ycode-written one-shot jobs (`--oneshot`): argv of each, in order.
    let oneshots: [[String]]
    /// Runtime job plists copied into DEV/ycode-jobs (`--runtime-job <label>`).
    let runtimeJobs: [String]
    /// Debug: top-level bootstrap-plist booleans replaced (`--debug-plist-bool K=V`).
    var plistBoolOverrides: [String: Bool] = [:]
    /// One-shot jobs start this many seconds after load (`--oneshot-delay`).
    var oneshotDelay: Int?

    // Device identity (stage4c-contract.md §2).
    static let deviceName = "Ycode"
    static let modelIdentifier = "iPhone19,4"
    static let productClass = "V68"
    static let legacyAssetSuffix = "iphone"
    static let screen = (width: 1206, height: 2622, scale: 3.0, pitch: 460.0)

    init(dev: String, runtimeRoot: String, udid: String?, jobPaths: [String], runtimePaths: Bool = false,
         oneshots: [[String]] = [], runtimeJobs: [String] = [], bootTime: Int = Int(Date().timeIntervalSince1970)) {
        self.dev = dev
        self.runtimeRoot = runtimeRoot
        self.udid = udid?.uppercased() ?? Self.stableUDID(for: dev)
        self.oneshots = oneshots
        self.runtimeJobs = runtimeJobs
        // Ycode's own job directory comes after the --job-path ones; with
        // neither, one empty directory (stage4c-contract.md §2).
        let ycodeJobs = oneshots.isEmpty && runtimeJobs.isEmpty ? [] : [dev + "/ycode-jobs"]
        let coreSimulatorPaths = runtimePaths
            ? ["/System/Library/LaunchDaemons", "/System/Library/LaunchAngels", "/Developer/Library/LaunchDaemons"]
                .map { runtimeRoot + $0 } + [dev + "/data/Library/LaunchDaemons"]
            : []
        let paths = coreSimulatorPaths + jobPaths + ycodeJobs
        self.jobPaths = paths.isEmpty ? [dev + "/ycode-empty-jobs"] : paths
        self.bootTime = bootTime
    }

    // MARK: Paths

    var data: String { dev + "/data" }
    var varRun: String { data + "/var/run" }
    var plistPath: String { varRun + "/launchd_bootstrap.plist" }
    var audioPlistPath: String { varRun + "/com.apple.coresimulator.audio.plist" }
    var audioSettingsPath: String { varRun + "/simulatoraudio/audiosettings.plist" }
    var memoryWarningPath: String { varRun + "/memory_warning_simulation" }
    var extendedDisplayPath: String { data + "/Library/Application Support/Simulator/extended_display.plist" }
    var logRoot: String { dev + "/Logs" }
    /// The device launchd name (launchd-sim.md, terms).
    var launchdName: String { "com.apple.CoreSimulator.SimDevice.\(udid)" }
    /// TMP, the guest path of launchd_sim's per-device temporary directory.
    var tmpGuestPath: String { "/private/var/tmp/" + launchdName }
    /// The host directory behind /private/var/tmp (and /var/tmp). TMP is an
    /// ordinary directory in it, which launchd_sim creates itself: with TMP
    /// already present (`mkdir` → EEXIST) it does not open its flat log.
    var privateVarTmpHostPath: String { dev + "/private-var-tmp" }
    /// The host path of TMP.
    var tmpHostPath: String { privateVarTmpHostPath + "/" + launchdName }
    /// The host log of the logging bootstrap service.
    var hostBootstrapLogPath: String { dev + "/ycode-host-bootstrap.log" }
    var launchdSimPath: String { runtimeRoot + "/sbin/launchd_sim" }
    /// The job directory Ycode fills for `--oneshot` and `--runtime-job`.
    var ycodeJobsPath: String { dev + "/ycode-jobs" }

    // MARK: Ycode-written jobs (stage4c-contract.md §9.1)

    /// The label of one-shot job `index` (0-based): `com.ycode.oneshot.<n>.<program name>`.
    func oneshotLabel(_ index: Int) -> String {
        "com.ycode.oneshot.\(index + 1).\((oneshots[index].first.map { ($0 as NSString).lastPathComponent }) ?? "job")"
    }

    /// The guest path of one-shot job `index`'s stdout (`err` false) or stderr.
    func oneshotOutputGuestPath(_ index: Int, err: Bool) -> String {
        "/tmp/ycode-oneshot-\(index + 1).\(err ? "err" : "out")"
    }

    /// The host path behind it (guest /tmp is DEV/data/tmp).
    func oneshotOutputHostPath(_ index: Int, err: Bool) -> String {
        data + "/tmp/ycode-oneshot-\(index + 1).\(err ? "err" : "out")"
    }

    /// A job plist (launchd-sim.md §4.3 keys) that runs `argv` once at load,
    /// with stdout and stderr in files under /tmp.
    func oneshotPlist(_ index: Int) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": oneshotLabel(index),
            "ProgramArguments": oneshots[index],
            "StandardOutPath": oneshotOutputGuestPath(index, err: false),
            "StandardErrorPath": oneshotOutputGuestPath(index, err: true),
        ]
        if let oneshotDelay { plist["StartInterval"] = oneshotDelay } else { plist["RunAtLoad"] = true }
        return plist
    }

    /// The job directories of the runtime, in CoreSimulator's order (launchd-sim.md §4.1).
    var runtimeJobDirectories: [String] {
        ["/System/Library/LaunchDaemons", "/System/Library/LaunchAngels", "/Developer/Library/LaunchDaemons"].map { runtimeRoot + $0 }
    }

    /// The runtime plist whose file name is `<label>.plist` (or `label` as
    /// given if it ends in `.plist`), from the first runtime job directory
    /// that has it.
    func runtimeJobPlist(_ label: String) -> String? {
        let file = label.hasSuffix(".plist") ? label : label + ".plist"
        return runtimeJobDirectories.map { $0 + "/" + file }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// A UDID derived from the device path: stable across runs, upper case
    /// with dashes (two FNV-1a hashes; version 8 "custom" UUID layout).
    static func stableUDID(for path: String) -> String {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
            return h
        }
        var bytes = withUnsafeBytes(of: fnv(0xCBF2_9CE4_8422_2325).bigEndian, Array.init)
            + withUnsafeBytes(of: fnv(0x84222325CBF29CE4).bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hexText = bytes.map { String(format: "%02X", $0) }.joined()
        let c = Array(hexText)
        return [String(c[0..<8]), String(c[8..<12]), String(c[12..<16]), String(c[16..<20]), String(c[20..<32])].joined(separator: "-")
    }

    // MARK: Runtime version

    /// ProductVersion and ProductBuildVersion of RR's SystemVersion.plist.
    func runtimeVersion() -> (version: String, build: String) {
        let path = runtimeRoot + "/System/Library/CoreServices/SystemVersion.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return ("", "")
        }
        return (plist["ProductVersion"] as? String ?? "", plist["ProductBuildVersion"] as? String ?? "")
    }

    // MARK: Environment

    /// `Bootstrap.ChildDefaults` (launchd-sim.md §3).
    var childDefaults: [String: String] {
        [
            "CFFIXED_USER_HOME": data,
            "HOME": data,
            "TMPDIR": data + "/tmp/",
            "DYLD_FALLBACK_FRAMEWORK_PATH": runtimeRoot + "/System/Library/Frameworks",
            "DYLD_FALLBACK_LIBRARY_PATH": runtimeRoot + "/usr/lib",
        ]
    }

    /// `Bootstrap.Child` (launchd-sim.md §3), with Ycode's values.
    var child: [String: String] {
        let rr = runtimeRoot
        let (version, build) = runtimeVersion()
        func decimal(_ v: Double) -> String { String(format: "%f", v) }
        return [
            "DYLD_ROOT_PATH": rr,
            "IPHONE_SIMULATOR_ROOT": rr,
            "SIMULATOR_ROOT": rr,
            "DYLD_SHARED_CACHE_DIR": rr + "/System/Library/Caches/com.apple.dyld",
            "PATH": "\(rr)/usr/bin:\(rr)/bin:\(rr)/usr/sbin:\(rr)/sbin:\(rr)/usr/local/bin",
            "IPHONE_SHARED_RESOURCES_DIRECTORY": data,
            "SIMULATOR_SHARED_RESOURCES_DIRECTORY": data,
            "XPC_SIMULATOR_LAUNCHD_NAME": launchdName,
            "LS_ENABLE_BUNDLE_LOCALIZATION_CACHING": "1",
            "SIMULATOR_UDID": udid,
            "SIMULATOR_DEVICE_NAME": Self.deviceName,
            "SIMULATOR_MODEL_IDENTIFIER": Self.modelIdentifier,
            "SIMULATOR_PRODUCT_CLASS": Self.productClass,
            "SIMULATOR_LEGACY_ASSET_SUFFIX": Self.legacyAssetSuffix,
            "SIMULATOR_MAINSCREEN_WIDTH": String(Self.screen.width),
            "SIMULATOR_MAINSCREEN_HEIGHT": String(Self.screen.height),
            "SIMULATOR_MAINSCREEN_SCALE": decimal(Self.screen.scale),
            "SIMULATOR_MAINSCREEN_PITCH": decimal(Self.screen.pitch),
            "SIMULATOR_CAPABILITIES": "",
            "SIMULATOR_RUNTIME_VERSION": version,
            "SIMULATOR_RUNTIME_BUILD_VERSION": build,
            "SIMULATOR_ARCHS": "arm64",
            "SIMULATOR_VERSION_INFO": "Ycode - Device: \(Self.deviceName) (\(udid)) - Runtime: iOS \(version) (\(build)) - DeviceType: \(Self.modelIdentifier)",
            "SIMULATOR_BOOT_TIME": String(bootTime),
            "SIMULATOR_HOST_HOME": dev,
            "SIMULATOR_LOG_ROOT": logRoot,
            "SIMULATOR_FRAMEBUFFER_FRAMEWORK": "",
            "SIMULATOR_HID_SYSTEM_MANAGER": "",
            "SIMULATOR_AUDIO_DEVICES_PLIST_PATH": audioPlistPath,
            "SIMULATOR_AUDIO_SETTINGS_PATH": audioSettingsPath,
            "SIMULATOR_MEMORY_WARNINGS": memoryWarningPath,
            "SIMULATOR_EXTENDED_DISPLAY_PROPERTIES": extendedDisplayPath,
            "IPHONE_TVOUT_EXTENDED_PROPERTIES": extendedDisplayPath,
        ]
    }

    /// `Bootstrap.Self` = Child ∪ ChildDefaults.
    var selfEnvironment: [String: String] { child.merging(childDefaults) { a, _ in a } }

    /// launchd_sim's environment (launchd-sim.md §2.2): Self plus the
    /// launch-time variables (not the holding-tank ones), then `overrides`
    /// ("K=V"), sorted by name.
    func launchdEnvironment(overrides: [String]) -> [String] {
        var env = selfEnvironment
        env["XPC_SERVICE_NAME"] = launchdName
        env["XPC_FLAGS"] = "0x0"
        env["OSLogRateLimit"] = "64"
        env["USER"] = "mobile"
        env["LOGNAME"] = "mobile"
        env["SHELL"] = "/bin/sh"
        env["__CF_USER_TEXT_ENCODING"] = "0x1F5:0x0:0x0"
        for pair in overrides {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return env.keys.sorted().map { "\($0)=\(env[$0]!)" }
    }

    // MARK: The bootstrap plist

    /// launchd-sim.md §3, every key, Ycode's values.
    var bootstrapPlist: [String: Any] {
        var plist: [String: Any] = [
            "Bootstrap": [
                "SimulatorRuntimeRoot": runtimeRoot,
                "Paths": jobPaths,
                "Self": selfEnvironment,
                "Child": child,
                "ChildDefaults": childDefaults,
                "BinaryOrderPreference": "arm64",
                "CheckedAllocationsPosixSpawnFlagsGlobal": false,
            ] as [String: Any],
            "AbortOnUnknownIPC": true,
            "CrashOnSIGTERMTimeout": true,
            "ExtensionWatchdog": 0,
            "LogServiceLifecycle": true,
            "LogToFlatFile": true,
            // CoreSimulator writes true and then binds the session over the
            // control channel (launchd-sim.md §6.1 `startsession`). Ycode has
            // no bind yet, and with true launchd_sim defers the spawn of every
            // `system` job (xpcproxy_sim never gets its answer; level 3, our
            // runs), so Ycode writes false (stage4c-contract.md §9).
            "RequireDomainBinding": false,
            "SIGTERMTimeout": 3,
            "UseGuardMalloc": false,
        ]
        for (key, value) in plistBoolOverrides { plist[key] = value }
        return plist
    }

    // MARK: Preparing the directory

    /// Creates DEV's layout (stage4c-contract.md §2) and writes the plists.
    /// Existing files are replaced; the job directories are created if absent.
    func prepare() throws {
        let fm = FileManager.default
        func dir(_ path: String, mode: Int = 0o755) throws {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
        for path in [dev, data, data + "/tmp", varRun, varRun + "/simulatoraudio", data + "/Library/LaunchDaemons",
                     data + "/Library/Application Support/Simulator", logRoot, privateVarTmpHostPath] {
            try dir(path)
        }
        // A fresh boot: no TMP yet (launchd_sim makes it, mode 0700). A
        // previous boot's TMP is kept, renamed with its boot's end time.
        if fm.fileExists(atPath: tmpHostPath) {
            let stamp = Int((try? fm.attributesOfItem(atPath: tmpHostPath)[.modificationDate] as? Date)??.timeIntervalSince1970 ?? 0)
            try fm.moveItem(atPath: tmpHostPath, toPath: "\(tmpHostPath).previous-\(stamp)-\(bootTime)")
        }
        // Ycode's job directory is rebuilt on every boot.
        if fm.fileExists(atPath: ycodeJobsPath) { try fm.removeItem(atPath: ycodeJobsPath) }
        for path in jobPaths where !fm.fileExists(atPath: path) { try dir(path) }
        for index in oneshots.indices {
            try writeXML(oneshotPlist(index), to: ycodeJobsPath + "/" + oneshotLabel(index) + ".plist")
            for err in [false, true] where fm.fileExists(atPath: oneshotOutputHostPath(index, err: err)) {
                try fm.removeItem(atPath: oneshotOutputHostPath(index, err: err))
            }
        }
        // Copies, never links: the runtime's files stay where they are and
        // nothing from the runtime enters the repository.
        for label in runtimeJobs {
            guard let source = runtimeJobPlist(label) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: runtimeRoot + "/…/" + label + ".plist"])
            }
            try fm.copyItem(atPath: source, toPath: ycodeJobsPath + "/" + (source as NSString).lastPathComponent)
        }
        if !fm.fileExists(atPath: memoryWarningPath) {
            guard fm.createFile(atPath: memoryWarningPath, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: memoryWarningPath])
            }
        }
        let audio: [String: Any] = [
            "sim_input_device_uid": "",
            "sim_output_device_uid": "",
            "useHostDefaultInputDevice": true,
            "useHostDefaultOutputDevice": true,
        ]
        try writeXML(audio, to: audioPlistPath)
        try writeXML(bootstrapPlist, to: plistPath)
    }

    private func writeXML(_ plist: [String: Any], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
