#if os(Linux)
import Foundation
import SwiftUI
import YcodeIDEShell

// YCODE_IDE_IME=1: set the window up for a test with a real input method
// (issue 23; docs/PARITY.md §5.9). It opens YCODE_IDE_SCRIPT_FILE (default:
// the first .swift file under Sources), clicks below the last line so the
// caret is in the source text, and then, while OV_QUIT_AFTER runs, prints a line
// whenever the composition or the text changes:
//
//   ime: marked="<preedit>" cursor=<n> line="<the caret's line>" find="<Find field>"
//
// The keys come from outside, through the input method, as a person's
// would (a test session's compositor). The driver sends none itself:
// synthetic input goes past the input method.

extension ShellDriver {
    static func prepareInputMethodTest(_ app: ShellAppModel) async {
        guard let w = app.workspace else {
            say("ime: no workspace")
            return
        }
        let file = env["YCODE_IDE_SCRIPT_FILE"].flatMap { name in w.root.allFiles.first { $0.name == name } }
            ?? w.root.allFiles.first { $0.name.hasSuffix(".swift") && ($0.path ?? "").contains("/Sources/") }
        guard let file else {
            say("ime: no file to open")
            return
        }
        w.selection = file.id
        for _ in 0..<40 where w.document == nil || frame("source") == nil { await pause(0.1) }
        await pause(0.3)
        guard let text = frame("source") else {
            say("ime: no source text view")
            return
        }
        await OpenViewsAutomation.click(at: CGPoint(x: text.minX + 300, y: text.maxY - 60))
        await pause(0.3)
        say("ime: ready \(file.name) \(state(app))")
        Task { @MainActor in
            var last = ""
            while true {
                let line = inputMethodState(w)
                if line != last {
                    say(line)
                    last = line
                }
                await pause(0.05)
            }
        }
    }

    static func inputMethodState(_ w: WorkspaceShellModel) -> String {
        guard let b = w.editor?.buffer else { return "ime: no editor" }
        let lines = b.text.split(separator: "\n", omittingEmptySubsequences: false)
        let line = lines.indices.contains(b.caretLine) ? String(lines[b.caretLine]) : ""
        return "ime: marked=\"\(b.markedText)\" cursor=\(b.markedCursor) line=\"\(line)\" find=\"\(w.findText)\""
    }
}
#endif
