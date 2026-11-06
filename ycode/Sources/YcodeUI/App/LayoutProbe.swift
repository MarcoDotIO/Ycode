import AppKit
import Foundation
import YcodeIDECore
import YcodeProject

/// The layout probe (`specs/ide/metrics.md` §14): with
/// `YCODE_LAYOUT_PROBE=<out.json>` the app opens a workspace window on a
/// project at the default size (1400 × 900), lets layout settle, writes
/// the frames of the IDE's chrome in window points (origin at the top
/// left) and each one against its `metrics.md` value, then quits. It needs
/// no developer tools, so it runs on any Mac with the app, including the
/// CI runner and older systems (`scripts/layout-probe.sh`).
///
/// Environment (all optional except the first):
/// - `YCODE_LAYOUT_PROBE`: where the JSON report goes.
/// - `YCODE_LAYOUT_PROBE_PROJECT`: the project, workspace or package to
///   open; by default a package "Demo" (two sources and a test target) in
///   a temporary folder, as `UISpacingTests` opens.
/// - `YCODE_LAYOUT_PROBE_SHOTS`: a folder for `cacheDisplay` snapshots of
///   each state (no screen capture, so no privacy permission).
/// - `YCODE_LAYOUT_PROBE_SETTLE`: seconds to let layout settle per state
///   (default 1.5).
/// - `YCODE_LAYOUT_PROBE_SHOW=1`: order the windows in (behind the
///   others). By default they stay off screen, as in the tests.
///
/// The probe reads its values from the same views the spacing tests read
/// (`UISpacingTests`, `NavigatorInspectorR45Tests`, `LiquidGlassTests`),
/// so a probe run on another macOS tells which of those checks would hold
/// there. It uses its own preferences domain in a temporary folder and
/// writes no window frames or workspace state.
@MainActor
public enum LayoutProbe {
    /// A frame in window points, origin at the top left.
    public struct Frame: Codable, Equatable {
        public var x, y, w, h: Double
        public var maxX: Double { x + w }
        public var maxY: Double { y + h }
    }

    /// One value against its spec value: `op` is "=", "<=" or ">=".
    public struct Measure: Codable {
        public var name: String
        public var value: Double
        public var spec: Double?
        public var op: String
        public var tolerance: Double
        public var source: String
        /// value − spec (nil without a spec).
        public var delta: Double?
        /// Whether the value meets the spec within the tolerance.
        public var ok: Bool?
    }

    /// The probe's report.
    public struct Report: Codable {
        public var macOS: String
        public var macOSVersion: String
        public var backingScale: Double
        public var screen: Frame?
        public var glass: Bool
        public var shown: Bool
        public var windows: [String: Frame] = [:]
        public var frames: [String: Frame] = [:]
        public var measures: [Measure] = []
        public var notes: [String] = []
    }

    /// Collects frames and measures.
    @MainActor public final class Recorder {
        public private(set) var frames: [String: Frame] = [:]
        public private(set) var measures: [Measure] = []
        let root: NSView

        init(root: NSView) { self.root = root }

        /// A recorder for `window`'s frame view, laid out.
        public convenience init?(window: NSWindow) {
            guard let frame = window.contentView?.superview else { return nil }
            frame.layoutSubtreeIfNeeded()
            self.init(root: frame)
        }

        /// `v`'s frame in window points (origin at the top left).
        public func box(_ v: NSView) -> Frame {
            let r = v.convert(v.bounds, to: nil)
            return Frame(x: Double(r.minX), y: Double(root.bounds.height - r.maxY), w: Double(r.width), h: Double(r.height))
        }

        func rect(_ r: NSRect, in v: NSView) -> Frame {
            let w = v.convert(r, to: nil)
            return Frame(x: Double(w.minX), y: Double(root.bounds.height - w.maxY), w: Double(w.width), h: Double(w.height))
        }

        @discardableResult
        func frame(_ name: String, _ f: Frame) -> Frame {
            frames[name] = f
            return f
        }

        @discardableResult
        func frame(_ name: String, _ v: NSView?) -> Frame? {
            guard let v, v.window != nil else { return nil }
            return frame(name, box(v))
        }

