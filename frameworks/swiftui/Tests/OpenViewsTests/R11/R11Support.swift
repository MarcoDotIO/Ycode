import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Round R11 test support: an app with commands, a Settings scene and a
// single-window scene, run on the headless back end with the menu bar shown.

// The R2 tests define a `Settings` model class; the scene is named through
// its module here.
#if OPENVIEWS_RENAMED
typealias SettingsScene = OpenViews.Settings
#else
typealias SettingsScene = SwiftUI.Settings
#endif

@MainActor
final class CommandLog {
    static let shared = CommandLog()
    var entries: [String] = []
    var document: String?
    func add(_ s: String) { entries.append(s) }
}

struct DocumentKey: FocusedValueKey { typealias Value = String }
struct SceneTitleKey: FocusedValueKey { typealias Value = String }

extension FocusedValues {
    var document: String? {
        get { self[DocumentKey.self] }
        set { self[DocumentKey.self] = newValue }
    }

    var sceneTitle: String? {
        get { self[SceneTitleKey.self] }
        set { self[SceneTitleKey.self] = newValue }
    }
}

/// Commands that depend on the focused document.
struct DocumentCommands: Commands {
    @FocusedValue(\.document) var document: String?
    @FocusedValue(\.sceneTitle) var sceneTitle: String?

    var body: some Commands {
        CommandMenu("Build") {
            Button("Build") { CommandLog.shared.add("build \(document ?? "none")") }
                .keyboardShortcut("b")
                .disabled(document == nil)
            Button("Run") { CommandLog.shared.add("run \(sceneTitle ?? "none")") }
                .keyboardShortcut("r")
            Divider()
            Menu("More") {
                Button("Clean") { CommandLog.shared.add("clean") }
            }
        }
        CommandGroup(after: .newItem) {
            Button("New File") { CommandLog.shared.add("new file") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("OpenViews Guide") { CommandLog.shared.add("guide") }
        }
        SidebarCommands()
    }
}

struct CommandsApp: App {
    static var content: () -> AnyView = { AnyView(EmptyView()) }
    static var settings: () -> AnyView = { AnyView(Text("Settings pane").frame(width: 400, height: 250)) }

    var body: some Scene {
        WindowGroup("Main") { Self.content() }
            .defaultSize(width: 800, height: 500)
            .commands { DocumentCommands() }
        Window("Activity", id: "activity") { Text("Activity") }
        SettingsScene { Self.settings() }
    }
}

@MainActor
final class CommandsHarness {
    let backend: HeadlessBackend
    let host: AppHost

    init<V: View>(menuBar: Bool = true, desktop: Bool = false, @ViewBuilder content: @escaping () -> V) {
        backend = HeadlessBackend(scale: 1)
        CommandLog.shared.entries = []
        CommandsApp.content = { AnyView(content()) }
        host = AppHost(CommandsApp.self, backend: backend)
        host.makePresenter = { _ in nil }
        host.showsMenuBar = menuBar
        // R13: the desktop look (as on a Linux desktop host).
        if desktop { host.desktopTextInput = true }
        host.appName = "Demo"
        host.launch()
        host.run(until: 0.5)
    }

    var main: WindowHost { host.windows.first { !$0.isPopup }! }
    var windowID: PlatformWindowID { main.platform.id }
    var popups: [WindowHost] { host.windows.filter(\.isPopup) }
    var now: TimeInterval { backend.now }

    func run(until t: TimeInterval) { host.run(until: t) }

    func key(_ k: Key, _ modifiers: KeyModifiers = [], window: PlatformWindowID? = nil, at t: TimeInterval) {
        backend.post(.key(KeyEvent(window: window ?? windowID, key: k, modifiers: modifiers, timestamp: t)), at: t)
        run(until: t + 0.01)
    }

    func click(_ p: CGPoint, window: PlatformWindowID? = nil, button: Int = 1, kind: PointerKind = .mouse,
               at t: TimeInterval, duration: TimeInterval = 0.05) {
        let w = window ?? windowID
        backend.post(.pointer(PointerEvent(window: w, kind: kind, phase: .down, location: p, button: button, timestamp: t)), at: t)
        backend.post(.pointer(PointerEvent(window: w, kind: kind, phase: .up, location: p, button: button,
                                           isPressed: false, timestamp: t + duration)), at: t + duration)
        run(until: t + duration + 0.01)
    }

    func hover(_ p: CGPoint, at t: TimeInterval) {
        backend.post(.pointer(PointerEvent(window: windowID, kind: .mouse, phase: .moved, location: p, button: 0,
                                           isPressed: false, timestamp: t)), at: t)
        run(until: t + 0.01)
    }

    func type(_ text: String, at t: TimeInterval) {
        var time = t
        for c in text {
            backend.post(.key(KeyEvent(window: windowID, key: .character(Character(c.lowercased())), timestamp: time)), at: time)
            backend.post(.textInput(TextInputEvent(window: windowID, text: String(c), timestamp: time)), at: time)
            time += 0.05
        }
        run(until: time)
    }

    /// The window frame of the first node in `window` whose view matches.
    func frame(in window: WindowHost? = nil, where match: (any View) -> Bool) -> CGRect? {
        var out: CGRect?
        (window ?? main).graph.root?.forEachNode { n in
            if out == nil, !n.isInSuspendedSubtree, match(n.view), let f = HitTesting.frame(of: n, mirrorWidth: nil) { out = f }
        }
        return out
    }

    /// The frame of a `Text` with this string.
    func textFrame(_ s: String, in window: WindowHost? = nil) -> CGRect? {
        frame(in: window) { ($0 as? Text)?.plainString == s }
    }

    var menuTitles: [String] { main.services.menuBar?.menuTitles ?? [] }

    /// Opens the menu titled `title` with a press on its title.
    func openMenu(_ title: String, at t: TimeInterval) {
        guard let f = textFrame(title) else {
            Issue.record("no menu title \(title)")
            return
        }
        click(CGPoint(x: f.midX, y: f.midY), at: t)
    }

    /// Chooses the item `title` of the open (innermost) pop-up.
    func choose(_ title: String, at t: TimeInterval) {
        guard let p = popups.last, let f = textFrame(title, in: p) else {
            Issue.record("no item \(title)")
            return
        }
        click(CGPoint(x: f.midX, y: f.midY), window: p.platform.id, at: t)
    }

    /// The item titles of the innermost pop-up.
    var openItems: [String] {
        guard let p = popups.last else { return [] }
        var out: [String] = []
        p.graph.root?.forEachNode { n in
            if let t = n.view as? Text, HitTesting.frame(of: n, mirrorWidth: nil) != nil { out.append(t.plainString) }
        }
        return out
    }

    /// Whether the menu row with this title is enabled in the open pop-up.
    func isItemEnabled(_ title: String) -> Bool? {
        guard let p = popups.last else { return nil }
        var out: Bool?
        p.graph.root?.forEachNode { n in
            if out == nil, let t = n.view as? Text, t.plainString == title { out = n.environment.isEnabled }
        }
        return out
    }
}
