import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_TOUR=<prefix>: the Linux half of the 2026-11-15 parity tour
// (PARITY-LINUX): what the macOS IDE is compared with, recorded on the Linux
// IDE. It changes nothing in the app; each part prints "tour <part> …" lines
// and writes <prefix>-<part>-<NN>-<state>.png (with a .txt of the window's
// texts and identified views beside each still). YCODE_IDE_TOUR_PART
// chooses the part (default "menus"):
//
//   menus      the menu bar as the shell builds it (`ShellMenus`): every item
//              of every menu and submenu with its title in context, shortcut
//              and whether Linux performs it (ON), lists it disabled (OFF),
//              hides it (an alternate or a conditional item) or leaves it to
//              the toolkit; then every top-level menu opened with the pointer
//              (stills at fixed times after the click, for a fade), every
//              submenu opened by hovering its item, and the keyboard in a menu
//              (arrows, Right into a submenu, Escape). The table is printed for
//              the state the workspace is in (YCODE_IDE_TOUR_FILE opens a file
//              first, so the Editor menu is that editor's)
//   context    a secondary click on every place that has (or could have) a
//              context menu: navigator rows (file, group, project), the
//              editor's text and gutter, the jump bar, the toolbar, the debug
//              area, the inspector, each navigator's rows; the items listed
//   tooltips   the pointer resting on every identified control: the tooltip
//              text that appears (or none)
//   keys       Tab focus order (30 presses, a still each), the navigator
//              outline's keys (arrows, Left/Right, Return, Escape, type-select),
//              Escape and Return in the New Project sheet, About, Open Quickly,
//              Go to Line, the find bar and an alert
//   motion     frame timing of the animated transitions: the navigator,
//              inspector and debug area hidden and shown, a navigator switch,
//              a disclosure, the find bar, Open Quickly, a sheet, the split,
//              a menu: frames presented and their times after the input, and
//              stills at fixed times
//   editor     the source editor's features in turn: completion, Quick Help
//              (Alt-click), each jump bar segment's menu, find and replace, Go
//              to Line, Ctrl+Shift-click (multi-cursor), comment, split, canvas,
//              Open Quickly, the project row (project editor), fold commands
//   build      Product ▸ Build on a package with an error and a warning: the
//              activity area while building, the issue navigator, the inline
//              issues, the Report navigator's log
//   files      every file of the workspace opened in turn (YCODE_IDE_TOUR_FILES,
//              comma-separated names, default every file the navigator lists
//              up to 40): a still and the Editor menu's table for each
//   settings   Settings (window 1): every pane by its sidebar row, the pane
//              switch's frames, Escape and Ctrl+W
//   size       the window at the size YCODE_IDE_WINDOW_SIZE gives, with a file
//              open, the debug area and the inspector shown
extension ShellDriver {
    #if os(Linux)
    static func tourWalk(_ app: ShellAppModel, prefix: String) async {
        let part = env["YCODE_IDE_TOUR_PART"] ?? "menus"
        let tour = Tour(app: app, prefix: prefix, part: part)
        say("tour \(part): start \(state(app))")
        OpenViewsAutomation.setMenuBarRevealed(true)
        await pause(0.4)
        if let name = env["YCODE_IDE_TOUR_FILE"] { await tour.openFile(name) }
        switch part {
        case "menus": await tour.menus()
        case "context": await tour.contextMenus()
        case "tooltips": await tour.tooltips()
        case "keys": await tour.keys()
        case "motion": await tour.motion()
        case "editor": await tour.editor()
        case "build": await tour.buildPart()
        case "files": await tour.files()
        case "settings": await tour.settings()
        case "size": await tour.size()
        default: say("tour: unknown part \(part)")
        }
        say("tour \(part): end \(state(app))")
    }
    #endif
}

#if os(Linux)
@MainActor
final class Tour {
    let app: ShellAppModel
    let prefix: String
    let part: String
    var n = 0

    init(app: ShellAppModel, prefix: String, part: String) {
        self.app = app
        self.prefix = prefix
        self.part = part
    }

    var w: WorkspaceShellModel? { app.workspace }
    var env: [String: String] { ShellDriver.env }
    func say(_ s: String) { ShellDriver.say("tour \(part) " + s) }
    func pause(_ s: Double) async { await ShellDriver.pause(s) }

    // MARK: Stills and dumps

