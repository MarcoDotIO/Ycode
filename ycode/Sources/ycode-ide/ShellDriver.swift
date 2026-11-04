import Foundation
import SwiftUI
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// Automation for the done-criterion runs on OpenViews (Linux). Switches:
//
//   OV_PRINT_TARGETS=1      print "target <name> x y w h pixels x y w h" for
//                           every view with a driver name (`shellTarget`),
//                           the menu titles ("target menu_<title>") and the
//                           items of an open menu ("target item_<title>"),
//                           in window points then pixels, every second
//   OV_QUIT_AFTER=<s>       report the state every second and quit after s
//                           seconds; OV_SHOT_REQUEST=<file>: a driver
//                           writes a PNG path there to get a screenshot;
//                           OV_SCREENSHOT=<file> is written before quitting
//   YCODE_IDE_REMOTE_RUN=<destination name>  choose that run destination (a
//                           Ycode simulator host's device, ShellRemoteRun) and
//                           Product ▸ Run with the pointer; shots
//                           <prefix>-remote-*.png (REMOTE-X86)
//   YCODE_IDE_EDITOR_BENCH=<file>  open that file and measure the editor:
//                           opening, scrolling, typing, a page jump
//                           (docs/PARITY.md §5.9; EditorBench.swift)
//   YCODE_IDE_SCRIPT=1      drive the window with synthetic input through
//                           the back end's queue (expand a folder, open a
//                           file, Find in Workspace, Product ▸ Build, open
//                           the first issue; then OpenViews R13's: a
//                           submenu shortcut, the Run button's tooltip,
//                           View ▸ Navigators, File ▸ Open…'s dialog),
//                           printing the state after each
//                           step; YCODE_IDE_SHOT_PREFIX=<p> writes
//                           <p>-<step>.png; YCODE_IDE_SCRIPT_FILE names the
//                           file to open (default: the first .swift file
//                           under Sources), YCODE_IDE_FIND the query
//
//   YCODE_IDE_RUNTIME_WALK=<p>  the simulator runtime wizard, every step
//                           (ShellDriver+Runtimes.swift); writes <p>-runtime-*.png
//   YCODE_IDE_IME=1         open a file for a test with a real input method
//                           and report the composition
//                           (ShellDriverInputMethod.swift)
//
//   YCODE_IDE_SCM=<p>       source control's walk (ShellDriver+SourceControl.swift)
//   YCODE_IDE_TESTS=<p>     testing's walk (ShellDriver+Tests.swift)
//   YCODE_IDE_WALK=<p>      a tester's walk: Welcome, About, Clone, New Project
//                           (each tab) with no path; with a path every
//                           navigator, the menus, Build, Test, Run; writes
//                           <p>-<state>.png and quits
//
// OV_COLOR_SCHEME=dark (OpenViews' platform setting) starts in dark mode.

@MainActor
enum ShellDriver {
    static let env = ProcessInfo.processInfo.environment

    static func say(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    /// One line of the model's state, for logs and checks.
    static func state(_ app: ShellAppModel) -> String {
        guard let w = app.workspace else { return "state: welcome recent=\(app.recent.count)" }
        let c = w.issueCounts
        return "state: workspace=\(w.workspaceName) navigator=\(w.navigator.rawValue) document=\(w.document?.name ?? "none") "
            + "lines=\(w.editor?.buffer.lineCount ?? 0) edited=\(w.editedPaths.count) caret=\(w.editor.map { "\($0.buffer.caretLine + 1):\($0.buffer.caretColumn + 1)/\($0.buffer.selection.range.count)" } ?? "-") length=\(w.editor?.buffer.length ?? 0) findbar=\(w.findBar.isShown ? "\"" + w.findBar.countText + "\"" : "hidden") jump=\(w.isJumpToLineShown) alert=\(w.saveAlert != nil) marked=\(w.markedLine.map(String.init) ?? "none") "
            + "find=\"\(w.findText)\" results=\"\(w.findCountText)\" issues=\(c.errors)E/\(c.warnings)W "
            + "activity=\"\(w.activityText)\" builds=\(w.buildCount) debugArea=\(w.isDebugAreaShown) "
            + "inspector=\(w.isInspectorShown) navigatorShown=\(w.isNavigatorShown) findFocus=\(w.findFocusCount) bezel=\"\(w.notifier.bezel?.title ?? "")\""
    }

