import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
import YcodeIDEShell
import YcodeSimFeatures
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The macOS half of the 2026-11-15 parity tour's menu table (PARITY-LINUX
/// phase 2; the Linux half is `YCODE_IDE_TOUR_PART=menus`,
/// `ShellDriver+Tour.swift`). With `YCODE_PARITY_MENU_DIR=<folder>` it
/// builds the menu bar (`MainMenu.make()`), brings every menu up to date as
/// `MenuBarDelegate` does when a menu opens, and decides each item's state
/// as AppKit's automatic enabling would: the item's target, else the first
/// object along the key window's responder chain, the window's delegate,
/// the application and its delegate that implements the action, then that
/// object's `validateMenuItem(_:)`. Writes `mac-menus-<context>.tsv`
/// (path, title, shortcut, action, tag, hidden, alternate, enabled, state)
/// for Welcome (no window), a workspace with nothing open and a workspace
/// with a Swift file in the focused editor (the Linux table's contexts).
/// Windows stay off every display (origin −6000, −6000; the offscreen guard
/// is on). It never runs without the variable.
@MainActor
@Suite(.serialized) struct ParityMenuTableTests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YCODE_PARITY_MENU_DIR"]

    func pump(_ s: Double = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// Where `table` also draws the changed menus (set by `menuTables`).
    static var shotDir: URL?
    static var shotState: String?

    @Test(.enabled(if: outDir != nil)) func menuTables() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let prefs = IsolatedPreferences("parity-menus")
        defer { prefs.restore() }
        CrossPlatformParityShotTests.KeyLook.on()
        defer { CrossPlatformParityShotTests.KeyLook.off() }
        let appDelegate = AppDelegate()

        let shots = ycodeDir.deletingLastPathComponent().appendingPathComponent(".build-ide/b4-shots")
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        Self.shotDir = shots
        defer { Self.shotDir = nil }
        // Welcome: nothing but the application and its delegate.
        Self.shotState = "welcome"
        write(table(window: nil, controller: nil, appDelegate: appDelegate), "welcome", to: out)

        let repos = out.appendingPathComponent("repos")
        try? FileManager.default.removeItem(at: repos)
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/bin/sh")
        make.arguments = [ycodeDir.appendingPathComponent("scripts/linux-ui-parity/make-parity5.sh").path, repos.path]
        make.standardOutput = FileHandle.nullDevice
        try make.run()
        make.waitUntilExit()
        let rest = repos.appendingPathComponent("rest/Merger")
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: rest)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false)
        let win = try #require(wc.window)
        win.isExcludedFromWindowsMenu = true
        wc.applyDefaultLayout()
        win.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        win.orderBack(nil)
        await wc.sourceControl.idle()
        if wc.editor.fileURL != nil { wc.closeDocument(nil) }
        pump()
        Self.shotState = "workspace"
        write(table(window: win, controller: wc, appDelegate: appDelegate), "workspace", to: out)

        wc.open(path: rest.appendingPathComponent("Sources/Merger/Sample.swift").path, line: nil)
        win.makeFirstResponder(wc.editor.textView)
        wc.editor.textView.setSelectedRange(NSRange(location: 60, length: 0))
        pump()
        Self.shotState = "Sample.swift"
        write(table(window: win, controller: wc, appDelegate: appDelegate), "Sample.swift", to: out)
        Self.shotState = nil

        // Opening a folder that holds an .xcodeproj (inventory row L-159).
        let folder = out.appendingPathComponent("folder-with-project")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Holder.xcodeproj"), withIntermediateDirectories: true)
        try "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 77; objects = {}; rootObject = A; }\n"
            .write(to: folder.appendingPathComponent("Holder.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        var result: String
        do {
            let m = try WorkspaceModel(url: folder)
            result = "opened as \(m.kind) \(m.displayName)"
        } catch { result = "refused: \(error)" }
        try result.write(to: out.appendingPathComponent("folder-with-project.txt"), atomically: true, encoding: .utf8)
        win.close()
    }

    /// One line per item, depth first.
    func table(window: NSWindow?, controller wc: WorkspaceWindowController?, appDelegate: AppDelegate) -> [String] {
        let bar = MainMenu.make()
        var lines = ["path\ttitle\tshortcut\taction\ttag\thidden\talternate\tenabled\tstate\ttarget"]
        func chain() -> [NSObject] {
            var out: [NSObject] = []
            var r: NSResponder? = window?.firstResponder
            while let x = r { out.append(x); r = x.nextResponder }
            if let w = window { out.append(w) }
            if let d = window?.delegate as? NSObject { out.append(d) }
            if let wc { out.append(wc) }
            out.append(NSApp)
            out.append(appDelegate)
            out.append(NSDocumentController.shared)
            return out
        }
        func walk(_ menu: NSMenu, _ path: String) {
            MenuBarDelegate.shared.update(menu, controller: wc)
            for item in menu.items {
                if item.isSeparatorItem || item.isSectionHeader { continue }
                if let sub = item.submenu {
                    lines.append([path, item.title + " ▸", "", "", "", item.isHidden ? "hidden" : "", "", "", "", ""].joined(separator: "\t"))
                    walk(sub, path + " ▸ " + item.title)
                    continue
                }
                var enabled = false
                var targetName = "none"
                if let action = item.action {
                    // An explicit target that does not perform the action disables the item.
                    let explicit = item.target as? NSObject
                    let target: NSObject? = explicit.map { $0.responds(to: action) ? $0 : nil } ?? chain().first { $0.responds(to: action) }
                    if let t = target {
                        targetName = String(describing: type(of: t))
                        if let v = t as? NSMenuItemValidation {
                            enabled = v.validateMenuItem(item)
                        } else if let v = t as? NSUserInterfaceValidations {
                            enabled = v.validateUserInterfaceItem(item)
                        } else { enabled = true }
                    }
                }
                let state = item.state == .on ? "on" : (item.state == .mixed ? "mixed" : "")
                lines.append([path, item.title, MainMenu.canonicalShortcut(item), item.action.map { NSStringFromSelector($0) } ?? "",
                              String(item.tag), item.isHidden ? "hidden" : "", item.isAlternate ? "alt" : "",
                              enabled ? "enabled" : "disabled", state, targetName].joined(separator: "\t"))
            }
        }
        for top in bar.items {
            guard let m = top.submenu else { continue }
            walk(m, top.title)
        }
        if let shots = Self.shotDir, let state = Self.shotState {
            func isEnabled(_ item: NSMenuItem) -> Bool {
                if item.menu?.autoenablesItems == false { return item.isEnabled }
                guard let action = item.action else { return false }
                let explicit = item.target as? NSObject
                guard let t = explicit.map({ $0.responds(to: action) ? $0 : nil }) ?? chain().first(where: { $0.responds(to: action) }) else { return false }
                if let v = t as? NSMenuItemValidation { return v.validateMenuItem(item) }
                if let v = t as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) }
                return true
            }
            func find(_ path: [String]) -> NSMenu? {
                var m: NSMenu? = bar
                for t in path { m = m?.items.first { $0.title == t }?.submenu }
                return m
            }
            for path in [["File"], ["Edit"], ["View"], ["Navigate"], ["Editor"], ["Product"], ["Debug"], ["Debug", "Simulate Location"], ["Integrate"]] {
                guard let m = find(path) else { continue }
                drawMenu(m, enabled: isEnabled, to: shots.appendingPathComponent("mac-menu-\(state)-\(path.joined(separator: "-").replacingOccurrences(of: " ", with: "_")).png"))
            }
        }
        return lines
    }

    /// A drawing of one menu as its items stand after validation (title,
    /// check mark, shortcut, enabled or not, submenu arrow, separators):
    /// menus never pop up under the offscreen guard, so the shots are drawn
    /// from the items. Written as `mac-menu-<state>-<path>.png`.
    func drawMenu(_ menu: NSMenu, enabled: (NSMenuItem) -> Bool, to url: URL) {
        let rowH: CGFloat = 22, sepH: CGFloat = 11, width: CGFloat = 380
        let items = menu.items.filter { !$0.isHidden && !$0.isAlternate }
        let height = items.reduce(CGFloat(10)) { $0 + ($1.isSeparatorItem ? sepH : rowH) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: 10, yRadius: 10).fill()
        var y = height - 5
        let font = NSFont.menuFont(ofSize: 13)
        for i in items {
            if i.isSeparatorItem {
                y -= sepH
                NSColor(white: 1, alpha: 0.15).setFill()
                NSRect(x: 12, y: y + sepH / 2, width: width - 24, height: 1).fill()
                continue
            }
            y -= rowH
            // A submenu's item is enabled unless Ycode disabled it (an
            // action no one performs), as AppKit shows it.
            let on = i.isSectionHeader ? false
                : (i.submenu != nil ? !(i.action.map(NSStringFromSelector)?.hasPrefix("ycodeUnavailable") ?? false) : enabled(i))
            let color = i.isSectionHeader ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 1, alpha: on ? 0.9 : 0.3)
            let attrs: [NSAttributedString.Key: Any] = [.font: i.isSectionHeader ? NSFont.boldSystemFont(ofSize: 11) : font, .foregroundColor: color]
            if i.state == .on { ("✓" as NSString).draw(at: NSPoint(x: 8, y: y + 3), withAttributes: attrs) }
            if let img = i.image {
                // A template glyph in the row's text colour, as a menu draws it.
                // Tinted on its own canvas (sourceAtop on the menu would
                // fill the whole square, the background being opaque).
                let r = NSRect(x: 22, y: y + 4, width: 14, height: 14)
                let tinted = NSImage(size: r.size, flipped: false) { b in
                    img.draw(in: b)
                    color.set()
                    b.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: r)
            }
            (i.title as NSString).draw(at: NSPoint(x: i.image == nil ? 24 : 42, y: y + 3), withAttributes: attrs)
            let sc = i.submenu != nil ? "›" : MainMenu.canonicalShortcut(i)
            let w = (sc as NSString).size(withAttributes: attrs).width
            (sc as NSString).draw(at: NSPoint(x: width - 14 - w, y: y + 3), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func write(_ lines: [String], _ name: String, to out: URL) {
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("mac-menus-\(name).tsv"), atomically: true, encoding: .utf8)
    }
}

