import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViews
import OpenViewsCore
#else
import SwiftUI
import SwiftUICore
#endif

// The R7 sample: an OpenViews app with a button, a draggable box and a text
// field in one window. Run it with a display (X11 or Wayland) and libSDL3:
//
//   OV_SDL3_LIBRARY=<prefix>/lib/libSDL3.so.0 swift run ov-sample
//
// Environment switches (all optional):
//   OV_SAMPLE_SCRIPT=1      drive the window with synthetic events pushed
//                           through SDL's queue: tap, drag, focus, type "hi",
//                           Return; then quit
//   OV_SCREENSHOT=<file>    write the window surface (read back) as PNG
//                           before quitting
//   OV_QUIT_AFTER=<s>       quit after s seconds (screenshot first)
//   OV_PRINT_TARGETS=1      print the window-coordinate centres of the
//                           button, box and field (for external drivers)
//   OV_VULKAN_PROBE=1       open a second window with a Vulkan surface and
//                           report which devices can present to it
//   OV_TRACE=1              trace the app host's lifecycle on stderr

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup("OpenViews R7 sample") {
            SampleView()
        }
        .defaultSize(width: 420, height: 320)
    }
}

@MainActor
func say(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

struct SampleView: View {
    @State private var taps = 0
    @State private var offset = CGSize.zero
    @GestureState private var dragging = CGSize.zero
    @State private var name = ""
    @State private var submitted = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(spacing: 14) {
            Button("Tap me") {
                taps += 1
                say("button tapped (\(taps))")
            }
            .padding(10)
            .background { taps % 2 == 0 ? Color.blue : Color.orange }
            .keyboardShortcut("t", modifiers: .command)

            HStack(spacing: 4) {
                ForEach(0..<min(taps, 12), id: \.self) { _ in Color.red.frame(width: 10, height: 10) }
            }
            .frame(height: 10)

            ZStack {
                Color.gray.opacity(0.2)
                Color.green
                    .frame(width: 50, height: 50)
                    .offset(x: offset.width + dragging.width, y: offset.height + dragging.height)
                    .gesture(
                        DragGesture()
                            .updating($dragging) { v, s, _ in s = v.translation }
                            .onEnded { v in
                                offset.width += v.translation.width
                                offset.height += v.translation.height
                                say(String(format: "drag ended: translation (%.2f, %.2f) velocity (%.2f, %.2f) predicted (%.2f, %.2f)",
                                           v.translation.width, v.translation.height, v.velocity.width,
                                           v.velocity.height, v.predictedEndTranslation.width,
                                           v.predictedEndTranslation.height))
                            }
                    )
            }
            .frame(width: 300, height: 90)
            .clipped()

            TextField("Name", text: $name)
                .focused($nameFocused)
                .onSubmit {
                    submitted = name
                    say("submitted \"\(name)\" (focused: \(nameFocused))")
                }
                .padding(6)
                .background { nameFocused ? Color.yellow.opacity(0.4) : Color.gray.opacity(0.15) }
                .frame(width: 300)
                .onChange(of: name) { _, new in say("text \"\(new)\"") }
                .onChange(of: nameFocused) { _, f in say("field focused: \(f)") }

            HStack(spacing: 3) {
                ForEach(Array(submitted.enumerated()), id: \.offset) { _ in Color.purple.frame(width: 12, height: 12) }
            }
            .frame(height: 12)
        }
        .padding(16)
        .onChange(of: phase) { _, p in say("scene phase \(p)") }
        .task { await SampleDriver.start() }
    }
}

/// Automation for the done-criterion runs (see the header).
@MainActor
enum SampleDriver {
    static var started = false
    static let env = ProcessInfo.processInfo.environment

    static func start() async {
        guard !started, let host = AppHost.current else { return }
        started = true
        say("backend \(host.backend.name)\((host.backend as? SDLBackend).map { " SDL " + $0.libraryDescription } ?? "")")
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let window = host.windows.first else { return }
        say("window \(window.size.width)x\(window.size.height) pt, scale \(window.platform.scale), "
            + "pixels \(window.platform.pixelSize.width)x\(window.platform.pixelSize.height), "
            + "refresh \(window.platform.refreshRate) Hz")
        if let p = window.presenter as? CompositorPresenter {
            say("presenter: \(p.description)\(p.compositorError.map { " (makeCompositor: \($0))" } ?? "")")
        }
        if env["OV_PRINT_TARGETS"] != nil { printTargets(window) }
        if env["OV_VULKAN_PROBE"] != nil { probeVulkan(host) }
        if env["OV_SAMPLE_SCRIPT"] != nil { await script(host, window) }
        if let s = env["OV_QUIT_AFTER"], let t = Double(s) {
            try? await Task.sleep(nanoseconds: UInt64(t * 1e9))
            finish(host, window)
        }
    }