    #if os(Linux)
    static var started = false

    static func start(_ app: ShellAppModel) async {
        guard !started else { return }
        started = true
        // A normal launch prints nothing: everything below is for drivers.
        let switches = ["OV_PRINT_TARGETS", "OV_QUIT_AFTER", "YCODE_IDE_SCRIPT", "YCODE_IDE_PARITY", "YCODE_IDE_REMOTE_RUN", "YCODE_IDE_WALK",
                        "YCODE_IDE_DEBUG", "YCODE_IDE_SCM", "YCODE_IDE_TESTS", "YCODE_IDE_RUNTIME_WALK", "YCODE_IDE_SETTINGS",
                        "YCODE_IDE_SETTINGS_VERIFY", "YCODE_IDE_EDITORS", "YCODE_IDE_LSP",
                        "YCODE_IDE_IME"]
        guard switches.contains(where: { env[$0] != nil }) else { return }
        await pause(0.4)
        say("backend \(OpenViewsAutomation.backendName)")
        if let s = OpenViewsAutomation.windowSize() {
            say("window \(s.points.width)x\(s.points.height) pt, pixels \(s.pixels.width)x\(s.pixels.height)")
        }
        say("menus: \(OpenViewsAutomation.menuTitles())")
        say(state(app))
        if env["OV_PRINT_TARGETS"] != nil { printTargets() }
        if env["YCODE_IDE_SCRIPT"] != nil { await script(app) }
        if let prefix = env["YCODE_IDE_PARITY"] { await parity(app, prefix: prefix) }
        if let file = env["YCODE_IDE_EDITOR_BENCH"] { await EditorBench.run(app, file: file) }
        if let name = env["YCODE_IDE_REMOTE_RUN"] { await remoteRun(app, destination: name) }
        if let prefix = env["YCODE_IDE_WALK"] { await walk(app, prefix: prefix) }
        if let prefix = env["YCODE_IDE_EDITORS"] { await EditorsDriver.run(app, prefix: prefix) }
        if let prefix = env["YCODE_IDE_SETTINGS"] { await SettingsDriver.run(app, prefix: prefix) } else if env["YCODE_IDE_SETTINGS_VERIFY"] != nil { say(SettingsDriver.values()) }
        if let prefix = env["YCODE_IDE_LSP"] { await LanguageDriver.run(app, prefix: prefix) }   // LanguageDriver.swift
        if env["YCODE_IDE_IME"] != nil { await prepareInputMethodTest(app) }  // ShellDriverInputMethod.swift
        if let prefix = env["YCODE_IDE_DEBUG"] { await DebugDriver.run(app, prefix: prefix) }
        if let prefix = env["YCODE_IDE_SCM"] {
            await scmWalk(app, prefix: prefix)
            OpenViewsAutomation.terminate()
        }
        if let prefix = env["YCODE_IDE_TESTS"] {
            await testsWalk(app, prefix: prefix)
            OpenViewsAutomation.terminate()
        }
        if let prefix = env["YCODE_IDE_RUNTIME_WALK"] { await runtimeWalk(app, prefix: prefix) }
        if let s = env["OV_QUIT_AFTER"], let t = Double(s) {
            var elapsed = 0.0
            while elapsed < t {
                await pause(0.25)
                elapsed += 0.25
                if let req = env["OV_SHOT_REQUEST"], let path = try? String(contentsOfFile: req, encoding: .utf8) {
                    try? FileManager.default.removeItem(atPath: req)
                    // "<n>:<path>" photographs the n-th window (1: Settings).
                    let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let colon = p.firstIndex(of: ":"), let n = Int(p[..<colon]) {
                        say(OpenViewsAutomation.screenshot(n, to: String(p[p.index(after: colon)...])))
                    } else {
                        say(OpenViewsAutomation.screenshot(to: p))
                    }
                }
                if Int(elapsed * 4) % 4 == 0 || env["YCODE_IDE_STATE_FAST"] != nil {
                    if env["OV_PRINT_TARGETS"] != nil { printTargets() }
                    say(state(app))
                }
            }
            if let path = env["OV_SCREENSHOT"] { say(OpenViewsAutomation.screenshot(to: path)) }
            say(state(app))
            OpenViewsAutomation.terminate()
        }
    }

