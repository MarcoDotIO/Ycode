import Foundation
import Observation
import OVPlatform
import OVText
#if OPENVIEWS_RENAMED
import OpenViews
import OpenViewsCore
#else
import SwiftUI
import SwiftUICore
#endif

// The B5-OPENVIEWS demo (`specs/ide/cross-platform-parity.md` §15): a window
// laid out like Ycode's macOS IDE window, drawn with OpenViews' desktop
// chrome — a hidden title bar with OpenViews' close, minimize and zoom
// buttons, the menu bar on demand, the sidebar material, always-visible
// scrollers, the desktop control looks, the UI font's metric adjustment —
// and Welcome and a setup wizard as windows of their own.
//
//   OV_SDL3_LIBRARY=<prefix>/lib/libSDL3.so.0 swift run ov-chrome
//
// Environment switches (all optional):
//   OV_SAMPLE_SCRIPT=1        walk through the states below, print each
//                             state (hit regions, the accessibility tree of
//                             the alert's buttons), quit
//   OV_SCREENSHOT_PREFIX=<p>  write <p>-main.png, -buttons-hover.png,
//                             -inactive.png, -menubar.png, -menu.png,
//                             -welcome.png, -wizard.png, -alert.png,
//                             -controls.png during the walk
//   OV_FONT_METRICS=desktop   the macOS IDE's text widths (FontTracking)
//   OV_MENU_BAR=inline        the in-window menu bar instead
//   OV_COLOR_SCHEME=dark      dark appearance
//   OV_QUIT_AFTER=<s>         quit after s seconds (external drivers)

func say(_ s: String) {
    FileHandle.standardOutput.write(Data("[ov-chrome] \(s)\n".utf8))
}

@MainActor
@Observable
final class DemoModel {
    static let shared = DemoModel()
    var name = "Sample.swift"
    var fileType = 0
    var encoding = 0
    var lineEndings = 0
    var tab = 4
    var indent = 4
    var source = 0
    var host = ""
    var showsAlert = false
    var merged = false
}

@main
struct ChromeDemoApp: App {
    init() {
        // The Linux IDE's UI family (bundled Inter, SIL OFL 1.1).
        FontCatalog.shared.setFamilies(["Inter 24pt", "Noto Sans"], for: .default)
    }

    var body: some Scene {
        WindowGroup("Merger") {
            MainWindowView(model: DemoModel.shared)
                .task { await ChromeDriver.start() }
        }
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandMenu("Product") {
                Button("Build") { say("build") }.keyboardShortcut("b")
                Button("Run") { say("run") }.keyboardShortcut("r")
            }
        }
        Window("Welcome to Ycode", id: "welcome") {
            WelcomeCard()
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
        Window("Simulator Runtime Setup", id: "wizard") {
            WizardView(model: DemoModel.shared)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

// MARK: - The main window

struct MainWindowView: View {
    @Bindable var model: DemoModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            NavigatorColumn()
                .frame(width: 290)
            VStack(spacing: 0) {
                ToolbarBand(model: model)
                Divider()
                EditorColumn()
            }
            .background(Rectangle().fill(.bar))
            InspectorColumn(model: model)
                .frame(width: 260)
        }
        .alert("Are you sure you want to merge from “feature”?", isPresented: $model.showsAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Merge") { model.merged = true }.keyboardShortcut(.defaultAction)
        } message: {
            Text("This will merge the changes from the “feature” branch into your current branch (“main”).")
        }
    }
}

/// The navigator: the sidebar material from the window's top edge (under
/// the window buttons), a 52-point band, then rows.
struct NavigatorColumn: View {
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 52)
            List {
                ForEach(["Merger", "Package", "Sources", "Merger", "Colors", "Greeting", "main", "Notes", "Sample", "Stripes"],
                        id: \.self) { Text($0) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Rectangle().fill(.sidebarMaterial))
    }
}