    static func frame<V>(_ type: V.Type, in window: WindowHost) -> CGRect? {
        var out: CGRect?
        window.graph.root?.forEachNode { n in
            if out == nil, n.view is V { out = HitTesting.frame(of: n, mirrorWidth: nil) }
        }
        return out
    }

    static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    static func printTargets(_ window: WindowHost) {
        let scale = window.platform.pixelSize.width > 0 ? Double(window.platform.pixelSize.width) / window.size.width : 1
        for (name, f) in [("button", frame(Button<Text>.self, in: window)),
                          ("field", frame(TextField<Text>.self, in: window)),
                          ("box", boxFrame(window))] {
            guard let f else { continue }
            let c = center(f)
            say("target \(name) \(Int(c.x)) \(Int(c.y)) pixels \(Int(c.x * scale)) \(Int(c.y * scale))")
        }
    }

    static func boxFrame(_ window: WindowHost) -> CGRect? {
        var out: CGRect?
        window.graph.root?.forEachNode { n in
            if out == nil, let c = n.view as? Color, c == .green { out = HitTesting.frame(of: n, mirrorWidth: nil) }
        }
        return out
    }

    static func probeVulkan(_ host: AppHost) {
        do {
            let w = try host.backend.makeWindow(WindowConfiguration(title: "Vulkan probe", size: CGSize(width: 200, height: 120),
                                                                    vulkan: true))
            if let v = w.vulkan {
                say("vulkan instance extensions: \(v.requiredInstanceExtensions().joined(separator: ", "))")
                let r = v.probe()
                say("vulkan probe: \(r.presentingDevices) presenting device(s): \(r.report)")
            } else {
                say("vulkan: window has no Vulkan surface interface")
            }
            w.close()
        } catch {
            say("vulkan probe failed: \(error)")
        }
    }

    static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func post(_ host: AppHost, _ e: PlatformEvent) { host.backend.post(e) }

    static func pointer(_ host: AppHost, _ w: WindowHost, _ phase: PointerPhase, _ p: CGPoint) {
        post(host, .pointer(PointerEvent(window: w.platform.id, phase: phase, location: p, button: 1,
                                         isPressed: phase == .down || phase == .moved, timestamp: host.backend.now)))
    }

    static func script(_ host: AppHost, _ w: WindowHost) async {
        say("script: tap the button")
        if let b = frame(Button<Text>.self, in: w) {
            pointer(host, w, .down, center(b))
            await pause(0.08)
            pointer(host, w, .up, center(b))
        }
        await pause(0.3)
        say("script: drag the box")
        if let box = boxFrame(w) {
            var p = center(box)
            pointer(host, w, .down, p)
            for _ in 0..<20 {
                await pause(0.016)
                p.x += 4
                p.y += 1
                pointer(host, w, .moved, p)
            }
            await pause(0.016)
            pointer(host, w, .up, p)
        }
        await pause(0.3)
        say("script: focus the field and type")
        if let f = frame(TextField<Text>.self, in: w) {
            pointer(host, w, .down, center(f))
            await pause(0.05)
            pointer(host, w, .up, center(f))
        }
        await pause(0.2)
        for c in "hi" {
            post(host, .key(KeyEvent(window: w.platform.id, key: .character(c), timestamp: host.backend.now)))
            post(host, .textInput(TextInputEvent(window: w.platform.id, text: String(c), timestamp: host.backend.now)))
            await pause(0.08)
        }
        say("script: Ctrl+T (the button's shortcut)")
        post(host, .key(KeyEvent(window: w.platform.id, key: .character("t"), modifiers: .control,
                                 timestamp: host.backend.now)))
        await pause(0.1)
        post(host, .key(KeyEvent(window: w.platform.id, key: .return, timestamp: host.backend.now)))
        await pause(0.5)
        finish(host, w)
    }

    static func finish(_ host: AppHost, _ w: WindowHost) {
        if let path = env["OV_SCREENSHOT"] {
            if let shot = w.presenter?.readback() ?? w.platform.readback() {
                do {
                    try shot.writePNG(to: URL(fileURLWithPath: path))
                    say("screenshot \(shot.width)x\(shot.height) written to \(path)")
                } catch {
                    say("screenshot failed: \(error)")
                }
            } else {
                say("screenshot: no readback")
            }
        }
        say("frames presented: \(w.presentedFrames), run-loop frames \(host.runLoop.framesRendered), "
            + "iterations \(host.runLoop.iterations), idle waits \(host.runLoop.idleWaits)")
        host.terminate()
    }
}
