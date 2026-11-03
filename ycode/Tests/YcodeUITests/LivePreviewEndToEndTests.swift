#if os(macOS)
import AppKit
import Foundation
import Testing
import YcodeDisplayStream
@testable import YcodeIDECore
@testable import YcodeUI

/// Opt-in end-to-end live preview on a real Ycode simulator
/// (specs/ide/previews.md §Fast updates, §Measurements). Skipped unless these are set:
///   YCODE_E2E_REMOTE    ssh destination (user@host; key-based login only)
///   YCODE_E2E_DATA      remote data directory (apps/, devices/)
///   YCODE_E2E_RUNTIME   remote runtime root (iOS 27.0: the iPhone 18 Pro)
///   YCODE_E2E_SIMD      remote launcher (ycode-sim)
///   YCODE_E2E_PREVIEW   1 to run this test
///   YCODE_E2E_DEVICE    device name (default "ycode-device"; the preview
///                       device is "<name>-iphone-18-pro-27.0-previews")
///   YCODE_E2E_SHOT      where to write a PNG of the window (optional)
///   YCODE_E2E_EDITS     body edits to time (default 5)
///   YCODE_E2E_PREVIEW_DEVICE  the canvas's device choice, e.g. "iPhone 18 Pro (Ycode) 27.1"
///                       (default: Automatic)
/// Nothing here is machine-specific; the values come only from the environment.
@Suite(.serialized, .heavyIntegration, .previewHostCheck, .timeLimit(.minutes(30))) @MainActor struct LivePreviewEndToEndTests {
    static let contentView = """
    import SwiftUI

    struct ContentView: View {
        @State private var taps = 0
        var label = "Hello"
        var body: some View {
            VStack(spacing: 24) {
                Text("\\(label) \\(taps)")
                    .font(.system(size: 44, weight: .bold))
                Button("Tap me") { taps += 1 }
                    .font(.system(size: 40))
                    .padding(30)
                    .background(Color.orange)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.yellow)
        }
    }

    #Preview("Light") {
        ContentView()
    }

    #Preview("Dark") {
        ContentView(label: "Night")
            .preferredColorScheme(.dark)
    }

    """

    /// The share (0–1) of sampled pixels that differ between two images of one size.
    static func difference(_ a: CGImage?, _ b: CGImage?) -> Double {
        // No picture on either side is no evidence of a change.
        guard let a, let b else { return 0 }
        guard a.width == b.width, a.height == b.height else { return 1 }
        func samples(_ i: CGImage) -> [UInt8] {
            let w = 48, h = 64
            var px = [UInt8](repeating: 0, count: w * h * 4)
            px.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(i, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return px
        }
        let x = samples(a), y = samples(b)
        var n = 0
        for i in stride(from: 0, to: x.count, by: 4) where abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i + 1]) - Int(y[i + 1])) + abs(Int(x[i + 2]) - Int(y[i + 2])) > 30 { n += 1 }
        return Double(n) / Double(x.count / 4)
    }

    func tileImage(_ c: PreviewCanvasController, _ i: Int) -> CGImage? {
        (c.liveTileViews.count > i ? c.liveTileViews[i] as? PreviewLiveTileView : nil)?.picture
    }

    @Test func livePreviewOnARealYcodeSimulator() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["YCODE_E2E_PREVIEW"] == "1", let destination = env["YCODE_E2E_REMOTE"], let data = env["YCODE_E2E_DATA"],
              let runtime = env["YCODE_E2E_RUNTIME"], let simd = env["YCODE_E2E_SIMD"] else {
            print("skipping: YCODE_E2E_PREVIEW and friends are not set")
            return
        }
        _ = NSApplication.shared
        // The settings go into a scratch suite, never the test runner's own defaults.
        let scratch = TestDefaults("live-preview-e2e")
        let previous = Preferences.shared
        Preferences.shared = Preferences(defaults: scratch.defaults)
        defer { Preferences.shared = previous; scratch.remove() }
        let defaults = scratch.defaults
        var settings = RemoteSimulatorSettings(destination: destination, dataDirectory: data, runtimeRoot: runtime, simdPath: simd,
                                               deviceName: env["YCODE_E2E_DEVICE"] ?? "ycode-device")
        settings.runtimeVersion = RemoteSimulatorSettings.version(inPath: runtime) ?? "27.0"
        settings.save(defaults)
        RemoteSimulatorSettings.saveRuntimeVersion(settings.runtimeVersion!, root: runtime, defaults)

        // A sample iOS app with two previews.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-live-preview-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var o = ProjectOptions()
        o.productName = "PreviewSample"
        o.testing = .none
        let proj = try IOSAppTemplate.create(options: o, in: dir)
        let file = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "ContentView.swift" })
        try Self.contentView.write(to: file, atomically: true, encoding: .utf8)

        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.previewWorkDirectory = dir.appendingPathComponent("Previews")
        wc.window?.setContentSize(NSSize(width: 1500, height: 950))
        wc.showWindow(nil)
        #expect(wc.previewPlatform == .iOS)
        wc.open(path: file.path, line: 1)
        #expect(await waitUntil(10) { wc.canvas != nil })
        let c = try #require(wc.canvas)
        #expect(c.names == ["Light", "Dark"])

        // The preview device (the canvas's device menu), e.g. "iPhone 18 Pro (Ycode) 27.1".
        if let d = env["YCODE_E2E_PREVIEW_DEVICE"] { c.chooseDevice(d) }
        // First preview: build the host, start (or restore) the preview device, compile and load.
        let t0 = Date()
        c.resume()
        let first = await waitUntil(1200) { if case .live = c.state { return true }; if case .failed = c.state { return true }; return false }
        let firstSeconds = Date().timeIntervalSince(t0)
        if case .failed(let m) = c.state { Issue.record("the preview failed: \(m)") }
        #expect(first)
        guard case .live = c.state else { return }
        let ps = try #require(wc.livePreview.session)
        print(String(format: "e2e preview: first preview %.1f s (device start %.1f s)", firstSeconds, ps.startSeconds ?? -1))
        #expect(await waitUntil(60) { tileImage(c, 0) != nil })

        // Edits of the body: save → new pixels.
        let edits = Int(env["YCODE_E2E_EDITS"] ?? "5") ?? 5
        var times: [Double] = []
        for k in 0..<edits {
            let before = tileImage(c, 0)
            let text = wc.editor.text
            let old = k == 0 ? "\"Hello\"" : "\"Edit \(k - 1)\""
            let range = (text as NSString).range(of: old)
            #expect(range.location != NSNotFound)
            wc.editor.textView.insertText("\"Edit \(k)\"", replacementRange: range)
            let saved = Date()
            try wc.editor.save()
            let changed = await waitUntil(30) { Self.difference(before, tileImage(c, 0)) > 0 && !c.isUpdating }
            let dt = Date().timeIntervalSince(saved)
            #expect(changed)
            times.append(dt)
            print(String(format: "e2e preview: edit %d → new pixels %.2f s; %@", k, dt, wc.livePreviewTimings.last?.summary ?? ""))
            try await Task.sleep(for: .milliseconds(500))
        }
        if !times.isEmpty {
            let sorted = times.sorted()
            print(String(format: "e2e preview: save → new pixels median %.2f s, min %.2f, max %.2f (n=%d)", sorted[sorted.count / 2], sorted[0], sorted.last!, sorted.count))
        }

        // Live mode: a click on the button (a tap on the device) changes the count.
        c.setMode(.live)
        try await Task.sleep(for: .seconds(2))
        if let tile = c.liveTileViews.first as? PreviewLiveTileView, let window = tile.window {
            let before = tileImage(c, 0)
            #expect(before != nil)
            // The button is just below the middle of the tile.
            let local = NSPoint(x: tile.bounds.midX, y: tile.bounds.midY + tile.bounds.height * 0.05)
            let inWindow = tile.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = try #require(NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                if type == .leftMouseDown { tile.mouseDown(with: e) } else { tile.mouseUp(with: e) }
                try await Task.sleep(for: .milliseconds(90))
            }
            let tapped = Date()
            let changed = await waitUntil(20) { Self.difference(before, tileImage(c, 0)) > 0 }
            // Keep the tapped picture for the record.
            if let shot = env["YCODE_E2E_SHOT"], let img = tileImage(c, 0) {
                let rep = NSBitmapImageRep(cgImage: img)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-tapped.png")))
            }
            print(String(format: "e2e preview: tap → changed %@ after %.2f s", changed ? "yes" : "no", Date().timeIntervalSince(tapped)))
            #expect(changed)
        }

        // Two previews side by side (Grid).
        c.setMode(.grid)
        #expect(await waitUntil(30) { c.liveTileViews.count == 2 && !c.isUpdating })
        try await Task.sleep(for: .seconds(2))
        if case .live(let tiles) = c.state {
            #expect(tiles.count == 2 && tiles[0].region.y == tiles[1].region.y && tiles[0].region.x < tiles[1].region.x)
            print("e2e preview: grid regions \(tiles.map { "\($0.title) \(Int($0.region.x)),\(Int($0.region.y)) \(Int($0.region.width))x\(Int($0.region.height))" })")
        }
        print("e2e preview: timings\n" + wc.livePreviewTimings.map(\.summary).joined(separator: "\n"))

        if let shot = env["YCODE_E2E_SHOT"], let view = wc.window?.contentView {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
                print("e2e preview: window snapshot \(shot)")
            }
        }
        await ps.stop()
        #expect(await waitUntil(150) { !ps.isRunning })
        wc.close()
    }
}
#endif
