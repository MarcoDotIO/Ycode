import Foundation
import SwiftUI
import YcodeIDEShell

// YCODE_IDE_WINDOWCLOSE9=<prefix>: closing windows and quitting from Welcome
// (no path), as a person does: the windows' close buttons (the window
// system's close request) and File ▸ Quit's shortcut. The process must then
// exit with status 0 (scripts/linux-window-close/run.sh checks it).
// YCODE_IDE_WINDOWCLOSE9_PART chooses:
//
//   close (default)  open Settings and the runtime wizard; close the wizard,
//                    draw Welcome and Settings, close Settings, draw Welcome;
//                    then quit
//   quit             quit from Welcome at once
//   quit-settings    open Settings, then quit with both windows open
//
// Each drawn state writes <prefix>-<state>.png. Closing the wizard's window
// once crashed the next frame of the windows left (B9-SEGV: a closed
// window's Vulkan instance was destroyed under the others' swapchains).
extension ShellDriver {
    #if os(Linux)
    static func windowClose9Walk(_ app: ShellAppModel, prefix: String) async {
        guard app.workspace == nil else {
            say("windowclose9: run without a path (Welcome)")
            OpenViewsAutomation.terminate()
            return
        }
        let part = env["YCODE_IDE_WINDOWCLOSE9_PART"] ?? "close"
        func shot(_ state: String, window index: Int = 0) async {
            await pause(0.6)
            say("windowclose9 \(state): windows \(OpenViewsAutomation.windowCount) "
                + OpenViewsAutomation.screenshot(index, to: "\(prefix)-\(state).png"))
        }
        func waitForWindows(_ n: Int) async {
            for _ in 0..<30 where OpenViewsAutomation.windowCount != n { await pause(0.1) }
        }
        await shot("welcome")
        if part != "quit" {
            OpenViewsAutomation.press(.character(","), modifiers: [.control])
            await waitForWindows(2)
            await shot("settings", window: 1)
        }
        if part == "close" {
            app.showRuntimeSetup(step: .host)
            await waitForWindows(3)
            await shot("wizard", window: 2)
            if let i = OpenViewsAutomation.windowIndex(sceneID: ShellAppModel.runtimeSetupWindowID) {
                OpenViewsAutomation.requestClose(window: i)
            }
            await waitForWindows(2)
            await shot("wizard-closed")
            await shot("wizard-closed-settings", window: 1)
            OpenViewsAutomation.requestClose(window: 1)
            await waitForWindows(1)
            await shot("settings-closed")
        }
        say("windowclose9: quit with \(OpenViewsAutomation.windowCount) windows")
        OpenViewsAutomation.press(.character("q"), modifiers: [.control])
        await pause(5)
        // Only reached when the shortcut did not quit.
        say("windowclose9: still running after the quit shortcut")
        OpenViewsAutomation.terminate()
    }
    #endif
}
