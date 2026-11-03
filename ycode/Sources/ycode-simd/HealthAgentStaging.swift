// Staging Ycode's guest health agent into a device and the shut-down edits
// of its health store (specs/simulator/health-simulation.md §8.1 H-1, §8.2
// H-5/H-6, "Ycode implementation").
//
// The agent is an app bundle, `YcodeHealth.app` (SimGuestAgents/build-health.sh;
// `watchos/YcodeHealth.app` for watch devices). At every cold boot it is
// copied to DEV/data/Library/Ycode/YcodeHealth.app and its executable runs as
// a launchd daemon from DEV/data/Library/LaunchDaemons/dev.ycode.simulator.health.plist
// (RunAtLoad, KeepAlive, Interactive; stderr in DEV/data/tmp/ycode-health-agent.log),
// like the settings agent. HealthKit makes it a source of its own
// (dev.ycode.health, "Ycode Health"): a daemon whose executable sits in an
// app bundle with application-identifier and the HealthKit entitlement in
// its simulated-entitlements section is a client with a source (open
// question 1, answered on Ycode).
//
// Before the guest starts (a cold boot, never a snapshot restore: the
// restored healthd has the store open), Ycode answers the agent's own
// authorization request in the store (the rows healthd wrote when the agent
// asked, status 100 / request 203 → 101) and applies the `health grant` and
// `revoke` commands queued for the developer's apps, after a backup of the
// store (HealthStore.swift). The agent's first boot on a new device therefore
// only records its request; from the next cold boot on it may write.

import Foundation
import YcodeHealthStore
import YcodeSimFeatures

extension DeviceLayout {
    static let healthAgentLabel = "dev.ycode.simulator.health"
    static let healthAgentBundleName = "YcodeHealth.app"
    var healthAgentHostPath: String { data + "/Library/Ycode/" + Self.healthAgentBundleName }
    var healthAgentExecutableHostPath: String { healthAgentHostPath + "/YcodeHealth" }
    var healthAgentPlistPath: String { data + "/Library/LaunchDaemons/\(Self.healthAgentLabel).plist" }
    var healthAgentLogPath: String { data + "/tmp/ycode-health-agent.log" }
    var healthPendingPath: String { HealthDeviceFiles(dev: dev).pendingPath }
    var healthBackupsPath: String { HealthDeviceFiles(dev: dev).backupsPath }

    var healthAgentPlist: [String: Any] {
        ["Label": Self.healthAgentLabel,
         "ProgramArguments": [guestPath(healthAgentExecutableHostPath)],
         "RootedSimulatorPath": true,
         "ProcessType": "Interactive",
         "RunAtLoad": true,
         "KeepAlive": true,
         "StandardErrorPath": guestPath(healthAgentLogPath),
         "EnvironmentVariables": ["YCODE_HEALTH_AGENT": "1"]]
    }

    /// The bundle built for this runtime's platform: `<dir>/YcodeHealth.app`
    /// on iOS, `<dir>/watchos/YcodeHealth.app` on watchOS; nil elsewhere (a
    /// signed image cannot be retagged for another platform).
    func healthAgentBuild(_ source: String) -> String? {
        switch runtimePlatform() {
        case .iOS: return source
        case .watchOS: return platformBuild(of: source)
        case .visionOS: return nil
        }
    }

    func stageHealthAgent() throws {
        let fm = FileManager.default
        guard let agent = healthAgent, fm.fileExists(atPath: agent + "/YcodeHealth"), let build = healthAgentBuild(agent) else {
            if fm.fileExists(atPath: healthAgentPlistPath) { try fm.removeItem(atPath: healthAgentPlistPath) }
            return
        }
        try fm.createDirectory(atPath: (healthAgentHostPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: healthAgentHostPath) { try fm.removeItem(atPath: healthAgentHostPath) }
        try fm.copyItem(atPath: build, toPath: healthAgentHostPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: healthAgentExecutableHostPath)
        let data = try PropertyListSerialization.data(fromPropertyList: healthAgentPlist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: healthAgentPlistPath), options: .atomic)
        if fm.fileExists(atPath: healthAgentLogPath) { try? fm.removeItem(atPath: healthAgentLogPath) }
        HealthDeviceFiles(dev: dev).applyShutDownEdits(log: { FileHandle.standardError.write(Data(("ycode-simd: health: " + $0 + "\n").utf8)) })
    }
}

/// A device's health files: the store, the queue of grants for its next
/// cold boot, the store's backups.
struct HealthDeviceFiles {
    let dev: String
    var store: HealthStore { HealthStore(dev: dev) }
    /// `grant <bundle id>` / `revoke <bundle id>` lines, applied at the next cold boot.
    var pendingPath: String { dev + "/ycode-pending-health.txt" }
    var backupsPath: String { dev + "/ycode-health-backups" }

    func pending() -> [String] {
        ((try? String(contentsOfFile: pendingPath, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.isEmpty }
    }

    func setPending(_ lines: [String]) {
        if lines.isEmpty {
            try? FileManager.default.removeItem(atPath: pendingPath)
        } else {
            try? (lines.joined(separator: "\n") + "\n").write(toFile: pendingPath, atomically: true, encoding: .utf8)
        }
    }

    /// Queues a grant or revoke; a later line for the same app replaces an earlier one.
    func queue(_ verb: String, _ bundleID: String) {
        setPending(pending().filter { !$0.hasSuffix(" " + bundleID) } + ["\(verb) \(bundleID)"])
    }

    /// The shut-down edits: the agent's grant, then the queued app grants.
    /// A grant whose app has not asked yet stays queued. Returns log lines.
    @discardableResult
    func applyShutDownEdits(log: (String) -> Void) -> [String] {
        let s = store
        guard s.exists else {
            log("no health store yet (first boot); the agent asks for access in this boot and is granted at the next cold boot")
            return []
        }
        var lines: [String] = []
        var still: [String] = []
        let queued = pending()
        let agentRows = (try? s.authorizationRows(bundleID: HealthChannel.agentBundleID)) ?? []
        let agentNeeds = agentRows.contains { $0.request == HealthAuthorizationCode.sharePresented && $0.status != HealthAuthorizationCode.sharingAuthorized }
        guard agentNeeds || !queued.isEmpty else {
            log(agentRows.isEmpty ? "the agent has not asked for access yet (it asks in this boot; granted at the next cold boot)"
                : "the agent's \(agentRows.count) grants are in place")
            return []
        }
        do {
            let backup = try s.backup(into: backupsPath, reason: "grants")
            lines.append("store backed up to \(backup)")
        } catch {
            log("no edits: the store's backup failed: \(error)")
            return []
        }
        if agentNeeds {
            do { lines.append("agent \(HealthChannel.agentBundleID): \(try s.grant(bundleID: HealthChannel.agentBundleID))") } catch {
                lines.append("agent grant failed: \(error)")
            }
        }
        for line in queued {
            let w = line.split(separator: " ").map(String.init)
            guard w.count == 2 else { continue }
            do {
                let r = w[0] == "revoke" ? try s.revoke(bundleID: w[1]) : try s.grant(bundleID: w[1])
                lines.append("\(w[0]) \(w[1]): \(r)")
                if r.rows == 0 { still.append(line) }
            } catch {
                lines.append("\(w[0]) \(w[1]) failed: \(error)")
                still.append(line)
            }
        }
        setPending(still)
        for l in lines { log(l) }
        return lines
    }
}
