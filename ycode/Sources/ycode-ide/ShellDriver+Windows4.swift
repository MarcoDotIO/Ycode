import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// YCODE_IDE_WINDOWS4=<prefix>: beta 4's window walk (B4-WINDOWS), from
// Welcome (no path):
//
//   1. Welcome; its New Project button: Welcome closes and the template
//      sheet opens on an empty workspace window (P-177, P-023)
//   2. macOS ▸ Command Line Tool, Next: the options step, Product Name
//      focused (P-178); typing the name, Tab, the organization
//   3. Next: the save step; Create: the project opens in the window
//   4. Window ▸ Welcome to Ycode: Welcome beside the workspace, which stays
//      open (P-216)
//   5. About, closed with Escape; a notice alert with Ycode's icon
//
// YCODE_IDE_WINDOWS4_DIR is where the project is made (default: a new
// folder under the system's temporary folder). Each state writes
// <prefix>-<state>.png; each step prints "windows4 <state>: …".
extension ShellDriver {
    #if os(Linux)
    static func windows4Walk(_ app: ShellAppModel, prefix: String) async {
        guard app.workspace == nil else {
            say("windows4: run without a path (Welcome)")
            return
        }
        func shot(_ state: String, window index: Int = 0) async {
            await pause(0.7)
            say("windows4 \(state): windows \(OpenViewsAutomation.windowCount) scenes \(OpenViewsAutomation.windowSceneIDs) "
                + OpenViewsAutomation.screenshot(index, to: "\(prefix)-\(state).png"))
        }
        func waitFor(_ what: String, _ ok: () -> Bool) async {
            for _ in 0..<40 where !ok() { await pause(0.1) }
            if !ok() { say("windows4: timed out waiting for \(what)") }
        }
        await shot("welcome")
        await click("welcome new project")
        await waitFor("the New Project sheet on a workspace window") {
            app.newProject != nil && OpenViewsAutomation.windowSceneIDs == [ShellWindowID.workspace]
        }
        await shot("templates")
        guard let m = app.newProject else {
            say("windows4: no New Project sheet")
            return
        }
        m.setPlatform("macOS")
        m.select("macos.command-line-tool")
        await pause(0.3)
        await click("new project next")
        await waitFor("the options step") { m.step == .options }
        await pause(0.5)
        let focus = OpenViewsAutomation.textInput()
        say("windows4 options: step \(m.step) text input \(focus.active)")
        await shot("options")
        // Typed as a person does: the name, Tab, the organization.
        OpenViewsAutomation.type("Walk Tool")
        await pause(0.2)
        OpenViewsAutomation.press(.tab)
        await pause(0.2)
        OpenViewsAutomation.type("org.ycode.walk")
        await pause(0.4)
        say("windows4 typed: product \"\(m.flow.form.productName)\" organization \"\(m.flow.form.organizationIdentifier)\" next \(m.isNextEnabled)")
        await shot("options-filled")
        await click("new project next")
        await waitFor("the save step") { m.step == .save }
        let dir = env["YCODE_IDE_WINDOWS4_DIR"] ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("ycode-windows4-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        m.location = dir
        m.createGitRepository = false
        await shot("save")
        await click("new project next")
        await waitFor("the project to open") { app.workspace != nil }
        say("windows4 created: \(app.workspace?.workspaceName ?? "none") in \(dir)")
        say(state(app))
        await pause(1.5)
        await shot("created")
        app.perform(.welcome)
        await waitFor("Welcome beside the workspace") { OpenViewsAutomation.windowCount == 2 }
        say("windows4 welcome-beside: workspace \(app.workspace?.workspaceName ?? "none") scenes \(OpenViewsAutomation.windowSceneIDs)")
        await shot("welcome-beside-workspace", window: OpenViewsAutomation.windowIndex(sceneID: ShellWindowID.welcome) ?? 1)
        let ws = OpenViewsAutomation.windowIndex(sceneID: ShellWindowID.workspace) ?? 0
        await shot("workspace-kept", window: ws)
        // Alerts show Ycode's icon; About closes on Escape (orchestrator's requests).
        app.notice = ShellNotice("Walk Notice", "An alert with the app's icon.")
        for _ in 0..<20 where OpenViewsAutomation.openPopupCount == 0 { await pause(0.1) }
        await pause(0.4)
        say("windows4 alert-icon: notice \(app.notice != nil) popups \(OpenViewsAutomation.openPopupCount) "
            + OpenViewsAutomation.screenshotWithPopups(ws, to: "\(prefix)-alert-icon.png"))
        OpenViewsAutomation.press(.return, window: ws)
        await pause(0.4)
        say("windows4 alert after Return: shown=\(app.notice != nil)")
        app.isAboutShown = true
        await shot("about", window: ws)
        OpenViewsAutomation.press(.escape, window: ws)
        await pause(0.5)
        say("windows4 about after Escape: shown=\(app.isAboutShown)")
    }
    #endif
}
