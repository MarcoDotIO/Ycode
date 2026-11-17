import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_TOOLKIT4=<prefix>: beta 4's OpenViews items (B4-TOOLKIT;
// `specs/ide/parity-inventory.md` P-212, P-214, P-215), from the Welcome
// window (or a workspace, with a path):
//
//   menus    File opened with the pointer; the pointer resting on the New row
//            (pop-ups at 0.1 s and 0.4 s: the submenu opens after 0.2 s);
//            resting on another row closes it; the pop-ups' frames in the
//            window's points (a menu may extend past the window) and the
//            shortcut texts (⌘ ⌥ ⌃ ⇧ glyphs)
//   alerts   an alert answered by Return, another by Escape (both close it)
//   settings ⌘, opens Settings; ⌘W (Ctrl+W), then Escape close it (P-139, L-072)
//   sheets   Clone and New Project from Welcome: the window's size before,
//            while and after each sheet, and whether the sheet's buttons are
//            inside the window
//
// Stills: <prefix>-<state>.png (menus with their pop-ups on a larger canvas).
extension ShellDriver {
    #if os(Linux)
    static func toolkit4Walk(_ app: ShellAppModel, prefix: String) async {
        func shot(_ name: String, popups: Bool = false) async {
            await pause(0.3)
            let line = popups ? OpenViewsAutomation.screenshotWithPopups(to: "\(prefix)-\(name).png")
                : OpenViewsAutomation.screenshot(to: "\(prefix)-\(name).png")
            say("toolkit4 \(name): \(line)")
        }
        func size() -> String {
            guard let s = OpenViewsAutomation.windowSize() else { return "?" }
            return "\(Int(s.points.width))x\(Int(s.points.height))"
        }
        func popupText() -> String {
            OpenViewsAutomation.texts().filter(\.inPopup).map(\.text).joined(separator: " | ")
        }
        func inside(_ text: String) -> String {
            guard let s = OpenViewsAutomation.windowSize(),
                  let t = OpenViewsAutomation.texts().filter({ $0.text == text && !$0.inPopup }).max(by: { $0.frame.maxX < $1.frame.maxX })
            else { return "\(text): not shown" }
            let ok = t.frame.minX >= 0 && t.frame.maxX <= s.points.width && t.frame.minY >= 0 && t.frame.maxY <= s.points.height
            return "\(text): \(ok ? "inside" : "outside") at \(Int(t.frame.minX)),\(Int(t.frame.minY))"
        }

        // Menus (P-212).
        OpenViewsAutomation.setMenuBarRevealed(true)
        await pause(0.3)
        await clickText("File", inPopup: false)
        if let t = OpenViewsAutomation.lastPopupTiming {
            say("toolkit4 menu-file work: measure \(String(format: "%.1f", t.measure)) ms, window \(String(format: "%.1f", t.build)) ms")
        }
        await shot("menu-file", popups: true)
        say("toolkit4 menu-file frames: \(OpenViewsAutomation.popupFrames()) window \(size())")
        say("toolkit4 menu-file texts: \(popupText())")
        if let new = OpenViewsAutomation.texts().first(where: { $0.text == "New" && $0.inPopup }) {
            OpenViewsAutomation.move(to: CGPoint(x: new.frame.midX, y: new.frame.midY))
            await pause(0.1)
            say("toolkit4 rest 0.1 s on New: pop-ups \(OpenViewsAutomation.openPopupCount)")
            await pause(0.3)
            say("toolkit4 rest 0.4 s on New: pop-ups \(OpenViewsAutomation.openPopupCount)")
            await shot("menu-file-new", popups: true)
            say("toolkit4 menu-file-new frames: \(OpenViewsAutomation.popupFrames())")
            if let other = OpenViewsAutomation.texts().first(where: { $0.text == "Open…" && $0.inPopup }) {
                OpenViewsAutomation.move(to: CGPoint(x: other.frame.midX, y: other.frame.midY))
                await pause(0.5)
                say("toolkit4 rest 0.5 s on Open…: pop-ups \(OpenViewsAutomation.openPopupCount)")
            }
        } else {
            say("toolkit4 no New row")
        }
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        say("toolkit4 menus closed: pop-ups \(OpenViewsAutomation.openPopupCount)")

        // Alerts (P-214).
        app.notice = ShellNotice("Toolkit", "Return chooses the default button.")
        await pause(0.7)
        await shot("alert")
        OpenViewsAutomation.press(.return)
        await pause(0.7)
        say("toolkit4 alert after Return: \(app.notice == nil ? "closed" : "open")")
        app.notice = ShellNotice("Toolkit", "Escape chooses Cancel.")
        await pause(0.7)
        OpenViewsAutomation.press(.escape)
        await pause(0.7)
        say("toolkit4 alert after Escape: \(app.notice == nil ? "closed" : "open")")
        if app.notice != nil {
            app.notice = nil
            await pause(0.5)
        }

        // The Settings window (P-139, L-072): ⌘W (Ctrl+W) and Escape close it.
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        await pause(1.0)
        say("toolkit4 settings opened: windows \(OpenViewsAutomation.windowCount), size \(OpenViewsAutomation.windowSize(1).map { "\(Int($0.points.width))x\(Int($0.points.height))" } ?? "?")")
        OpenViewsAutomation.press(.character("w"), modifiers: [.control], window: 1)
        await pause(0.8)
        say("toolkit4 settings after Ctrl+W: windows \(OpenViewsAutomation.windowCount)")
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        await pause(1.0)
        OpenViewsAutomation.press(.escape, window: 1)
        await pause(0.8)
        say("toolkit4 settings after Escape: windows \(OpenViewsAutomation.windowCount)")

        // Sheets (P-215), from Welcome.
        guard app.workspace == nil else { return }
        say("toolkit4 window before Clone: \(size())")
        app.perform(.clone)
        await pause(1.0)
        await shot("clone")
        say("toolkit4 window with Clone: \(size()); \(inside("Clone")); \(inside("Cancel"))")
        app.cancelClone()
        await pause(1.0)
        say("toolkit4 window after Clone: \(size())")
        app.showNewProject()
        await pause(1.0)
        await shot("new-project")
        say("toolkit4 window with New Project: \(size()); \(inside("Next")); \(inside("Cancel"))")
        app.cancelNewProject()
        await pause(1.0)
        say("toolkit4 window after New Project: \(size())")
    }
    #endif
}
