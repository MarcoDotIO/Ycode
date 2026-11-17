import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_MENUS4=<prefix>: the beta 4 menu-bar walk (B4-MENUS). Prints
// the Linux menu bar as `ShellMenuModel` decides it ("menus4 row …", one
// line per item: path, title, shortcut, enabled, check mark) for the state
// the app is in, then opens the menus the pass changed with the pointer and
// writes <prefix>-<NN>-<menu>.png: File, Edit, View, Navigate, Editor,
// Product, Debug, Debug ▸ Simulate Location, Integrate. With
// YCODE_IDE_MENUS4_FILE=<name> a file is opened first (the Editor menu is
// then the source editor's).
extension ShellDriver {
    #if os(Linux)
    static func menus4Walk(_ app: ShellAppModel, prefix: String) async {
        OpenViewsAutomation.setMenuBarRevealed(true)
        await pause(0.4)
        if let name = env["YCODE_IDE_MENUS4_FILE"], let w = app.workspace,
           let p = w.root.allFiles.compactMap(\.path).first(where: { $0.hasSuffix("/" + name) }) {
            w.open(p)
            await pause(0.8)
        }
        let label = app.workspace == nil ? "welcome" : (app.workspace?.document?.name ?? "workspace")
        for r in ShellMenuModel.rows(app) { say("menus4 row \(label) | \(r)") }
        var n = 0
        func title(_ s: String) -> OpenViewsAutomation.TextItem? {
            OpenViewsAutomation.texts().filter { $0.text == s && !$0.inPopup && $0.frame.minY < 40 }.min { $0.frame.minY < $1.frame.minY }
        }
        func escapeAll() async {
            for _ in 0..<4 where OpenViewsAutomation.openPopupCount > 0 {
                OpenViewsAutomation.press(.escape)
                await pause(0.25)
            }
        }
        func shot(_ name: String) async {
            await pause(0.3)
            n += 1
            let path = String(format: "%@-%02d-%@-%@.png", prefix, n, label, name.replacingOccurrences(of: " ", with: "_"))
            say("menus4 shot \(name): \(OpenViewsAutomation.screenshot(0, to: path))")
        }
        for menu in ["File", "Edit", "View", "Navigate", "Editor", "Product", "Debug", "Integrate"] {
            await escapeAll()
            guard let t = title(menu) else { say("menus4 \(menu): no title"); continue }
            await OpenViewsAutomation.click(at: CGPoint(x: t.frame.midX, y: t.frame.midY))
            await shot(menu)
            if menu == "Debug", let item = OpenViewsAutomation.texts().first(where: { $0.text == "Simulate Location" && $0.inPopup }) {
                OpenViewsAutomation.move(to: CGPoint(x: item.frame.midX, y: item.frame.midY))
                await pause(0.6)
                if OpenViewsAutomation.openPopupCount < 2 { await OpenViewsAutomation.click(at: CGPoint(x: item.frame.midX, y: item.frame.midY)) }
                await shot("Debug-Simulate_Location")
            }
        }
        await escapeAll()
    }
    #endif
}