struct ToolbarBand: View {
    @Bindable var model: DemoModel
    var body: some View {
        HStack(spacing: 12) {
            Text("Merger").font(.system(size: 15))
            Spacer()
            Button("Merge…") { model.showsAlert = true }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

/// A tall document in a scroll view with the macOS IDE's always-visible
/// scroller, and the font-metric sample lines.
struct EditorColumn: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Identity and Type").font(.system(size: 11, weight: .semibold))
                Text("No Explicit Line Endings · Default - Swift Source · Relative to Group").font(.system(size: 11))
                Text("Are you sure you want to merge from “feature”?").font(.system(size: 13, weight: .semibold))
                ForEach(0..<60, id: \.self) { i in
                    Text("// Line \(i + 1): a comment that is long enough to show the editor's width").font(.system(size: 13, design: .monospaced))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollerStyle(.legacy)
    }
}

/// The inspector: the desktop control looks.
struct InspectorColumn: View {
    @Bindable var model: DemoModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.frame(height: 44)
            Text("Identity and Type").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            row("Name") { TextField("Name", text: $model.name).textFieldStyle(.plain) }
            row("Type") {
                Picker("Type", selection: $model.fileType) {
                    Text("Default - Swift Source").tag(0)
                    Text("Swift Package").tag(1)
                }
                .pickerStyle(.menu).menuStyle(.borderlessButton).labelsHidden()
            }
            Divider()
            Text("Text Settings").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            row("Text Encoding") {
                Picker("Text Encoding", selection: $model.encoding) {
                    Text("No Explicit Encoding").tag(0)
                    Text("Unicode (UTF-8)").tag(1)
                }
                .pickerStyle(.menu).menuStyle(.borderlessButton).labelsHidden()
            }
            row("Widths") {
                HStack(spacing: 6) {
                    Text("\(model.tab)")
                    Stepper("Tab", value: $model.tab, in: 1...16).labelsHidden()
                    Text("\(model.indent)")
                    Stepper("Indent", value: $model.indent, in: 1...16).labelsHidden()
                }
            }
            Divider()
            Picker("Source", selection: $model.source) {
                Text("Changes").tag(0)
                Text("Repositories").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.mini)
            TextField("user@sim-host", text: $model.host).textFieldStyle(.roundedBorder)
            Button("Simulator Runtimes…") {}.buttonStyle(.bordered)
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Rectangle().fill(.sidebarMaterial))
    }

    private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 74, alignment: .trailing)
            content()
        }
    }
}

// MARK: - Welcome and the wizard

struct WelcomeCard: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button { dismissWindow() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .accessibilityLabel("Close")
                Spacer()
            }
            Spacer().frame(height: 40)
            Text("Ycode").font(.system(size: 18.5, weight: .semibold))
            Text("Version 1.0.0 (beta 3)").foregroundStyle(.secondary)
            Button("Set Up Simulator Runtimes…") { openWindow(id: "wizard") }.buttonStyle(.bordered)
            Spacer()
        }
        .padding(20)
        .frame(width: 480, height: 632)
        .background(Rectangle().fill(.bar))
    }
}

struct WizardView: View {
    @Bindable var model: DemoModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            Text("Simulator Host").font(.system(size: 22, weight: .bold))
            Text("The arm64 Linux machine with KVM that runs the simulator.").foregroundStyle(.secondary)
            HStack {
                Text("Host:").frame(width: 110, alignment: .trailing)
                TextField("user@sim-host", text: $model.host).textFieldStyle(.roundedBorder).frame(width: 320)
            }
            Spacer()
            HStack {
                Button("Back") {}.buttonStyle(.bordered)
                Spacer()
                Button("Continue") { dismissWindow() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 760, height: 600)
        .windowButtonsShown(.close)
        .windowMinimizeBehavior(.disabled)
    }
}

// MARK: - The walk

@MainActor
enum ChromeDriver {
    static var started = false
    static let env = ProcessInfo.processInfo.environment

    static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func start() async {
        guard !started else { return }
        started = true
        say("backend \(OpenViewsAutomation.backendName); windows \(OpenViewsAutomation.windowSceneIDs.map { $0 ?? "main" })")
        if env["OV_SAMPLE_SCRIPT"] != nil { await walk() }
        if let s = env["OV_QUIT_AFTER"], let t = Double(s) {
            await pause(t)
            OpenViewsAutomation.terminate()
        }
    }

    static func shot(_ name: String, window: Int = 0) {
        guard let prefix = env["OV_SCREENSHOT_PREFIX"] else { return }
        say(OpenViewsAutomation.screenshot(window, to: "\(prefix)-\(name).png"))
    }

