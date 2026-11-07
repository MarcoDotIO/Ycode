import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_SETTINGS5=<prefix>: council round 5 in Settings and the
// runtime wizard's host step on Linux (`specs/ide/settings.md` R5.1–R5.5,
// `specs/ide/cross-platform-parity.md` §10–§11), the Linux half of
// SettingsR5Tests' shots. Run with no path (Welcome) and OV_COLOR_SCHEME.
// Writes <prefix>-<page>.png and .txt (every Text and identified view with
// its frame) for General, Appearance, Editing, Components (the inventory
// the macOS shots use), Simulators (the host page) and runtime-host.
extension ShellDriver {
    #if os(Linux)
    /// The macOS shots' inventory (SettingsR5Tests.inventory).
    static let settings5Inventory = ComponentsInventory(
        sdks: [],
        runtimes: [SimRuntimeRecord(platform: .iOS, version: "27.1", build: "24A94401", sizeBytes: 15_940_000_000, lastUsed: "2026-11-04T10:00:00Z"),
                   SimRuntimeRecord(platform: .watchOS, version: "27.0", build: "24R100", sizeBytes: 4_120_000_000)])

    static func settings5Walk(_ app: ShellAppModel, prefix: String) async {
        func dump(_ index: Int, _ name: String) {
            // Neither window has the in-window menu bar.
            let top: CGFloat = 0
            let size = OpenViewsAutomation.windowSize(index)
            var lines = [String(format: "window %.1f %.1f", size?.points.width ?? 0, (size?.points.height ?? 0) - top)]
            func box(_ f: CGRect) -> String { String(format: "%.1f %.1f %.1f %.1f", f.minX, f.minY - top, f.width, f.height) }
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
            say("settings5 \(name): " + OpenViewsAutomation.screenshot(index, to: "\(prefix)-\(name).png"))
        }
        ComponentsSettingsPane.inventoryOverride = settings5Inventory
        ComponentsSettingsPane.nowOverride = ComponentsPage.date("2026-11-07T10:00:00Z")
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        for _ in 0..<20 where OpenViewsAutomation.windowCount < 2 { await pause(0.2) }
        guard OpenViewsAutomation.windowCount >= 2 else { say("settings5: the Settings window did not open"); return }
        let settings = OpenViewsAutomation.windowCount - 1
        let m = ShellSettingsModel.shared
        for pane in [ShellSettingsPane.general, .appearance, .editing, .components] {
            m.select(pane)
            await shot("settings-\(pane.rawValue)", window: settings)
        }
        m.showHostPage()
        await shot("settings-simulators", window: settings)
        say("settings5 host page fields: \(SimulatorHostPage.Field.allCases.filter { frame("settings host \($0.rawValue)") != nil || OpenViewsAutomation.identifiedFrames(settings)["settings host \($0.rawValue)"] != nil }.count)")
        m.hideHostPage()
        // The wizard's host step, in its own window.
        var choices = RuntimeSetupChoices.load(app.runtimeDefaults)
        choices.useHost = true
        choices.save(app.runtimeDefaults)
        let before = OpenViewsAutomation.windowCount
        app.showRuntimeSetup(step: .host)
        for _ in 0..<20 where OpenViewsAutomation.windowCount <= before { await pause(0.2) }
        say("settings5 wizard windows \(before) -> \(OpenViewsAutomation.windowCount)")
        await shot("runtime-host", window: OpenViewsAutomation.windowCount - 1, settle: 1.2)
        app.closeRuntimeSetup()
        await pause(0.5)
        say("settings5 wizard closed: windows \(OpenViewsAutomation.windowCount)")
    }
    #endif
}
