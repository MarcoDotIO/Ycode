// Staging Ycode's guest pairing agent into a device
// (specs/simulator/device-pairing.md P-4, §8). As the settings agent
// (SettingsAgentStaging.swift): the binary is copied to
// DEV/data/Library/Ycode/bin and run by launchd_sim from
// DEV/data/Library/LaunchDaemons/dev.ycode.simulator.pairing.plist
// (RunAtLoad, KeepAlive, Interactive; `user/<uid>` on iOS, `system` on
// watchOS), its stderr in DEV/data/tmp/ycode-pairing-agent.log. Every device
// gets it when the binary is there, paired or not: a phone whose watch was
// unpaired while it was stopped removes the pair in its guest at its next
// boot (remove-unpaired, §3.1). Without a binary the plist is removed.

import Foundation

extension DeviceLayout {
    static let pairingAgentLabel = "dev.ycode.simulator.pairing"
    var pairingAgentHostPath: String { data + "/Library/Ycode/bin/ycode-pairing-agent" }
    var pairingAgentPlistPath: String { data + "/Library/LaunchDaemons/\(Self.pairingAgentLabel).plist" }
    var pairingAgentLogPath: String { data + "/tmp/ycode-pairing-agent.log" }
    /// The agent's own notes across its restarts (a call that ended the
    /// process is not tried again in this boot).
    var pairingAgentStatePath: String { data + "/tmp/ycode-pairing-agent.state" }

    var pairingAgentPlist: [String: Any] {
        ["Label": Self.pairingAgentLabel,
         "ProgramArguments": [guestPath(pairingAgentHostPath)],
         "RootedSimulatorPath": true,
         "ProcessType": "Interactive",
         "RunAtLoad": true,
         "KeepAlive": true,
         "StandardErrorPath": guestPath(pairingAgentLogPath),
         "EnvironmentVariables": ["YCODE_PAIRING_AGENT": "1",
                                  "YCODE_PAIRING_AGENT_STATE": guestPath(pairingAgentStatePath)]]
    }

    func stagePairingAgent() throws {
        let fm = FileManager.default
        guard let agent = pairingAgent, fm.fileExists(atPath: agent), try stageImage(agent, to: pairingAgentHostPath, mode: 0o755) else {
            if fm.fileExists(atPath: pairingAgentPlistPath) { try fm.removeItem(atPath: pairingAgentPlistPath) }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: pairingAgentPlist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: pairingAgentPlistPath), options: .atomic)
        for path in [pairingAgentLogPath, pairingAgentStatePath] where fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }
    }
}