    static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static var scale: Double {
        guard let s = OpenViewsAutomation.windowSize(), s.points.width > 0 else { return 1 }
        return Double(s.pixels.width) / s.points.width
    }

    static func printTargets() {
        // A second window's named views ("w1target", its own points).
        for (name, f) in OpenViewsAutomation.identifiedFrames(1).sorted(by: { $0.key < $1.key }) {
            say(String(format: "w1target %@ %.0f %.0f %.0f %.0f", name.replacingOccurrences(of: " ", with: "_"), f.minX, f.minY, f.width, f.height))
        }
        let k = scale
        func line(_ name: String, _ f: CGRect) -> String {
            String(format: "target %@ %.0f %.0f %.0f %.0f pixels %.0f %.0f %.0f %.0f", name.replacingOccurrences(of: " ", with: "_"),
                   f.minX, f.minY, f.width, f.height, f.minX * k, f.minY * k, f.width * k, f.height * k)
        }
        let titles = Set(OpenViewsAutomation.menuTitles())
        var seen = Set<String>()
        for t in OpenViewsAutomation.texts() {
            let name = t.inPopup ? "item_" + t.text : (titles.contains(t.text) ? "menu_" + t.text : "")
            guard !name.isEmpty, t.frame.minY < 40 || t.inPopup, seen.insert(name).inserted else { continue }
            say(line(name, t.frame))
        }
        // (Project navigator rows are among them: "row <file name>", the
        // whole row.)
        for (name, f) in OpenViewsAutomation.identifiedFrames().sorted(by: { $0.key < $1.key }) { say(line(name, f)) }
        // The texts of the navigator's rows ("row_<text>", the text's own
        // frame, printed last), for drivers that click beside a text.
        for t in OpenViewsAutomation.texts() where !t.inPopup && inNavigator(t.frame) {
            guard seen.insert("row_" + t.text).inserted else { continue }
            say(line("row_" + t.text, t.frame))
        }
    }

    /// Where the navigator's rows are: under the selector bar, left of the
    /// editor.
    static func inNavigator(_ f: CGRect) -> Bool {
        let top = frame("selector 0")?.maxY ?? 100
        let right = frame("editor")?.minX ?? 290
        return f.minY > top + 4 && f.maxX < right
    }

    static func frame(_ name: String) -> CGRect? { OpenViewsAutomation.identifiedFrames()[name] }

    static func click(_ name: String, dx: CGFloat? = nil) async {
        guard let f = frame(name) else {
            say("no target \(name)")
            return
        }
        await OpenViewsAutomation.click(at: CGPoint(x: dx.map { f.minX + $0 } ?? f.midX, y: f.midY))
        await pause(0.35)
    }

    static func clickText(_ text: String, inPopup: Bool) async {
        guard let t = OpenViewsAutomation.texts().first(where: { $0.text == text && $0.inPopup == inPopup }) else {
            say("no text \(text)")
            return
        }
        await OpenViewsAutomation.click(at: CGPoint(x: t.frame.midX, y: t.frame.midY))
        await pause(0.4)
    }

    /// Clicks a text of the navigator area, `dx` from its start (the
    /// disclosure triangles are left of the texts).
    static func clickNavigatorText(_ text: String, dx: CGFloat) async {
        guard let t = OpenViewsAutomation.texts().first(where: { !$0.inPopup && $0.text == text && inNavigator($0.frame) })
        else {
            say("no navigator text \(text)")
            return
        }
        await OpenViewsAutomation.click(at: CGPoint(x: t.frame.minX + dx, y: t.frame.midY))
        await pause(0.35)
    }

