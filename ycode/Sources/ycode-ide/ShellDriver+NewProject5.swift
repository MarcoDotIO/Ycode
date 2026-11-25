import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// YCODE_IDE_NEWPROJECT5=<prefix>: beta 5's New Project walk (B5-NEWPROJECT),
// from Welcome (no path):
//
//   1. Welcome (the 37-point close button first; the recents list takes
//      the keyboard: Down moves the selection) (P-186, L-070, L-177)
//   2. File ▸ New ▸ Project…: the compact picker (P-187); Choose Template…
//   3. The template step: 720 × 480, five columns, the 202-point filter;
//      Right twice moves the selection; Tab to the filter, "Lib", Tab
//      back (P-181)
//   4. macOS ▸ Command Line Tool, Next: the options step (P-182), typed
//   5. Next: the save step with the new-workspace choice (L-154); Create
//   6. ⌘N: the New File sheet (P-187); Swift File, Next, Create
//   7. File ▸ New ▸ Window: a second window on the workspace; Close
//      Window closes it alone (P-022)
//
// YCODE_IDE_NEWPROJECT5_DIR is where the project is made. Each state writes
// <prefix>-<state>.png; each step prints "newproject5 <state>: …".
extension ShellDriver {
    #if os(Linux)
    static func newProject5Walk(_ app: ShellAppModel, prefix: String) async {
        guard app.workspace == nil else {
            say("newproject5: run without a path (Welcome)")
            return
        }
        func shot(_ state: String, window index: Int = 0) async {
            await pause(0.7)
            say("newproject5 \(state): windows \(OpenViewsAutomation.windowCount) scenes \(OpenViewsAutomation.windowSceneIDs) "
                + OpenViewsAutomation.screenshot(index, to: "\(prefix)-\(state).png"))
        }
        func waitFor(_ what: String, _ ok: () -> Bool) async {
            for _ in 0..<50 where !ok() { await pause(0.1) }
            if !ok() { say("newproject5: timed out waiting for \(what)") }
        }
        func frameText(_ name: String) -> String {
            frame(name).map { "\(name) \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "\(name) none"
        }
        // 1. Welcome.
        await shot("welcome")
        say("newproject5 welcome: \(frameText("welcome close")) \(frameText("welcome new project"))")
        if let first = app.recent.first {
            // A click gives the list focus (the accent selection); Down moves it.
            await click("recent \(RecentProjects.displayName(first))")
            await shot("welcome-recents-focused")
            // The pointer leaves the row (its path tooltip closes) before the key.
            OpenViewsAutomation.move(to: CGPoint(x: 240, y: 610))
            await pause(0.4)
            OpenViewsAutomation.press(.downArrow)
            await pause(0.2)
            OpenViewsAutomation.press(.downArrow)
            await pause(0.3)
            await shot("welcome-recents-keyboard")
        }

        // 2. The compact picker.
        app.showNewProjectPicker()
        await waitFor("the picker on a workspace window") { app.newProject?.step == .picker && app.workspaceWindowCount > 0 }
        await shot("picker")
        await click("new project row Choose Template…")
        guard let m = app.newProject else {
            say("newproject5: no New Project sheet")
            return
        }
        await waitFor("the template step") { m.step == .template }

        // 3. The template step and its keyboard.
        m.setPlatform("macOS")
        await pause(0.4)
        await shot("templates")
        say("newproject5 templates: \(frameText("new project filter")) \(frameText("new project tabs")) "
            + "\(frameText("template Framework")) \(frameText("template Library")) \(frameText("template Metal Library"))")
        let before = m.flow.selected?.title ?? "none"
        OpenViewsAutomation.press(.rightArrow)
        await pause(0.2)
        OpenViewsAutomation.press(.rightArrow)
        await pause(0.3)
        say("newproject5 keyboard: \(before) → \(m.flow.selected?.title ?? "none")")
        await shot("templates-keyboard")
        OpenViewsAutomation.press(.tab)
        await pause(0.2)
        OpenViewsAutomation.type("Lib")
        await pause(0.5)
        say("newproject5 filter: \"\(m.flow.filter)\" shows \(m.flow.sections.flatMap(\.entries).map(\.title))")
        await shot("templates-filter")
        m.setFilter("")
        m.select("macos.command-line-tool")
        await pause(0.3)

        // 4. Options.
        await click("new project next")
        await waitFor("the options step") { m.step == .options }
        await pause(0.6)
        await shot("options")
        OpenViewsAutomation.type("Walk Tool")
        await pause(0.2)
        OpenViewsAutomation.press(.tab)
        await pause(0.2)
        OpenViewsAutomation.type("org.ycode.walk")
        await pause(0.4)
        let rows = m.flow.form.visibleFields.map(\.id).compactMap { frame("option row \($0)") }
        let pitches = zip(rows.dropFirst(), rows).map { Int(($0.midY - $1.midY).rounded()) }
        say("newproject5 options: rows \(rows.map { Int($0.height) }) pitches \(pitches) \(frameText("option productName"))")
        await shot("options-filled")

        // 5. Save.
        await click("new project next")
        await waitFor("the save step") { m.step == .save }
        let dir = env["YCODE_IDE_NEWPROJECT5_DIR"] ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("ycode-newproject5-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        m.location = dir
        m.createGitRepository = false
        await shot("save")
        await click("new project next")
        await waitFor("the project to open") { app.workspace != nil }
        await pause(1.0)
        say("newproject5 created: \(app.workspace?.workspaceName ?? "none")")
        await shot("created")

        // 6. New File.
        _ = app.performMenuAction("newFile:")
        await waitFor("the New File sheet") { app.newFile != nil }
        guard let f = app.newFile else {
            say("newproject5: no New File sheet")
            return
        }
        f.setPlatform("macOS")
        f.select("Swift File")
        await shot("new-file")
        await click("new file next")
        await waitFor("the New File save step") { f.step == .save }
        f.saveAs = "Walk"
        await shot("new-file-save")
        await click("new file next")
        await waitFor("the file to open") { app.newFile == nil }
        await pause(0.8)
        let made = app.workspace?.root.children?.flatMap { $0.children ?? [] }.contains { $0.name.hasPrefix("Walk") } ?? false
        say("newproject5 new file: open \(app.workspace?.document?.path ?? "none") in navigator \(made)")
        await shot("new-file-created")

        // 7. A second window, then Close Window on it.
        _ = app.performMenuAction("newWorkspaceWindow:")
        await waitFor("a second workspace window") { app.workspaceWindowCount == 2 }
        await pause(0.8)
        say("newproject5 second window: count \(app.workspaceWindowCount) windows \(OpenViewsAutomation.windowCount)")
        await shot("window-1", window: 0)
        await shot("window-2", window: 1)
        _ = app.performMenuAction("performClose:")
        await waitFor("one workspace window") { app.workspaceWindowCount == 1 }
        await pause(0.5)
        say("newproject5 after Close Window: count \(app.workspaceWindowCount) windows \(OpenViewsAutomation.windowCount) workspace \(app.workspace?.workspaceName ?? "none")")
        await shot("window-closed")
    }
    #endif
}
