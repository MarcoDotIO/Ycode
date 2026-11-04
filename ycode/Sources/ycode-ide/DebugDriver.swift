import Foundation
import SwiftUI
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_DEBUG=<prefix>  the debugger's end-to-end walk (B2-DEBUG) with
//                           the pointer and keys: open YCODE_IDE_DEBUG_FILE
//                           (default main.swift), click the gutter at line
//                           YCODE_IDE_DEBUG_LINE, show the Breakpoint
//                           navigator, Product ▸ Run, wait for the stop,
//                           expand the first aggregate in the variables view,
//                           evaluate YCODE_IDE_DEBUG_EXPR at the (lldb)
//                           prompt, Step Over, Continue to the exit; writes
//                           <prefix>-<state>.png after each.

#if os(Linux)
@MainActor
enum DebugDriver {
    static let env = ProcessInfo.processInfo.environment
    static func say(_ s: String) { ShellDriver.say(s) }

    static func state(_ w: WorkspaceShellModel) -> String {
        let d = w.debug
        return "debug: debugging=\(d.isDebugging) paused=\(d.isPaused) navigator=\(w.navigator.rawValue) "
            + "breakpoints=\(d.breakpoints.all.map { "\(($0.file as NSString).lastPathComponent):\($0.line)\($0.isEnabled ? "" : "-off")" }) "
            + "pc=\(w.document.map { d.marks(for: $0.path).pcLine.map(String.init) ?? "-" } ?? "-") "
            + "annotation=\"\(w.document.flatMap { d.marks(for: $0.path).annotation } ?? "")\" bar=\"\(d.barPath)\" "
            + "threads=\(d.threads.map(\.name)) frames=\(d.frames.map(\.name)) variables=\(d.variableRows.map { ($0.badge.map { $0 + " " } ?? "") + $0.text }) "
            + "activity=\"\(w.activityText)\""
    }

    static func shot(_ prefix: String, _ name: String, _ w: WorkspaceShellModel) async {
        await ShellDriver.pause(0.8)
        say("debug \(name): \(state(w)) " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(name).png"))
    }

    static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        var t = 0.0
        while !condition() && t < seconds {
            await ShellDriver.pause(0.25)
            t += 0.25
        }
        return condition()
    }

    static func run(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("debug: no workspace"); return }
        let name = env["YCODE_IDE_DEBUG_FILE"] ?? "main.swift"
        let line = Int(env["YCODE_IDE_DEBUG_LINE"] ?? "") ?? 1
        guard let file = w.root.allFiles.first(where: { $0.name == name }), let path = file.path else {
            say("debug: no file \(name)")
            return
        }
        w.isInspectorShown = false
        // A clean start: an earlier run's breakpoints are stored with the package.
        w.perform(.deleteAllBreakpoints)
        w.open(path)
        await ShellDriver.pause(0.8)
        await shot(prefix, "opened", w)

        // A breakpoint: a click on the line number.
        guard let source = ShellDriver.frame("source"), let editor = w.editor else { say("debug: no source editor"); return }
        let c = SourceEditorController.of(editor)
        let y = source.minY + SourceEditorController.topInset + CGFloat(line - 1) * c.lineHeight - c.top + c.lineHeight / 2
        await OpenViewsAutomation.click(at: CGPoint(x: source.minX + 16, y: y))
        await ShellDriver.pause(0.5)
        await shot(prefix, "breakpoint", w)
        await ShellDriver.click("selector 6")
        await shot(prefix, "debug-navigator-empty", w)
        await ShellDriver.click("selector 7")
        await shot(prefix, "breakpoint-navigator", w)
        // The debug bar's toggle deactivates them, and activates them again.
        await ShellDriver.click("bar breakpoints")
        await shot(prefix, "breakpoints-deactivated", w)
        await ShellDriver.click("bar breakpoints")

        // Product ▸ Run: build, launch under lldb-dap, stop at the line.
        await ShellDriver.clickText("Product", inPopup: false)
        await ShellDriver.clickText("Run", inPopup: true)
        let stopped = await wait(300) { w.debug.isPaused && !w.debug.variables.isEmpty }
        say("debug: stopped=\(stopped)")
        await ShellDriver.pause(1.0)
        await shot(prefix, "stopped", w)

        // The variables view: open the first aggregate.
        let aggregate = w.debug.variableRows.last(where: \.isExpandable)
        if let row = aggregate, let f = ShellDriver.frame("disclosure \(row.id)") {
            await OpenViewsAutomation.click(at: CGPoint(x: f.midX, y: f.midY))
            _ = await wait(10) { w.debug.variableRows.contains { $0.level > 0 } }
        } else {
            say("debug: no aggregate to expand")
        }
        await shot(prefix, "variables", w)

        // The (lldb) prompt.
        if let field = ShellDriver.frame("console input") {
            await OpenViewsAutomation.click(at: CGPoint(x: field.midX, y: field.midY))
            await ShellDriver.pause(0.3)
            OpenViewsAutomation.type(env["YCODE_IDE_DEBUG_EXPR"] ?? "bt")
            await ShellDriver.pause(0.2)
            OpenViewsAutomation.press(.return)
            _ = await wait(15) { w.console.contains("(lldb) ") && !w.console.hasSuffix("(lldb) \(env["YCODE_IDE_DEBUG_EXPR"] ?? "bt")\n") }
        } else {
            say("debug: no console input")
        }
        await shot(prefix, "console", w)

        // Step Over with the debug bar's button.
        let stops = w.session.stopCount
        await ShellDriver.click("bar step over")
        let stepped = await wait(30) { w.session.stopCount > stops && w.debug.isPaused && !w.debug.variables.isEmpty }
        say("debug: stepped=\(stepped)")
        await shot(prefix, "stepped", w)

        // F6 (Step Over from the keyboard).
        let before = w.session.stopCount
        OpenViewsAutomation.press(.function(6))
        let keyed = await wait(30) { w.session.stopCount > before && w.debug.isPaused }
        say("debug: F6 stepped=\(keyed)")
        await shot(prefix, "stepped-f6", w)

        // The Debug menu, open while paused.
        await ShellDriver.clickText("Debug", inPopup: false)
        await shot(prefix, "debug-menu", w)
        OpenViewsAutomation.press(.escape)
        await ShellDriver.pause(0.3)

        // Continue to the exit.
        await ShellDriver.click("bar continue")
        let exited = await wait(30) { !w.debug.isDebugging && !w.isBusy }
        say("debug: exited=\(exited) console tail: \(w.console.split(separator: "\n").suffix(4).joined(separator: " | "))")
        await shot(prefix, "exited", w)
        OpenViewsAutomation.terminate()
    }
}
#endif
