import Foundation
import Observation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViews
import OpenViewsCore
#else
import SwiftUI
import SwiftUICore
#endif

// The R9 sample, a "mini IDE", extended in R10/R11: a NavigationSplitView
// with a file outline in the sidebar, a text editor over a scrolling console
// in a draggable vertical split, a sheet (build settings) and an alert
// (delete); since R11 a menu bar (File, Edit, View, Project, …) with
// keyboard shortcuts, a window toolbar with Build and Run, a context menu on
// the outline rows, and a Settings window whose values live in `@AppStorage`
// (R10). Run it with a display (X11 or Wayland) and libSDL3:
//
//   OV_SDL3_LIBRARY=<prefix>/lib/libSDL3.so.0 swift run ov-mini-ide
//
// Environment switches (all optional):
//   OV_SAMPLE_SCRIPT=1        drive it with synthetic events through SDL's
//                             queue (outline, scrolling, the split, menus,
//                             shortcuts, toolbar, context menu, Settings,
//                             sheet, alert), print the state after each
//                             step, quit
//   OV_SCREENSHOT_PREFIX=<p>  write <p>-light.png, -menu.png, -context.png,
//                             -settings.png, -sheet.png, -alert.png and
//                             -dark.png during the script (menus are
//                             composited from their pop-up windows)
//   OV_COLOR_SCHEME=dark      start in dark mode (R10: a platform setting)
//   OV_PRINT_TARGETS=1        print window-coordinate frames of the parts
//                             (for external drivers such as xdotool),
//                             including the items of an open menu
//   OV_QUIT_AFTER=<s>         print the state and quit after s seconds
//                             (OV_SCREENSHOT=<file> writes the window first;
//                             OV_SHOT_REQUEST=<file>: a driver writes a PNG
//                             path there to get a screenshot meanwhile)
//   OV_TRACE=1                trace the app host on stderr

struct FileKey: FocusedValueKey { typealias Value = String }

extension FocusedValues {
    /// The file whose editor has keyboard focus (enables File > Save).
    var editorFile: String? {
        get { self[FileKey.self] }
        set { self[FileKey.self] = newValue }
    }
}

@main
struct MiniIDEApp: App {
    var body: some Scene {
        WindowGroup("OpenViews R11 mini IDE") {
            MiniIDEView()
        }
        .defaultSize(width: 1000, height: 680)
        .commands { IDECommands() }
        Settings {
            IDESettingsView()
        }
    }
}

/// The menu bar's own commands.
struct IDECommands: Commands {
    @FocusedValue(\.editorFile) var editorFile: String?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New File…") { IDEState.shared.newFile() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { IDEState.shared.save() }
                .keyboardShortcut("s")
                .disabled(editorFile == nil)
        }
        CommandMenu("Project") {
            Button("Build") { IDEState.shared.build() }
                .keyboardShortcut("b")
            Button("Run") { IDEState.shared.run() }
                .keyboardShortcut("r")
            Divider()
            Button("Clean Build Folder") { IDEState.shared.clean() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        SidebarCommands()
        ToolbarCommands()
    }
}

/// The Settings window (values in the app's UserDefaults).
struct IDESettingsView: View {
    @AppStorage("ide.editorFontSize") private var fontSize = 13
    @AppStorage("ide.showLineNumbers") private var lineNumbers = true
    @AppStorage("ide.appearance") private var appearance = "System"

    var body: some View {
        Form {
            Section("Editor") {
                Target("settings font") {
                    Stepper("Font size: \(fontSize) pt", value: $fontSize, in: 9...24)
                }
                Target("settings lines") {
                    Toggle("Show line numbers", isOn: $lineNumbers)
                }
            }
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)
            }
        }
        .frame(width: 440, height: 300)
    }
}