        func measure(_ name: String, _ value: Double, _ op: String = "=", _ spec: Double?, tolerance: Double = 0.5, source: String) {
            var m = Measure(name: name, value: value, spec: spec, op: op, tolerance: tolerance, source: source)
            if let spec {
                m.delta = value - spec
                switch op {
                case "<=": m.ok = value <= spec + tolerance
                case ">=": m.ok = value >= spec - tolerance
                default: m.ok = abs(value - spec) <= tolerance
                }
            }
            measures.append(m)
        }

        /// The given edges of a frame against their spec values.
        func edges(_ name: String, _ f: Frame?, x: Double? = nil, y: Double? = nil, maxX: Double? = nil, maxY: Double? = nil,
                   w: Double? = nil, h: Double? = nil, tolerance: Double = 0.5, source: String) {
            guard let f else { return }
            for (edge, value, spec) in [("x", f.x, x), ("y", f.y, y), ("maxX", f.maxX, maxX), ("maxY", f.maxY, maxY), ("w", f.w, w), ("h", f.h, h)] {
                if let spec { measure("\(name).\(edge)", value, "=", spec, tolerance: tolerance, source: source) }
            }
        }
    }

    // MARK: Launch

    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    /// Whether this launch is a probe run.
    public static var isRequested: Bool { environment["YCODE_LAYOUT_PROBE"]?.isEmpty == false }
    private static var running: Runner?

    /// Before anything reads the preferences: a fresh domain in a
    /// temporary folder, so the probe neither sees nor changes the user's.
    public static func prepareIfRequested() {
        guard isRequested else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-layout-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = UserDefaults(suiteName: dir.appendingPathComponent("defaults").path) {
            Preferences.shared = Preferences(defaults: d, themesDirectory: dir.appendingPathComponent("Themes"))
        }
    }

    /// Starts the probe when asked; true when it runs (the app then opens
    /// nothing else and quits when the probe is done).
    public static func startIfRequested() -> Bool {
        guard let out = environment["YCODE_LAYOUT_PROBE"], !out.isEmpty else { return false }
        let r = Runner(out: URL(fileURLWithPath: out), environment: environment)
        running = r
        r.start()
        return true
    }

    // MARK: Measuring (shared with the tests)

