import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_MOTION4=<prefix>: council round 4's chrome rows on the Linux
// IDE (`fidelity-council.md` rows 110, 111, 113, 114): the navigator's
// bottom bar, the empty inspector and jump bar, the Repositories view's
// "No Selection" and its 16-point control, a group expanded (kept in the
// workspace's user data). Open a workspace in a git repository. Writes
// <prefix>-m4-<state>.png and prints one line per step.
extension ShellDriver {
    #if os(Linux)
    static func motion4Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("m4: no workspace"); return }
        func shot(_ name: String) async {
            await pause(0.6)
            say("m4 \(name): document=\(w.document?.path ?? "-") navigator=\(w.navigator) "
                + OpenViewsAutomation.screenshot(to: "\(prefix)-m4-\(name).png"))
        }
        // 110, 111: nothing open; the bottom bar, the empty jump bar and inspector.
        await shot("110-111-empty")
        say("m4 110: add \(frame("navigator add").map { "\($0)" } ?? "-") filter \(frame("navigator filter").map { "\($0)" } ?? "-")")
        // 113: a group expanded is in the user data for the next launch.
        say("m4 113: expanded \(w.expanded.sorted())")
        // 111, 114: the Repositories view.
        await click("selector 1")
        await pause(0.8)
        await click("scm mode 1")
        await w.sourceControl.idle()
        await shot("111-114-repositories")
        say("m4 114: control \(frame("scm mode 0").map { "\($0)" } ?? "-") \(frame("scm mode 1").map { "\($0)" } ?? "-")")
    }
    #endif
}
