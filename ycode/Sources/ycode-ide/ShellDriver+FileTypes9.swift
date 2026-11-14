import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_FILETYPES9=<prefix>: council round 9 group C's states
// (`fidelity-council.md` rows 228–230) on the workspace given as the path,
// a project holding NOTES.md, palette.json and a Swift file, with the real
// language server the app starts. After the server is up, each file is
// opened in turn; for each the walk prints the toolbar's issue counts, the
// editor's line issues, the server's documents with live issues, and the
// File inspector's Type and sections, and writes <prefix>-<state>.png
// (dark; NOTES.md also in light).
extension ShellDriver {
    #if os(Linux)
    static func fileTypes9Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("filetypes9: no workspace"); return }
        Preferences.shared.appearance = .dark
        var waited = 0.0
        while w.session.language == nil || w.session.isPreparingEditorServices, waited < 60 {
            await pause(0.5)
            waited += 0.5
        }
        say("filetypes9 language service \(w.session.language == nil ? "absent" : "running") after \(waited) s")
        let files = w.root.allFiles.compactMap(\.path)
        func path(_ name: String) -> String? { files.first { $0.hasSuffix("/" + name) } }
        func report(_ state: String) {
            let type = w.fileInspector.first?.rows.first { $0.key == "Type" }.map { "\($0.value)" } ?? "-"
            let live = w.session.language?.liveIssues.filter { !$0.value.isEmpty }.keys.map { ($0 as NSString).lastPathComponent }.sorted() ?? []
            say("filetypes9 \(state): errors \(w.issueCounts.errors) warnings \(w.issueCounts.warnings) "
                + "editor line issues \(w.editorIssues.keys.sorted()) live issues in \(live) "
                + "type \(type) sections \(w.fileInspector.map(\.title))")
        }
        for (name, state) in [("NOTES.md", "notes"), ("palette.json", "palette"), ("Long.swift", "swift")] {
            guard let p = path(name) else { say("filetypes9: no \(name)"); continue }
            if let ids = w.root.idPath(to: p) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.selection = w.root.idPath(to: p)?.last
            // Time for a server's answer (sourcekit-lsp answered NOTES.md
            // within about a second before row 228's fix).
            await pause(6)
            report(state)
            say("filetypes9 \(state): " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state)-dark.png"))
            if state == "notes" {
                Preferences.shared.appearance = .light
                await pause(0.8)
                say("filetypes9 \(state) light: " + OpenViewsAutomation.screenshot(0, to: "\(prefix)-\(state)-light.png"))
                Preferences.shared.appearance = .dark
                await pause(0.5)
            }
        }
    }
    #endif
}