    /// The workspace window's chrome in its default layout.
    public static func measureWorkspace(_ wc: WorkspaceWindowController, into r: Recorder) {
        guard let win = wc.window else { return }
        let src = "metrics.md"
        // §3 Toolbar.
        let toolbarHeight = Double(r.root.bounds.height - win.contentLayoutRect.maxY)
        r.measure("toolbar.height", toolbarHeight, "=", 52, source: "\(src) §3")
        measureToolbar(win, into: r)
        let glass = GlassBars.enabled
        // The glass toolbar's positions. Before macOS 26 the toolbar keeps
        // the earlier design (liquid-glass-ycode.md §2: bordered controls
        // 40 tall at y 6, the earlier segment widths), which no spec gives
        // positions for; only the activity icon's gap applies there.
        if glass {
            r.edges("toolbar.run", r.frames["toolbar.run"], x: 208.5, maxX: 281.5, source: "\(src) §3")
            r.edges("toolbar.history", r.frames["toolbar.history"], x: 297.5, maxX: 370.5, source: "\(src) §3")
        }
        // The activity icon 14 after Back | Forward: x 385 (liquid-glass.md §7.1).
        if let history = r.frames["toolbar.history"], wc.activityView.window != nil, !wc.activityView.isHiddenOrHasHiddenAncestor {
            let icon = r.frame("toolbar.activityIcon", r.box(wc.activityView.icon))
            r.measure("toolbar.activityIcon.gapAfterHistory", icon.x - history.maxX, "=", Double(ActivityView.gapAfterNeighbor),
                      source: "liquid-glass.md §7.1")
            if glass { r.measure("toolbar.activityIcon.x", icon.x, "=", 385, source: "liquid-glass.md §7.1") }
        }

        // §2 Navigator.
        let nav = wc.navigator
        let navArea = r.frame("navigator.area", nav.view)
        r.edges("navigator.area", navArea, x: 0, w: Double(WorkspaceWindowController.navigatorWidth), source: "\(src) §2")
        r.edges("navigator.selector", r.frame("navigator.selector", nav.selectorView), x: glass ? 6 : nil, y: glass ? 51 : nil,
                w: glass ? 278 : nil, h: glass ? 30 : nil, source: "\(src) §2")
        if glass {
            r.edges("navigator.selectorPill", r.frame("navigator.selectorPill", nav.selectorPill), w: 30, h: 24, source: "\(src) §2")
        }
        let o = nav.outlineView
        if o.numberOfRows > 0, let sel = r.frames["navigator.selector"] {
            let row = r.frame("navigator.row0", r.rect(o.rect(ofRow: 0), in: o))
            r.measure("navigator.row0.gapBelowSelector", row.y - sel.maxY, "=", Double(NavigatorAreaController.firstRowGap), source: "\(src) §2")
            r.measure("navigator.row0.h", row.h, "=", 22, source: "\(src) §2")
        }
        if glass {
            let h = Double(r.root.bounds.height)
            r.edges("navigator.plus", r.frame("navigator.plus", nav.plusGlass), x: 6, maxY: h - 7, w: 31, h: 30, source: "\(src) §2")
            r.edges("navigator.filterCapsule", r.frame("navigator.filterCapsule", nav.filterGlass), x: 42, maxX: 284, maxY: h - 7, h: 30,
                    source: "\(src) §2")
        }
        for i in 0..<CommandTable.navigators.count {
            nav.select(i)
            nav.view.layoutSubtreeIfNeeded()
            measureFilter(nav, prefix: "navigator[\(i)]", into: r)
        }
        nav.select(0)
        nav.view.layoutSubtreeIfNeeded()

        // §4 Editor.
        let e = wc.editor
        let bar = r.frame("editor.jumpBar", e.jumpBar)
        r.edges("editor.jumpBar", bar, y: 52, h: 34, source: "\(src) §12.3, UISpacingTests")
        if let bar, let scroll = r.frame("editor.scrollView", e.scrollView) {
            r.measure("editor.textTop", scroll.y + Double(e.scrollView.contentInsets.top), "=", bar.maxY, source: "UISpacingTests")
        }
        r.frame("editor.area", wc.editorArea.view)
        let debugBar = r.frame("editor.debugBar", wc.debugArea.debugBar)
        r.edges("editor.debugBar", debugBar, maxY: Double(r.root.bounds.height), h: Double(DebugAreaController.debugBarHeight),
                source: "\(src) §4")

        // §5 Inspector.
        let insp = wc.inspector
        insp.view.layoutSubtreeIfNeeded()
        if let area = r.frame("inspector.area", insp.view) {
            r.measure("inspector.area.w", area.w, "=", Double(WorkspaceWindowController.inspectorWidth), source: "\(src) §5")
            if glass {
                r.edges("inspector.tabs", r.frame("inspector.tabs", insp.tabBarView), x: area.x + 6, y: 51, maxX: area.maxX - 6, h: 30,
                        source: "LiquidGlassTests, liquid-glass-ycode.md §3")
                r.edges("inspector.tabPill", r.frame("inspector.tabPill", insp.tabPill), w: 78, h: 24, source: "\(src) §5")
            } else {
                r.frame("inspector.tabs", insp.tabBarView)
            }
            if let name = r.frame("inspector.name", insp.nameField) {
                r.measure("inspector.name.trailingInset", area.maxX - name.maxX, "=", 7, tolerance: 1, source: "\(src) §12.4, UISpacingTests")
            }
            let inset = Double(InspectorAreaController.contentInset)
            for key in insp.fileControls.keys.sorted() {
                guard let c = insp.fileControls[key], let f = r.frame("inspector.row.\(key)", c) else { continue }
                if ["Type", "Location", "Text Encoding", "Line Endings", "Indent Using"].contains(key) {
                    r.measure("inspector.row.\(key).trailingInset", area.maxX - f.maxX, ">=", inset, tolerance: 1, source: "UISpacingTests")
                    r.measure("inspector.row.\(key).leadingInset", f.x - area.x, ">=", inset, tolerance: 0, source: "UISpacingTests")
                }
            }
        }
    }

