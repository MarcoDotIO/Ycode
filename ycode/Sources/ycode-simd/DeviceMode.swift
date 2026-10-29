// ycode-simd --device: the simulated device's directory, its bootstrap
// plist, and launchd_sim's start parameters (specs/simulator/stage4c-contract.md
// §2; specs/simulator/launchd-sim.md §2, §3, §7.1). Plain Foundation, so the
// layout code also builds where the VMM does not run.

import Foundation

/// The device directory and everything derived from it.
struct DeviceLayout {
    /// DEV: the device directory (its host path).
    let dev: String
    /// The guest path of DEV: the path its data was first booted at, kept by
    /// copies and moves (DeviceRelocation.swift; app-launch.md §3.3). The
    /// VMM serves it from DEV. Equal to `dev` for a device booted where it
    /// was made.
    var guestDev: String
    /// RR: the runtime root (guest path = host path).
    let runtimeRoot: String
    let udid: String
    let jobPaths: [String]
    let bootTime: Int
    /// One-shot programs (`--oneshot`), run through the control channel: argv of each, in order.
    let oneshots: [[String]]
    /// Runtime job plists copied into DEV/ycode-jobs (`--runtime-job <label>`).
    let runtimeJobs: [String]
    /// Debug: top-level bootstrap-plist booleans replaced (`--debug-plist-bool K=V`).
    var plistBoolOverrides: [String: Bool] = [:]
    /// One-shots start this many seconds after the bind (`--oneshot-delay`).
    var oneshotDelay: Int?
    /// Stage 7 (stage7-contract.md §3.2 item 3): the host `.app` to install
    /// (`--install-app`), the bundle id to launch (`--launch`), its extra
    /// arguments and environment, and the directory holding `ylaunch`.
    var installApp: String?
    var launchBundleID: String?
    var appArguments: [String] = []
    /// A URL the launched app is asked to open (`--app-url`; app-launch.md §2).
    var appURL: String?
    var appEnvironment: [String] = []
    var guestTools: String?
    /// Ycode's headless SimFramebuffer library (host path of the binary;
    /// SimGuestFrameworks/build.sh), copied into DEV and named by
    /// SIMULATOR_FRAMEBUFFER_FRAMEWORK. Nil: the variable is empty.
    var framebufferLibrary: String?
    /// Ycode's HID bundle directory (SimGuestFrameworks/build.sh; hid-input.md
    /// §2), copied into DEV and named by SIMULATOR_HID_SYSTEM_MANAGER. Nil:
    /// the variable is empty (no input).
    var hidBundle: String?
    /// Ycode's guest settings agent (SimGuestAgents; simulator-features.md
    /// "Ycode implementation"): host path of the binary, staged into DEV and
    /// run by launchd_sim from the plist Ycode writes. Nil: no agent.
    var settingsAgent: String?
    /// Ycode's Environment Overrides library, staged into DEV for apps
    /// launched with it (`--environment-overrides`). Nil: none.
    var overridesLibrary: String?
    /// Record the first-boot data migration as done for this runtime build
    /// before the boot (`--skip-first-boot-migration`).
    var skipFirstBootMigration = false
    /// The lean boot profile (lean-boot.md; `YCODE_LEAN_BOOT`). Nil: off.
    var lean: LeanBootProfile? = LeanBootProfile.fromProcessEnvironment
    /// A golden device directory (lean-boot.md §5; `YCODE_DEVICE_TEMPLATE`):
    /// when DEV has no `data` yet, the template's `data` is copied in first.
    var templatePath: String? = ProcessInfo.processInfo.environment["YCODE_DEVICE_TEMPLATE"].flatMap { $0.isEmpty ? nil : $0 }
    /// A snapshot restore (`YCODE_RESTORE_DIR`, snapshot.md §7): DEV holds
    /// the snapshot's state and the restored processes have its files open,
    /// so `prepare` only stages the app and ylaunch; TMP, the job directory,
    /// the plists and the framebuffer state file stay.
    var restoring = false
    /// The device type (`--device-type`; ipad.md §4): the identity variables
    /// and the capabilities plist come from its record (DeviceTypes.swift).
    var deviceType: DeviceType = .default

    // Device identity (stage4c-contract.md §2; the rest is the device type's).
    static let deviceName = "Ycode"

