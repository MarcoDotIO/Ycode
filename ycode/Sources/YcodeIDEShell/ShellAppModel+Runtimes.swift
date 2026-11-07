import Foundation
import YcodeIDECore

// The simulator runtime wizard in the Linux shell (`runtime-onboarding.md`
// §11): Window ▸ Downloads opens it (as Settings ▸ Components does on
// macOS), and the first launch offers it once when this computer has no
// runtime for the chosen platforms or must use a simulator host.
extension ShellAppModel {
    /// The wizard's window (its own window, as on macOS; cross-platform
    /// parity §11).
    public static let runtimeSetupWindowID = "runtime-setup"
    /// Closes the wizard's window (set by the window's view).
    @MainActor public static var dismissRuntimeSetupWindow: () -> Void = {}

    /// Opens the wizard (on `step`, else on the first problem once checked).
    public func showRuntimeSetup(step: RuntimeSetupStep? = nil) {
        let s = runtimeSetup ?? RuntimeSetupSession(defaults: runtimeDefaults)
        runtimeSetup = s
        openWindow(Self.runtimeSetupWindowID)
        let t = s.recheck()
        if let step { s.show(step) } else {
            Task { @MainActor in
                await t.value
                s.openOnFirstProblem()
            }
        }
    }

    public func closeRuntimeSetup() {
        runtimeSetup?.stop()
        runtimeSetup = nil
        Self.dismissRuntimeSetupWindow()
    }

    /// Once per installation (`RuntimeSetupChoices.offeredKey`); never with
    /// `YCODE_NO_FIRST_LAUNCH` or under the drivers.
    @discardableResult
    public func offerRuntimeSetupAtFirstLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) -> Task<Void, Never>? {
        let d = runtimeDefaults
        let drivers = ["YCODE_NO_FIRST_LAUNCH", "OV_QUIT_AFTER", "YCODE_IDE_SCRIPT", "YCODE_IDE_WALK", "YCODE_IDE_PARITY", "YCODE_IDE_REMOTE_RUN"]
        guard !d.bool(forKey: RuntimeSetupChoices.offeredKey), !drivers.contains(where: { environment[$0] != nil }) else { return nil }
        d.set(true, forKey: RuntimeSetupChoices.offeredKey)
        let choices = RuntimeSetupChoices.load(d)
        let machine = SetupMachine.current
        return Task { @MainActor [weak self] in
            let r = await RuntimeSetupChecker(machine: machine, choices: choices).run()
            if !machine.canRunSimulatorHere || choices.useHost || r.readyPlatforms.isEmpty { self?.showRuntimeSetup() }
        }
    }
}