    /// The navigator's filter field, its options pull-down, the text and
    /// the toggles (`NavigatorInspectorR45Tests.filterOptionsAndTogglesSitInsideTheField`).
    public static func measureFilter(_ nav: NavigatorAreaController, prefix: String, into r: Recorder) {
        guard let field = nav.filter as? NavigatorFilterField, !field.isHiddenOrHasHiddenAncestor else { return }
        let src = "NavigatorInspectorR45Tests (reference-ui-6.md §5.6)"
        let f = r.frame("\(prefix).filter", r.box(field))
        let opts = r.frame("\(prefix).filterOptions", r.rect(nav.filterOptions.alignmentRect(forFrame: nav.filterOptions.frame),
                                                               in: nav.filterOptions.superview ?? nav.view))
        let text = r.frame("\(prefix).filterText", r.rect(field.rectForSearchText(whenCentered: false), in: field))
        // Horizontally the button's frame, from which it draws its glyph,
        // against the field's alignment rectangle, which the layout uses.
        let optsFrame = r.rect(nav.filterOptions.frame, in: nav.filterOptions.superview ?? nav.view)
        let fieldAlign = r.rect(field.alignmentRect(forFrame: field.frame), in: field.superview ?? nav.view)
        r.measure("\(prefix).options.leadingGap", optsFrame.x - fieldAlign.x, "=", NavigatorFilterField.optionsLeading, tolerance: 0.5,
                  source: "metrics.md §15")
        r.measure("\(prefix).options.inside", (opts.x >= f.x - 0.01 && opts.maxX <= f.maxX + 0.01 && opts.y >= f.y - 0.01 && opts.maxY <= f.maxY + 0.01) ? 1 : 0,
                  "=", 1, tolerance: 0, source: src)
        r.measure("\(prefix).text.afterOptions", text.x - optsFrame.maxX, ">=", 0, source: src)
        var last: Frame?
        for (k, b) in nav.toggleButtons.filter({ !$0.isHidden }).enumerated() {
            let t = r.frame("\(prefix).toggle\(k)", r.box(b))
            r.measure("\(prefix).toggle\(k).inside",
                      (t.x >= f.x - 0.5 && t.maxX <= f.maxX + 0.5 && t.y >= f.y - 0.5 && t.maxY <= f.maxY + 0.5) ? 1 : 0, "=", 1, tolerance: 0, source: src)
            r.measure("\(prefix).text.beforeToggle\(k)", t.x - text.maxX, ">=", 0, source: src)
            last = t
        }
        if let last {
            r.measure("\(prefix).toggles.trailingGap", f.maxX - last.maxX, "<=", 6, tolerance: 0, source: src)
        }
    }

    /// The debug area's bottom bars (metrics.md §7), with the area open.
    public static func measureDebugArea(_ wc: WorkspaceWindowController, into r: Recorder) {
        let d = wc.debugArea
        let height = Double(r.root.bounds.height)
        r.frame("debug.area", d.view)
        for (name, bar) in [("debug.variablesBar", d.variablesBarStack), ("debug.consoleBar", d.consoleBarStack)] {
            guard let bar, let b = r.frame(name, bar) else { continue }
            r.edges(name, b, maxY: height, h: Double(DebugAreaController.bottomBarHeight), source: "metrics.md §7")
            // The drawn controls (their alignment rectangles, which the stack
            // view centres): before macOS 26 a small pop-up's frame reaches
            // 2 points further down than its bezel (metrics.md §14.1).
            var lowest = Double.infinity
            for (i, v) in bar.arrangedSubviews.enumerated() where !v.isHidden {
                r.frame("\(name).control\(i)", r.box(v))
                let drawn = r.frame("\(name).control\(i).drawn", r.rect(v.alignmentRect(forFrame: v.frame), in: v.superview ?? bar))
                lowest = min(lowest, height - drawn.maxY)
            }
            if lowest.isFinite { r.measure("\(name).controlsAboveBottom", lowest, ">=", 3.5, tolerance: 0, source: "UISpacingTests") }
        }
    }

