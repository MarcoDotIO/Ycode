import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeIDEShell
import YcodeProject
@testable import YcodeUI

/// A tester's walk through the AppKit IDE, offscreen. With `YCODE_WALK_DIR`
/// and `YCODE_WALK_PACKAGE` (the Greeter package of
/// `scripts/linux-ui-parity/make-demo.sh`) set, it writes a PNG of each state
/// and `menus-*.txt`, the menu bar's enabled items in that state, so a person
/// can look through them. It asserts nothing and never runs without the variables.
@MainActor
@Suite(.serialized) struct BetaWalkProbeTests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YCODE_WALK_DIR"]
    nonisolated static let package = ProcessInfo.processInfo.environment["YCODE_WALK_PACKAGE"]

    @Test(.enabled(if: outDir != nil && package != nil)) func walk() async throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let prefs = IsolatedPreferences("beta-walk")
        defer { prefs.restore() }
        let dir = URL(fileURLWithPath: try #require(Self.package))
        for appearance in ProcessInfo.processInfo.environment["YCODE_WALK_APPEARANCES"]?.split(separator: ",").map(String.init) ?? ["light", "dark"] {
            try await states(dir, appearance: appearance, out: out)
        }
    }

    func states(_ dir: URL, appearance: String, out: URL) async throws {
        let look = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        func shot(_ win: NSWindow, _ state: String) throws {
            win.contentView?.layoutSubtreeIfNeeded()
            try LinuxParityProbeTests.write(window: win, name: "\(appearance)-\(state)", to: out)
        }
        func settle(_ s: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

        // First launch: no recents; then one.
        let td = TestDefaults("beta-walk-welcome")
        defer { td.remove() }
        let recents = RecentProjects(defaults: td.defaults)
        var welcome = WelcomeWindowController(recents: recents)
        welcome.window?.appearance = look
        try shot(try #require(welcome.window), "welcome-first-launch")
        welcome.window?.close()
        recents.note(dir)
        welcome = WelcomeWindowController(recents: recents)
        welcome.window?.appearance = look
        try shot(try #require(welcome.window), "welcome-recent")
        welcome.window?.close()

        // Settings, every pane.
        let settings = SettingsWindowController(prefs: Preferences(defaults: td.defaults), components: [])
        let sw = try #require(settings.window)
        sw.appearance = look
        for (i, title) in SettingsWindowController.paneTitles.enumerated() {
            settings.select(i)
            await settle(0.2)
            try shot(sw, "settings-\(i)-\(title.replacingOccurrences(of: " ", with: "-"))")
        }
        sw.close()

        // New Project, every platform tab.
        let sheet = NewProjectSheetController(defaults: td.defaults)
        let host = NSWindow(contentViewController: sheet)
        host.appearance = look
        host.setContentSize(NSSize(width: 760, height: 540))
        _ = sheet.view
        for (i, tab) in sheet.platforms.enumerated() {
            sheet.platformControl.selectedSegment = i
            sheet.platformControl.sendAction(sheet.platformControl.action, to: sheet.platformControl.target)
            await settle(0.1)
            try shot(host, "new-project-\(i)-\(tab.replacingOccurrences(of: " ", with: "-"))")
        }
        host.close()

        // The workspace.
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        session.engine = PackageBuildEngine()
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false, openFirstFile: false)
        let win = try #require(wc.window)
        win.appearance = look
        wc.applyDefaultLayout()
        wc.notificationWindowStateOverride = .frontmost
        wc.bezelReduceMotionOverride = true
        try shot(win, "workspace-no-destinations")
        try Self.menus(controller: wc, name: "\(appearance)-menus-workspace", to: out)

        // Controls a screen reader could not name.
        func unlabelled(_ v: NSView, _ out: inout [String]) {
            if let c = v as? NSControl, !v.isHidden, !(v is NSTextField), !(v is NSTableView), !(v is NSScroller) {
                let title = (c as? NSButton)?.title ?? ""
                let named = !title.isEmpty || !(c.accessibilityLabel() ?? "").isEmpty || !(c.toolTip ?? "").isEmpty || (c as? NSSegmentedControl) != nil || (c as? NSPopUpButton) != nil
                if !named { out.append("\(type(of: c)) image=\((c as? NSButton)?.image?.accessibilityDescription ?? "-") id=\(c.identifier?.rawValue ?? "-")") }
            }
            for s in v.subviews { unlabelled(s, &out) }
        }
        var nameless: [String] = []
        if let frame = win.contentView?.superview { unlabelled(frame, &nameless) }
        try nameless.joined(separator: "\n").write(to: out.appendingPathComponent("\(appearance)-unlabelled.txt"), atomically: true, encoding: .utf8)

        // Each navigator.
        for i in 0..<CommandTable.navigators.count {
            wc.navigator.select(i)
            await settle(0.2)
            try shot(win, "navigator-\(i)-\(CommandTable.navigators[i].replacingOccurrences(of: " ", with: "-"))")
        }
        wc.navigator.select(0)

        // A file, find, then a failing build, then a fixed build, tests and run.
        let greeting = session.model.root.allFiles.first { $0.name == "Greeting.swift" }?.path
        wc.open(path: try #require(greeting), line: nil)
        try shot(win, "file")
        wc.findInWorkspace(nil)
        wc.navigator.findField.stringValue = "Greeting"
        wc.navigator.find("Greeting")
        await settle(0.5)
        try shot(win, "find")

        // The assistant with no model configured: nothing answers at the address.
        Preferences.shared.codingAssistant.ollamaURL = "http://127.0.0.1:1"
        wc.setLeftPane(codingAssistant: true)
        await settle(0.5)
        try shot(win, "assistant-no-model")
        wc.setLeftPane(codingAssistant: false)

        // Destination pop-up contents with nothing available.
        var lines = ["destinations: \(wc.session.model.destinationGroups.map { "\($0)" })"]
        lines.append("scheme: \(session.scheme ?? "none") destination: \(session.destination.map(\.name) ?? "none")")
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("\(appearance)-destinations.txt"), atomically: true, encoding: .utf8)

        wc.buildProduct(nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        for _ in 0..<2400 where session.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
        if wc.buildBezelView != nil { try shot(win, "build-failed-bezel") }
        for _ in 0..<40 where wc.buildBezelView != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        wc.navigator.select(4)
        try shot(win, "build-failed-issues")
        wc.showDebugArea(true)
        try shot(win, "build-failed-log")
        wc.navigator.select(8)
        try shot(win, "build-failed-report")
        wc.navigator.select(0)

        // The error fixed: a build that succeeds, tests, Run, and the menus with a file open.
        let main = dir.appendingPathComponent("Sources/Greeter/main.swift")
        let before = try String(contentsOf: main, encoding: .utf8)
        try before.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains("deliberate error") }.joined(separator: "\n")
            .write(to: main, atomically: true, encoding: .utf8)
        defer { try? before.write(to: main, atomically: true, encoding: .utf8) }
        func finished() async {
            try? await Task.sleep(nanoseconds: 300_000_000)
            for _ in 0..<3000 where session.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        wc.buildProduct(nil)
        await finished()
        if wc.buildBezelView != nil { try shot(win, "build-succeeded-bezel") }
        for _ in 0..<40 where wc.buildBezelView != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        wc.navigator.select(8)
        await settle(0.3)
        try shot(win, "build-succeeded-reports")
        wc.navigator.select(0)
        wc.testProduct(nil)
        await finished()
        wc.navigator.select(5)
        await settle(0.3)
        try shot(win, "tests-ran")
        wc.navigator.select(0)
        try Self.menus(controller: wc, name: "\(appearance)-menus-file-open", to: out)
        wc.runProduct(nil)
        for _ in 0..<300 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !session.isBusy, !session.console.isEmpty { break }
        }
        await settle(0.5)
        try shot(win, "run-console")
        try "\(session.console)\n--- activity \(session.activity)".write(to: out.appendingPathComponent("\(appearance)-run-console.txt"), atomically: true, encoding: .utf8)
        wc.stopProduct(nil)

        // About.
        let about = AboutWindowController()
        about.window?.appearance = look
        try shot(try #require(about.window), "about")
        about.close()

        // What a failed open and a failed clone say.
        var errors: [String] = []
        do { _ = try WorkspaceModel(url: FileManager.default.temporaryDirectory) } catch {
            errors.append("open folder: \(error.localizedDescription) | \((error as NSError).localizedRecoverySuggestion ?? "")")
        }
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("beta-walk-broken-\(UUID().uuidString).xcodeproj")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "not a project".write(to: broken.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: broken) }
        do { _ = try WorkspaceModel(url: broken) } catch { errors.append("open broken: \(error.localizedDescription)") }
        do { _ = try WorkspaceModel(url: broken.appendingPathComponent("missing.xcodeproj")) } catch { errors.append("open missing: \(error.localizedDescription)") }
        do { try GitRepository.clone("/nonexistent/repository", into: FileManager.default.temporaryDirectory.appendingPathComponent("beta-walk-clone-\(UUID().uuidString)")) } catch {
            errors.append("clone: \(error.localizedDescription)")
        }
        try errors.joined(separator: "\n").write(to: out.appendingPathComponent("\(appearance)-errors.txt"), atomically: true, encoding: .utf8)

        // Device Hub with no simulator.
        let hub = DevicesController(devices: [], simulators: [])
        let hw = hub.makeWindow()
        hw.appearance = look
        await settle(0.3)
        try shot(hw, "device-hub-empty")
        hw.close()

        // Source Control on a repository with a change.
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent("beta-walk-repo-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: dir, to: repoDir)
        defer { try? FileManager.default.removeItem(at: repoDir) }
        _ = try GitRepository.initialize(at: repoDir)
        func git(_ args: String...) throws { _ = try GitRepository.run("/usr/bin/git", ["-C", repoDir.path, "-c", "user.name=T", "-c", "user.email=t@example.com"] + args) }
        try git("add", ".")
        try git("commit", "-qm", "first")
        try "// A change.\n".write(to: repoDir.appendingPathComponent("Sources/GreeterCore/New.swift"), atomically: true, encoding: .utf8)
        let repoSession = WorkspaceSession(model: try WorkspaceModel(url: repoDir))
        repoSession.engine = PackageBuildEngine()
        let rc = WorkspaceWindowController(session: repoSession, loadDestinations: false, startLanguageService: false, openFirstFile: false)
        let rw = try #require(rc.window)
        rw.appearance = look
        rc.applyDefaultLayout()
        rc.refreshFileStatus(nil)
        rc.navigator.select(1)
        await settle(1.5)
        try shot(rw, "source-control-changes")
        rw.close()

        // Organizer, Gauge, scheme editor.
        let archives = FileManager.default.temporaryDirectory.appendingPathComponent("beta-walk-archives-\(UUID().uuidString)")
        let org = OrganizerController(archivesDirectory: archives)
        let ow = NSWindow(contentViewController: org)
        ow.title = "Organizer"
        ow.appearance = look
        try shot(ow, "organizer-empty")
        ow.close()
        win.close()
    }

    /// The menu bar's items with what validation says now: "on" or "off".
    static func menus(controller wc: WorkspaceWindowController, name: String, to out: URL) throws {
        let bar = MainMenu.make()
        var lines: [String] = []
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items where !item.isSeparatorItem {
                let p = path + " > " + item.title
                if let sub = item.submenu { walk(sub, p); continue }
                guard let action = item.action else { lines.append("none \(p)"); continue }
                let t: AnyObject? = item.target ?? (wc.responds(to: action) ? wc : nil)
                var on = t != nil
                if let t, t === wc { on = wc.validateMenuItem(item) }
                lines.append("\(on ? "on  " : "off ") \(p)  [\(NSStringFromSelector(action))]")
            }
        }
        for item in bar.items { if let m = item.submenu { walk(m, item.title) } }
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }
}
