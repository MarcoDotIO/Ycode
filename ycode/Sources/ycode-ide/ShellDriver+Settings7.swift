import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_SETTINGS7=<prefix>: council round 7 in Settings ▸ Appearance on
// Linux (`specs/ide/settings.md` R7.1–R7.4, rows 182–185), the Linux half of
// SettingsR7Tests' shots. Run with no path (Welcome) and OV_COLOR_SCHEME.
// Writes <prefix>-appearance.png (unscrolled), -scrolled.png (the list 360
// points down, the council's X13), -rows.png (450) and -end.png, each with
// a .txt of every Text and identified view with its frame, and
// <prefix>-appearance-ax.txt (the accessibility tree), then turns on
// Customize All Colors in a duplicated theme and writes -customize.png.
extension ShellDriver {
    #if os(Linux)
    static func settings7Walk(_ app: ShellAppModel, prefix: String) async {
        func dump(_ index: Int, _ name: String) {
            let size = OpenViewsAutomation.windowSize(index)
            var lines = [String(format: "window %.1f %.1f", size?.points.width ?? 0, size?.points.height ?? 0)]
            func box(_ f: CGRect) -> String { String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY, f.width, f.height) }
            for t in OpenViewsAutomation.texts(index) where !t.text.isEmpty {
                lines.append("text \"\(t.text.replacingOccurrences(of: "\n", with: " "))\" \(box(t.frame))")
            }
            for (id, f) in OpenViewsAutomation.identifiedFrames(index).sorted(by: { $0.key < $1.key }) {
                lines.append("view \(box(f)) id=\(id.replacingOccurrences(of: " ", with: "_"))")
            }
            try? lines.joined(separator: "\n").write(toFile: "\(prefix)-\(name).txt", atomically: true, encoding: .utf8)
        }
        func shot(_ name: String, window index: Int, settle: Double = 0.8) async {
            await pause(settle)
            dump(index, name)
            say("settings7 \(name): " + OpenViewsAutomation.screenshot(index, to: "\(prefix)-\(name).png"))
        }
        // Scrolls the list `points` down (wheel notches of 10 points).
        func scrollList(_ points: Int, window index: Int) async {
            for _ in 0..<(abs(points) / 10) {
                OpenViewsAutomation.scroll(at: CGPoint(x: 445, y: 400), delta: CGSize(width: 0, height: points > 0 ? -10 : 10), window: index)
                await pause(0.02)
            }
        }
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        for _ in 0..<20 where OpenViewsAutomation.windowCount < 2 { await pause(0.2) }
        guard OpenViewsAutomation.windowCount >= 2 else { say("settings7: the Settings window did not open"); return }
        let settings = OpenViewsAutomation.windowCount - 1
        ShellSettingsModel.shared.select(.appearance)
        await shot("appearance", window: settings)
        try? OpenViewsAutomation.accessibilityDump(settings).write(toFile: "\(prefix)-appearance-ax.txt", atomically: true, encoding: .utf8)
        await scrollList(360, window: settings)
        await shot("appearance-scrolled", window: settings)
        await scrollList(90, window: settings)
        await shot("appearance-rows", window: settings)
        await scrollList(600, window: settings)
        await shot("appearance-end", window: settings)
        // A duplicated theme with Customize All Colors on: every row a slider.
        let prefs = Preferences.shared
        _ = try? prefs.duplicate(prefs.theme)
        prefs.editSelectedTheme { SettingsAppearanceR7.set(.customizeAllColors, true, in: &$0) }
        await scrollList(-1100, window: settings)
        await scrollList(360, window: settings)
        await shot("appearance-customize", window: settings)
        say("settings7 theme \(prefs.themeName): customize \(SettingsAppearanceR7.isOn(.customizeAllColors, in: prefs.theme))")
        prefs.deleteTheme(named: prefs.themeName)
    }
    #endif
}