    /// Device Hub's toolbar (metrics.md §9): the Hide Sidebar circle and
    /// Add Device | Filter at the sidebar's edge.
    public static func measureDeviceHub(_ w: NSWindow, into r: Recorder) {
        measureToolbar(w, prefix: "hub.toolbar", into: r)
        measureHubOverflow(w, prefix: "hub.toolbar", into: r)
        let toggle = toolbarControls(w).first { ($0 as? NSButton)?.action == #selector(NSSplitViewController.toggleSidebar(_:)) }
        let edge = 240.0
        if let toggle {
            let t = r.frame("hub.hideSidebar", r.box(toggle))
            r.measure("hub.hideSidebar.gapToSidebarEdge", edge - t.maxX, "=", 7, tolerance: 1.5, source: "metrics.md §9, UISpacingTests")
        }
    }

    /// The toolbar's items in its overflow menu ("»") with the window 1100
    /// wide (device-hub.md §I.13: none). The window keeps its own width
    /// afterwards.
    static func measureHubOverflow(_ w: NSWindow, prefix: String, into r: Recorder) {
        guard let tb = w.toolbar else { return }
        let old = w.frame
        w.setContentSize(NSSize(width: 1100, height: w.contentLayoutRect.height))
        w.contentView?.layoutSubtreeIfNeeded()
        w.displayIfNeeded()
        let shown = tb.items.filter { i in
            if #available(macOS 15.0, *), i.isHidden { return false }
            return ![.flexibleSpace, .space, .sidebarTrackingSeparator, .inspectorTrackingSeparator].contains(i.itemIdentifier)
        }
        let visible = Set((tb.visibleItems ?? []).map(\.itemIdentifier))
        let over = shown.map(\.itemIdentifier.rawValue).filter { !visible.contains(NSToolbarItem.Identifier($0)) }
        r.measure("\(prefix).overflowedAt1100", Double(over.count), "=", 0, tolerance: 0, source: "device-hub.md §I.13, DeviceHubR3Tests")
        for id in over {
            r.measure("\(prefix).overflowed.\(id.split(separator: ".").last.map(String.init) ?? id)", 1, "=", 0, tolerance: 0,
                      source: "device-hub.md §I.13 (window \(Int(w.frame.width)) wide)")
        }
        w.setFrame(old, display: false)
        w.contentView?.layoutSubtreeIfNeeded()
    }

    /// The toolbar's controls (outside the content view, in the top 60
    /// points), not the window's own buttons.
    static func toolbarControls(_ w: NSWindow) -> [NSView] {
        guard let frame = w.contentView?.superview else { return [] }
        let content = w.contentView
        let standard = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
        var out: [NSView] = []
        func walk(_ v: NSView) {
            if v === content { return }
            if let c = v as? NSControl, !standard.contains(where: { $0 === c }), !c.isHiddenOrHasHiddenAncestor {
                let r = c.convert(c.bounds, to: nil)
                if frame.bounds.height - r.maxY < 60, r.width > 0 { out.append(c) }
                return
            }
            for s in v.subviews { walk(s) }
        }
        walk(frame)
        return out
    }

    /// Every toolbar item by its identifier: an item's own view, or the
    /// system's button whose action or label is the item's. Other controls
    /// (the system's own items) are numbered.
    static func measureToolbar(_ w: NSWindow, prefix: String = "toolbar", into r: Recorder) {
        let items = w.toolbar?.items ?? []
        func key(_ i: NSToolbarItem) -> String {
            let id = i.itemIdentifier.rawValue
            return "\(prefix).\(id.split(separator: ".").last.map(String.init) ?? id)"
        }
        for i in items where !i.isHidden {
            if let v = i.view, v.window != nil, !v.isHiddenOrHasHiddenAncestor { r.frame(key(i), r.box(v)) }
        }
        var unnamed = 0
        for c in toolbarControls(w) where !items.contains(where: { i in i.view.map { c === $0 || c.isDescendant(of: $0) } ?? false }) {
            let item = items.first { i in
                if let b = c as? NSButton, let a = i.action, b.action == a { return true }
                let label = c.accessibilityLabel() ?? c.toolTip ?? ""
                return !label.isEmpty && (label == i.label || label == i.toolTip)
            }
            var name: String
            if let item { name = key(item) } else {
                name = "\(prefix).control\(unnamed)"
                unnamed += 1
            }
            if r.frames[name] != nil { name += ".\(Int(r.box(c).x))" }
            r.frame(name, r.box(c))
        }
    }

    // MARK: The run

    /// Runs the probe's steps on the main run loop, a settle delay apart.
    @MainActor final class Runner {
        let out: URL
        let env: [String: String]
        let settle: TimeInterval
        let show: Bool
        let shots: URL?
        var report: Report
        var wc: WorkspaceWindowController?
        var tempProject: URL?
        var hub: DevicesController?
        var hubWindow: NSWindow?

        init(out: URL, environment: [String: String]) {
            self.out = out
            env = environment
            settle = environment["YCODE_LAYOUT_PROBE_SETTLE"].flatMap(Double.init) ?? 1.5
            show = environment["YCODE_LAYOUT_PROBE_SHOW"] == "1"
            shots = environment["YCODE_LAYOUT_PROBE_SHOTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let screen = NSScreen.main
            report = Report(macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                            macOSVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                            backingScale: Double(screen?.backingScaleFactor ?? 0),
                            screen: screen.map { Frame(x: 0, y: 0, w: Double($0.frame.width), h: Double($0.frame.height)) },
                            glass: GlassBars.enabled, shown: show)
        }

        /// `<out>.pid` holds the process id while the probe runs, so a
        /// runner can end exactly this process after a timeout.
        var pidFile: URL { out.appendingPathExtension("pid") }

        func start() {
            try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: pidFile, atomically: true, encoding: .utf8)
            do {
                try openWorkspace()
            } catch {
                report.notes.append("could not open the workspace: \(error)")
                finish()
                return
            }
            after { self.measureWorkspaceState() }
        }

        func after(_ step: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { MainActor.assumeIsolated { step() } }
        }

        func openWorkspace() throws {
            let project: URL
            if let p = env["YCODE_LAYOUT_PROBE_PROJECT"], !p.isEmpty {
                project = URL(fileURLWithPath: p)
            } else {
                project = try LayoutProbe.demoPackage()
                tempProject = project.deletingLastPathComponent()
            }
            let state = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-layout-probe-state-\(UUID().uuidString).plist")
            let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: project)), loadDestinations: false,
                                               startLanguageService: false, openFirstFile: false, userStateURL: state)
            self.wc = wc
            guard let win = wc.window else { return }
            win.setFrameAutosaveName("")
            win.isRestorable = false
            win.appearance = NSAppearance(named: env["YCODE_LAYOUT_PROBE_APPEARANCE"] == "dark" ? .darkAqua : .aqua)
            place(win, size: WorkspaceWindowController.defaultSize)
            wc.applyDefaultLayout()
            let model = project.appendingPathComponent("Sources/Demo/Model.swift")
            if tempProject != nil { wc.open(path: model.path, line: nil) } else { wc.openFirstSourceFile() }
            win.contentView?.layoutSubtreeIfNeeded()
        }

        /// The window at `size`, at the screen's top left; ordered in
        /// behind every other window only when asked.
        func place(_ win: NSWindow, size: NSSize) {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            win.setFrame(NSRect(x: visible.minX, y: visible.maxY - size.height, width: size.width, height: size.height), display: false)
            if show {
                win.orderBack(nil)
                // Ordering in may fit the window to a smaller screen; the
                // probe wants the default size.
                win.setFrame(NSRect(x: visible.minX, y: visible.maxY - size.height, width: size.width, height: size.height), display: true)
            }
            if win.frame.size != size {
                report.notes.append("\(win.title): \(Int(win.frame.width)) x \(Int(win.frame.height)) instead of \(Int(size.width)) x \(Int(size.height))"
                                    + " (the screen is smaller); y values near the bottom differ")
            }
        }

        func recorder(_ win: NSWindow) -> Recorder? { Recorder(window: win) }

        func merge(_ r: Recorder, window name: String, _ win: NSWindow) {
            report.windows[name] = Frame(x: 0, y: 0, w: Double(win.frame.width), h: Double(win.frame.height))
            report.frames.merge(r.frames) { _, b in b }
            report.measures += r.measures
            if report.backingScale == 0 { report.backingScale = Double(win.backingScaleFactor) }
            snapshot(win, name)
        }

        func snapshot(_ win: NSWindow, _ name: String) {
            guard let shots, let frame = win.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent("\(name).png"))
        }

        func measureWorkspaceState() {
            guard let wc, let win = wc.window, let r = recorder(win) else { return finish() }
            LayoutProbe.measureWorkspace(wc, into: r)
            merge(r, window: "workspace", win)
            wc.toggleDebugArea(nil)
            after { self.measureDebugState() }
        }

        func measureDebugState() {
            guard let wc, let win = wc.window, let r = recorder(win) else { return finish() }
            LayoutProbe.measureDebugArea(wc, into: r)
            merge(r, window: "workspace-debug", win)
            win.close()
            measurePlainNavigator()
            openDeviceHub()
            after { self.measureHubState() }
        }

        /// The navigator alone in a 280 × 600 window with a small tree, as
        /// `NavigatorInspectorR45Tests.laidOutNavigator` lays it out.
        func measurePlainNavigator() {
            let nav = NavigatorAreaController()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.contentView = nav.view
            nav.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
            nav.setProjectTree(NavigatorNode(name: "App", kind: .container, path: "/tmp/App.xcodeproj", children: [
                NavigatorNode(name: "A", kind: .group, path: "/tmp/A", children: [NavigatorNode(name: "a.swift", kind: .file, path: "/tmp/A/a.swift")]),
                NavigatorNode(name: "b.swift", kind: .file, path: "/tmp/b.swift"),
            ]))
            nav.view.layoutSubtreeIfNeeded()
            guard let r = recorder(w) else { return }
            for i in 0..<CommandTable.navigators.count {
                nav.select(i)
                nav.view.layoutSubtreeIfNeeded()
                LayoutProbe.measureFilter(nav, prefix: "plainNavigator[\(i)]", into: r)
            }
            merge(r, window: "navigator-plain", w)
            w.close()
        }

        func openDeviceHub() {
            let row = DeviceRow.shutDownYcodeSimulator(name: "Phone (Ycode)", identifier: "layout-probe-1")
            // A booted foldable on a simulator host (as DeviceHubR3Tests selects):
            // its controls widen the toolbar (no connection is made).
            var booted = DeviceRow.shutDownYcodeSimulator(name: "Foldable (Ycode)", identifier: "h:/layout-probe-2")
            booted.state = "Booted"
            booted.osVersion = "27.1"
            booted.model = "Foldable, Ycode Simulator (Linux)"
            booted.isYcodeRemote = true
            booted.isFoldable = true
            booted.deviceTypeID = "iphone-duo"
            let hub = DevicesController(devices: [], simulators: [row, booted])
            let w = hub.makeWindow()
            w.setFrameAutosaveName("")
            hub.splitView.autosaveName = nil
            w.isRestorable = false
            w.appearance = NSAppearance(named: .aqua)
            place(w, size: w.frame.size)
            w.contentView?.layoutSubtreeIfNeeded()
            // What the window does when it first appears.
            if !show { hub.placeFirstDividers() }
            self.hub = hub
            hubWindow = w
        }

        func measureHubState() {
            guard let w = hubWindow, let r = recorder(w) else { return finish() }
            LayoutProbe.measureDeviceHub(w, into: r)
            if let hub, let i = hub.rows.firstIndex(where: { $0.identifier == "h:/layout-probe-2" }) {
                hub.select(row: i)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                LayoutProbe.measureHubOverflow(w, prefix: "hub.booted.toolbar", into: r)
            }
            merge(r, window: "device-hub", w)
            w.close()
            finish()
        }

        func finish() {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try enc.encode(report).write(to: out, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("layout probe: \(error)\n".utf8))
            }
            if let tempProject { try? FileManager.default.removeItem(at: tempProject) }
            try? FileManager.default.removeItem(at: pidFile)
            NSApp.terminate(nil)
        }
    }

    /// A package "Demo" (as `UISpacingTests` opens): two sources and a
    /// test target, in a new temporary folder.
    public static func demoPackage() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-layout-probe-\(UUID().uuidString)").resolvingSymlinksInPath()
        let dir = base.appendingPathComponent("Demo")
        let files = [
            "Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.target(name: \"Demo\"), "
                + ".testTarget(name: \"DemoTests\", dependencies: [\"Demo\"])])\n",
            "Sources/Demo/Model.swift": "public struct Model {\n    public var value = 1\n}\n",
            "Sources/Demo/Helper.swift": "public func helper() -> Int {\n    1\n}\n",
            "Tests/DemoTests/DemoTests.swift": "import Testing\n@Test func t() {}\n",
        ]
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }
}