@MainActor
func say(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

struct FileItem: Identifiable, Hashable {
    let id: String
    let name: String
    var children: [FileItem]?
    var isFolder: Bool { children != nil }
}

let projectTree: [FileItem] = [
    FileItem(id: "Package.swift", name: "Package.swift", children: nil),
    FileItem(id: "Sources", name: "Sources", children: [
        FileItem(id: "Sources/App", name: "App", children: [
            FileItem(id: "Sources/App/App.swift", name: "App.swift", children: nil),
            FileItem(id: "Sources/App/ContentView.swift", name: "ContentView.swift", children: nil),
        ]),
        FileItem(id: "Sources/Model", name: "Model", children: [
            FileItem(id: "Sources/Model/Store.swift", name: "Store.swift", children: nil),
        ]),
    ]),
    FileItem(id: "Tests", name: "Tests", children: [
        FileItem(id: "Tests/StoreTests.swift", name: "StoreTests.swift", children: nil),
    ]),
    FileItem(id: "README.md", name: "README.md", children: nil),
]

func sourceText(_ id: String) -> String {
    let name = (id as NSString).lastPathComponent
    return """
    // \(name)
    import SwiftUI

    struct \(name.replacingOccurrences(of: ".swift", with: "")): View {
        var body: some View {
            Text("Hello from \(name)")
        }
    }
    """
}

@MainActor
@Observable
final class IDEState {
    static let shared = IDEState()
    var selection: String?
    var text = ""
    var showSettings = false
    var showDelete = false
    var deleted: [String] = []
    var configuration = "Debug"
    var parallel = true
    /// Forces dark mode (the script's last step); nil follows the platform.
    var dark: Bool?
    var console: [String] = (1...200).map { String(format: "[%03d] Compiling module %d of 200", $0, $0) }
    // R11: what the commands did.
    var status = "Ready"
    var builds = 0
    var runs = 0
    var saves = 0
    var cleans = 0
    var newFiles = 0
    var log: [String] = []

    func note(_ s: String) {
        log.append(s)
        console.append("[ide] " + s)
        say("command \(s)")
    }

    func newFile() {
        newFiles += 1
        note("new file \(newFiles)")
    }

    func save() {
        saves += 1
        note("saved \(selection ?? "none")")
    }

    func build() {
        builds += 1
        status = "Build \(builds) succeeded"
        note("build \(builds)")
    }

    func run() {
        runs += 1
        status = "Running (\(runs))"
        note("run \(runs)")
    }

    func clean() {
        cleans += 1
        status = "Cleaned"
        note("clean")
    }

    func describe() -> String {
        "state: selection=\(selection ?? "none") sheet=\(showSettings) alert=\(showDelete) deleted=\(deleted) "
            + "configuration=\(configuration) dark=\(dark.map { "\($0)" } ?? "platform") builds=\(builds) runs=\(runs) "
            + "saves=\(saves) newFiles=\(newFiles) cleans=\(cleans) status=\"\(status)\""
    }
}

/// Marks a part for the drivers (its frame is looked up by name).
struct Target<Content: View>: View, NamedTarget {
    let name: String
    let content: Content
    init(_ name: String, @ViewBuilder content: () -> Content) {
        self.name = name
        self.content = content()
    }
    var body: some View { content }
}

@MainActor protocol NamedTarget { var name: String { get } }

struct MiniIDEView: View {
    @Bindable var state = IDEState.shared
    @AppStorage("ide.appearance") private var appearance = "System"
    @Environment(\.colorScheme) private var platformScheme

    var scheme: ColorScheme {
        if let d = state.dark { return d ? .dark : .light }
        switch appearance {
        case "Dark": return .dark
        case "Light": return .light
        default: return platformScheme
        }
    }

    var body: some View {
        NavigationSplitView {
            Target("outline") {
                List(projectTree, children: \.children, selection: $state.selection) { item in
                    Target("row \(item.id)") {
                        Label(item.name, systemImage: item.isFolder ? "folder" : "doc")
                    }
                }
                .listStyle(.sidebar)
                // R11: a context menu on the outline's rows.
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Open") { state.selection = ids.first }
                        .disabled(ids.isEmpty)
                    Button("Reveal in Console") { state.note("reveal \(ids.sorted().joined(separator: ","))") }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        state.selection = ids.first
                        state.showDelete = true
                    }
                    .disabled(ids.isEmpty)
                }
            }
            .navigationTitle("Project")
        } detail: {
            DetailView(state: state)
        }
        // R11: the window toolbar (outside the navigation containers).
        .toolbar {
            ToolbarItem(placement: .principal) {
                Target("tb status") { Text(state.status).font(.subheadline).foregroundStyle(.secondary) }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Target("tb build") {
                    Button { state.build() } label: { Label("Build", systemImage: "hammer") }
                        .buttonStyle(.bordered)
                }
                Target("tb run") {
                    Button { state.run() } label: { Label("Run", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .environment(\.colorScheme, scheme)
        .onChange(of: platformScheme) { _, s in say("platform colour scheme \(s)") }
        .onChange(of: state.selection) { _, s in
            if let s { state.text = sourceText(s) }
            say("selected \(s ?? "none")")
        }
        .task { await IDEDriver.start() }
    }
}

struct DetailView: View {
    @Bindable var state: IDEState

    var body: some View {
        Group {
            if let file = state.selection {
                VSplitView {
                    Target("editor") {
                        EditorPane(state: state, file: file)
                    }
                    Target("console") {
                        ConsoleView(lines: state.console)
                            .frame(minHeight: 80)
                    }
                }
                .navigationTitle((file as NSString).lastPathComponent)
            } else {
                Text("Select a file in the outline").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Mini IDE")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Target("build") { Button("Build…") { state.showSettings = true }.buttonStyle(.bordered) }
            }
            ToolbarItem(placement: .primaryAction) {
                Target("delete") {
                    Button("Delete", role: .destructive) { state.showDelete = true }
                        .buttonStyle(.bordered)
                        .disabled(state.selection == nil)
                }
            }
        }
        .sheet(isPresented: $state.showSettings) {
            BuildSettingsSheet(state: state)
        }
        .alert("Delete \(((state.selection ?? "") as NSString).lastPathComponent)?", isPresented: $state.showDelete) {
            Button("Delete", role: .destructive) {
                if let s = state.selection { state.deleted.append(s) }
                say("deleted \(state.selection ?? "")")
            }
            Button("Cancel", role: .cancel) { say("delete cancelled") }
        } message: {
            Text("The file moves to the Trash.")
        }
    }
}

/// The editor: its font size and line-number setting come from the
/// Settings window (`@AppStorage`, R10); it publishes its file for File >
/// Save (R11).
struct EditorPane: View {
    @Bindable var state: IDEState
    let file: String
    @AppStorage("ide.editorFontSize") private var fontSize = 13
    @AppStorage("ide.showLineNumbers") private var lineNumbers = true

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if lineNumbers {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(1...9, id: \.self) { n in
                        Text("\(n)").font(.system(size: CGFloat(fontSize)).monospaced()).foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 8)
                .accessibilityHidden(true)
            }
            TextEditor(text: $state.text)
                .font(.system(size: CGFloat(fontSize)).monospaced())
                .focusedValue(\.editorFile, file)
        }
        .frame(minHeight: 120)
    }
}

struct ConsoleView: View {
    let lines: [String]
    var body: some View {
        List(Array(lines.enumerated()), id: \.offset) { pair in
            Text(pair.element).font(.footnote.monospaced())
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 22)
    }
}

struct BuildSettingsSheet: View {
    @Bindable var state: IDEState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Build Settings").font(.headline)
            Picker("Configuration", selection: $state.configuration) {
                Text("Debug").tag("Debug")
                Text("Release").tag("Release")
            }
            .pickerStyle(.segmented)
            Toggle("Parallel build", isOn: $state.parallel)
            HStack {
                Spacer()
                Target("sheet done") {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Automation for the done-criterion runs (see the header).
@MainActor
enum IDEDriver {
    static var started = false
    static let env = ProcessInfo.processInfo.environment

    static func start() async {
        guard !started, let host = AppHost.current else { return }
        started = true
        if env["OV_SAMPLE_SCRIPT"] != nil || env["OV_QUIT_AFTER"] != nil {
            // Reproducible runs: the Settings values start at their defaults.
            for k in ["ide.editorFontSize", "ide.showLineNumbers", "ide.appearance"] { UserDefaults.standard.removeObject(forKey: k) }
        }
        say("backend \(host.backend.name)\((host.backend as? SDLBackend).map { " SDL " + $0.libraryDescription } ?? "")")
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let window = host.windows.first else { return }
        say("window \(window.size.width)x\(window.size.height) pt, scale \(window.platform.scale), "
            + "pixels \(window.platform.pixelSize.width)x\(window.platform.pixelSize.height)")
        if let p = window.presenter as? CompositorPresenter { say("presenter: \(p.description)") }
        if let sdl = host.backend as? SDLBackend {
            say("settings sources: \(sdl.settingsSources) dark=\(sdl.settings.darkAppearance) locale=\(sdl.settings.localeIdentifier)")
        }
        if env["OV_PRINT_TARGETS"] != nil { printTargets(window) }
        if env["OV_SAMPLE_SCRIPT"] != nil { await script(host, window) }
        if let s = env["OV_QUIT_AFTER"], let t = Double(s) {
            var elapsed = 0.0
            // Report the state while an external driver works; a driver can
            // ask for a screenshot by writing its path to OV_SHOT_REQUEST.
            while elapsed < t {
                await pause(0.25)
                elapsed += 0.25
                if let req = env["OV_SHOT_REQUEST"], let path = try? String(contentsOfFile: req, encoding: .utf8) {
                    try? FileManager.default.removeItem(atPath: req)
                    shot(window, path.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if Int(elapsed * 4) % 4 == 0 {
                    if env["OV_PRINT_TARGETS"] != nil { printTargets(window, quiet: true) }
                    report(window)
                }
            }
            say(IDEState.shared.describe())
            if let path = env["OV_SCREENSHOT"] { shot(window, path) }
            host.terminate()
        }
    }

    static func frame(_ name: String, in window: WindowHost) -> CGRect? {
        var out: CGRect?
        window.graph.root?.forEachNode { n in
            if out == nil, !n.isInSuspendedSubtree, let t = n.view as? any NamedTarget, t.name == name {
                out = HitTesting.frame(of: n, mirrorWidth: nil)
            }
        }
        return out
    }

    static func dividers(in window: WindowHost) -> [CGRect] {
        var out: [CGRect] = []
        window.graph.root?.forEachNode { n in
            if !n.isInSuspendedSubtree, String(describing: type(of: n.view)) == "SplitDivider",
               let f = HitTesting.frame(of: n, mirrorWidth: nil) { out.append(f) }
        }
        return out
    }

    /// The console's scroll offset and the split's pane heights.
    static func report(_ window: WindowHost) {
        var offsets: [CGFloat] = []
        window.graph.root?.forEachNode { n in
            if !n.isInSuspendedSubtree, let s = n.primitiveState as? ScrollViewState { offsets.append(s.offset.y) }
        }
        let editor = frame("editor", in: window), console = frame("console", in: window)
        var rows = 0
        window.graph.root?.forEachNode { n in
            if !n.isInSuspendedSubtree, let t = n.view as? any NamedTarget, t.name.hasPrefix("row ") { rows += 1 }
        }
        say(String(format: "report: outline rows=%d scroll offsets=%@ editor height=%.0f console height=%.0f sheet=%@ alert=%@",
                   rows, offsets.map { String(format: "%.0f", $0) }.joined(separator: ","),
                   editor?.height ?? 0, console?.height ?? 0, "\(IDEState.shared.showSettings)", "\(IDEState.shared.showDelete)"))
    }

    /// The frame of a `Text` with this string in `window` (menu titles and
    /// items).
    static func textFrame(_ s: String, in window: WindowHost) -> CGRect? {
        var out: CGRect?
        window.graph.root?.forEachNode { n in
            if out == nil, !n.isInSuspendedSubtree, let t = n.view as? Text, t.plainString == s {
                out = HitTesting.frame(of: n, mirrorWidth: nil)
            }
        }
        return out
    }

    /// The open pop-ups of the main window, outermost first.
    static func popups(_ host: AppHost) -> [WindowHost] { host.windows.filter(\.isPopup) }

    /// A pop-up's origin in the main window (nested submenus add up).
    static func origin(of p: WindowHost) -> CGPoint {
        var o = p.popupOrigin
        var w = p.popupOwner
        while let x = w, x.isPopup {
            o.x += x.popupOrigin.x
            o.y += x.popupOrigin.y
            w = x.popupOwner
        }
        return o
    }

    static func printTargets(_ window: WindowHost, quiet: Bool = false) {
        let scale = window.platform.pixelSize.width > 0 ? Double(window.platform.pixelSize.width) / window.size.width : 1
        // R11: menu titles, the toolbar's buttons and the items of an open menu.
        for title in window.services.menuBar?.menuTitles ?? [] {
            if let f = textFrame(title, in: window) {
                say(String(format: "target menu_%@ %.0f %.0f %.0f %.0f", title.replacingOccurrences(of: " ", with: "_"),
                           f.minX, f.minY, f.width, f.height))
            }
        }
        if let host = AppHost.current {
            for p in popups(host) {
                let o = origin(of: p)
                p.graph.root?.forEachNode { n in
                    guard let t = n.view as? Text, let f = HitTesting.frame(of: n, mirrorWidth: nil) else { return }
                    say(String(format: "target item_%@ %.0f %.0f %.0f %.0f", t.plainString.replacingOccurrences(of: " ", with: "_"),
                               o.x + f.minX, o.y + f.minY, f.width, f.height))
                }
            }
        }
        var names = ["outline", "editor", "console", "build", "delete", "sheet done", "tb build", "tb run", "tb status"]
        for item in allItems(projectTree) { names.append("row \(item.id)") }
        for name in names {
            guard let f = frame(name, in: window) else { continue }
            say(String(format: "target %@ %.0f %.0f %.0f %.0f pixels %.0f %.0f %.0f %.0f", name.replacingOccurrences(of: " ", with: "_"),
                       f.minX, f.minY, f.width, f.height, f.minX * scale, f.minY * scale, f.width * scale, f.height * scale))
        }
        for (i, d) in dividers(in: window).enumerated() {
            say(String(format: "target divider_%d %.0f %.0f %.0f %.0f", i, d.minX, d.minY, d.width, d.height))
        }
        if let alertButton = alertButtonFrame(window, "Delete") {
            say(String(format: "target alert_delete %.0f %.0f %.0f %.0f", alertButton.minX, alertButton.minY, alertButton.width, alertButton.height))
        }
        _ = quiet
    }

    static func alertButtonFrame(_ window: WindowHost, _ title: String) -> CGRect? {
        var out: CGRect?
        window.graph.root?.forEachNode { n in
            guard out == nil, String(describing: type(of: n.view)).hasPrefix("AlertCard") else { return }
            n.forEachNode { m in
                if out == nil, let t = m.view as? Text, t.plainString == title {
                    out = HitTesting.frame(of: m, mirrorWidth: nil)
                }
            }
        }
        return out
    }

    static func allItems(_ items: [FileItem]) -> [FileItem] {
        items.flatMap { [$0] + allItems($0.children ?? []) }
    }

    static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func post(_ host: AppHost, _ e: PlatformEvent) { host.backend.post(e) }

    static func pointer(_ host: AppHost, _ w: PlatformWindowID, _ phase: PointerPhase, _ p: CGPoint) {
        post(host, .pointer(PointerEvent(window: w, phase: phase, location: p, button: 1,
                                         isPressed: phase == .down || phase == .moved, timestamp: host.backend.now)))
    }

    static func click(_ host: AppHost, _ w: PlatformWindowID, _ p: CGPoint) async {
        pointer(host, w, .down, p)
        await pause(0.05)
        pointer(host, w, .up, p)
        await pause(0.25)
    }

    static func key(_ host: AppHost, _ w: PlatformWindowID, _ k: Key, _ mods: KeyModifiers = []) async {
        post(host, .key(KeyEvent(window: w, key: k, modifiers: mods, timestamp: host.backend.now)))
        await pause(0.12)
    }

    static func shot(_ w: WindowHost, _ path: String) {
        guard var image = w.presenter?.readback() ?? w.platform.readback() else {
            say("screenshot: no readback for \(path)")
            return
        }
        // Menus are pop-up windows of their own: draw them over the window's
        // image at their places (R11).
        if let host = AppHost.current, !w.isPopup {
            let scale = Double(image.width) / max(1, w.size.width)
            for p in popups(host) {
                guard let pi = p.presenter?.readback() ?? p.platform.readback() else { continue }
                let o = origin(of: p)
                let ox = Int((o.x * scale).rounded()), oy = Int((o.y * scale).rounded())
                for y in 0..<pi.height where oy + y >= 0 && oy + y < image.height {
                    for x in 0..<pi.width where ox + x >= 0 && ox + x < image.width {
                        image[ox + x, oy + y] = pi[x, y]
                    }
                }
            }
        }
        do {
            try image.writePNG(to: URL(fileURLWithPath: path))
            say("screenshot \(image.width)x\(image.height) written to \(path)")
        } catch {
            say("screenshot failed: \(error)")
        }
    }

    static func clickText(_ host: AppHost, _ s: String, in window: WindowHost, button: Int = 1) async {
        guard let f = textFrame(s, in: window) else {
            say("no target \(s)")
            return
        }
        let id = window.platform.id
        post(host, .pointer(PointerEvent(window: id, phase: .down, location: CGPoint(x: f.midX, y: f.midY), button: button,
                                         isPressed: true, timestamp: host.backend.now)))
        await pause(0.05)
        post(host, .pointer(PointerEvent(window: id, phase: .up, location: CGPoint(x: f.midX, y: f.midY), button: button,
                                         isPressed: false, timestamp: host.backend.now)))
        await pause(0.3)
    }

    /// The R11 steps: menus, shortcuts, toolbar, context menu, Settings.
    static func r11(_ host: AppHost, _ w: WindowHost, prefix: String?, step: (String) -> Void) async {
        let id = w.platform.id
        let s = IDEState.shared
        say("menus: \(w.services.menuBar?.menuTitles ?? [])")
        // File > New File… with the pointer.
        await clickText(host, "File", in: w)
        say("open menu items: \(popups(host).last.map(items) ?? [])")
        if let prefix { shot(w, prefix + "-menu.png") }
        if let p = popups(host).last { await clickText(host, "New File…", in: p) }
        step("File > New File…")
        // Shortcuts: Ctrl+B, Ctrl+Shift+N; the toolbar's Run.
        await key(host, id, .character("b"), [.control])
        await key(host, id, .character("n"), [.control, .shift])
        if let r = frame("tb run", in: w) { await click(host, id, CGPoint(x: r.midX, y: r.midY)) }
        step("Ctrl+B, Ctrl+Shift+N, toolbar Run")
        // Save is enabled while the editor has focus (a focused value).
        await key(host, id, .character("s"), [.control])
        if let e = frame("editor", in: w) { await click(host, id, CGPoint(x: e.midX, y: e.minY + 30)) }
        await key(host, id, .character("s"), [.control])
        step("Ctrl+S without and with the editor focused")
        // Edit > Select All, Edit > Copy (on the focused editor).
        await clickText(host, "Edit", in: w)
        if let p = popups(host).last { await clickText(host, "Select All", in: p) }
        await clickText(host, "Edit", in: w)
        if let p = popups(host).last { await clickText(host, "Copy", in: p) }
        say("clipboard: \((host.backend.clipboard.text ?? "").prefix(24).replacingOccurrences(of: "\n", with: "⏎"))…")
        step("Edit > Select All, Copy")
        // The keyboard: F10, Right, Right, Escape.
        await key(host, id, .function(10))
        await key(host, id, .rightArrow)
        await key(host, id, .rightArrow)
        say("menu open by keyboard: \(w.services.menuBar?.openIndex.map { w.services.menuBar?.menuTitles[$0] ?? "" } ?? "none")")
        await key(host, id, .escape)
        // A context menu on an outline row: right click, Open.
        if let r = frame("row Sources/App/App.swift", in: w) {
            post(host, .pointer(PointerEvent(window: id, phase: .down, location: CGPoint(x: r.midX, y: r.midY), button: 3,
                                             isPressed: true, timestamp: host.backend.now)))
            await pause(0.05)
            post(host, .pointer(PointerEvent(window: id, phase: .up, location: CGPoint(x: r.midX, y: r.midY), button: 3,
                                             isPressed: false, timestamp: host.backend.now)))
            await pause(0.4)
        }
        say("context menu items: \(popups(host).last.map(items) ?? [])")
        if let prefix { shot(w, prefix + "-context.png") }
        if let p = popups(host).last { await clickText(host, "Open", in: p) }
        step("context menu Open on App.swift")
        // Settings: Ctrl+, opens the window; toggle line numbers there.
        await key(host, id, .character(","), [.control])
        await pause(0.5)
        if let sw = host.windows.first(where: { !$0.isPopup && $0 !== w }) {
            say("settings window \(sw.size.width)x\(sw.size.height)")
            if let t = frame("settings lines", in: sw) {
                post(host, .pointer(PointerEvent(window: sw.platform.id, phase: .down, location: CGPoint(x: t.maxX - 20, y: t.midY),
                                                 isPressed: true, timestamp: host.backend.now)))
                await pause(0.05)
                post(host, .pointer(PointerEvent(window: sw.platform.id, phase: .up, location: CGPoint(x: t.maxX - 20, y: t.midY),
                                                 isPressed: false, timestamp: host.backend.now)))
                await pause(0.4)
            }
            say("line numbers: \(UserDefaults.standard.object(forKey: "ide.showLineNumbers").map { "\($0)" } ?? "default")")
            if let prefix { shot(sw, prefix + "-settings.png") }
            post(host, .window(sw.platform.id, .closeRequested))
            await pause(0.4)
        }
        step("Settings window")
        _ = s
    }

    /// Text in a pop-up's rows.
    static func items(_ p: WindowHost) -> [String] {
        var out: [String] = []
        p.graph.root?.forEachNode { n in if let t = n.view as? Text { out.append(t.plainString) } }
        return out
    }

    static func script(_ host: AppHost, _ w: WindowHost) async {
        let id = w.platform.id
        let s = IDEState.shared
        let prefix = env["OV_SCREENSHOT_PREFIX"]
        func step(_ label: String) {
            say("step \(label): \(s.describe())")
            report(w)
        }
        step("launched")
        // Expand "Sources" with its chevron, then "App", select a file.
        for folder in ["row Sources", "row Sources/App"] {
            if let f = frame(folder, in: w) { await click(host, id, CGPoint(x: f.minX - 10, y: f.midY)) }
        }
        step("expanded Sources and App")
        if let f = frame("row Sources/App/ContentView.swift", in: w) { await click(host, id, CGPoint(x: f.midX, y: f.midY)) }
        await pause(0.3)
        step("selected ContentView.swift")
        // Keyboard: Up selects App.swift, Left goes to the folder, Left
        // collapses it.
        await key(host, id, .upArrow)
        step("Up")
        await key(host, id, .leftArrow)
        await key(host, id, .leftArrow)
        step("Left, Left (collapsed App)")
        await key(host, id, .rightArrow)
        await key(host, id, .rightArrow)
        await key(host, id, .downArrow)
        step("Right, Right, Down")
        // Scroll the console with the wheel and with a drag.
        if let c = frame("console", in: w) {
            for _ in 0..<12 {
                post(host, .scroll(ScrollEvent(window: id, location: CGPoint(x: c.midX, y: c.midY),
                                               delta: CGSize(width: 0, height: -30), timestamp: host.backend.now)))
                await pause(0.02)
            }
            await pause(0.2)
            step("wheel-scrolled the console")
            var p = CGPoint(x: c.midX, y: c.maxY - 20)
            pointer(host, id, .down, p)
            for _ in 0..<10 {
                await pause(0.016)
                p.y -= 25
                pointer(host, id, .moved, p)
            }
            pointer(host, id, .up, p)
            await pause(1.5)
            step("drag-scrolled (fling) the console")
        }
        // Drag the editor/console divider up by 100 points.
        if let d = dividers(in: w).last(where: { $0.width > $0.height }) {
            var p = CGPoint(x: d.midX, y: d.midY)
            pointer(host, id, .down, p)
            for _ in 0..<10 {
                await pause(0.016)
                p.y -= 10
                pointer(host, id, .moved, p)
            }
            pointer(host, id, .up, p)
            await pause(0.3)
            step("dragged the split divider up 100")
        }
        if let prefix { shot(w, prefix + "-light.png") }
        await r11(host, w, prefix: prefix, step: step)
        // The sheet: open with Build…, close with Done.
        if let b = frame("build", in: w) { await click(host, id, CGPoint(x: b.midX, y: b.midY)) }
        await pause(0.6)
        step("opened the sheet")
        if let prefix { shot(w, prefix + "-sheet.png") }
        if let d = frame("sheet done", in: w) { await click(host, id, CGPoint(x: d.midX, y: d.midY)) }
        await pause(0.8)
        step("closed the sheet")
        // The alert: Delete, then its destructive button.
        if let b = frame("delete", in: w) { await click(host, id, CGPoint(x: b.midX, y: b.midY)) }
        await pause(0.6)
        step("opened the alert")
        if let prefix { shot(w, prefix + "-alert.png") }
        if let b = alertButtonFrame(w, "Delete") { await click(host, id, CGPoint(x: b.midX, y: b.midY)) }
        await pause(0.8)
        step("confirmed the alert")
        s.dark = true
        await pause(0.5)
        if let prefix { shot(w, prefix + "-dark.png") }
        step("dark")
        say("frames presented: \(w.presentedFrames), run-loop frames \(host.runLoop.framesRendered), idle waits \(host.runLoop.idleWaits)")
        say(s.describe())
        host.terminate()
    }
}
