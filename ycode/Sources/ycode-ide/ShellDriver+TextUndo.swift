import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_TEXTUNDO=<prefix>: B5-FIX-UNDO (1.0.0-beta.5 fix round) on the
// Linux IDE: text undo belongs to the file (`specs/ide/source-editor.md`).
// Open a workspace with two text files; YCODE_IDE_TEXTUNDO_FILES names them
// ("A.swift:B.swift", paths relative to the workspace's folder).
//
//   a-edited         A with an edit typed at the end of its first line
//   b-ctrl-z         B shown, the editor focused, Ctrl+Z: B unchanged
//   a-ctrl-z         back to A, Ctrl+Z: A's edit undone
//
// Each state writes <prefix>-<state>.png and prints a "textundo …" line.
extension ShellDriver {
    #if os(Linux)
    static func textUndoWalk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("textundo: no workspace"); return }
        let names = (ProcessInfo.processInfo.environment["YCODE_IDE_TEXTUNDO_FILES"] ?? "A.swift:B.swift").split(separator: ":").map(String.init)
        guard names.count == 2 else { say("textundo: two files needed"); return }
        let folder = w.session.model.kind == .package ? w.session.model.url : w.session.model.url.deletingLastPathComponent()
        let a = folder.appendingPathComponent(names[0]).path, b = folder.appendingPathComponent(names[1]).path
        func shot(_ state: String) async {
            await pause(0.5)
            let path = "\(prefix)-\(state).png"
            say("textundo \(state): " + OpenViewsAutomation.screenshot(to: path))
        }
        func disk(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
        func controlZ() async {
            w.focusEditor()
            await pause(0.3)
            OpenViewsAutomation.press(.character("z"), modifiers: [.control])
            await pause(0.3)
        }
        let aDisk = disk(a), bDisk = disk(b)
        w.open(a)
        await pause(0.4)
        if let buf = w.editor?.buffer {
            buf.setCaret((buf.text as NSString).range(of: "\n").location)
            buf.insertText(" // edited in A")
            buf.breakUndoGroup()
        }
        await shot("a-edited")
        let edited = w.editor?.buffer.text ?? ""
        w.open(b)
        await pause(0.4)
        await controlZ()
        await shot("b-ctrl-z")
        say("textundo b: unchanged=\(w.editor?.buffer.text == bDisk) canUndo=\(w.editor?.buffer.canUndo == true) "
            + "aOnDiskUnchanged=\(disk(a) == aDisk)")
        w.open(a)
        await pause(0.4)
        let back = w.editor?.buffer.text == edited
        await controlZ()
        await shot("a-ctrl-z")
        say("textundo a: editKept=\(back) undone=\(w.editor?.buffer.text == aDisk) canRedo=\(w.editor?.buffer.canRedo == true)")
    }
    #endif
}
