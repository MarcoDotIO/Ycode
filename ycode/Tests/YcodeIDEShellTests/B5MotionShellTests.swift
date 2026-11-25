import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// Beta 5's motion layer in the Linux IDE's model (B5-MOTION, P-192):
/// ⌥⌘1/⌥⌘2 on the inspector already shown hides it and the next press
/// shows it again, each on the selector's curves; another tab only
/// switches; the inspector's own tabs never hide it.
@MainActor
@Suite(.serialized) struct B5MotionShellTests {
    @Test func inspectorCommandsToggleTheShownInspector() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let model = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        _ = PaneMotion.takeInspectorSelector()
        model.isInspectorShown = true
        model.languageFeatures.inspectorTab = .file
        model.perform(.showFileInspector)
        #expect(!model.isInspectorShown && PaneMotion.takeInspectorSelector())
        model.perform(.showFileInspector)
        #expect(model.isInspectorShown && model.languageFeatures.inspectorTab == .file && PaneMotion.takeInspectorSelector())
        // Another tab switches, with no slide.
        model.perform(.showQuickHelpInspector)
        #expect(model.isInspectorShown && model.languageFeatures.inspectorTab == .quickHelp && !PaneMotion.takeInspectorSelector())
        // The inspector's own tab buttons only select.
        model.showInspector(.quickHelp)
        #expect(model.isInspectorShown)
        // The curves the window takes for them.
        #expect(Motion.inspector(show: false, bySelector: true).duration > Motion.inspector(show: false).duration)
    }
}
