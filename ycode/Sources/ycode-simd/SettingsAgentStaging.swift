// Staging Ycode's guest settings agent and Environment Overrides library
// into a device (specs/simulator/simulator-features.md "Ycode
// implementation" §I.1, §I.6).
//
// The agent binary is copied to DEV/data/Library/Ycode/bin and run by
// launchd_sim from DEV/data/Library/LaunchDaemons/dev.ycode.simulator.settings.plist
// (a daemon of the `system` domain, RunAtLoad and KeepAlive, its stderr in
// DEV/data/tmp/ycode-settings-agent.log), as the reference's host-supplied
// agents are run from that directory (launchd-sim.md §4.5). Without an agent
// binary the plist is removed. Both images are built for the iOS simulator;
// on another platform's runtime they are retagged (GuestImagePlatform) or,
// when that is refused, left out.

import Foundation

extension DeviceLayout {
    static let settingsAgentLabel = "dev.ycode.simulator.settings"
    var settingsAgentHostPath: String { data + "/Library/Ycode/bin/ycode-settings-agent" }
    var settingsAgentPlistPath: String { data + "/Library/LaunchDaemons/\(Self.settingsAgentLabel).plist" }
    var settingsAgentLogPath: String { data + "/tmp/ycode-settings-agent.log" }
    var overridesLibraryHostPath: String { data + "/Library/Ycode/lib/libYcodeEnvironmentOverrides.dylib" }
    var overridesDirectoryHostPath: String { DeviceSettingsFiles(dev: dev, guestData: guestData).overridesDirectory }

    /// The agent's launchd job.
    var settingsAgentPlist: [String: Any] {
        ["Label": Self.settingsAgentLabel,
         "ProgramArguments": [guestPath(settingsAgentHostPath)],
         // A path of DEV, not of the runtime (launchd-sim.md §4.4).
         "RootedSimulatorPath": true,
         // Answers the host at once: not held at boot (scheduling-policy.md §4.2).
         "ProcessType": "Interactive",
         "RunAtLoad": true,
         "KeepAlive": true,
         "StandardErrorPath": guestPath(settingsAgentLogPath),
         "EnvironmentVariables": ["YCODE_SETTINGS_AGENT": "1"]]
    }

    /// Copies `source` to `target` (replacing it) and makes it fit the runtime's platform.
    private func stageImage(_ source: String, to target: String, mode: Int) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
        try fm.copyItem(atPath: source, toPath: target)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target)
        if runtimePlatform() != .iOS {
            do {
                try GuestImagePlatform.adapt(fileAt: target, for: runtimePlatform(), version: runtimeVersion().version)
            } catch {
                FileHandle.standardError.write(Data("ycode-simd: \((target as NSString).lastPathComponent) is not used on this runtime: \(error)\n".utf8))
                try? fm.removeItem(atPath: target)
                return false
            }
        }
        return true
    }

    func stageSettingsAgent() throws {
        let fm = FileManager.default
        guard let agent = settingsAgent, fm.fileExists(atPath: agent), try stageImage(agent, to: settingsAgentHostPath, mode: 0o755) else {
            if fm.fileExists(atPath: settingsAgentPlistPath) { try fm.removeItem(atPath: settingsAgentPlistPath) }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: settingsAgentPlist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: settingsAgentPlistPath), options: .atomic)
        if fm.fileExists(atPath: settingsAgentLogPath) { try? fm.removeItem(atPath: settingsAgentLogPath) }
    }

    func stageOverridesLibrary() throws {
        guard let lib = overridesLibrary, FileManager.default.fileExists(atPath: lib) else { return }
        _ = try stageImage(lib, to: overridesLibraryHostPath, mode: 0o755)
        try FileManager.default.createDirectory(atPath: overridesDirectoryHostPath, withIntermediateDirectories: true)
        // Overrides belong to one run of the app (simulator-features.md §7.3): it launches with none.
        if let id = launchBundleID {
            try? FileManager.default.removeItem(atPath: DeviceSettingsFiles(dev: dev, guestData: guestData).overridesPath(id))
        }
    }

    /// The launched app's environment for Environment Overrides.
    var overridesEnvironment: [String] {
        guard overridesLibrary != nil else { return [] }
        return ["DYLD_INSERT_LIBRARIES=" + guestPath(overridesLibraryHostPath),
                "YCODE_ENV_OVERRIDES_DIR=" + DeviceSettingsFiles(dev: dev, guestData: guestData).overridesGuestDirectory]
    }
}