/// The macOS and Linux menu bars compared item by item (beta 4, B4-MENUS):
/// the AppKit table (`ParityMenuTableTests.table`) against the Linux
/// shell's `ShellMenuModel.rows` for the same workspace in three states —
/// Welcome, a workspace with nothing open, and a Swift file in the editor.
/// Every row both list is matched by its menu path, action and tag; the
/// titles must match everywhere, enablement and check marks for the items
/// this pass touched (`checked`). With `YCODE_PARITY_MENU_DIR` the full
/// difference lists are written as `menu-diff-<state>.txt`.
@MainActor
@Suite(.serialized) struct ParityMenuCompareTests {
    struct MacRow {
        var path, title, shortcut, action: String
        var tag: Int
        var hidden, alternate, enabled, checked: Bool
    }

    /// The macOS table's command rows.
    static func macRows(window: NSWindow?, controller: WorkspaceWindowController?, appDelegate: AppDelegate) -> [MacRow] {
        ParityMenuTableTests().table(window: window, controller: controller, appDelegate: appDelegate).dropFirst().compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 9, !f[1].hasSuffix(" ▸") else { return nil }
            return MacRow(path: f[0], title: f[1], shortcut: f[2], action: f[3], tag: Int(f[4]) ?? 0, hidden: f[5] == "hidden",
                          alternate: f[6] == "alt", enabled: f[7] == "enabled", checked: f[8] == "on")
        }
    }

    /// Actions whose enablement and check mark the two IDEs must agree on
    /// in every state (the items this pass changed on both).
    static let checked: Set<String> = [
        "closeTab:", "saveAllDocuments:", "openDocument:", "closeWorkspace:", "openTerminalAtLocation:",
        "changeEditorOrientation:", "showCommitSheet:", "scmPush:", "scmPull:", "scmFetch:", "scmCherryPick:", "scmStash:",
        "scmDiscardAll:", "scmNewRepository:", "scmClone:", "refreshFileStatus:", "testProduct:", "chooseTheme:",
        "showWelcomeWindow:", "showDownloads:", "showOrganizer:", "showAboutWindow:", "showYcodeHelp:", "showReleaseNotes:",
        "reportBug:", "showSwiftBook:", "showEditorOnly:", "moveFocusToNextEditorPane:", "moveFocusToPreviousEditorPane:",
        "ycodeUnavailableDontSimulateLocation:", "ycodeUnavailableAddGPSExchangetoProject:",
    ]

    /// Differences between the two tables: (lines, failures among `checked`).
    static func compare(mac: [MacRow], linux: [ShellMenuRow], state: String) -> (all: [String], failures: [String]) {
        var all: [String] = [], failures: [String] = []
        let shown = mac.filter { !$0.hidden && !$0.alternate }
        // Commands by action and tag; rows a menu fills at display (no
        // table action) by title.
        let macByKey = Dictionary(shown.map { ("\($0.path)|\($0.action)|\($0.tag)", $0) }, uniquingKeysWith: { a, _ in a })
        let macByTitle = Dictionary(shown.map { ("\($0.path)|\($0.title)", $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        for l in linux where !l.isSubmenu && l.action != "terminate:" {
            var key = "\(l.path)|\(l.action)|\(l.tag)"
            var found = l.action.isEmpty ? nil : macByKey[key]
            if found == nil, let m = macByTitle["\(l.path)|\(l.title)"] {
                found = m
                key = "\(m.path)|\(m.action)|\(m.tag)"
            }
            seen.insert(key)
            guard let m = found else { all.append("Linux only: \(l)"); continue }
            // A row filled at display on macOS and listed from the table on Linux.
            let dynamic = m.action != l.action
            var d: [String] = []
            // AppKit titles Show/Hide Spelling and Grammar by the shared
            // spelling panel, app-wide state other tests can leave open.
            if m.title != l.title, l.action != "showGuessPanel:" { d.append("title mac “\(m.title)” linux “\(l.title)”") }
            if Shortcut.canonical(l.shortcut) != m.shortcut, !(l.shortcut.isEmpty && m.shortcut.isEmpty) {
                d.append("shortcut mac \(m.shortcut) linux \(Shortcut.canonical(l.shortcut))")
            }
            if m.enabled != l.isEnabled, !dynamic { d.append("enabled mac \(m.enabled) linux \(l.isEnabled)") }
            if m.checked != l.isChecked { d.append("checked mac \(m.checked) linux \(l.isChecked)") }
            guard !d.isEmpty else { continue }
            let line = "\(l.path) ▸ \(m.title) [\(l.action)]: " + d.joined(separator: "; ")
            all.append(line)
            // Known platform differences (reported): Linux's Welcome is the
            // app's last window, so ⌘W there would quit; the Linux model has
            // no pasteboard for New File from Clipboard (Ycode-only, P-020).
            let platform = (state == "welcome" && l.action == "closeTab:") || l.action == "newFileFromClipboard:"
            if !platform, checked.contains(l.action) || d.contains(where: { $0.hasPrefix("title") }) { failures.append(line) }
        }
        let toolkit = ShellMenuModel.toolkitEditActions.union(["terminate:"])
        for m in shown where !seen.contains("\(m.path)|\(m.action)|\(m.tag)") && !toolkit.contains(m.action) && !m.action.hasPrefix("_") {
            all.append("macOS only: \(m.path) ▸ \(m.title) [\(m.action)]")
        }
        return (all.sorted(), failures.sorted())
    }

    func pump(_ s: Double = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    @Test func menuBarsMatchItemByItem() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let prefs = IsolatedPreferences("parity-menu-compare")
        defer { prefs.restore() }
        CrossPlatformParityShotTests.KeyLook.on()
        defer { CrossPlatformParityShotTests.KeyLook.off() }
        let appDelegate = AppDelegate()
        let out = ParityMenuTableTests.outDir.map { URL(fileURLWithPath: $0) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("menu-compare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/bin/sh")
        make.arguments = [ycodeDir.appendingPathComponent("scripts/linux-ui-parity/make-parity5.sh").path, tmp.path]
        make.standardOutput = FileHandle.nullDevice
        try make.run()
        make.waitUntilExit()
        let repo = tmp.appendingPathComponent("rest/Merger")
        let linux = ShellAppModel(recentProjects: RecentProjects(defaults: UserDefaults(suiteName: "menu-compare-\(UUID().uuidString)")!),
                                  engine: { PackageBuildEngine() })
        var failures: [String] = []
        func check(_ state: String, _ mac: [MacRow]) {
            let r = Self.compare(mac: mac, linux: ShellMenuModel.rows(linux), state: state)
            // File ▸ Open… is the application delegate's, whichever
            // document controller is shared (menu test hygiene, beta 5).
            failures += r.failures.map { "\(state): \($0)" }
            if let out {
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try? r.all.joined(separator: "\n").write(to: out.appendingPathComponent("menu-diff-\(state).txt"), atomically: true, encoding: .utf8)
            }
        }

        check("welcome", Self.macRows(window: nil, controller: nil, appDelegate: appDelegate))

        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: repo)), loadDestinations: false,
                                           startLanguageService: false, openFirstFile: false)
        let win = try #require(wc.window)
        win.isExcludedFromWindowsMenu = true
        wc.applyDefaultLayout()
        win.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        win.orderBack(nil)
        await wc.sourceControl.idle()
        if wc.editor.fileURL != nil { wc.closeDocument(nil) }
        #expect(linux.open(path: repo.path))
        let lw = try #require(linux.workspace)
        await lw.sourceControl.idle()
        pump()
        check("workspace", Self.macRows(window: win, controller: wc, appDelegate: appDelegate))

        let sample = repo.appendingPathComponent("Sources/Merger/Sample.swift").path
        wc.open(path: sample, line: nil)
        win.makeFirstResponder(wc.editor.textView)
        wc.editor.textView.setSelectedRange(NSRange(location: 60, length: 0))
        lw.open(sample)
        lw.selection = lw.root.allFiles.first { $0.path == sample }?.id
        lw.editor?.buffer.setCaret(60)
        pump()
        check("Sample.swift", Self.macRows(window: win, controller: wc, appDelegate: appDelegate))
        win.close()
        lw.stop()
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) differences:\n" + failures.joined(separator: "\n")))
    }

    /// Debug ▸ Simulate Location's places are the simulator's presets.
    @Test func simulateLocationPlacesAreThePresets() {
        #expect(SimulateLocationMenu.places == SimLocation.presets.map(\.name))
    }
}
