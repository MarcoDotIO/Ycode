import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
import YcodePreviews
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_PREVIEWS=<prefix>  the preview canvas's walk (B3-PREVIEWS,
//                              previews.md §Linux "The Linux canvas") with
//                              the pointer and the keyboard: open
//                              YCODE_IDE_PREVIEW_FILE (default: the first
//                              Swift file with a #Preview), the paused
//                              canvas, Resume, the first picture; then
//                              YCODE_IDE_PREVIEW_EDITS (default 5) edits typed
//                              into the file's first string literal, each
//                              timed from the keystroke to the new picture
//                              ("preview edit N: X s"); a compile error (the
//                              banner over the last picture) and its fix;
//                              the second tab, Grid, the Color Scheme and
//                              Dynamic Type variants, an iPad, Selectable's
//                              reveal; with YCODE_IDE_PREVIEW_UIKIT_FILE that
//                              file (UIKit previews: needs a simulator host,
//                              or the simulator's picture). Writes
//                              <prefix>-<state>.png after each step and quits.

#if os(Linux)
@MainActor
enum PreviewsDriver {
    static let env = ProcessInfo.processInfo.environment
    static func say(_ s: String) { ShellDriver.say("previews: " + s) }

    static func state(_ c: PreviewCanvasShellModel) -> String {
        "shown=\(c.isShown) paused=\(c.isPaused) state=\(c.state) tiles=\(c.tiles.count) selected=\(c.selectedIndex) grid=\(c.isGrid) "
            + "variants=\(c.variantKind?.rawValue ?? "off") device=\(c.deviceTitle) updating=\(c.isUpdating) banner=\(c.banner?.title ?? "none") "
            + "status=\"\(c.statusText)\""
    }

    static func shot(_ prefix: String, _ name: String, _ c: PreviewCanvasShellModel) async {
        await ShellDriver.pause(0.6)
        say("\(name): \(state(c)) " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(name).png"))
    }

    static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < seconds { await ShellDriver.pause(0.05) }
        return condition()
    }

    static func run(_ app: ShellAppModel, prefix: String) async {
        await walk(app, prefix: prefix)
        OpenViewsAutomation.terminate()
    }

    /// Waits until an update that started after `count` timings finishes (or fails).
    static func settled(_ c: PreviewCanvasShellModel, after count: Int, seconds: Double) async -> Bool {
        await wait(seconds) { (c.timings.count > count || c.banner != nil || { if case .failed = c.state { return true }; return false }()) && !c.isUpdating }
    }

