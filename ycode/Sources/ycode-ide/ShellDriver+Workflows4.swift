import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_WORKFLOWS4=<prefix>: beta 4's workflow fixes on the Linux IDE
// (B4-WORKFLOWS), through the model and the keyboard:
// 1. Activate Console (P-123): a Swift file open with the keyboard in the
//    source, then ⇧⌘C and typed text: the file is unchanged, the console
//    has the keyboard (`workflows4 console`); <prefix>-workflows4-console.png.
// 2. New Branch… (P-132): the sheet "Create new branch in “…”:" with From
//    and To; Create disabled while the name is empty, enabled once typed
//    (`workflows4 branch`); <prefix>-workflows4-branch-empty.png, -named.png.
// The merge sheet's Cancel (P-131) is in the conflict walk
// (ShellDriver+Conflicts.swift, scripts/linux-conflict/run.sh).
extension ShellDriver {
    #if os(Linux)
    static func workflows4Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("workflows4: no workspace"); return }
        func shot(_ name: String) async {
            await pause(0.7)
            say("workflows4 shot \(name) " + OpenViewsAutomation.screenshot(to: "\(prefix)-workflows4-\(name).png"))
        }

        // 1. Activate Console.
        let files = w.root.allFiles.compactMap(\.path).filter { $0.hasSuffix(".swift") }
        if let path = files.first {
            if let ids = w.root.idPath(to: path) { for id in ids.dropLast() { w.setExpanded(id, true) } }
            w.open(path)
            await pause(1.0)
            if let source = frame("source") {
                await OpenViewsAutomation.click(at: CGPoint(x: source.midX, y: source.midY))
                await pause(0.3)
            }
            let before = w.editor?.buffer.text ?? ""
            let shownBefore = w.isDebugAreaShown
            say("workflows4 console before: debugArea=\(shownBefore) textInputActive=\(OpenViewsAutomation.textInput().active)")
            w.perform(.activateConsole)
            await pause(0.1)
            say("workflows4 console +0.1s: textInputActive=\(OpenViewsAutomation.textInput().active)")
            await pause(0.5)
            say("workflows4 console +0.6s: textInputActive=\(OpenViewsAutomation.textInput().active)")
            OpenViewsAutomation.type("p 1 + 2")
            await pause(0.4)
            let after = w.editor?.buffer.text ?? ""
            let input = OpenViewsAutomation.textInput()
            say("workflows4 console: debugArea=\(w.isDebugAreaShown) pane=\(w.debugPane.rawValue) pending=\(w.consoleFocusPending) "
                + "sourceUnchanged=\(before == after) textInputActive=\(input.active) "
                + "output=\(frame("console output").map { "\($0)" } ?? "-")")
            await shot("console")
        } else {
            say("workflows4 console: no Swift file")
        }

        // 2. New Branch….
        let scm = w.sourceControl
        if scm.repository != nil {
            scm.choose(.newBranch(from: nil))
            await pause(0.6)
            let p = scm.prompt
            say("workflows4 branch: title=\"\(p?.title ?? "-")\" info=\(p?.info.map { "\($0.label)=\($0.text)" } ?? []) "
                + "fields=\(p?.fields.map(\.label) ?? []) canConfirm=\(p?.canConfirm ?? false)")
            await shot("branch-empty")
            if frame("scm prompt field 0") != nil { await click("scm prompt field 0") }
            OpenViewsAutomation.type("feature/b4")
            await pause(0.4)
            say("workflows4 branch typed: canConfirm=\(scm.prompt?.canConfirm ?? false)")
            await shot("branch-named")
            OpenViewsAutomation.press(.escape)
            await pause(0.4)
            say("workflows4 branch cancelled: prompt=\(scm.prompt != nil)")
        } else {
            say("workflows4 branch: no repository")
        }
        say("workflows4 done")
    }
    #endif
}
