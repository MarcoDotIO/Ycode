import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_R4EDITOR=<prefix>: council round 4's editor rows on the Linux
// IDE (`fidelity-council.md` rows 83–88; run with OV_COLOR_SCHEME=dark for
// the dark theme). Open a workspace whose files include `Bands.swift` and
// `Greeting.swift`; writes <prefix>-r4-<file>.png and prints one line each.
extension ShellDriver {
    #if os(Linux)
    static func editorR4Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("r4: no workspace"); return }
        for name in ["Bands.swift", "Greeting.swift"] {
            guard let path = w.root.allFiles.compactMap(\.path).first(where: { $0.hasSuffix("/" + name) }) else {
                say("r4: no \(name)")
                continue
            }
            if let ids = w.root.idPath(to: path) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.open(path)
            if let e = frame("editor") { await OpenViewsAutomation.click(at: CGPoint(x: e.midX, y: e.minY + 40)) }
            await pause(0.8)
            say("r4 \(name): document=\(w.document?.path ?? "-") "
                + OpenViewsAutomation.screenshot(to: "\(prefix)-r4-\(name.replacingOccurrences(of: ".swift", with: "")).png"))
        }
    }
    #endif
}