    static func walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("no workspace"); return }
        let c = w.previewCanvas
        let wanted = env["YCODE_IDE_PREVIEW_FILE"]
        let file = w.root.allFiles.first { f in
            guard let p = f.path, p.hasSuffix(".swift") else { return false }
            if let wanted { return f.name == wanted }
            return ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").contains("#Preview")
        }
        guard let path = file?.path else { say("no file with a preview"); return }
        w.isInspectorShown = false
        w.open(path)
        await ShellDriver.pause(1.0)
        await shot(prefix, "paused", c)

        // Resume: the first picture (the first run builds the host: minutes).
        await ShellDriver.click("canvas resume")
        let t0 = Date()
        _ = await wait(2, { if case .starting = c.state { return true }; return false })
        await shot(prefix, "starting", c)
        let first = await settled(c, after: 0, seconds: 1800)
        say("first picture=\(first) after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(c.timings.last?.summary ?? "-")")
        await shot(prefix, "rendered", c)
        guard first, case .rendered = c.state else { return }

        // Edits typed into the first string literal, timed to the new picture.
        let edits = Int(env["YCODE_IDE_PREVIEW_EDITS"] ?? "") ?? 5
        var times: [Double] = []
        if let source = ShellDriver.frame("source") {
            await OpenViewsAutomation.click(at: CGPoint(x: source.midX, y: source.minY + 12))
            await ShellDriver.pause(0.3)
        }
        for i in 1...max(edits, 1) {
            guard let editor = w.editor else { break }
            let text = editor.buffer.text as NSString
            let quote = text.range(of: "\"", options: [], range: NSRange(location: Self.bodyStart(text), length: text.length - Self.bodyStart(text)))
            guard quote.location != NSNotFound else { say("no string literal to edit"); break }
            editor.buffer.setCaret(quote.location + 1)
            let before = c.timings.count
            let start = Date()
            OpenViewsAutomation.type(i % 2 == 1 ? "★" : "✓")
            let ok = await settled(c, after: before, seconds: 60)
            let dt = Date().timeIntervalSince(start)
            times.append(dt)
            say("preview edit \(i): \(String(format: "%.2f", dt)) s ok=\(ok) \(c.timings.last?.summary ?? "-")")
            if i == 1 { await shot(prefix, "edited", c) }
            await ShellDriver.pause(0.4)
        }
        let sorted = times.sorted()
        if !sorted.isEmpty {
            say(String(format: "preview edits: median %.2f s, min %.2f, max %.2f (n=%d)", sorted[sorted.count / 2], sorted.first!, sorted.last!, sorted.count))
        }

        // YCODE_IDE_PREVIEW_QUICK: the first picture and the edits only (a slow path, such as UIKit previews).
        if env["YCODE_IDE_PREVIEW_QUICK"] != nil { say("done: \(state(c))"); return }

        // A compile error: the banner over the last picture, then the fix.
        if let editor = w.editor, let source = ShellDriver.frame("source") {
            _ = source
            let text = editor.buffer.text as NSString
            let start = Self.bodyStart(text)
            let brace = text.range(of: "{", options: [], range: NSRange(location: start, length: text.length - start))
            if brace.location != NSNotFound {
                editor.buffer.setCaret(brace.location + 1)
                let before = c.timings.count
                OpenViewsAutomation.type(" undefinedName123 ")
                _ = await wait(30) { c.banner != nil && !c.isUpdating }
                _ = before
                await shot(prefix, "error-banner", c)
                if let i = c.banner?.issues.first { say("banner issue: \(i.description)") }
                for _ in 0..<" undefinedName123 ".count { OpenViewsAutomation.press(.backspace) }
                _ = await wait(30) { c.banner == nil && !c.isUpdating }
                await shot(prefix, "fixed", c)
            }
        }

        // Another tab, Grid, variants, a device, Selectable.
        if c.previews.count > 1 {
            await ShellDriver.click("canvas tab 1")
            _ = await settled(c, after: c.timings.count - 1, seconds: 30)
            await shot(prefix, "second-tab", c)
        }
        let n0 = c.timings.count
        await ShellDriver.click("canvas mode Grid")
        _ = await settled(c, after: n0, seconds: 30)
        await shot(prefix, "grid", c)
        await ShellDriver.click("canvas mode Grid")
        let n1 = c.timings.count
        c.setVariants(.colorScheme)
        _ = await settled(c, after: n1, seconds: 30)
        await shot(prefix, "variants-color", c)
        let n2 = c.timings.count
        c.setVariants(.dynamicType)
        _ = await settled(c, after: n2, seconds: 60)
        await shot(prefix, "variants-dynamic-type", c)
        c.setVariants(nil)
        let n3 = c.timings.count
        c.chooseDevice(DeviceFrameSpecID.iPad)
        _ = await settled(c, after: n3, seconds: 30)
        await shot(prefix, "ipad", c)
        c.chooseDevice(nil)
        await ShellDriver.click("canvas mode Selectable")
        await ShellDriver.pause(1.0)
        let caretBefore = w.editor?.buffer.caretLine ?? -1
        await ShellDriver.click("canvas tile 0")
        await ShellDriver.pause(0.6)
        say("selectable reveal: caret line \(caretBefore + 1) → \((w.editor?.buffer.caretLine ?? -1) + 1) (preview line \(c.previews.first?.line ?? 0))")
        await ShellDriver.click("canvas mode Live")
        await ShellDriver.click("canvas settings")
        await ShellDriver.pause(0.6)
        await shot(prefix, "settings", c)
        OpenViewsAutomation.press(.escape)
        await ShellDriver.pause(0.3)

        // Editor ▸ Layout ▸ Canvas on Bottom, then back.
        w.perform(.canvasLayoutBottom)
        await shot(prefix, "below", c)
        w.perform(.canvasLayoutAutomatic)

        // UIKit previews.
        if let name = env["YCODE_IDE_PREVIEW_UIKIT_FILE"], let f = w.root.allFiles.first(where: { $0.name == name }), let p = f.path {
            w.open(p)
            await ShellDriver.pause(1.0)
            _ = await wait(900) { if case .starting = c.state { return false }; return !c.isUpdating }
            await shot(prefix, "uikit", c)
        }
        say("done: \(state(c))")
    }

    /// Where previews start: the first `#Preview`'s line (string literals
    /// before it are the views' own), else 0.
    static func bodyStart(_ text: NSString) -> Int {
        let r = text.range(of: "#Preview")
        return r.location == NSNotFound ? 0 : r.location
    }
}

/// Device type ids the walk picks.
enum DeviceFrameSpecID {
    static let iPad = "ipad-a16"
}
#endif
