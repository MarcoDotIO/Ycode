import AppKit
import YcodeSimFeatures

/// The debug bar's Environment Overrides and Simulate Location for an app
/// running on the Ycode simulator (`specs/ide/debug.md` §Environment
/// Overrides): each change is one control command through ssh to the run's
/// device (`overrides <bundle id> …`, `location …`).
extension WorkspaceWindowController {
    func wireSimulatorDebugBar() {
        debugArea.simulatorRunKey = { [weak self] in
            guard let r = self?.session.simulatorRun, case .remote = r.target, r.exitStatus == nil, r.remote != nil else { return nil }
            return "\(r.app.bundleID)#\(r.remotePID ?? 0)"
        }
        debugArea.applyEnvironmentOverrides = { [weak self] overrides in
            guard let self, let r = self.session.simulatorRun, case .remote = r.target, let remote = r.remote else {
                return (false, "No app is running on the Ycode simulator.")
            }
            return await self.session.controlRemoteSimulator(remote: remote, overrides.commandWords(bundleID: r.app.bundleID))
        }
        debugArea.simulateLocationHandler = { [weak self] words in
            guard let self, let r = self.session.simulatorRun, case .remote = r.target, let remote = r.remote else {
                return (false, "No app is running on the Ycode simulator.")
            }
            return await self.session.controlRemoteSimulator(remote: remote, ["location"] + words)
        }
    }
}
