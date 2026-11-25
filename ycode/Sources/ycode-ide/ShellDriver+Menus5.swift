import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_MENUS5=<prefix>: the beta 5 menu-bar cost walk (B5-MENUS2).
// Selects the workspace's first two Swift files in turn, 24 times, as a
// navigator click does (the row's selection, then the open), and prints for
// each the work of the first frame presented after it (update, layout,
// drawing, presenting), then the median and mean (`menus5 select`). The
// menu bar's items are rebuilt in those frames, so their per-item cost
// shows here.
extension ShellDriver {
    #if os(Linux)
    static func menus5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("menus5: no workspace"); return }
        let swift = w.root.allFiles.filter { $0.path?.hasSuffix(".swift") == true }
        guard swift.count >= 2, let a = swift[0].path, let b = swift[1].path else { say("menus5: needs two Swift files"); return }
        for p in [a, b] { if let ids = w.root.idPath(to: p) { for id in ids.dropLast() { w.setExpanded(id, true) } } }
        w.open(a)
        await pause(1.0)
        var work: [Double] = []
        for i in 0..<24 {
            let p = i % 2 == 0 ? b : a
            let frames0 = OpenViewsAutomation.presentedFrames()
            OpenViewsAutomation.frameDurations = []
            let start = Date()
            w.selection = w.root.allFiles.first { $0.path == p }?.id
            w.open(p)
            while OpenViewsAutomation.presentedFrames() == frames0, Date().timeIntervalSince(start) < 2 { await pause(0.001) }
            let ms = (OpenViewsAutomation.frameDurations?.first ?? 0) * 1000
            work.append(ms)
            say(String(format: "menus5 select %d: first frame's work %.1f ms", i, ms))
            await pause(0.4)
        }
        OpenViewsAutomation.frameDurations = nil
        let sorted = work.sorted()
        say(String(format: "menus5 select: median %.1f ms, mean %.1f ms, min %.1f ms, max %.1f ms over %d selections",
                   sorted[sorted.count / 2], work.reduce(0, +) / Double(work.count), sorted.first ?? 0, sorted.last ?? 0, work.count))
        // The menu bar's own share: every row's title and enabled state with
        // one shared pass (as `ShellMenus` now builds them) and with a pass
        // per item (as each item rebuilt the context before beta 5's fix).
        let commands = CommandTable.allCommands
        func time(_ body: () -> Void) -> Double {
            let t = Date()
            for _ in 0..<10 { body() }
            return Date().timeIntervalSince(t) * 100
        }
        let shared = time {
            let pass = ShellMenuModel.Pass(app)
            for c in commands { _ = ShellMenuModel.title(c, in: pass); _ = ShellMenuModel.isEnabled(c, in: pass) }
        }
        let perItem = time {
            for c in commands { _ = ShellMenuModel.title(c, in: .init(app)); _ = ShellMenuModel.isEnabled(c, in: .init(app)) }
        }
        say(String(format: "menus5 items: %d commands, titles and enabled states %.2f ms with one pass, %.2f ms with a pass per item",
                   commands.count, shared, perItem))
        say("menus5 shot: " + OpenViewsAutomation.screenshot(to: "\(prefix)-menus5-select.png"))
    }
    #endif
}
