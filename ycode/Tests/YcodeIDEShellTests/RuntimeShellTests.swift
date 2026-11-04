import Foundation
import Testing
import YcodeBuild
import YcodeIDECore
import YcodeSimLink
@testable import YcodeIDEShell

/// B2-RUNTIME (#68, #69) in the Linux shell: Window ▸ Downloads opens the
/// runtime wizard, and a paired host that does not answer keeps a run
/// destination that says so and fails at once on Run, instead of waiting.
@MainActor
@Suite(.serialized) struct RuntimeShellTests {
    @Test func downloadsOpensTheWizard() {
        let d = TestShellDefaults()
        defer { d.remove() }
        let a = ShellAppModel(recentProjects: RecentProjects(defaults: d.defaults), engine: { PackageBuildEngine() })
        a.runtimeDefaults = d.defaults
        #expect(ShellCommand.downloads.menuCommand?.title == "Downloads")
        #expect(ShellCommand.downloads.shortcut?.text == "⇧⌘9")
        #expect(a.isEnabled(.downloads))
        a.perform(.downloads)
        #expect(a.runtimeSetup != nil)
        a.closeRuntimeSetup()
        #expect(a.runtimeSetup == nil)
        // The first-launch offer happens once, and never under a driver.
        #expect(a.offerRuntimeSetupAtFirstLaunch(environment: ["OV_QUIT_AFTER": "5"]) == nil)
        d.defaults.set(true, forKey: RuntimeSetupChoices.offeredKey)
        #expect(a.offerRuntimeSetupAtFirstLaunch(environment: [:]) == nil)
    }

    @Test func offlineHostKeepsADestinationThatSaysSo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LinkStore(directory: dir)
        // A paired host whose port nobody listens on.
        try store.addPeer(TrustedPeer(name: "sim-host", publicKey: Array(repeating: 7, count: 32), role: "host", address: "127.0.0.1:9", mediaPort: 10))
        let start = Date()
        let groups = ShellRemoteRun.destinationGroups(store: store)
        #expect(Date().timeIntervalSince(start) < 8)
        let row = try #require(groups.first?.destinations.first)
        #expect(row.name == "sim-host is offline")
        #expect(ShellRemoteRun.target(of: row)?.host == "sim-host" && ShellRemoteRun.target(of: row)?.device == "")
        do {
            _ = try await ShellRemoteRun.run(project: "/nonexistent", scheme: "S", destination: row, packageRoot: dir) { _ in }
            Issue.record("expected the offline error")
        } catch {
            #expect("\(error)" == ShellRemoteRun.offlineMessage(host: "sim-host"))
        }
    }
}
