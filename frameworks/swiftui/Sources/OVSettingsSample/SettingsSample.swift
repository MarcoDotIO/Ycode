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

// The R8 sample: a settings form with text fields, toggles, a slider, a
// stepper, pickers, a date picker, buttons, progress and a gauge in one
// window. Run it with a display (X11 or Wayland) and libSDL3:
//
//   OV_SDL3_LIBRARY=<prefix>/lib/libSDL3.so.0 swift run ov-settings
//
// Environment switches (all optional):
//   OV_SAMPLE_SCRIPT=1        drive every control with synthetic events
//                             through SDL's queue (type, select, undo, pop-up
//                             menus), print the state after each step, quit
//   OV_SCREENSHOT_PREFIX=<p>  write <p>-light.png, <p>-dark.png (the form in
//                             each scheme) and <p>-menu.png (a pop-up menu)
//                             during the script
//   OV_COLOR_SCHEME=dark      start in dark mode
//   OV_PRINT_TARGETS=1        print the window-coordinate centres of the
//                             controls (for external drivers such as xdotool)
//   OV_QUIT_AFTER=<s>         print the state and quit after s seconds
//   OV_TRACE=1                trace the app host on stderr

@main
struct SettingsApp: App {
    var body: some Scene {
        WindowGroup("OpenViews R8 settings") {
            SettingsView()
        }
        .defaultSize(width: 460, height: 740)
    }
}