    /// Clicks the Project navigator's row `id`, `dx` from the start of its
    /// text. Rows are found by their text, and titles repeat (a package and
    /// its main target's folder share a name, and file extensions may be
    /// hidden), so this is the row's text that comes as many times after the
    /// others with that title as the row does in the model's rows.
    static func clickProjectRow(_ w: WorkspaceShellModel, id: String, dx: CGFloat) async {
        let rows = w.projectRows
        guard let index = rows.firstIndex(where: { $0.id == id }) else {
            say("no project row \(id)")
            return
        }
        let title = rows[index].title
        let nth = rows[..<index].filter { $0.title == title }.count
        let texts = OpenViewsAutomation.texts().filter { !$0.inPopup && $0.text == title && inNavigator($0.frame) }
            .sorted { $0.frame.minY < $1.frame.minY }
        guard texts.indices.contains(nth) else {
            say("no navigator text \(title) (row \(nth + 1) with that title)")
            return
        }
        let f = texts[nth].frame
        await OpenViewsAutomation.click(at: CGPoint(x: f.minX + dx, y: f.midY))
        await pause(0.35)
    }

    static func shot(_ step: String) {
        if let p = env["YCODE_IDE_SHOT_PREFIX"] { say(OpenViewsAutomation.screenshot(to: "\(p)-\(step).png")) }
    }

    /// Run on a Ycode simulator host's device (REMOTE-X86).
    static func remoteRun(_ app: ShellAppModel, destination name: String) async {
        guard let w = app.workspace else { say("remote run: no workspace"); return }
        say("destinations: \(w.destinations.map(\.name))")
        guard let d = w.destinations.first(where: { $0.name == name }) else { say("remote run: no destination \(name)"); return }
        w.destination = d
        await pause(0.5)
        shot("remote-destination")
        await clickText("Product", inPopup: false)
        await clickText("Run", inPopup: true)
        for _ in 0..<240 {
            await pause(0.5)
            if w.console.contains("Installing and launching") || w.console.contains("failed") { break }
        }
        say("remote run console: \(w.console.split(separator: "\n").suffix(4).joined(separator: " | "))")
        await pause(1)
        shot("remote-run")
    }

    /// The done-criterion steps with synthetic input (no external tool).
    static func script(_ app: ShellAppModel) async {
        guard let w = app.workspace else {
            say("script: no workspace")
            return
        }
        func step(_ label: String) { say("step \(label): \(state(app))") }
        step("opened")
        shot("open")
        // Open a file: expand the folders above it with their chevrons,
        // then click its row.
        let target = env["YCODE_IDE_SCRIPT_FILE"].flatMap { name in w.root.allFiles.first { $0.name == name } }
            ?? w.root.allFiles.first { $0.name.hasSuffix(".swift") && ($0.path ?? "").contains("/Sources/") }
        if let file = target, let path = file.path, let ids = w.root.idPath(to: path) {
            for id in ids.dropLast() where !w.isExpanded(id) {
                await pause(0.3)
                // The disclosure triangle is left of the folder icon.
                await clickProjectRow(w, id: id, dx: -26)
            }
            await pause(0.3)
            await clickProjectRow(w, id: file.id, dx: 10)
            await pause(0.5)
        }
        step("selected a file")
        // Selecting a file's row opens it. (Issue 25: the step looked rows
        // up by the file's name, which the navigator shows without its
        // extension, and expanded a folder by clicking the first row with
        // its name, the package's own row, which collapsed the package.)
        if let file = target {
            say("check selected a file: \(w.document?.name == file.name ? "ok" : "FAILED") (\(file.name))")
        }
        shot("file")
        // Find in Workspace: Ctrl+Shift+F, the query, Return.
        OpenViewsAutomation.press(.character("f"), modifiers: [.control, .shift])
        await pause(0.4)
        OpenViewsAutomation.type(env["YCODE_IDE_FIND"] ?? "Greeting")
        await pause(0.2)
        OpenViewsAutomation.press(.return)
        for _ in 0..<40 where w.isSearching || w.findRows.isEmpty { await pause(0.1) }
        await pause(0.4)
        step("find in workspace")
        shot("find")
        // Product ▸ Build with the pointer, then wait for the build.
        await clickText("Product", inPopup: false)
        shot("product-menu")
        await clickText("Build", inPopup: true)
        await pause(0.5)
        for _ in 0..<600 where w.isBusy { await pause(0.25) }
        await pause(0.8)
        step("built")
        shot("build")
        // Open the first issue.
        if let first = w.allIssues.first(where: { $0.file != nil }) {
            await clickNavigatorText(first.message, dx: 20)
            await pause(0.6)
        }
        step("opened the first issue")
        shot("issue")
        await r13Steps(app)
        OpenViewsAutomation.terminate()
    }

