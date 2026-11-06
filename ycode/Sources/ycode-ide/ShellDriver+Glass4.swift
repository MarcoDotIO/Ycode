import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_GLASS4=<prefix>: council round 3's main-window rows on the
// Linux IDE (`fidelity-council.md` rows 74, 75, 77, 81, 82). Open a
// workspace whose Sources hold `Bands.swift` (a line of full blocks);
// in a git repository for the Repositories view. Writes
// <prefix>-g4-<state>.png and prints one line per step.
extension ShellDriver {
    #if os(Linux)
    static func glass4Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("g4: no workspace"); return }
        func shot(_ name: String) async {
            await pause(0.6)
            say("g4 \(name): document=\(w.document?.path ?? "-") navigator=\(w.navigator) "
                + OpenViewsAutomation.screenshot(to: "\(prefix)-g4-\(name).png"))
        }
        // 74: nothing open, the editor's background alone.
        await shot("74-empty-editor")
        say("g4 74: minimap target \(frame("minimap").map { "\($0)" } ?? "none")")
        // 75, 77: Bands.swift; every block one cell; the minimap's width.
        if let bands = w.root.allFiles.compactMap(\.path).first(where: { $0.hasSuffix("Bands.swift") }) {
            if let ids = w.root.idPath(to: bands) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            await pause(0.3)
            // A click on its row: the outline has the keyboard (81, accent band).
            if let id = w.root.idPath(to: bands)?.last { await clickProjectRow(w, id: id, dx: 10) }
            if w.document?.path != bands { w.open(bands) }
            await shot("75-77-bands-outline-focused")
            say("g4 77: editor \(frame("editor").map { "\($0)" } ?? "-") minimap \(frame("minimap").map { "\($0)" } ?? "-")")
            // 81: a click in the editor takes the keyboard: the band turns grey.
            if let e = frame("editor") { await OpenViewsAutomation.click(at: CGPoint(x: e.midX, y: e.midY)) }
            await shot("81-editor-focused")
        } else {
            say("g4: no Bands.swift under the workspace")
        }
        // 82: the Source Control navigator's Repositories view.
        await click("selector 1")
        await pause(0.8)
        await click("scm mode 1")
        await w.sourceControl.idle()
        await shot("82-repositories")
        say("g4 82: rows \(w.sourceControl.rows.map(\.title)) collapsed \(w.sourceControl.collapsed.sorted())")
    }
    #endif
}