    static func walk() async {
        await pause(0.8)
        let main = OpenViewsAutomation.windowSceneIDs.firstIndex { $0 == nil } ?? 0
        if let size = OpenViewsAutomation.windowSize(main) { say("main window \(size.points.width)x\(size.points.height) pt") }
        // Hit regions: the band moves the window, the buttons are the app's.
        for (name, p) in [("band", CGPoint(x: 600, y: 26)), ("title", CGPoint(x: 320, y: 26)), ("close", CGPoint(x: 26, y: 26)),
                          ("content", CGPoint(x: 600, y: 300)), ("left edge", CGPoint(x: 2, y: 300))] {
            say("hit \(name): \(OpenViewsAutomation.hitRegion(at: p, window: main))")
        }
        say("menu bar revealed: \(OpenViewsAutomation.isMenuBarRevealed(main))")
        OpenViewsAutomation.move(to: CGPoint(x: 600, y: 400), window: main)
        await pause(0.3)
        shot("main", window: main)
        // The window buttons' glyphs under the pointer.
        OpenViewsAutomation.move(to: CGPoint(x: 49, y: 26), window: main)
        await pause(0.3)
        shot("buttons-hover", window: main)
        // Inactive: grey buttons.
        OpenViewsAutomation.move(to: CGPoint(x: 600, y: 400), window: main)
        OpenViewsAutomation.setActiveState(.inactive, window: main)
        await pause(0.3)
        shot("inactive", window: main)
        OpenViewsAutomation.setActiveState(nil, window: main)
        // The menu bar on demand: the pointer at the top edge, then F10.
        OpenViewsAutomation.move(to: CGPoint(x: 700, y: 1), window: main)
        await pause(0.7)
        say("menu bar revealed after resting at the top edge: \(OpenViewsAutomation.isMenuBarRevealed(main))")
        shot("menubar", window: main)
        OpenViewsAutomation.press(.function(10), window: main)
        await pause(0.4)
        say("pop-ups open after F10: \(OpenViewsAutomation.openPopupCount)")
        shot("menu", window: main)
        OpenViewsAutomation.press(.escape, window: main)
        await pause(0.2)
        OpenViewsAutomation.move(to: CGPoint(x: 600, y: 400), window: main)
        await pause(0.3)
        say("menu bar revealed after Escape and moving away: \(OpenViewsAutomation.isMenuBarRevealed(main))")
        // Welcome, a window of its own.
        if let w = OpenViewsAutomation.windowIndex(sceneID: "welcome") {
            if let size = OpenViewsAutomation.windowSize(w) { say("welcome window \(size.points.width)x\(size.points.height) pt") }
            shot("welcome", window: w)
            if let t = OpenViewsAutomation.texts(w).first(where: { $0.text == "Set Up Simulator Runtimes…" }) {
                await OpenViewsAutomation.click(at: CGPoint(x: t.frame.midX, y: t.frame.midY), window: w)
                await pause(0.6)
            }
        }
        if let w = OpenViewsAutomation.windowIndex(sceneID: "wizard") {
            if let size = OpenViewsAutomation.windowSize(w) { say("wizard window \(size.points.width)x\(size.points.height) pt") }
            shot("wizard", window: w)
        }
        // The alert: its default and cancel buttons in the accessibility tree.
        if let t = OpenViewsAutomation.texts(main).first(where: { $0.text == "Merge…" }) {
            await OpenViewsAutomation.click(at: CGPoint(x: t.frame.midX, y: t.frame.midY), window: main)
            await pause(0.5)
            shot("alert", window: main)
            for line in OpenViewsAutomation.accessibilityDump(main).split(separator: "\n")
            where line.contains("button") && (line.contains("Merge") || line.contains("Cancel") || line.contains("Close")
                                               || line.contains("Minimize") || line.contains("Zoom")) {
                say("ax \(line.trimmingCharacters(in: .whitespaces))")
            }
            OpenViewsAutomation.press(.return, window: main)
            await pause(0.4)
            say("merged after Return: \(DemoModel.shared.merged)")
        }
        for t in OpenViewsAutomation.texts(main) where ["Identity and Type", "No Explicit Line Endings · Default - Swift Source · Relative to Group",
                                                         "Are you sure you want to merge from “feature”?"].contains(t.text) {
            say(String(format: "text width %.2f: %@", t.frame.width, t.text))
        }
        OpenViewsAutomation.terminate()
    }
}