@MainActor
func say(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

/// Marks a control for the drivers (its frame is looked up by name).
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

enum Theme: Hashable { case system, light, dark }

@MainActor
@Observable
final class Settings {
    static let shared = Settings()
    var name = ""
    var password = ""
    var notifications = false
    var sounds = true
    var volume = 0.4
    var fontSize = 13
    var theme: Theme = ProcessInfo.processInfo.environment["OV_COLOR_SCHEME"] == "dark" ? .dark : .system
    var language = "en"
    var start = Date(timeIntervalSince1970: 1_793_000_000)
    var notes = "First line\nSecond line"
    var saved = 0
    var syncing = false

    func describe() -> String {
        String(format: "state: name=\"%@\" password=%d chars notifications=%@ sounds=%@ volume=%.2f fontSize=%d theme=%@ language=%@ start=%@ saved=%d",
               name, password.count, "\(notifications)", "\(sounds)", volume, fontSize, "\(theme)", language,
               ISO8601DateFormatter().string(from: start), saved)
    }
}

struct SettingsView: View {
    @Bindable var settings = Settings.shared

    var body: some View {
        Form {
            Section("Account") {
                Target("name") { TextField("Name", text: $settings.name).textFieldStyle(.roundedBorder) }
                Target("password") { SecureField("Password", text: $settings.password).textFieldStyle(.roundedBorder) }
            }
            Section("Preferences") {
                Target("notifications") { Toggle("Notifications", isOn: $settings.notifications) }
                Target("sounds") { Toggle("Play sounds", isOn: $settings.sounds).toggleStyle(.checkbox) }
                LabeledContent("Volume") {
                    Target("volume") { Slider(value: $settings.volume, in: 0...1).frame(width: 200) }
                }
                Target("fontSize") { Stepper("Font size: \(settings.fontSize) pt", value: $settings.fontSize, in: 9...24) }
                Target("theme") {
                    Picker("Theme", selection: $settings.theme) {
                        Text("System").tag(Theme.system)
                        Text("Light").tag(Theme.light)
                        Text("Dark").tag(Theme.dark)
                    }
                    .pickerStyle(.segmented)
                }
                Target("language") {
                    Picker("Language", selection: $settings.language) {
                        Text("English").tag("en")
                        Text("Deutsch").tag("de")
                        Text("Français").tag("fr")
                    }
                }
                Target("start") { DatePicker("Start", selection: $settings.start, displayedComponents: .date) }
            }
            Section("Status") {
                if settings.syncing {
                    HStack { ProgressView(); Text("Syncing…") }
                } else {
                    ProgressView("Sync", value: Double(min(settings.saved, 4)), total: 4)
                }
                Gauge(value: settings.volume) { Text("Level") }
            }
            Section {
                HStack(spacing: 12) {
                    Target("reset") {
                        Button("Reset", role: .destructive) { reset() }.buttonStyle(.bordered)
                    }
                    Spacer()
                    Target("save") {
                        Button("Save") {
                            settings.saved += 1
                            say("saved (\(settings.saved))")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s")
                    }
                }
                Link("About Ycode", destination: URL(string: "https://example.com/ycode")!)
            }
        }
        .onChange(of: settings.name) { _, n in say("name \"\(n)\"") }
        .onChange(of: settings.language) { _, l in say("language \(l)") }
        .environment(\.defaultMinListRowHeight, 38)
        .environment(\.colorScheme, settings.theme == .dark ? .dark : .light)
        .task { await SettingsDriver.start() }
    }

    private func reset() {
        settings.name = ""
        settings.password = ""
        settings.volume = 0.4
        say("reset")
    }
}

/// Automation for the done-criterion runs (see the header).
@MainActor
enum SettingsDriver {
    static var started = false
    static let env = ProcessInfo.processInfo.environment

    static func start() async {
        guard !started, let host = AppHost.current else { return }
        started = true
        say("backend \(host.backend.name)\((host.backend as? SDLBackend).map { " SDL " + $0.libraryDescription } ?? "")")
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let window = host.windows.first else { return }
        say("window \(window.size.width)x\(window.size.height) pt, scale \(window.platform.scale), "
            + "pixels \(window.platform.pixelSize.width)x\(window.platform.pixelSize.height)")
        if let p = window.presenter as? CompositorPresenter { say("presenter: \(p.description)") }
        if env["OV_PRINT_TARGETS"] != nil { printTargets(window) }
        if env["OV_SAMPLE_SCRIPT"] != nil { await script(host, window) }
        if let s = env["OV_QUIT_AFTER"], let t = Double(s) {
            try? await Task.sleep(nanoseconds: UInt64(t * 1e9))
            say(Settings.shared.describe())
            if let path = env["OV_SCREENSHOT"] { shot(window, path) }
            host.terminate()
        }
    }

    static func frame(_ name: String, in window: WindowHost) -> CGRect? {
        var out: CGRect?
        window.graph.root?.forEachNode { n in
            if out == nil, let t = n.view as? any NamedTarget, t.name == name { out = HitTesting.frame(of: n, mirrorWidth: nil) }
        }
        return out
    }

    static func printTargets(_ window: WindowHost) {
        let scale = window.platform.pixelSize.width > 0 ? Double(window.platform.pixelSize.width) / window.size.width : 1
        for name in ["name", "password", "notifications", "sounds", "volume", "fontSize", "theme", "language", "start",
                     "reset", "save"] {
            guard let f = frame(name, in: window) else { continue }
            say(String(format: "target %@ %.0f %.0f %.0f %.0f pixels %.0f %.0f %.0f %.0f", name, f.minX, f.minY, f.width, f.height,
                       f.minX * scale, f.minY * scale, f.width * scale, f.height * scale))
        }
    }

    static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func post(_ host: AppHost, _ e: PlatformEvent) { host.backend.post(e) }

    static func pointer(_ host: AppHost, _ w: PlatformWindowID, _ phase: PointerPhase, _ p: CGPoint, _ mods: KeyModifiers = []) {
        post(host, .pointer(PointerEvent(window: w, phase: phase, location: p, button: 1,
                                         isPressed: phase == .down || phase == .moved, modifiers: mods,
                                         timestamp: host.backend.now)))
    }

    static func click(_ host: AppHost, _ w: PlatformWindowID, _ p: CGPoint, _ mods: KeyModifiers = []) async {
        pointer(host, w, .down, p, mods)
        await pause(0.05)
        pointer(host, w, .up, p, mods)
        await pause(0.15)
    }

    static func key(_ host: AppHost, _ w: PlatformWindowID, _ k: Key, _ mods: KeyModifiers = []) async {
        post(host, .key(KeyEvent(window: w, key: k, modifiers: mods, timestamp: host.backend.now)))
        await pause(0.06)
    }

    static func type(_ host: AppHost, _ w: PlatformWindowID, _ text: String) async {
        for c in text {
            post(host, .key(KeyEvent(window: w, key: .character(Character(c.lowercased())), timestamp: host.backend.now)))
            post(host, .textInput(TextInputEvent(window: w, text: String(c), timestamp: host.backend.now)))
            await pause(0.04)
        }
    }

    static func shot(_ w: WindowHost, _ path: String) {
        guard let image = w.presenter?.readback() ?? w.platform.readback() else {
            say("screenshot: no readback for \(path)")
            return
        }
        do {
            try image.writePNG(to: URL(fileURLWithPath: path))
            say("screenshot \(image.width)x\(image.height) written to \(path)")
        } catch {
            say("screenshot failed: \(error)")
        }
    }

    static func script(_ host: AppHost, _ w: WindowHost) async {
        let id = w.platform.id
        let s = Settings.shared
        let prefix = env["OV_SCREENSHOT_PREFIX"]
        func step(_ label: String) { say("step \(label): \(s.describe())") }

        // Text: type, select a word with a double click, replace it, undo.
        if let f = frame("name", in: w) {
            await click(host, id, CGPoint(x: f.midX, y: f.midY))
            await type(host, id, "Ada Lovelace")
            step("typed name")
            let wordX = f.maxX - 40
            pointer(host, id, .down, CGPoint(x: min(wordX, f.minX + 70), y: f.midY))
            pointer(host, id, .up, CGPoint(x: min(wordX, f.minX + 70), y: f.midY))
            await pause(0.05)
            await click(host, id, CGPoint(x: min(wordX, f.minX + 70), y: f.midY))
            await type(host, id, "Byron")
            step("double-click selected a word and typing replaced it")
            await key(host, id, .character("z"), .control)
            step("Ctrl+Z")
            await key(host, id, .leftArrow, [.control, .shift])
            step("Ctrl+Shift+Left selected the last word")
            await key(host, id, .end)
        }
        await key(host, id, .tab)
        await type(host, id, "secret")
        step("tabbed to the password and typed")
        // Toggles.
        if let f = frame("notifications", in: w) { await click(host, id, CGPoint(x: f.maxX - 30, y: f.midY)) }
        if let f = frame("sounds", in: w) { await click(host, id, CGPoint(x: f.minX + 9, y: f.midY)) }
        step("toggles")
        // Slider: drag the thumb right.
        if let f = frame("volume", in: w) {
            let usable = f.width - 24
            var p = CGPoint(x: f.minX + 12 + CGFloat(s.volume) * usable, y: f.midY)
            pointer(host, id, .down, p)
            for _ in 0..<12 {
                await pause(0.016)
                p.x += 6
                pointer(host, id, .moved, p)
            }
            await pause(0.016)
            pointer(host, id, .up, p)
            await pause(0.15)
        }
        step("slider dragged")
        // Stepper: + twice, − once.
        if let f = frame("fontSize", in: w) {
            await click(host, id, CGPoint(x: f.maxX - 20, y: f.midY))
            await click(host, id, CGPoint(x: f.maxX - 20, y: f.midY))
            await click(host, id, CGPoint(x: f.maxX - 74, y: f.midY))
        }
        step("stepper")
        // Menu picker: open the pop-up, choose the second language.
        if let f = frame("language", in: w) {
            await click(host, id, CGPoint(x: f.maxX - 30, y: f.midY))
            await pause(0.2)
            if let popup = host.windows.first(where: \.isPopup) {
                say("pop-up window \(popup.platform.id) \(popup.size.width)x\(popup.size.height)")
                if let prefix { shot(popup, prefix + "-menu.png") }
                await click(host, popup.platform.id, CGPoint(x: 40, y: 5 + 26 * 1.5))
            } else if !w.overlayPopups.isEmpty {
                say("pop-up shown as an overlay")
                if let prefix { shot(w, prefix + "-menu.png") }
                await click(host, id, CGPoint(x: f.maxX - 60, y: f.maxY + 4 + 5 + 26 * 1.5))
            } else {
                say("no pop-up")
            }
        }
        step("language chosen from the pop-up menu")
        // Date: open the calendar, pick the 20th.
        if let f = frame("start", in: w) {
            await click(host, id, CGPoint(x: f.maxX - 30, y: f.midY))
            await pause(0.2)
            if let popup = host.windows.first(where: \.isPopup) {
                var days: [CGRect] = []
                popup.graph.root?.forEachNode { n in
                    if String(describing: Swift.type(of: n.view)) == "DayCell", let f = HitTesting.frame(of: n, mirrorWidth: nil) { days.append(f) }
                }
                if days.count >= 20 {
                    let d = days[19]
                    await click(host, popup.platform.id, CGPoint(x: d.midX, y: d.midY))
                } else {
                    await key(host, popup.platform.id, .escape)
                }
            }
        }
        step("date picked")
        // Buttons: Save twice (click, then its shortcut).
        if let f = frame("save", in: w) { await click(host, id, CGPoint(x: f.midX, y: f.midY)) }
        await key(host, id, .character("s"), .control)
        step("saved")
        // Animation frame rate (QA B1): a spinning progress indicator for 2 s.
        s.syncing = true
        await pause(0.3)
        let f0 = w.presentedFrames, t0 = host.backend.now
        await pause(2.0)
        let fps = Double(w.presentedFrames - f0) / (host.backend.now - t0)
        say(String(format: "animation: %.1f presented frames/s (spinner, display %.0f Hz)", fps, w.platform.refreshRate))
        if let prefix { shot(w, prefix + "-spinner.png") }
        s.syncing = false
        await pause(0.4)
        if let prefix { shot(w, prefix + "-light.png") }
        // Dark mode through the segmented picker.
        if let f = frame("theme", in: w) { await click(host, id, CGPoint(x: f.maxX - f.width / 6, y: f.midY)) }
        step("theme")
        await pause(0.5)
        if let prefix { shot(w, prefix + "-dark.png") }
        say("frames presented: \(w.presentedFrames), run-loop frames \(host.runLoop.framesRendered), idle waits \(host.runLoop.idleWaits)")
        say(s.describe())
        host.terminate()
    }
}
