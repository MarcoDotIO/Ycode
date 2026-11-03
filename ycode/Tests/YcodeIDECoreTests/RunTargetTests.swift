import Foundation
import Testing
import YcodeDebug
@testable import YcodeIDECore

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(15))) struct RunTargetTests {
    /// Lean boot was on by default until 2026-10-27, and every save stored
    /// it: a stored `true` under the old key is the old default and gives a
    /// full boot now, once; the user's later choice is kept (run.md).
    @Test func leanBootSettingMigratesToFullBoot() throws {
        let t = TestDefaults("remote-lean")
        defer { t.remove() }
        t.defaults.set(true, forKey: RemoteSimulatorSettings.leanBootLegacyKey)
        var s = RemoteSimulatorSettings.load(t.defaults)
        #expect(!s.leanBoot)
        // A save (of any setting) drops the old key and stores the choice.
        s.deviceName = "other"
        s.save(t.defaults)
        #expect(t.defaults.object(forKey: RemoteSimulatorSettings.leanBootLegacyKey) == nil)
        #expect(t.defaults.object(forKey: RemoteSimulatorSettings.leanBootKey) as? Bool == false)
        // Turned on again: remembered, and not undone by later loads.
        s.leanBoot = true
        s.save(t.defaults)
        #expect(RemoteSimulatorSettings.load(t.defaults).leanBoot)
        #expect(RemoteSimulatorSettings.load(t.defaults).leanBoot)
        #expect(RemoteSimulator(settings: RemoteSimulatorSettings.load(t.defaults)).leanBootVariables == "YCODE_LEAN_BOOT=daemons ")
    }
}