    init(dev: String, runtimeRoot: String, udid: String?, jobPaths: [String], runtimePaths: Bool = false,
         oneshots: [[String]] = [], runtimeJobs: [String] = [], bootTime: Int = Int(Date().timeIntervalSince1970)) {
        self.dev = dev
        self.guestDev = dev
        self.runtimeRoot = runtimeRoot
        self.udid = udid?.uppercased() ?? Self.stableUDID(for: dev)
        self.oneshots = oneshots
        self.runtimeJobs = runtimeJobs
        // Ycode's own job directory comes after the --job-path ones; with
        // neither, one empty directory (stage4c-contract.md §2).
        let ycodeJobs = runtimeJobs.isEmpty ? [] : [dev + "/ycode-jobs"]
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
    /// The guest path of a host path in DEV (others are returned as they are).
    func guestPath(_ hostPath: String) -> String {
        if guestDev == dev { return hostPath }
        if hostPath == dev { return guestDev }
        if hostPath.hasPrefix(dev + "/") { return guestDev + hostPath.dropFirst(dev.count) }
        return hostPath
    }
    /// DEV/data as the guest sees it (HOME).
    var guestData: String { guestPath(data) }
    var varRun: String { data + "/var/run" }
    var plistPath: String { varRun + "/launchd_bootstrap.plist" }
    var audioPlistPath: String { varRun + "/com.apple.coresimulator.audio.plist" }
    var audioSettingsPath: String { varRun + "/simulatoraudio/audiosettings.plist" }
    var memoryWarningPath: String { varRun + "/memory_warning_simulation" }
    /// Ycode's device-capabilities plist (device-capabilities.md), rewritten on every boot.
    var capabilitiesPath: String { dev + "/ycode-capabilities.plist" }
    var extendedDisplayPath: String { data + "/Library/Application Support/Simulator/extended_display.plist" }
    /// The device type this DEV was first booted as (ipad.md §4.3 R2): one
    /// line, the type's id. A DEV that was booted (it has a bootstrap plist)
    /// and has no record is an iPhone Duo (every device made before device
    /// types existed).
    var deviceTypePath: String { dev + "/ycode-device-type" }
    /// The runtime the device last booted (`<ProductName> <version> <build>`;
    /// ipad.md §2.2: per-runtime state, `runtimeCheck`).
    var runtimeRecordPath: String { dev + "/ycode-runtime" }
    /// The device's global preferences (ipad.md §10 Q8): a new device starts
    /// with a US English region before its first boot.
    var globalPreferencesPath: String { data + "/Library/Preferences/.GlobalPreferences.plist" }
    /// What a new device's global preferences hold before the first boot.
    static var firstBootGlobalPreferences: [String: Any] { ["AppleLanguages": ["en-US"], "AppleLocale": "en_US"] }
    var logRoot: String { dev + "/Logs" }
    /// The device launchd name (launchd-sim.md, terms).
    var launchdName: String { "com.apple.CoreSimulator.SimDevice.\(udid)" }
    /// TMP, the guest path of launchd_sim's per-device temporary directory.
    var tmpGuestPath: String { "/private/var/tmp/" + launchdName }
    /// launchd_sim's per-label enable/disable overrides (launchd-sim.md §4.2;
    /// the file `launchctl disable` writes).
    var disabledOverridesHostPath: String { tmpHostPath + "/disabled.plist" }
    /// The host directory behind /private/var/tmp (and /var/tmp). TMP is an
    /// ordinary directory in it, which launchd_sim creates itself. An earlier
    /// note said that with TMP already present launchd_sim does not open its
    /// flat log; on 2026-10-17 it did (the lean profile makes TMP first, and
    /// `launchd.log` was written; on the Mac TMP persists across boots and
    /// the log is rotated, lean-boot.md §3.1).
    var privateVarTmpHostPath: String { dev + "/private-var-tmp" }
    /// The host path of TMP.
    var tmpHostPath: String { privateVarTmpHostPath + "/" + launchdName }
    /// The host log of the logging bootstrap service.
    var hostBootstrapLogPath: String { dev + "/ycode-host-bootstrap.log" }
    var launchdSimPath: String { runtimeRoot + "/sbin/launchd_sim" }
    /// The job directory Ycode fills for `--runtime-job`.
    var ycodeJobsPath: String { dev + "/ycode-jobs" }

    /// Where the HID bundle is copied, and its log (YCODE_SIMHID_LOG).
    var hidGuestPath: String? { hidBundle.map { _ in dev + "/ycode-frameworks/SimHID.framework" } }
    var hidLogPath: String { data + "/tmp/ycode-simhid.log" }

    /// The headless framebuffer library's frame record: host path (the
    /// display server, screenshots) and guest path, in the memory directory
    /// (DeviceMemoryFiles.swift).
    var framebufferStatePath: String { memoryFile("ycode-framebuffer.state").host }
    var framebufferStateGuestPath: String { memoryFile("ycode-framebuffer.state").guest }
    /// Frame and input timing (display-stream.md §10), on only when the
    /// host sets YCODE_DISPLAY_TIMING=1: the framebuffer library's swap log,
    /// the HID bundle's event log (guest paths), and the display server's
    /// trace (host path), all in the memory directory.
    static let displayTiming: Bool = ProcessInfo.processInfo.environment["YCODE_DISPLAY_TIMING"] == "1"
    var framebufferTimingPath: String { memoryFile("ycode-framebuffer.timing").guest }
    var hidTimingPath: String { memoryFile("ycode-simhid.timing").guest }
    var displayTracePath: String { memoryFile("ycode-display.trace").host }

    /// Where the framebuffer library is copied (a guest-readable DEV path).
    var framebufferGuestPath: String? {
        framebufferLibrary.map { _ in dev + "/ycode-frameworks/SimFramebuffer.framework/SimFramebuffer" }
    }

    // MARK: Apps (stage7-contract.md §3.2 items 2, 3)

    /// Where `--install-app` copies the bundle (a guest-readable DEV path).
    var appsDirectory: String { data + "/tmp/ycode-apps" }
    /// The staged copy of the `--install-app` bundle, if any.
    var stagedAppGuestPath: String? {
        installApp.map { appsDirectory + "/" + (($0 as NSString).standardizingPath as NSString).lastPathComponent }
    }
    /// The staged `ylaunch` (DEV/data/tmp/ycode-tools/ylaunch) when an app is installed or launched.
    var ylaunchPath: String? { installApp != nil || launchBundleID != nil ? data + "/tmp/ycode-tools/ylaunch" : nil }
    /// The launched app's stdio (guest paths; DEV/data/tmp on the host, app-install-launch.md §3.4).
    static let appStdoutGuestPath = "/tmp/ycode-app.out"
    static let appStderrGuestPath = "/tmp/ycode-app.err"
    var appStdoutHostPath: String { data + Self.appStdoutGuestPath }
    var appStderrHostPath: String { data + Self.appStderrGuestPath }

    // MARK: One-shots (stage7-contract.md §3.2)

    /// The display name of one-shot `index` (0-based): `com.ycode.oneshot.<n>.<program name>`.
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

    /// The path of one-shot `index`'s program as 704 takes it (the path in
    /// the simulator's file system, launch-sim-control.md §3.6): a path
    /// inside DEV (its guest path) or RR; any other absolute path names a
    /// file under RR.
    func oneshotProgram(_ index: Int) -> String {
        let program = oneshots[index].first ?? "/"
        if program.hasPrefix(dev + "/") { return guestPath(program) }
        if program.hasPrefix(guestDev + "/") || program.hasPrefix(runtimeRoot + "/") { return program }
        return runtimeRoot + program
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

    /// The runtime's platform, from `ProductName` of the same file
    /// (visionos.md V-2): `xrOS` is visionOS, anything else iOS.
    func runtimePlatform() -> RuntimePlatform {
        let path = runtimeRoot + "/System/Library/CoreServices/SystemVersion.plist"
        let plist = FileManager.default.contents(atPath: path).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        }
        return RuntimePlatform(productName: plist?["ProductName"] as? String)
    }

    // MARK: Environment

    /// `Bootstrap.ChildDefaults` (launchd-sim.md §3).
    var childDefaults: [String: String] {
        [
            "CFFIXED_USER_HOME": guestData,
            "HOME": guestData,
            "TMPDIR": guestData + "/tmp/",
            "DYLD_FALLBACK_FRAMEWORK_PATH": runtimeRoot + "/System/Library/Frameworks",
            "DYLD_FALLBACK_LIBRARY_PATH": runtimeRoot + "/usr/lib",
        ]
    }

    /// `Bootstrap.Child` (launchd-sim.md §3), with Ycode's values.
    var child: [String: String] {
        let rr = runtimeRoot
        let (version, build) = runtimeVersion()
        func decimal(_ v: Double) -> String { String(format: "%f", v) }
        var env = [
            "DYLD_ROOT_PATH": rr,
            "IPHONE_SIMULATOR_ROOT": rr,
            "SIMULATOR_ROOT": rr,
            "DYLD_SHARED_CACHE_DIR": rr + "/System/Library/Caches/com.apple.dyld",
            "PATH": "\(rr)/usr/bin:\(rr)/bin:\(rr)/usr/sbin:\(rr)/sbin:\(rr)/usr/local/bin",
            "IPHONE_SHARED_RESOURCES_DIRECTORY": guestData,
            "SIMULATOR_SHARED_RESOURCES_DIRECTORY": guestData,
            "XPC_SIMULATOR_LAUNCHD_NAME": launchdName,
            "LS_ENABLE_BUNDLE_LOCALIZATION_CACHING": "1",
            "SIMULATOR_UDID": udid,
            "SIMULATOR_DEVICE_NAME": Self.deviceName,
            "SIMULATOR_MODEL_IDENTIFIER": deviceType.modelIdentifier,
            "SIMULATOR_PRODUCT_CLASS": deviceType.productClass,
            "SIMULATOR_LEGACY_ASSET_SUFFIX": deviceType.legacyAssetSuffix,
            "SIMULATOR_MAINSCREEN_WIDTH": String(deviceType.screen.width),
            "SIMULATOR_MAINSCREEN_HEIGHT": String(deviceType.screen.height),
            "SIMULATOR_MAINSCREEN_SCALE": decimal(deviceType.screen.scale),
            "SIMULATOR_MAINSCREEN_PITCH": decimal(deviceType.screen.pitch),
            "SIMULATOR_CAPABILITIES": guestPath(capabilitiesPath),
            "SIMULATOR_RUNTIME_VERSION": version,
            "SIMULATOR_RUNTIME_BUILD_VERSION": build,
            "SIMULATOR_ARCHS": "arm64",
            "SIMULATOR_VERSION_INFO": "Ycode - Device: \(Self.deviceName) (\(udid)) - Runtime: \(runtimePlatform().displayName) \(version) (\(build)) - DeviceType: \(deviceType.modelIdentifier)",
            "SIMULATOR_BOOT_TIME": String(bootTime),
            "SIMULATOR_HOST_HOME": guestDev,
            "SIMULATOR_LOG_ROOT": guestPath(logRoot),
            // The binary's path (simframebuffer.md §2): Ycode's headless library.
            "SIMULATOR_FRAMEBUFFER_FRAMEWORK": framebufferGuestPath.map(guestPath) ?? "",
            // Ycode's headless library writes its frame record here (the
            // presented IOSurface; screenshots).
            "YCODE_FRAMEBUFFER_STATE": framebufferStateGuestPath,
            "YCODE_FRAMEBUFFER_TIMING": Self.displayTiming ? framebufferTimingPath : "",
            "YCODE_SIMHID_TIMING": Self.displayTiming && hidGuestPath != nil ? hidTimingPath : "",
            // Diagnostic only (simframebuffer.c): delayed swap completions.
            "YCODE_FRAMEBUFFER_COMPLETION": ProcessInfo.processInfo.environment["YCODE_FRAMEBUFFER_COMPLETION"] ?? "",
            "SIMULATOR_HID_SYSTEM_MANAGER": hidGuestPath.map(guestPath) ?? "",
            "YCODE_SIMHID_LOG": hidGuestPath == nil ? "" : guestPath(hidLogPath),
            "SIMULATOR_AUDIO_DEVICES_PLIST_PATH": guestPath(audioPlistPath),
            "SIMULATOR_AUDIO_SETTINGS_PATH": guestPath(audioSettingsPath),
            "SIMULATOR_MEMORY_WARNINGS": guestPath(memoryWarningPath),
        ]
        // A display unique id fixed by the device type (visionos.md §3.3,
        // V-6): the framebuffer library reports it for its one display.
        if let uid = deviceType.displayUID { env["YCODE_FRAMEBUFFER_DISPLAY_UID"] = uid }
        // A foldable (foldable.md §8): the HID bundle publishes the
        // device-motion service (the hinge, §8.2 I2) and the framebuffer
        // library its second built-in display (§8.1 D1), by default; the
        // capabilities plist then carries the type's `displays` list, from
        // which SpringBoard takes each panel's surface (cover, inner;
        // foldable.md §9 Q7). YCODE_FOLD_DISPLAYS=0 publishes the cover only
        // and writes no `displays`.
        if deviceType.isFoldable {
            env["YCODE_SIMHID_DEVICE_MOTION"] = "1"
            if let second = deviceType.publishedSecondDisplay { env["YCODE_FRAMEBUFFER_SECOND_DISPLAY"] = second.environmentValue }
        }
        // Diagnostic only (host YCODE_FRAMEBUFFER_CALLS=1): the framebuffer
        // library logs its state-changing calls per process to
        // DEV/data/tmp/ycode-framebuffer.calls.<pid> (simframebuffer.c).
        if ProcessInfo.processInfo.environment["YCODE_FRAMEBUFFER_CALLS"] == "1" {
            env["YCODE_FRAMEBUFFER_CALLS"] = guestPath(data + "/tmp/ycode-framebuffer.calls")
        }
        // Diagnostic only: YCODE_CHILD_ENV="K=V;K=V" adds variables to every
        // job's environment (for example a recorder library in
        // DYLD_INSERT_LIBRARIES; SimShim/guest-tests/visionos/mtlwatch.m).
        if let extra = ProcessInfo.processInfo.environment["YCODE_CHILD_ENV"] {
            for pair in extra.split(separator: ";") {
                guard let eq = pair.firstIndex(of: "=") else { continue }
                env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
            }
        }
        // The iPhone's environment names the extended-display plist; an
        // iPad's and the Vision Pro's do not (ipad.md §4.1, visionos.md §3.4).
        if deviceType.extendedDisplayProperties {
            env["SIMULATOR_EXTENDED_DISPLAY_PROPERTIES"] = guestPath(extendedDisplayPath)
            env["IPHONE_TVOUT_EXTENDED_PROPERTIES"] = guestPath(extendedDisplayPath)
        }
        return env
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
                "Paths": jobPaths.map(guestPath),
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
            // As CoreSimulator: the host binds the session over the control
            // channel (700) right after the 808 reply; until then `system`
            // jobs are held (launch-sim-control.md §3.1, §7 item 3).
            "RequireDomainBinding": true,
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
        try checkDeviceType()
        try checkRuntime()
        // A device that never booted (no type record, no bootstrap plist).
        let isNewDevice = Self.recordedDeviceType(in: dev) == nil
        if restoring {
            // The framebuffer state file stays: backboardd's framebuffer
            // library keeps it open and rewrites it on every swap. Removed
            // here, the restore would hand backboardd an unlinked stand-in,
            // and the display server (which reads the path) would never see
            // a frame of the restored device. Its record names a surface the
            // IOSurface service restores, so the last frame shows at once.
            // (It is in the memory directory, refilled from the snapshot's copy.)
            try prepareMemoryDirectory()
            try stageApp(dir)
            try stageOverridesLibrary()
            return
        }
        if let templatePath, !fm.fileExists(atPath: data) {
            try checkTemplate(templatePath)
            try cloneData(from: templatePath)
        }
        // A copied or moved device: no paths of the device it came from (app-launch.md §4).
        try handleRelocation()
        for path in [dev, data, data + "/tmp", varRun, varRun + "/simulatoraudio", data + "/Library/LaunchDaemons",
                     data + "/Library/Application Support/Simulator", logRoot, privateVarTmpHostPath] {
            try dir(path)
        }
        try prepareMemoryDirectory()
        // A new device starts with a US English region (ipad.md §10 Q8),
        // unless its data already has global preferences (a golden-device
        // copy, files put in before the first boot).
        if isNewDevice && !fm.fileExists(atPath: globalPreferencesPath) {
            try dir((globalPreferencesPath as NSString).deletingLastPathComponent)
            try writeXML(Self.firstBootGlobalPreferences, to: globalPreferencesPath)
        }
        // A fresh boot: no TMP yet (launchd_sim makes it, mode 0700). A
        // previous boot's TMP is kept, renamed with its boot's end time.
        if fm.fileExists(atPath: tmpHostPath) {
            let stamp = Int((try? fm.attributesOfItem(atPath: tmpHostPath)[.modificationDate] as? Date)??.timeIntervalSince1970 ?? 0)
            try fm.moveItem(atPath: tmpHostPath, toPath: "\(tmpHostPath).previous-\(stamp)-\(bootTime)")
        }
        // Lean boot: TMP made here (mode 0700, as launchd_sim makes it) with
        // the disabled overrides in it (lean-boot.md §3.1).
        if let lean, !lean.disabledLabels.isEmpty {
            try dir(tmpHostPath, mode: 0o700)
            let plist = lean.disabledOverrides().mapValues { $0 as Any }
            try writeXML(plist, to: disabledOverridesHostPath)
        }
        try applyLoggingPreferences(lean?.loggingOff == true)
        if let lean { FileHandle.standardError.write(Data(("ycode-simd: " + lean.summary + "\n").utf8)) }
        // Ycode's job directory is rebuilt on every boot.
        if fm.fileExists(atPath: ycodeJobsPath) { try fm.removeItem(atPath: ycodeJobsPath) }
        for path in jobPaths where !fm.fileExists(atPath: path) { try dir(path) }
        for index in oneshots.indices {
            for err in [false, true] where fm.fileExists(atPath: oneshotOutputHostPath(index, err: err)) {
                try fm.removeItem(atPath: oneshotOutputHostPath(index, err: err))
            }
        }
        try stageApp(dir)
        // The frame record and timing files: prepareMemoryDirectory emptied their directory.
        if skipFirstBootMigration { try recordMigrationDone() }
        if let framebufferLibrary, let target = framebufferGuestPath {
            try dir((target as NSString).deletingLastPathComponent)
            if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
            try fm.copyItem(atPath: framebufferLibrary, toPath: target)
            try GuestImagePlatform.adapt(fileAt: target, for: runtimePlatform(), version: runtimeVersion().version)
        }
        if let hidBundle, let target = hidGuestPath {
            try dir((target as NSString).deletingLastPathComponent)
            if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
            try fm.copyItem(atPath: hidBundle, toPath: target)
            try GuestImagePlatform.adapt(fileAt: target + "/SimHID", for: runtimePlatform(), version: runtimeVersion().version)
            if fm.fileExists(atPath: hidLogPath) { try fm.removeItem(atPath: hidLogPath) }
        }
        try prepareJobsAndPlists()
        try stageSettingsAgent()
        try stageOverridesLibrary()
        DeviceSettingsFiles(dev: dev, guestData: guestData).resetNonPersistentAtColdBoot()
    }

    /// Stage 7: the app bundle and ylaunch, copied where the guest can read
    /// them; the app's previous stdio files are removed.
    private func stageApp(_ dir: (String, Int) throws -> Void) throws {
        let fm = FileManager.default
        if let installApp {
            try dir(appsDirectory, 0o755)
            let target = stagedAppGuestPath!
            if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
            try fm.copyItem(atPath: installApp, toPath: target)
        }
        if let ylaunchPath {
            guard let tools = guestTools, fm.fileExists(atPath: tools + "/ylaunch") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: (guestTools ?? "?") + "/ylaunch"])
            }
            try dir((ylaunchPath as NSString).deletingLastPathComponent, 0o755)
            if fm.fileExists(atPath: ylaunchPath) { try fm.removeItem(atPath: ylaunchPath) }
            try fm.copyItem(atPath: tools + "/ylaunch", toPath: ylaunchPath)
            for path in [appStdoutHostPath, appStderrHostPath] where fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        }
    }

    private func prepareJobsAndPlists() throws {
        let fm = FileManager.default
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
        // Audio (audio-host.md §12, "Ycode implementation"): the device list
        // names the host service's output device; there is no input device.
        // The settings file is the one the reference's CoreSimulatorBridge (a
        // host program Ycode does not run) writes from it: written here,
        // before boot, with the reference's ringer state and volume.
        // The device's choices (simulator-features.md §4.11–4.13) stay
        // across boots: the files are rewritten from what they hold (a new
        // device: System, System, volume 60).
        try DeviceSettingsFiles(dev: dev, guestData: guestData).writeAudio(DeviceSettingsFiles(dev: dev).audio())
        try writeXML(DeviceCapabilities.plist(for: deviceType), to: capabilitiesPath)
        try writeXML(bootstrapPlist, to: plistPath)
        if recordedDeviceType() == nil { try Data((deviceType.id + "\n").utf8).write(to: URL(fileURLWithPath: deviceTypePath)) }
        try recordRuntime()
    }

    // MARK: Runtime of a device (ipad.md §2.2; home-apps.md §4)

    /// A runtime as a device records it: platform name, version, build.
    struct RuntimeRecord: Equatable {
        var productName: String
        var version: String
        var build: String
        var line: String { "\(productName) \(version) \(build)\n" }
        init(productName: String, version: String, build: String) {
            self.productName = productName.isEmpty ? "iPhone OS" : productName
            self.version = version
            self.build = build
        }
        /// "<ProductName…> <version> <build>": the last two words are version and build.
        init?(line: String) {
            let words = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
            guard words.count >= 3 else { return nil }
            self.init(productName: words.dropLast(2).joined(separator: " "), version: words[words.count - 2], build: words[words.count - 1])
        }
        var displayName: String { "\(RuntimePlatform(productName: productName).displayName) \(version) (\(build))" }
    }

    /// This boot's runtime.
    func currentRuntimeRecord() -> RuntimeRecord {
        let path = runtimeRoot + "/System/Library/CoreServices/SystemVersion.plist"
        let plist = FileManager.default.contents(atPath: path).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        }
        return RuntimeRecord(productName: plist?["ProductName"] as? String ?? "", version: plist?["ProductVersion"] as? String ?? "",
                             build: plist?["ProductBuildVersion"] as? String ?? "")
    }

    static func recordedRuntime(in dev: String) -> RuntimeRecord? {
        FileManager.default.contents(atPath: dev + "/ycode-runtime").flatMap { RuntimeRecord(line: String(decoding: $0, as: UTF8.self)) }
    }

    /// The build the guest's data was last migrated to (`LastSystemVersion`
    /// of `com.apple.migration.plist`, first-boot.md §1), or nil.
    static func lastSystemBuild(in dev: String) -> String? {
        let path = dev + "/data/Library/Preferences/com.apple.migration.plist"
        let plist = FileManager.default.contents(atPath: path).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        return plist?["LastSystemVersion"] as? String
    }

    /// Dotted version order ("27.0" < "27.1" < "27.10").
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// A device keeps its runtime, as a CoreSimulator device does: its
    /// data (LaunchServices store, home-screen layout, migrated databases)
    /// belongs to the runtime it booted. **Ycode decision:** booting it on an
    /// older runtime version is refused (simctl only ever moves a device to
    /// a newer runtime, `simctl upgrade`); a newer version or another build
    /// of the same version boots with a warning (the guest's data migration
    /// runs, first-boot.md §1). A device with no record is checked against
    /// the build its data was migrated to, with a warning only.
    func checkRuntime() throws {
        let now = currentRuntimeRecord()
        guard !now.build.isEmpty else { return }
        if let was = Self.recordedRuntime(in: dev) {
            guard was.build != now.build else { return }
            if !was.version.isEmpty, !now.version.isEmpty, Self.compareVersions(now.version, was.version) < 0 {
                throw DeviceRuntimeDowngrade(dev: dev, recorded: was, requested: now)
            }
            FileHandle.standardError.write(Data("ycode-simd: warning: the device \(dev) last booted \(was.displayName); this boot of \(now.displayName) migrates its data\n".utf8))
        } else if let last = Self.lastSystemBuild(in: dev), last != now.build {
            FileHandle.standardError.write(Data("ycode-simd: warning: the device \(dev) was last booted on runtime build \(last), not \(now.build); this boot migrates its data\n".utf8))
        }
    }

    /// Records this boot's runtime in DEV (written when it changes).
    func recordRuntime() throws {
        let now = currentRuntimeRecord()
        guard !now.build.isEmpty, Self.recordedRuntime(in: dev) != now else { return }
        try Data(now.line.utf8).write(to: URL(fileURLWithPath: runtimeRecordPath), options: .atomic)
    }

    // MARK: Device type (ipad.md §4.3 R2)

    /// The type recorded in a device directory: its `ycode-device-type`, or
    /// the default type for a directory that was booted (its bootstrap plist
    /// exists) but has no record (made before device types existed); nil
    /// for a directory that never booted (files put into `data` before the
    /// first boot do not count).
    static func recordedDeviceType(in dev: String) -> String? {
        let fm = FileManager.default
        if let data = fm.contents(atPath: dev + "/ycode-device-type") {
            let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        return fm.fileExists(atPath: dev + "/data/var/run/launchd_bootstrap.plist") ? DeviceType.default.id : nil
    }

    func recordedDeviceType() -> String? {
        guard FileManager.default.fileExists(atPath: deviceTypePath) else { return nil }
        return Self.recordedDeviceType(in: dev)
    }

    /// A device keeps its type: its LaunchServices store, home-screen layout
    /// and migrated data are per idiom. Booting it as another type is refused.
    func checkDeviceType() throws {
        // visionos.md V-1: a type runs only on its platform's runtimes.
        let platform = runtimePlatform()
        if deviceType.platform != platform {
            throw DeviceTypePlatformMismatch(type: deviceType, runtime: platform, runtimeRoot: runtimeRoot)
        }
        // iphone-types.md §1, §2: a type older runtimes do not accept (the
        // iPhone Duo on 27.0) is refused, as CoreSimulator refuses it.
        // YCODE_ALLOW_ANY_DEVICE_TYPE=1 (diagnostics) boots it anyway.
        let version = runtimeVersion().version
        if !deviceType.runs(onVersion: version), ProcessInfo.processInfo.environment["YCODE_ALLOW_ANY_DEVICE_TYPE"] != "1" {
            throw DeviceTypeRuntimeMismatch(type: deviceType, runtimeVersion: version, runtimeRoot: runtimeRoot)
        }
        if let recorded = Self.recordedDeviceType(in: dev), recorded != deviceType.id {
            throw DeviceTypeMismatch(what: "the device \(dev)", recorded: recorded, requested: deviceType.id)
        }
    }

    /// A golden device (lean-boot.md §5) is per (runtime build, device
    /// type): a template of another type is refused; one first-booted on
    /// another runtime build is used, with a warning (the boot migrates it).
    func checkTemplate(_ template: String) throws {
        let recorded = Self.recordedDeviceType(in: template) ?? DeviceType.default.id
        if recorded != deviceType.id {
            throw DeviceTypeMismatch(what: "the golden device \(template)", recorded: recorded, requested: deviceType.id)
        }
        let migration = template + "/data/Library/Preferences/com.apple.migration.plist"
        let build = runtimeVersion().build
        if let data = FileManager.default.contents(atPath: migration),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let last = plist["LastSystemVersion"] as? String, !build.isEmpty, last != build {
            FileHandle.standardError.write(Data("ycode-simd: warning: the golden device \(template) was booted on runtime build \(last), not \(build); this boot migrates it\n".utf8))
        }
    }

    /// The data-migration preferences (`DEV/data/Library/Preferences/
    /// com.apple.migration.plist`, read as a file format from a Mac device
    /// after its first boot; level 2): `LastSystemVersion` = the runtime
    /// build (datamigrator logs "System build version changed from (null)"
    /// without it), `DMLastMigrationResults` = {buildVersion, success: true},
    /// `DMUserDataDisposition` = {buildVersion, EraseIsRapidReturnToService:
    /// false, SyntheticDidUpgrade: false}. With them the boot does not run the
    /// first-boot migrators. Kept if present.
    func recordMigrationDone() throws {
        let path = data + "/Library/Preferences/com.apple.migration.plist"
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let build = runtimeVersion().build
        try writeXML(["LastSystemVersion": build,
                      "DMLastMigrationResults": ["buildVersion": build, "success": true] as [String: Any],
                      "DMUserDataDisposition": ["buildVersion": build, "EraseIsRapidReturnToService": false,
                                                "SyntheticDidUpgrade": false] as [String: Any]], to: path)
    }

    /// The guest's per-subsystem logging preferences.
    var loggingSubsystemsPath: String { data + "/Library/Preferences/Logging/Subsystems" }
    /// The subsystem files the lean profile wrote, one name per line (so that
    /// a later boot without it removes them again).
    var leanLoggingRecordPath: String { dev + "/ycode-lean-logging.txt" }

    /// Lean logging (lean-boot.md §4.3): with `on`, writes a level-off
    /// preference for each subsystem of the list that has none yet and
    /// records it; without, removes the recorded files that still hold
    /// exactly that preference. A preference someone else wrote is never
    /// touched.
    func applyLoggingPreferences(_ on: Bool) throws {
        let fm = FileManager.default
        let offData = try PropertyListSerialization.data(fromPropertyList: LeanBootProfile.levelOffPreference, format: .xml, options: 0)
        var recorded = (fm.contents(atPath: leanLoggingRecordPath)).map {
            String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init)
        } ?? []
        if on {
            try fm.createDirectory(atPath: loggingSubsystemsPath, withIntermediateDirectories: true)
            for subsystem in LeanBootProfile.loggingOffSubsystems where !recorded.contains(subsystem) {
                let path = loggingSubsystemsPath + "/" + subsystem + ".plist"
                guard !fm.fileExists(atPath: path) else { continue }
                try offData.write(to: URL(fileURLWithPath: path))
                recorded.append(subsystem)
            }
        } else {
            for subsystem in recorded {
                let path = loggingSubsystemsPath + "/" + subsystem + ".plist"
                if fm.contents(atPath: path) == offData { try fm.removeItem(atPath: path) }
            }
            recorded = []
        }
        if recorded.isEmpty {
            if fm.fileExists(atPath: leanLoggingRecordPath) { try fm.removeItem(atPath: leanLoggingRecordPath) }
        } else {
            try Data((recorded.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: leanLoggingRecordPath))
        }
    }

    /// Copies the golden device's `data` directory into DEV (lean-boot.md
    /// §5): every file, with modes and times (`cp -a`, a reflink where the
    /// file system has them). The copy gets this DEV's UDID at boot, as
    /// `simctl clone` gives the clone a new identity over the same data.
    func cloneData(from template: String) throws {
        let source = template + "/data"
        guard FileManager.default.fileExists(atPath: source) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source])
        }
        try FileManager.default.createDirectory(atPath: dev, withIntermediateDirectories: true)
        #if os(Linux)
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-a", "--reflink=auto", source, data]
        try cp.run()
        cp.waitUntilExit()
        guard cp.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: data])
        }
        #else
        try FileManager.default.copyItem(atPath: source, toPath: data)
        #endif
        FileHandle.standardError.write(Data("ycode-simd: device data cloned from \(template)\n".utf8))
    }

    /// The host audio service's output device UID (`AudioObjectModel.deviceUID`).
    static let audioOutputDeviceUID = "dev.ycode.simulator.audio.output"

    private func writeXML(_ plist: [String: Any], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// A device type on a runtime of another platform (visionos.md V-1).
struct DeviceTypePlatformMismatch: Error, CustomStringConvertible {
    let type: DeviceType
    let runtime: RuntimePlatform
    let runtimeRoot: String
    var description: String {
        let fitting = DeviceType.all.filter { $0.platform == runtime }.map(\.id).joined(separator: ", ")
        return "the device type \(type.id) (\(type.name)) runs on \(type.platform.displayName) runtimes; \(runtimeRoot) is a \(runtime.displayName) runtime (its device types: \(fitting))"
    }
}

/// A device type on a runtime version older than the type's minimum.
struct DeviceTypeRuntimeMismatch: Error, CustomStringConvertible {
    let type: DeviceType
    let runtimeVersion: String
    let runtimeRoot: String
    var description: String {
        let fitting = DeviceType.all.filter { $0.platform == type.platform && $0.runs(onVersion: runtimeVersion) }.map(\.id).joined(separator: ", ")
        return "the device type \(type.id) (\(type.name)) needs runtime \(type.minRuntimeVersion ?? "?") or later; \(runtimeRoot) is \(runtimeVersion) (its device types: \(fitting))"
    }
}

/// A device booted on a runtime older than the one it last booted.
struct DeviceRuntimeDowngrade: Error, CustomStringConvertible {
    let dev: String
    let recorded: DeviceLayout.RuntimeRecord
    let requested: DeviceLayout.RuntimeRecord
    var description: String {
        "the device \(dev) last booted \(recorded.displayName); it cannot boot the older runtime \(requested.displayName) (use another device directory for each runtime)"
    }
}

/// A device directory (or golden device) of one type booted as another.
struct DeviceTypeMismatch: Error, CustomStringConvertible {
    let what: String
    let recorded: String
    let requested: String
    var description: String {
        "\(what) has the device type \(recorded); it cannot boot as \(requested) (use another device directory, or --device-type \(recorded))"
    }
}