    /// The Linux half of the paired screenshots (`docs/PARITY.md` §5.10,
    /// `LinuxParityProbeTests` on macOS): the same states in the same
    /// order, set through the model as the macOS probe sets them, each
    /// photographed as `<prefix>-<state>.png`. Without a workspace only
    /// Welcome is taken.
    static func parity(_ app: ShellAppModel, prefix: String) async {
        func shot(_ state: String) async {
            await pause(0.6)
            say("parity \(state): " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(state).png"))
        }
        guard let w = app.workspace else {
            await shot("welcome")
            OpenViewsAutomation.terminate()
            return
        }
        await shot("workspace")
        if let file = w.root.allFiles.first(where: { $0.name == (env["YCODE_IDE_SCRIPT_FILE"] ?? "Greeting.swift") }), let p = file.path {
            w.open(p)
        }
        await shot("file")
        w.isInspectorShown = false
        await shot("inspector-hidden")
        w.isInspectorShown = true
        w.perform(.findInWorkspace)
        w.findText = env["YCODE_IDE_FIND"] ?? "Greeting"
        w.runFind()
        await w.waitForFind()
        await shot("find")
        // Product, open.
        await clickText("Product", inPopup: false)
        await shot("product-menu")
        OpenViewsAutomation.press(.escape)
        OpenViewsAutomation.move(to: CGPoint(x: 700, y: 500))
        await pause(0.3)
        // A failed build: the bezel, then (once it has gone) the Issue
        // navigator with the debug area hidden, as on macOS.
        w.perform(.build)
        await pause(0.3)
        for _ in 0..<1200 where w.isBusy { await pause(0.1) }
        if w.notifier.bezel != nil { await shot("bezel") }
        for _ in 0..<60 where w.notifier.bezel != nil { await pause(0.1) }
        w.isDebugAreaShown = false
        w.navigator = .issues
        await shot("issues")
        w.isDebugAreaShown = true
        await shot("debug")
        w.isDebugAreaShown = false
        // File ▸ Open…: the dialog.
        app.showOpenSheet()
        await shot("sheet")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        OpenViewsAutomation.terminate()
    }

    /// A tester's walk (`YCODE_IDE_WALK`), through the model and the pointer.
    static func walk(_ app: ShellAppModel, prefix: String) async {
        func shot(_ name: String) async {
            await pause(0.7)
            say("walk \(name): \(state(app)) " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(name).png"))
        }
        func menu(_ title: String, _ name: String) async {
            await clickText(title, inPopup: false)
            await shot("menu-\(name)")
            OpenViewsAutomation.press(.escape)
            await pause(0.3)
        }
        guard let w = app.workspace else {
            await shot("welcome")
            await menu("Ycode", "ycode")
            await menu("Help", "help")
            app.perform(.about)
            await shot("about")
            app.isAboutShown = false
            await pause(0.8)
            app.perform(.clone)
            await shot("clone")
            if let c = app.clone {
                c.address = "file:///nonexistent/Repository.git"
                await c.clone().value
                await shot("clone-failed")
            }
            app.cancelClone()
            await pause(0.8)
            app.showNewProject()
            await shot("new-project")
            if let m = app.newProject {
                for tab in m.flow.tabs {
                    m.setPlatform(tab)
                    await shot("new-project-\(tab)")
                }
                m.setPlatform(m.flow.tabs[1])
                m.next()
                await shot("new-project-options")
            }
            app.cancelNewProject()
            await pause(0.8)
            app.notice = ShellNotice("Sample", "A long message that wraps over more than one line, to look at how the alert sets its text and where its button goes.")
            await shot("notice")
            app.notice = nil
            await pause(0.5)
            // The round close button ends the app: it is the only window.
            await click("welcome close")
            await pause(2)
            say("walk: still running after Close")
            OpenViewsAutomation.terminate()
            return
        }
        await shot("workspace")
        for i in 0..<9 {
            await click("selector \(i)")
            await shot("navigator-\(i)")
        }
        await click("selector 0")
        await menu("File", "file")
        await menu("Edit", "edit")
        await menu("View", "view")
        await menu("Find", "find")
        await menu("Navigate", "navigate")
        await menu("Editor", "editor")
        await menu("Product", "product")
        await menu("Debug", "debug")
        await menu("Integrate", "integrate")
        await menu("Window", "window")
        await menu("Help", "help")
        await click("tb destination")
        await shot("destination-menu")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        w.perform(.build)
        await pause(0.5)
        while w.isBusy { await pause(0.1) }
        await shot("after-build")
        for _ in 0..<60 where w.notifier.bezel != nil { await pause(0.1) }
        await shot("after-build-settled")
        say("walk build log: \(w.buildLog.suffix(12).joined(separator: " | "))")
        w.perform(.test)
        await pause(0.5)
        while w.isBusy { await pause(0.1) }
        await shot("after-test")
        say("walk test log: \(w.buildLog.suffix(8).joined(separator: " | "))")
        w.perform(.run)
        for _ in 0..<240 {
            await pause(0.25)
            if !w.isBusy && !w.console.isEmpty { break }
        }
        await pause(1)
        await shot("after-run")
        say("walk run console: \(w.console.suffix(600))")
        OpenViewsAutomation.terminate()
    }

    /// OpenViews R13's features in the shell: a toolbar tooltip, View ▸
    /// Navigators as a submenu (and its shortcut before it was opened), the
    /// file dialog of File ▸ Open….
    static func r13Steps(_ app: ShellAppModel) async {
        guard let w = app.workspace else { return }
        // A shortcut inside the Navigators submenu, never opened so far.
        OpenViewsAutomation.press(.character("1"), modifiers: [.control])
        await pause(0.4)
        say("step submenu shortcut: navigator=\(w.navigator.rawValue)")
        // The tooltip of the Run button.
        if let run = frame("tb run") {
            OpenViewsAutomation.move(to: CGPoint(x: run.midX, y: run.midY))
            await pause(1.4)
            let tip = OpenViewsAutomation.texts().first { $0.text == "Build and run the scheme" }
            say("step tooltip: \(tip.map { "shown at \(Int($0.frame.minX)),\(Int($0.frame.minY))" } ?? "none")")
            shot("tooltip")
            OpenViewsAutomation.move(to: CGPoint(x: run.midX, y: run.maxY + 200))
            await pause(0.3)
        }
        // View ▸ Navigators.
        await clickText("View", inPopup: false)
        if let nav = OpenViewsAutomation.texts().first(where: { $0.inPopup && $0.text == "Navigators" }) {
            OpenViewsAutomation.move(to: CGPoint(x: nav.frame.midX, y: nav.frame.midY))
            await pause(0.3)
            await OpenViewsAutomation.click(at: CGPoint(x: nav.frame.midX, y: nav.frame.midY))
            await pause(0.5)
        }
        let items = OpenViewsAutomation.texts().filter(\.inPopup).map(\.text)
        say("step submenu: \(OpenViewsAutomation.openPopupCount) pop-ups, items \(items)")
        shot("submenu")
        OpenViewsAutomation.press(.escape)
        await pause(0.2)
        OpenViewsAutomation.press(.escape)
        await pause(0.4)
        // File ▸ Open…: the dialog; open the same package through its Go to
        // field.
        OpenViewsAutomation.press(.character("o"), modifiers: [.control])
        await pause(0.8)
        say("step file dialog: shown=\(app.isOpenSheetShown) folder=\(OpenViewsAutomation.texts().first { $0.text.hasPrefix("/") }?.text ?? "?")")
        shot("file-dialog")
        if let field = frame("file dialog path") {
            await OpenViewsAutomation.click(at: CGPoint(x: field.midX, y: field.midY))
            await pause(0.3)
            OpenViewsAutomation.type(w.session.model.url.path)
            await pause(0.2)
            OpenViewsAutomation.press(.return)      // Go to: shows the folder
            await pause(0.6)
            shot("file-dialog-folder")
            OpenViewsAutomation.press(.return)      // Open: chooses it
            await pause(1.0)
        }
        say("step reopened: shown=\(app.isOpenSheetShown) \(state(app))")
        shot("reopened")
    }
    #else
    static func start(_ app: ShellAppModel) async {}
    #endif
}