    /// A still of window `index` with a .txt of its texts and identified views.
    @discardableResult
    func shot(_ state: String, window index: Int = 0, settle: Double = 0.5) async -> String {
        await pause(settle)
        n += 1
        let base = String(format: "%@-%@-%02d-%@", prefix, part, n, state.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "_"))
        let r = OpenViewsAutomation.screenshot(index, to: base + ".png")
        var lines: [String] = []
        for t in OpenViewsAutomation.texts(index) {
            lines.append(String(format: "%@ %.1f %.1f %.1f %.1f %@", t.inPopup ? "popup" : "text", t.frame.minX, t.frame.minY, t.frame.width, t.frame.height, t.text))
        }
        for (k, f) in OpenViewsAutomation.identifiedFrames(index).sorted(by: { $0.key < $1.key }) {
            lines.append(String(format: "id %.1f %.1f %.1f %.1f %@", f.minX, f.minY, f.width, f.height, k))
        }
        try? lines.joined(separator: "\n").write(toFile: base + ".txt", atomically: true, encoding: .utf8)
        say("shot \(state): \(r)")
        return base
    }

    /// The texts of the open pop-ups, top to bottom, a row per line (texts
    /// on one row joined by " | ").
    func popupRows(_ index: Int = 0) -> [String] {
        let items = OpenViewsAutomation.texts(index).filter(\.inPopup).sorted { ($0.frame.midY, $0.frame.minX) < ($1.frame.midY, $1.frame.minX) }
        var rows: [[OpenViewsAutomation.TextItem]] = []
        for t in items {
            if let last = rows.last?.last, abs(last.frame.midY - t.frame.midY) < 4 { rows[rows.count - 1].append(t) } else { rows.append([t]) }
        }
        return rows.map { r in r.map { String(format: "%@@%.0f", $0.text, $0.frame.minX) }.joined(separator: " | ") }
    }

    func dumpPopups(_ label: String) {
        let rows = popupRows()
        say("popup \(label): \(OpenViewsAutomation.openPopupCount) pop-ups, \(rows.count) rows")
        for r in rows { say("popup \(label) row: \(r)") }
    }

    func escapeAll() async {
        for _ in 0..<4 where OpenViewsAutomation.openPopupCount > 0 {
            OpenViewsAutomation.press(.escape)
            await pause(0.25)
        }
    }

    func text(_ s: String, popup: Bool = false) -> OpenViewsAutomation.TextItem? {
        OpenViewsAutomation.texts().filter { $0.text == s && $0.inPopup == popup }.min { $0.frame.minY < $1.frame.minY }
    }

    /// A menu bar title (the topmost text with that title).
    func menuTitle(_ s: String) -> OpenViewsAutomation.TextItem? {
        OpenViewsAutomation.texts().filter { $0.text == s && !$0.inPopup && $0.frame.minY < 40 }.min { $0.frame.minY < $1.frame.minY }
    }

    func center(_ f: CGRect) -> CGPoint { CGPoint(x: f.midX, y: f.midY) }

    // MARK: Files

    func path(_ name: String) -> String? {
        w?.root.allFiles.compactMap(\.path).first { $0.hasSuffix("/" + name) || $0 == name }
    }

    func openFile(_ name: String) async {
        guard let w, let p = path(name) else { say("no file \(name)"); return }
        if let ids = w.root.idPath(to: p) { for id in ids.dropLast() { w.setExpanded(id, true) } }
        w.open(p)
        await pause(0.8)
        say("opened \(name): \(ShellDriver.state(app))")
    }

    // MARK: Frame timing

    /// Performs `action`, then samples for `ms`: the times (ms after the
    /// action) at which window `index` presented a frame, the pop-up count's
    /// changes, and an identified view's frame (`track`) when given.
    func timed(_ name: String, ms: Double = 700, window index: Int = 0, track: String? = nil, stills: [Double] = [],
               _ action: () async -> Void) async {
        let f0 = OpenViewsAutomation.presentedFrames(window: index)
        OpenViewsAutomation.frameDurations = []
        var frames: [Double] = []
        var popups: [(Double, Int)] = [(0, OpenViewsAutomation.openPopupCount)]
        var tracked: [(Double, CGRect?)] = []
        var lastFrames = f0
        var pending = stills.sorted()
        let start = Date()
        await action()
        let after = Date().timeIntervalSince(start) * 1000
        while true {
            let t = Date().timeIntervalSince(start) * 1000
            if t > ms { break }
            let f = OpenViewsAutomation.presentedFrames(window: index)
            if f != lastFrames {
                for _ in lastFrames..<f { frames.append(t) }
                lastFrames = f
            }
            let p = OpenViewsAutomation.openPopupCount
            if popups.last?.1 != p { popups.append((t, p)) }
            if let track {
                let r = OpenViewsAutomation.identifiedFrames(index)[track]
                if tracked.last.map({ $0.1 != r }) ?? true { tracked.append((t, r)) }
            }
            if let next = pending.first, t >= next {
                pending.removeFirst()
                n += 1
                let base = String(format: "%@-%@-%02d-%@-%04.0fms", prefix, part, n, name, t)
                _ = OpenViewsAutomation.screenshot(index, to: base + ".png")
            }
            await pause(0.002)
        }
        let work = (OpenViewsAutomation.frameDurations ?? []).map { $0 * 1000 }
        OpenViewsAutomation.frameDurations = nil
        let gaps = zip(frames.dropFirst(), frames).map { $0 - $1 }
        say(String(format: "timing %@: action took %.0f ms; %d frames in %.0f ms; first at %.0f, last at %.0f; longest gap %.0f ms; frame work median %.1f max %.1f ms",
                   name, after, frames.count, ms, frames.first ?? -1, frames.last ?? -1, gaps.max() ?? 0,
                   work.sorted().dropFirst(work.count / 2).first ?? 0, work.max() ?? 0))
        say("timing \(name) frames: " + frames.map { String(format: "%.0f", $0) }.joined(separator: " "))
        if popups.count > 1 { say("timing \(name) popups: " + popups.map { String(format: "%.0f:%d", $0.0, $0.1) }.joined(separator: " ")) }
        if track != nil {
            say("timing \(name) \(track!): " + tracked.map { s in s.1.map { String(format: "%.0f:%.0f,%.0f,%.0f,%.0f", s.0, $0.minX, $0.minY, $0.width, $0.height) } ?? String(format: "%.0f:none", s.0) }.joined(separator: " "))
        }
    }

    // MARK: Menus

    /// One line per item of the shell's menu bar, as `ShellMenus` decides.
    func menuTable(_ label: String) {
        let kind = w?.editorKind ?? .source
        var counts: [String: Int] = [:]
        func status(_ c: MenuCommand) -> (String, String) {
            let shell = ShellCommand.allCases.first { $0.action == (c.action, c.tag) }
            let title = shell.map { app.title($0) } ?? MenuTitles.title(for: c, in: w?.menuContext)
            if c.isAlternate { return ("HIDDEN-alternate", title) }
            if c.condition == .integrationInProgress, !MenuConditions.isShown(c.condition, in: w?.menuContext) { return ("HIDDEN-condition", title) }
            if c.condition != nil, shell == nil { return ("HIDDEN-condition", title) }
            if ShellMenus.toolkitEditActions.contains(c.action) { return ("TOOLKIT", title) }
            if shell == nil, let s = w?.editorActionState(c.action, tag: c.tag) { return (s.enabled ? "ON-editor" + (s.checked ? "-checked" : "") : "OFF-editor", title) }
            guard let shell else { return (c.action.hasPrefix("ycodeUnavailable") ? "OFF-unavailable" : "OFF-not-in-shell", title) }
            let checked = app.isChecked(shell).map { $0 ? "-checked" : "-unchecked" } ?? ""
            return ((app.isEnabled(shell) ? "ON" : "OFF-disabled-now") + checked, title)
        }
        func walk(_ items: [MenuItemSpec], _ path: String) {
            for i in items {
                switch i {
                case .separator: break
                case .label(let t): say("menu \(label) | \(path) | [label] \(t) | | LABEL |")
                case .submenu(let t, let sub):
                    say("menu \(label) | \(path) | \(t) ▸ | | SUBMENU |")
                    walk(sub, path + " ▸ " + t)
                case .command(let c):
                    let (s, title) = status(c)
                    counts[s.components(separatedBy: "-").first ?? s, default: 0] += 1
                    let shortcut = ShellShortcut(command: KeyBindings.effective(c))?.text ?? ""
                    say("menu \(label) | \(path) | \(title) | \(shortcut) | \(s) | \(c.action)\(c.tag != 0 ? "#\(c.tag)" : "")")
                }
            }
        }
        for (menu, items) in CommandTable.menus {
            walk(menu == "Editor" ? EditorMenu.items(for: kind) : items, menu)
        }
        say("menu \(label) counts: \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    }

    /// Opens every top-level menu and every submenu with the pointer.
    func openMenus(_ label: String) async {
        let titles = OpenViewsAutomation.menuTitles()
        say("menu bar \(label): \(titles)")
        for title in titles {
            await escapeAll()
            guard let t = menuTitle(title) else { say("menu \(title): no title text"); continue }
            await timed("menu-\(title)", ms: 450, stills: [0, 17, 50, 120, 300]) {
                await OpenViewsAutomation.click(at: center(t.frame))
            }
            dumpPopups("\(label) \(title)")
            await shot("\(label)-menu-\(title)", settle: 0.1)
            // Submenus: the rows the table marks as submenus, by their titles,
            // each from the menu freshly opened: hovered first (as a desktop
            // menu opens a submenu), then clicked if hovering did not.
            for s in submenuTitles(title) {
                await escapeAll()
                await OpenViewsAutomation.click(at: center(t.frame))
                await pause(0.4)
                guard let item = text(s, popup: true) else { say("submenu \(title) ▸ \(s): not shown"); continue }
                let p0 = OpenViewsAutomation.openPopupCount
                OpenViewsAutomation.move(to: CGPoint(x: item.frame.minX - 4, y: item.frame.midY))
                await pause(0.05)
                await timed("submenu-hover-\(title)-\(s)", ms: 1000, stills: [0, 150, 400]) {
                    OpenViewsAutomation.move(to: center(item.frame))
                }
                let hovered = OpenViewsAutomation.openPopupCount
                if hovered <= p0 {
                    await timed("submenu-click-\(title)-\(s)", ms: 500, stills: [0, 100]) {
                        await OpenViewsAutomation.click(at: center(item.frame))
                    }
                }
                say("submenu \(title) ▸ \(s): pop-ups \(p0), after hovering 1 s \(hovered), after a click \(OpenViewsAutomation.openPopupCount)")
                dumpPopups("\(label) \(title) ▸ \(s)")
                await shot("\(label)-menu-\(title)-\(s)", settle: 0.1)
            }
            await escapeAll()
            await pause(0.2)
        }
    }

    func submenuTitles(_ menu: String) -> [String] {
        let items = menu == "Editor" ? EditorMenu.items(for: w?.editorKind ?? .source) : (CommandTable.menus.first { $0.0 == menu }?.1 ?? [])
        return items.compactMap { if case .submenu(let t, _) = $0 { return t }; return nil }
    }

    func menus() async {
        menuTable(w == nil ? "welcome" : (w?.document?.name ?? "workspace"))
        await openMenus(w == nil ? "welcome" : "workspace")
        // The keyboard in a menu.
        if let file = menuTitle("File") {
            await OpenViewsAutomation.click(at: center(file.frame))
            await pause(0.4)
            for k in 1...3 {
                OpenViewsAutomation.press(.downArrow)
                await pause(0.25)
                await shot("keys-file-down\(k)", settle: 0.05)
            }
            OpenViewsAutomation.press(.upArrow)
            OpenViewsAutomation.press(.upArrow)
            OpenViewsAutomation.press(.upArrow)
            await pause(0.2)
            OpenViewsAutomation.press(.downArrow)   // New ▸ is the first row
            await pause(0.2)
            OpenViewsAutomation.press(.rightArrow)
            await pause(0.4)
            say("keys: Right on New ▸: pop-ups \(OpenViewsAutomation.openPopupCount)")
            await shot("keys-file-right", settle: 0.05)
            OpenViewsAutomation.press(.leftArrow)
            await pause(0.3)
            say("keys: Left: pop-ups \(OpenViewsAutomation.openPopupCount)")
            OpenViewsAutomation.press(.rightArrow)
            await pause(0.3)
            say("keys: Right in the menu bar row: pop-ups \(OpenViewsAutomation.openPopupCount), rows \(popupRows().prefix(2))")
            await shot("keys-file-right-again", settle: 0.05)
            OpenViewsAutomation.press(.escape)
            await pause(0.3)
            say("keys: Escape: pop-ups \(OpenViewsAutomation.openPopupCount)")
            await escapeAll()
        }
        // F10 and Alt+F (the desktop's ways into a menu bar).
        OpenViewsAutomation.press(.function(10))
        await pause(0.4)
        say("keys: F10: pop-ups \(OpenViewsAutomation.openPopupCount) menu bar revealed \(OpenViewsAutomation.isMenuBarRevealed())")
        await shot("keys-f10", settle: 0.05)
        await escapeAll()
        OpenViewsAutomation.press(.character("f"), modifiers: [.option])
        await pause(0.4)
        say("keys: Alt+F: pop-ups \(OpenViewsAutomation.openPopupCount)")
        await shot("keys-alt-f", settle: 0.05)
        await escapeAll()
        // The menu bar hidden (as a normal launch shows it).
        OpenViewsAutomation.setMenuBarRevealed(false)
        await shot("menubar-hidden")
        OpenViewsAutomation.setMenuBarRevealed(true)
    }

    // MARK: Context menus

    func secondaryClick(_ label: String, at p: CGPoint?) async {
        guard let p else { say("context \(label): no place"); return }
        await escapeAll()
        await timed("context-\(label)", ms: 400, stills: [0, 50, 200]) {
            await OpenViewsAutomation.click(at: p, button: 3)
        }
        dumpPopups("context \(label)")
        await shot("context-\(label)", settle: 0.1)
        await escapeAll()
    }

    func rowText(_ s: String) -> CGPoint? {
        OpenViewsAutomation.texts().first { !$0.inPopup && $0.text == s && ShellDriver.inNavigator($0.frame) }.map { center($0.frame) }
    }

    func idCenter(_ name: String) -> CGPoint? { OpenViewsAutomation.identifiedFrames()[name].map(center) }

    func contextMenus() async {
        guard let w else {
            // Welcome: its recent row.
            let rows = OpenViewsAutomation.identifiedFrames().filter { $0.key.hasPrefix("welcome recent") || $0.key.hasPrefix("recent") }
            say("welcome targets: \(OpenViewsAutomation.identifiedFrames().keys.sorted())")
            for (k, f) in rows { await secondaryClick("welcome-\(k)", at: center(f)) }
            return
        }
        let rows = w.projectRows
        say("project rows: \(rows.prefix(30).map(\.title))")
        // The project (first row), a group and a file.
        if let first = rows.first { await secondaryClick("project-root", at: rowText(first.title)) }
        if let group = rows.dropFirst().first(where: { $0.isExpandable }) { await secondaryClick("group", at: rowText(group.title)) }
        if let file = rows.first(where: { !$0.isExpandable }) { await secondaryClick("file", at: rowText(file.title)) }
        // A file open: the editor's text, gutter, jump bar, minimap.
        if let file = w.root.allFiles.first(where: { $0.name.hasSuffix(".swift") }), let p = file.path {
            w.open(p)
            await pause(0.8)
        }
        let ids = OpenViewsAutomation.identifiedFrames()
        say("targets: \(ids.keys.sorted())")
        if let s = ids["source"] ?? ids["editor"] {
            await secondaryClick("editor-text", at: CGPoint(x: s.minX + 200, y: s.minY + 60))
            await secondaryClick("editor-gutter", at: CGPoint(x: s.minX + 15, y: s.minY + 60))
        }
        for (k, f) in ids where k.hasPrefix("jump path title") { await secondaryClick(k, at: center(f)) }
        for k in ["minimap", "jump bar symbol", "jump bar grid", "tb run", "tb scheme", "tb destination", "activity", "inspector", "debug bar", "navigator add", "navigator filter"] {
            if let f = ids[k] { await secondaryClick(k, at: center(f)) }
        }
        // Each navigator's first rows.
        for nav in ShellNavigator.allCases where nav != .project {
            w.navigator = nav
            await pause(0.6)
            let texts = OpenViewsAutomation.texts().filter { !$0.inPopup && ShellDriver.inNavigator($0.frame) }.sorted { $0.frame.minY < $1.frame.minY }
            say("navigator \(nav.rawValue) texts: \(texts.prefix(12).map(\.text))")
            await shot("navigator-\(nav.rawValue)")
            for t in texts.prefix(3) { await secondaryClick("\(nav.rawValue)-\(t.text)", at: center(t.frame)) }
        }
        w.navigator = .project
        // The debug area: console and variables.
        w.isDebugAreaShown = true
        await pause(0.6)
        let d = OpenViewsAutomation.identifiedFrames()
        for k in ["debug pane", "console filter", "console search"] { if let f = d[k] { await secondaryClick(k, at: center(f)) } }
        if let a = d["debug area"] {
            await secondaryClick("debug-console", at: CGPoint(x: a.maxX - 200, y: a.midY + 20))
            await secondaryClick("debug-variables", at: CGPoint(x: a.minX + 150, y: a.midY + 20))
        }
    }

    // MARK: Tooltips

    func tooltips() async {
        if let name = w?.root.allFiles.first(where: { $0.name.hasSuffix(".swift") })?.path { w?.open(name); await pause(0.8) }
        w?.isDebugAreaShown = true
        await pause(0.6)
        let ids = OpenViewsAutomation.identifiedFrames()
        let size = OpenViewsAutomation.windowSize()?.points ?? CGSize(width: 1400, height: 900)
        let targets = ids.filter { $0.value.width > 4 && $0.value.width < 260 && $0.value.height < 60 && $0.value.maxX <= size.width && $0.value.maxY <= size.height }
            .sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }
        say("tooltip targets: \(targets.count)")
        for (k, f) in targets {
            OpenViewsAutomation.move(to: CGPoint(x: 5, y: size.height - 5))
            await pause(0.25)
            let before = Set(OpenViewsAutomation.texts().map { "\($0.inPopup)|\($0.text)" })
            OpenViewsAutomation.move(to: center(f))
            var shown: [String] = []
            var at = -1.0
            let start = Date()
            while Date().timeIntervalSince(start) < 2.0 {
                await pause(0.05)
                let now = OpenViewsAutomation.texts().filter { !before.contains("\($0.inPopup)|\($0.text)") }.map(\.text)
                if !now.isEmpty { shown = now; at = Date().timeIntervalSince(start) * 1000; break }
            }
            say(String(format: "tooltip %@: %@ (after %.0f ms)", k, shown.isEmpty ? "none" : "\"" + shown.joined(separator: " / ") + "\"", at))
            if !shown.isEmpty, k.hasPrefix("tb ") { await shot("tooltip-\(k)", settle: 0.05) }
        }
    }

    // MARK: Keys and focus

    func keys() async {
        if let w {
            if let p = w.root.allFiles.first(where: { $0.name.hasSuffix(".swift") })?.path { w.open(p); await pause(0.8) }
            // Tab order from the editor.
            for i in 1...30 {
                OpenViewsAutomation.press(.tab)
                await pause(0.2)
                let ti = OpenViewsAutomation.textInput()
                say("tab \(i): text input \(ti.active) area \(ti.area.map { String(format: "%.0f,%.0f", $0.minX, $0.minY) } ?? "-") \(ShellDriver.state(app).prefix(160))")
                await shot("tab-\(i)", settle: 0.05)
            }
            OpenViewsAutomation.press(.tab, modifiers: [.shift])
            await pause(0.2)
            await shot("shift-tab", settle: 0.05)
            // The outline: click a row, then keys.
            w.navigator = .project
            await pause(0.4)
            let rows = w.projectRows
            if let first = rows.first, let p = rowText(first.title) {
                await OpenViewsAutomation.click(at: p)
                await pause(0.4)
                func key(_ k: OVPlatform.Key, _ label: String, _ mods: OVPlatform.KeyModifiers = []) async {
                    OpenViewsAutomation.press(k, modifiers: mods)
                    await pause(0.35)
                    say("outline \(label): selection=\(w.selection ?? "none") expanded=\(w.expanded.count) document=\(w.document?.name ?? "none") rename-field=\(OpenViewsAutomation.textInput().active)")
                    await shot("outline-\(label)", settle: 0.05)
                }
                await key(.downArrow, "down")
                await key(.downArrow, "down2")
                await key(.rightArrow, "right")
                await key(.leftArrow, "left")
                await key(.leftArrow, "left2")
                await key(.upArrow, "up")
                await key(.rightArrow, "right-alt", [.option])
                await key(.space, "space")
                await key(.return, "return")
                await key(.escape, "escape")
                await key(.home, "home")
                await key(.end, "end")
                OpenViewsAutomation.type("Sa")
                await pause(0.4)
                say("outline type-select Sa: selection=\(w.selection ?? "none")")
                await shot("outline-typeselect")
            }
            // Open Quickly: type, arrows, Escape; then again with Return.
            OpenViewsAutomation.press(.character("o"), modifiers: [.control, .shift])
            await pause(0.5)
            OpenViewsAutomation.type("swift")
            await pause(0.6)
            await shot("openquickly-typed")
            OpenViewsAutomation.press(.downArrow)
            await pause(0.2)
            await shot("openquickly-down")
            OpenViewsAutomation.press(.escape)
            await pause(0.4)
            await shot("openquickly-escape")
            // Go to Line: Escape, then Return.
            OpenViewsAutomation.press(.character("l"), modifiers: [.control])
            await pause(0.5)
            say("goto shown=\(w.isJumpToLineShown)")
            await shot("goto")
            OpenViewsAutomation.press(.escape)
            await pause(0.4)
            say("goto after Escape shown=\(w.isJumpToLineShown)")
            OpenViewsAutomation.press(.character("l"), modifiers: [.control])
            await pause(0.5)
            OpenViewsAutomation.type("3")
            OpenViewsAutomation.press(.return)
            await pause(0.5)
            say("goto after 3 Return: shown=\(w.isJumpToLineShown) \(ShellDriver.state(app).prefix(200))")
            // The find bar: Escape closes it?
            OpenViewsAutomation.press(.character("f"), modifiers: [.control])
            await pause(0.4)
            OpenViewsAutomation.type("let")
            OpenViewsAutomation.press(.return)
            await pause(0.4)
            say("find after Return: \(w.findBar.isShown) \"\(w.findBar.countText)\"")
            await shot("findbar")
            OpenViewsAutomation.press(.escape)
            await pause(0.4)
            say("find after Escape: shown=\(w.findBar.isShown)")
            await shot("findbar-escape")
        }
        // About: Escape, then Return.
        app.perform(.about)
        await pause(0.6)
        await shot("about")
        OpenViewsAutomation.press(.escape)
        await pause(0.5)
        say("about after Escape: shown=\(app.isAboutShown)")
        if app.isAboutShown {
            OpenViewsAutomation.press(.return)
            await pause(0.5)
            say("about after Return: shown=\(app.isAboutShown)")
            app.isAboutShown = false
            await pause(0.5)
        }
        // New Project: Tab order, Escape, Return.
        app.showNewProject()
        await pause(0.8)
        await shot("newproject")
        for i in 1...12 {
            OpenViewsAutomation.press(.tab)
            await pause(0.15)
            await shot("newproject-tab-\(i)", settle: 0.05)
        }
        OpenViewsAutomation.press(.rightArrow)
        await pause(0.3)
        await shot("newproject-right")
        OpenViewsAutomation.press(.return)
        await pause(0.6)
        say("newproject after Return: \(app.newProject.map { "step \($0.step)" } ?? "closed")")
        await shot("newproject-return")
        OpenViewsAutomation.press(.escape)
        await pause(0.6)
        say("newproject after Escape: \(app.newProject == nil ? "closed" : "open")")
        if app.newProject != nil { app.cancelNewProject(); await pause(0.6) }
        // An alert: Return, then Escape.
        app.notice = ShellNotice("Parity", "An alert for the keyboard check.")
        await pause(0.6)
        await shot("alert")
        OpenViewsAutomation.press(.return)
        await pause(0.5)
        say("alert after Return: \(app.notice == nil ? "closed" : "open")")
        if app.notice != nil {
            OpenViewsAutomation.press(.escape)
            await pause(0.5)
            say("alert after Escape: \(app.notice == nil ? "closed" : "open")")
            app.notice = nil
        }
    }

    // MARK: Motion

    /// A transition's stills: for each offset, `forward`, a still that long
    /// after it, then `back` and a pause (a still blocks drawing while it is
    /// read back, so each offset gets its own run of the transition).
    func stills(_ name: String, at offsets: [Double], settle: Double = 0.9,
                _ forward: () async -> Void, back: () async -> Void) async {
        for o in offsets {
            await forward()
            await pause(o / 1000)
            n += 1
            let base = String(format: "%@-%@-%02d-%@-%04.0fms", prefix, part, n, name, o)
            _ = OpenViewsAutomation.screenshot(to: base + ".png")
            await back()
            await pause(settle)
        }
    }

    func motion() async {
        let offsets: [Double] = [16, 50, 100, 180, 300, 500]
        guard let w else {
            // Welcome: the New Project sheet and About.
            await timed("sheet-newproject-in", ms: 900) { app.showNewProject() }
            await pause(0.6)
            await timed("sheet-newproject-out", ms: 900) { app.cancelNewProject() }
            await pause(0.8)
            await timed("about-in", ms: 900) { app.perform(.about) }
            await pause(0.6)
            await timed("about-out", ms: 900) { app.isAboutShown = false }
            await pause(0.8)
            await stills("sheet-newproject-in", at: offsets + [800], { app.showNewProject() }, back: { app.cancelNewProject() })
            return
        }
        if let p = w.root.allFiles.first(where: { $0.name.hasSuffix(".swift") })?.path { w.open(p); await pause(1.0) }
        // Pass 1: frame timing only (no stills while sampling).
        for (name, cmd, track) in [("navigator", ShellCommand.toggleNavigator, "navigator"), ("inspector", .toggleInspector, "inspector"), ("debug-area", .toggleDebugArea, "debug area")] {
            await timed("\(name)-toggle", ms: 800, track: track) { w.perform(cmd) }
            await pause(0.5)
            await timed("\(name)-toggle-back", ms: 800, track: track) { w.perform(cmd) }
            await pause(0.5)
        }
        for i in [1, 4, 0] {
            if let f = OpenViewsAutomation.identifiedFrames()["selector \(i)"] {
                await timed("navigator-switch-\(i)", ms: 500) { await OpenViewsAutomation.click(at: center(f)) }
                await pause(0.3)
            }
        }
        var disclosure: CGPoint?
        if let group = w.projectRows.dropFirst().first(where: { $0.isExpandable }), let p = rowText(group.title) {
            disclosure = CGPoint(x: p.x - 40, y: p.y)
            await timed("disclosure-1", ms: 600) { await OpenViewsAutomation.click(at: disclosure!) }
            await pause(0.4)
            await timed("disclosure-2", ms: 600) { await OpenViewsAutomation.click(at: disclosure!) }
            await pause(0.4)
        }
        await timed("findbar-in", ms: 500) { OpenViewsAutomation.press(.character("f"), modifiers: [.control]) }
        await pause(0.3)
        await timed("findbar-out", ms: 500) { w.findBar.isShown = false }
        await pause(0.3)
        await timed("openquickly-in", ms: 600) { OpenViewsAutomation.press(.character("o"), modifiers: [.control, .shift]) }
        await pause(0.3)
        await timed("openquickly-out", ms: 600) { OpenViewsAutomation.press(.escape) }
        await pause(0.3)
        await timed("sheet-open-in", ms: 900) { app.showOpenSheet() }
        await pause(0.4)
        await timed("sheet-open-out", ms: 900) { OpenViewsAutomation.press(.escape) }
        await pause(0.6)
        await timed("about-in", ms: 900) { app.perform(.about) }
        await pause(0.4)
        await timed("about-out", ms: 900) { app.isAboutShown = false }
        await pause(0.6)
        if let t = menuTitle("View") {
            await timed("menu-view-open", ms: 500) { await OpenViewsAutomation.click(at: center(t.frame)) }
            if let item = text("Navigators", popup: true) {
                await timed("submenu-navigators-click", ms: 500) { await OpenViewsAutomation.click(at: center(item.frame)) }
            }
            await timed("menu-close", ms: 400) { OpenViewsAutomation.press(.escape); OpenViewsAutomation.press(.escape) }
            await escapeAll()
        }
        if let t = menuTitle("View") {
            await OpenViewsAutomation.click(at: center(t.frame))
            await pause(0.4)
            if let item = OpenViewsAutomation.texts().first(where: { $0.inPopup && ($0.text.hasPrefix("Hide Navigator") || $0.text.hasPrefix("Show Navigator")) }) {
                await timed("menu-choose", ms: 600) { await OpenViewsAutomation.click(at: center(item.frame)) }
                await stills("menu-choose", at: [16, 60, 120], {
                    await OpenViewsAutomation.click(at: center(t.frame))
                    await pause(0.4)
                    if let i = OpenViewsAutomation.texts().first(where: { $0.inPopup && ($0.text.hasPrefix("Hide Navigator") || $0.text.hasPrefix("Show Navigator")) }) {
                        await OpenViewsAutomation.click(at: center(i.frame))
                    }
                }, back: {})
            }
            await escapeAll()
            w.isNavigatorShown = true
        }
        await timed("split-right", ms: 600) { w.perform(.splitEditor) }
        await pause(0.6)
        // Pass 2: stills at fixed offsets, each from its own run.
        await stills("inspector-hide", at: offsets, { w.perform(.toggleInspector) }, back: { w.perform(.toggleInspector) })
        await stills("navigator-hide", at: offsets, { w.perform(.toggleNavigator) }, back: { w.perform(.toggleNavigator) })
        await stills("debug-area-show", at: offsets, { w.perform(.toggleDebugArea) }, back: { w.perform(.toggleDebugArea) })
        if let d = disclosure {
            await stills("disclosure", at: [16, 50, 100, 180], { await OpenViewsAutomation.click(at: d) }, back: { await OpenViewsAutomation.click(at: d) })
        }
        await stills("sheet-open-in", at: offsets + [800], { app.showOpenSheet() }, back: { OpenViewsAutomation.press(.escape); await pause(0.6) })
        await stills("about-in", at: offsets + [800], { app.perform(.about) }, back: { app.isAboutShown = false; await pause(0.6) })
        await stills("openquickly-in", at: [16, 50, 100, 180], { OpenViewsAutomation.press(.character("o"), modifiers: [.control, .shift]) },
                     back: { OpenViewsAutomation.press(.escape) })
        // Hover over toolbar buttons (the hover state).
        for k in ["tb run", "tb navigator", "tb scheme", "tb inspector", "tb add editor", "selector 2"] {
            if let f = OpenViewsAutomation.identifiedFrames()[k] {
                OpenViewsAutomation.move(to: center(f))
                await shot("hover-\(k)", settle: 0.4)
                OpenViewsAutomation.move(to: CGPoint(x: f.midX, y: f.maxY + 300))
                await pause(0.2)
            }
        }
    }

    // MARK: Editor

    func editor() async {
        guard let w else { return }
        let name = env["YCODE_IDE_TOUR_FILE"] ?? "main.swift"
        if w.document == nil { await openFile(name) }
        await shot("file")
        guard let s = OpenViewsAutomation.identifiedFrames()["source"] ?? OpenViewsAutomation.identifiedFrames()["editor"] else { say("no editor"); return }
        // Click in the text on line 3, then the end of the file.
        await OpenViewsAutomation.click(at: CGPoint(x: s.minX + 120, y: s.minY + 40))
        await pause(0.3)
        OpenViewsAutomation.press(.downArrow, modifiers: [.control])
        OpenViewsAutomation.press(.end, modifiers: [.control])
        await pause(0.3)
        OpenViewsAutomation.press(.return)
        // Completion: type a prefix.
        OpenViewsAutomation.type("gre")
        await pause(1.6)
        await shot("completion-typed")
        OpenViewsAutomation.press(.downArrow)
        await pause(0.3)
        await shot("completion-down")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        OpenViewsAutomation.press(.space, modifiers: [.control])
        await pause(1.5)
        await shot("completion-ctrl-space")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        OpenViewsAutomation.press(.backspace)
        OpenViewsAutomation.press(.backspace)
        OpenViewsAutomation.press(.backspace)
        OpenViewsAutomation.press(.backspace)
        await pause(0.3)
        // Quick Help: Alt-click a word on line 1.
        await OpenViewsAutomation.click(at: CGPoint(x: s.minX + 80, y: s.minY + 10), modifiers: [.option])
        await pause(2.0)
        await shot("quickhelp-alt-click")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        // The jump bar's segments.
        for (k, f) in OpenViewsAutomation.identifiedFrames().filter({ $0.key.hasPrefix("jump path title") || $0.key == "jump bar symbol" || $0.key == "jump bar grid" }).sorted(by: { $0.value.minX < $1.value.minX }) {
            await OpenViewsAutomation.click(at: center(f))
            await pause(0.5)
            dumpPopups("jump bar \(k)")
            await shot("jumpbar-\(k)", settle: 0.05)
            await escapeAll()
        }
        // Find and replace.
        OpenViewsAutomation.press(.character("f"), modifiers: [.control])
        await pause(0.4)
        OpenViewsAutomation.type("print")
        await pause(0.4)
        await shot("find")
        if let m = OpenViewsAutomation.identifiedFrames()["find mode"] {
            await OpenViewsAutomation.click(at: center(m))
            await pause(0.4)
            dumpPopups("find mode")
            await shot("find-mode-menu", settle: 0.05)
            await escapeAll()
        }
        for k in ["find case", "find word", "find regex"] {
            if let f = OpenViewsAutomation.identifiedFrames()[k] { await OpenViewsAutomation.click(at: center(f)); await pause(0.3) }
        }
        await shot("find-options-on")
        OpenViewsAutomation.press(.character("f"), modifiers: [.control, .option])
        await pause(0.4)
        await shot("find-replace")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        // Ctrl+Shift-click (multi-cursor on macOS: ⌃⇧-click).
        await OpenViewsAutomation.click(at: CGPoint(x: s.minX + 100, y: s.minY + 30))
        await OpenViewsAutomation.click(at: CGPoint(x: s.minX + 100, y: s.minY + 66), modifiers: [.control, .shift])
        await pause(0.3)
        await shot("ctrl-shift-click")
        OpenViewsAutomation.type("X")
        await pause(0.3)
        await shot("ctrl-shift-click-typed")
        OpenViewsAutomation.press(.character("z"), modifiers: [.control])
        await pause(0.3)
        // Alt-drag (column selection on macOS).
        // Comment toggle.
        OpenViewsAutomation.press(.character("/"), modifiers: [.control])
        await pause(0.3)
        await shot("comment")
        OpenViewsAutomation.press(.character("/"), modifiers: [.control])
        await pause(0.3)
        // Fold (⌥⌘← on macOS: Alt+Ctrl+Left here).
        OpenViewsAutomation.press(.leftArrow, modifiers: [.option, .control])
        await pause(0.3)
        await shot("fold-shortcut")
        // Re-indent (⌃I).
        OpenViewsAutomation.press(.character("i"), modifiers: [.control])
        await pause(0.3)
        await shot("reindent-shortcut")
        // The editor's context menu.
        await OpenViewsAutomation.click(at: CGPoint(x: s.minX + 150, y: s.minY + 40), button: 3)
        await pause(0.4)
        dumpPopups("editor context")
        await shot("editor-context", settle: 0.05)
        await escapeAll()
        // Split, then the canvas.
        w.perform(.splitEditor)
        await shot("split-right", settle: 0.8)
        w.perform(.splitEditorBelow)
        await shot("split-below", settle: 0.8)
        w.perform(.toggleCanvas)
        await shot("canvas", settle: 1.5)
        w.perform(.toggleCanvas)
        // Open Quickly with typing.
        OpenViewsAutomation.press(.character("o"), modifiers: [.control, .shift])
        await pause(0.5)
        OpenViewsAutomation.type("gre")
        await pause(0.8)
        await shot("openquickly")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        // The project's row: the project editor.
        if let first = w.projectRows.first, let p = rowText(first.title) {
            await OpenViewsAutomation.click(at: p)
            await pause(1.0)
            say("project row clicked: \(ShellDriver.state(app).prefix(200)) editorKind=\(w.editorKind)")
            await shot("project-row")
        }
        // An .xcodeproj row if the navigator lists one.
        if let proj = w.projectRows.first(where: { $0.title.hasSuffix(".xcodeproj") }), let p = rowText(proj.title) {
            await OpenViewsAutomation.click(at: p)
            await pause(1.0)
            await shot("xcodeproj-row")
        }
    }

    // MARK: Build

    func buildPart() async {
        guard let w else { return }
        if let p = path("main.swift") { w.open(p); await pause(0.6) }
        let start = Date()
        w.perform(.build)
        var shots = 0
        while w.isBusy || Date().timeIntervalSince(start) < 1 {
            await pause(0.25)
            if shots < 6, Int(Date().timeIntervalSince(start) * 4) % 4 == 0 { shots += 1; await shot("building-\(shots)", settle: 0) }
            if Date().timeIntervalSince(start) > 300 { break }
        }
        say(String(format: "build took %.1f s: %@", Date().timeIntervalSince(start), ShellDriver.state(app)))
        await shot("built-bezel", settle: 0.1)
        await pause(2.5)
        await shot("built")
        w.navigator = .issues
        await shot("issues")
        if let first = w.allIssues.first(where: { $0.file != nil }) {
            await ShellDriver.clickNavigatorText(first.message, dx: 20)
            await shot("issue-opened", settle: 0.8)
        }
        w.navigator = .reports
        await shot("reports")
        let texts = OpenViewsAutomation.texts().filter { !$0.inPopup && ShellDriver.inNavigator($0.frame) }.sorted { $0.frame.minY < $1.frame.minY }
        say("reports texts: \(texts.prefix(12).map(\.text))")
        if let row = texts.first(where: { $0.text.contains("Build") }) {
            await OpenViewsAutomation.click(at: center(row.frame))
            await shot("report-build", settle: 0.8)
        }
        w.isDebugAreaShown = true
        await shot("debug-area-log")
    }

    // MARK: Files

    func files() async {
        guard let w else { return }
        let names = env["YCODE_IDE_TOUR_FILES"].map { $0.split(separator: ",").map(String.init) }
            ?? w.root.allFiles.prefix(40).map(\.name)
        for name in names {
            await openFile(name)
            say("file \(name): editorKind=\(w.editorKind) document=\(w.document?.name ?? "none")")
            await shot("file-\(name)", settle: 1.0)
            menuTable("file \(name)")
        }
    }

    // MARK: Settings

    func settings() async {
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        await pause(1.2)
        say("windows: \(OpenViewsAutomation.windowCount) scenes \(OpenViewsAutomation.windowSceneIDs)")
        guard OpenViewsAutomation.windowCount > 1 else { say("settings: no window"); return }
        await shot("settings-open", window: 1)
        let rows = OpenViewsAutomation.texts(1).filter { !$0.inPopup && $0.frame.maxX < 180 && $0.frame.minY > 30 }.sorted { $0.frame.minY < $1.frame.minY }
        say("settings sidebar: \(rows.map(\.text))")
        for r in rows {
            await timed("pane-\(r.text)", ms: 500, window: 1, stills: [0, 50, 120, 250]) {
                await OpenViewsAutomation.click(at: center(r.frame), window: 1)
            }
            await shot("settings-\(r.text)", window: 1, settle: 0.3)
        }
        // The keyboard in the sidebar.
        if let first = rows.first {
            await OpenViewsAutomation.click(at: center(first.frame), window: 1)
            await pause(0.3)
            OpenViewsAutomation.press(.downArrow, window: 1)
            await pause(0.4)
            await shot("settings-down", window: 1)
        }
        OpenViewsAutomation.press(.escape, window: 1)
        await pause(0.5)
        say("settings after Escape: windows \(OpenViewsAutomation.windowCount)")
        if OpenViewsAutomation.windowCount > 1 {
            OpenViewsAutomation.press(.character("w"), modifiers: [.control], window: 1)
            await pause(0.6)
            say("settings after Ctrl+W: windows \(OpenViewsAutomation.windowCount)")
        }
    }

    // MARK: Size

    func size() async {
        if let w {
            if let p = path(env["YCODE_IDE_TOUR_FILE"] ?? "Sample.swift") ?? w.root.allFiles.first(where: { $0.name.hasSuffix(".swift") })?.path { w.open(p) }
            w.isDebugAreaShown = true
            w.isInspectorShown = true
        }
        let s = OpenViewsAutomation.windowSize()
        say("window \(s.map { "\($0.points.width)x\($0.points.height) pt" } ?? "?")")
        await shot("size-\(Int(s?.points.width ?? 0))x\(Int(s?.points.height ?? 0))", settle: 1.5)
        if let w {
            w.isDebugAreaShown = false
            await shot("size-no-debug", settle: 0.8)
        }
    }
}
#endif
