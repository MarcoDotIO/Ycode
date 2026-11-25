import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_OPENVIEWS5=<prefix>: B5-OPENVIEWS's Linux checks
// (`parity-inventory.md` P-033, P-155, P-217; `docs/beta5/b5-openviews.md`).
// Each check prints "openviews5 <name>: … yes|NO".
//
// With a workspace:
// 1. P-033 (L-001): the menu bar shown on demand: the toolbar moves down by
//    the bar's height instead of being covered (shot `-menubar-shown`).
// 2. P-155: Settings (Ctrl+,): Down and Up move between panes (L-071); a
//    Simulator Host value left with Tab is kept (L-198); Ctrl+W closes.
// 3. P-217 (L-222): a Settings pop-up opens over its button with the chosen
//    row on it (shot `-popup`).
// Without one (Welcome, 480 points wide):
// 4. P-033 (L-002): the revealed bar shows whole titles and an overflow
//    menu (shots `-welcome-bar`, `-welcome-overflow`).
extension ShellDriver {
    #if os(Linux)
    static func openViews5Walk(_ app: ShellAppModel, prefix: String) async {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            say("openviews5 \(name): \(detail) \(ok ? "yes" : "NO")")
        }
        guard app.workspace != nil else {
            await openViews5Welcome(prefix: prefix, check: check)
            return
        }
        // 1. The bar over the toolbar.
        let before = frame("tb navigator")
        OpenViewsAutomation.setMenuBarRevealed(true)
        await pause(0.5)
        let after = frame("tb navigator")
        let moved = (after?.minY ?? 0) - (before?.minY ?? 0)
        check("menu bar moves the toolbar down", abs(moved - 26) < 0.5, String(format: "toolbar moved %.1f", Double(moved)))
        say("openviews5 shot: " + OpenViewsAutomation.screenshot(to: "\(prefix)-menubar-shown.png"))
        OpenViewsAutomation.setMenuBarRevealed(false)
        await pause(0.5)
        check("toolbar back when the bar hides", abs((frame("tb navigator")?.minY ?? -1) - (before?.minY ?? 0)) < 0.5)

        // 2. Settings keys and fields.
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        for _ in 0..<30 where OpenViewsAutomation.windowCount < 2 { await pause(0.1) }
        await pause(0.8)
        let model = ShellSettingsModel.shared
        model.select(.general)
        await pause(0.3)
        OpenViewsAutomation.press(.downArrow, window: 1)
        await pause(0.3)
        OpenViewsAutomation.press(.downArrow, window: 1)
        await pause(0.3)
        check("Down twice shows Accounts", model.pane == .accounts, "pane \(model.pane.rawValue)")
        OpenViewsAutomation.press(.upArrow, window: 1)
        await pause(0.3)
        check("Up shows Appearance", model.pane == .appearance, "pane \(model.pane.rawValue)")
        say("openviews5 shot: " + OpenViewsAutomation.screenshot(1, to: "\(prefix)-settings-arrows.png"))

        // P-217: a pop-up of the General pane.
        model.select(.general)
        await pause(0.5)
        if let f = SettingsDriver.frame("settings navigator size") {
            await OpenViewsAutomation.click(at: CGPoint(x: f.midX, y: f.midY), window: 1)
            await pause(0.6)
            let popups = OpenViewsAutomation.popupFrames(1)
            if let p = popups.last {
                check("pop-up opens over its button", p.minY < f.minY && p.maxY > f.maxY,
                      "button \(Int(f.minY))–\(Int(f.maxY)), menu \(Int(p.minY))–\(Int(p.maxY))")
            } else {
                check("pop-up opens over its button", false, "no pop-up")
            }
            say("openviews5 shot: " + OpenViewsAutomation.screenshotWithPopups(1, to: "\(prefix)-popup.png"))
            OpenViewsAutomation.press(.escape, window: 1)
            await pause(0.4)
        }

        // L-198: a Simulator Host value left with Tab.
        model.showHostPage()
        await pause(0.6)
        // (Run with XDG_CONFIG_HOME in a scratch folder: this writes the
        // user's defaults.)
        let field = SimulatorHostPage.Field.dataFolder
        let value = "/tmp/b5-tab-\(Int(Date().timeIntervalSince1970) % 1000)"
        await SettingsDriver.type(value, into: "settings host \(field.rawValue)")
        OpenViewsAutomation.press(.tab, window: 1)
        await pause(0.4)
        let saved = SimulatorHostPage.value(field, app.runtimeDefaults)
        check("value left with Tab is kept", saved == value, "\(field.rawValue)=\(saved)")
        say("openviews5 shot: " + OpenViewsAutomation.screenshot(1, to: "\(prefix)-settings-host.png"))
        OpenViewsAutomation.press(.character("w"), modifiers: [.control], window: 1)
        for _ in 0..<20 where OpenViewsAutomation.windowCount > 1 { await pause(0.1) }
        check("Ctrl+W closes Settings", OpenViewsAutomation.windowCount == 1, "windows \(OpenViewsAutomation.windowCount)")
    }

    /// Welcome: the revealed bar in a 480-point window.
    static func openViews5Welcome(prefix: String, check: (String, Bool, String) -> Void) async {
        await pause(0.6)
        OpenViewsAutomation.setMenuBarRevealed(true)
        await pause(0.6)
        let items = OpenViewsAutomation.texts().filter { !$0.inPopup && $0.frame.minY < 26 }
        let inside = items.filter { $0.frame.minX >= 0 && $0.frame.maxX <= (OpenViewsAutomation.windowSize()?.points.width ?? 480) }
        check("titles are whole", !inside.contains { $0.text.contains("…") }, inside.map(\.text).joined(separator: " "))
        check("overflow shown", inside.contains { $0.text == "»" }, "")
        say("openviews5 shot: " + OpenViewsAutomation.screenshot(to: "\(prefix)-welcome-bar.png"))
        if let more = inside.first(where: { $0.text == "»" }) {
            await OpenViewsAutomation.click(at: CGPoint(x: more.frame.midX, y: more.frame.midY))
            await pause(0.6)
            let rows = OpenViewsAutomation.texts().filter(\.inPopup).map(\.text)
            check("overflow lists the hidden menus", rows.contains("Help"), rows.joined(separator: ", "))
            say("openviews5 shot: " + OpenViewsAutomation.screenshotWithPopups(to: "\(prefix)-welcome-overflow.png"))
            OpenViewsAutomation.press(.escape)
            await pause(0.3)
        }
    }
    #endif
}
