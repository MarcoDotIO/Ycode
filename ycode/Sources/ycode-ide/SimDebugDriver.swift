import Foundation
import SwiftUI
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_SIMDEBUG=<prefix>  the simulator debugger's walk (B3-SIMDEBUG,
//                              debug.md "The Linux IDE: apps on the
//                              simulator") with the pointer and keys: open
//                              YCODE_IDE_DEBUG_FILE (default TapCounter.swift),
//                              click the gutter at YCODE_IDE_DEBUG_LINE, pick
//                              the destination YCODE_IDE_SIMDEBUG_DESTINATION
//                              ("<device> (<host>)"), Product ▸ Run, wait
//                              until the app runs under the debugger, tap the
//                              device at YCODE_IDE_SIMDEBUG_DISPLAY (its display
//                              socket, `unix:<path>`), wait for the stop,
//                              expand `self`, evaluate YCODE_IDE_DEBUG_EXPR at
//                              the (lldb) prompt, Step Over, Continue, tap
//                              again, Stop; writes <prefix>-<state>.png after
//                              each.

#if os(Linux)
@MainActor
enum SimDebugDriver {
    static let env = ProcessInfo.processInfo.environment
    static func say(_ s: String) { ShellDriver.say("simdebug: " + s) }

    static func shot(_ prefix: String, _ name: String, _ w: WorkspaceShellModel) async {
        await ShellDriver.pause(0.8)
        say("\(name): \(DebugDriver.state(w)) " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(name).png"))
    }

    static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < seconds { await ShellDriver.pause(0.25) }
        return condition()
    }

    static func tap(_ address: String?) async {
        guard let address else { say("no YCODE_IDE_SIMDEBUG_DISPLAY: no tap"); return }
        do {
            let p = try await Task.detached { try SimDeviceTap.tap(address: address) }.value
            say("tapped the device at \(Int(p.x)),\(Int(p.y))")
        } catch {
            say("tap failed: \(error)")
        }
    }

    /// The walk; the app quits at its end, also when a step fails.
    static func run(_ app: ShellAppModel, prefix: String) async {
        await walk(app, prefix: prefix)
        OpenViewsAutomation.terminate()
    }

    static func walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("no workspace"); return }
        let name = env["YCODE_IDE_DEBUG_FILE"] ?? "TapCounter.swift"
        let line = Int(env["YCODE_IDE_DEBUG_LINE"] ?? "") ?? 72
        let display = env["YCODE_IDE_SIMDEBUG_DISPLAY"]
        guard let file = w.root.allFiles.first(where: { $0.name == name }), let path = file.path else { say("no file \(name)"); return }
        w.isInspectorShown = false
        w.perform(.deleteAllBreakpoints)
        w.open(path)
        await ShellDriver.pause(0.8)

        // The breakpoint: scroll the line into view, then click its number.
        w.jumpToLine("\(line)")
        if let b = w.editor?.buffer { b.setCaret(b.document.lineRange(b.caretLine).lowerBound) }
        await ShellDriver.pause(0.8)
        guard let source = ShellDriver.frame("source"), let editor = w.editor else { say("no source editor"); return }
        let c = SourceEditorController.of(editor)
        let y = source.minY + SourceEditorController.topInset + CGFloat(line - 1) * c.lineHeight - c.top + c.lineHeight / 2
        await OpenViewsAutomation.click(at: CGPoint(x: source.minX + 16, y: y))
        await ShellDriver.pause(0.5)
        guard !w.debug.breakpoints.all.isEmpty else { say("the gutter click made no breakpoint (line \(line), y \(Int(y)))"); return }

        // The destination: the paired host's device.
        let wanted = env["YCODE_IDE_SIMDEBUG_DESTINATION"]
        say("destinations: \(w.destinations.map(\.name))")
        guard let d = w.destinations.first(where: { wanted == nil ? $0.identifier?.hasPrefix(ShellRemoteRun.prefix) == true : $0.name == wanted }) else {
            say("no destination \(wanted ?? "on a simulator host")")
            return
        }
        w.destination = d
        await shot(prefix, "breakpoint", w)

        // Product ▸ Run: build, upload, boot or restore, launch, attach.
        await ShellDriver.clickText("Product", inPopup: false)
        await ShellDriver.clickText("Run", inPopup: true)
        let t0 = Date()
        if await wait(120, { w.activityText.hasPrefix("Launching") }) { await shot(prefix, "launching", w) }
        if await wait(1500, { w.activityText == "Configuring Debugger Actions" }) { await shot(prefix, "configuring", w) }
        let running = await wait(600) { w.session.isDebuggingSimulatorStub && !w.debug.isPaused && w.activityText.hasPrefix("Running") }
        say("running=\(running) after \(Int(Date().timeIntervalSince(t0))) s; console tail: \(w.console.split(separator: "\n").suffix(4).joined(separator: " | "))")
        await shot(prefix, "running", w)
        guard running else { return }

        // A tap on the button: the handler's breakpoint stops the app.
        await tap(display)
        let stopped = await wait(120) { w.debug.isPaused && !w.debug.variables.isEmpty }
        say("stopped=\(stopped)")
        await ShellDriver.pause(1.0)
        await shot(prefix, "stopped", w)

        // The variables view: open `self` (the controller and its tally).
        if let row = w.debug.variableRows.first(where: { $0.name == "self" && $0.isExpandable }), let f = ShellDriver.frame("disclosure \(row.id)") {
            await OpenViewsAutomation.click(at: CGPoint(x: f.midX, y: f.midY))
            _ = await wait(15) { w.debug.variableRows.contains { $0.level > 0 } }
        } else {
            say("no expandable self")
        }
        await shot(prefix, "variables", w)

        // The (lldb) prompt.
        let expr = env["YCODE_IDE_DEBUG_EXPR"] ?? "frame variable sender"
        if let field = ShellDriver.frame("console input") {
            await OpenViewsAutomation.click(at: CGPoint(x: field.midX, y: field.midY))
            await ShellDriver.pause(0.3)
            OpenViewsAutomation.type(expr)
            await ShellDriver.pause(0.2)
            OpenViewsAutomation.press(.return)
            _ = await wait(30) { w.console.contains("(lldb) \(expr)\n") && !w.console.hasSuffix("(lldb) \(expr)\n") }
        } else {
            say("no console input")
        }
        await shot(prefix, "console", w)

        // Step Over with the debug bar's button.
        let stops = w.session.stopCount
        await ShellDriver.click("bar step over")
        let stepped = await wait(60) { w.session.stopCount > stops && w.debug.isPaused && !w.debug.variables.isEmpty }
        say("stepped=\(stepped) step=\(w.debug.variables.first { $0.name == "step" }?.value ?? "-")")
        await shot(prefix, "stepped", w)

        // Continue: the app runs again.
        await ShellDriver.click("bar continue")
        let resumed = await wait(60) { !w.debug.isPaused && w.activityText.hasPrefix("Running") }
        say("continued=\(resumed)")
        await shot(prefix, "continued", w)

        // The next tap stops again.
        await tap(display)
        let again = await wait(120) { w.debug.isPaused && !w.debug.variables.isEmpty }
        say("stopped again=\(again)")
        await shot(prefix, "stopped-again", w)

        // Stop: the debugger detaches, the app runs on on the device.
        await ShellDriver.clickText("Product", inPopup: false)
        await ShellDriver.clickText("Stop", inPopup: true)
        let detached = await wait(60) { !w.session.isDebuggingSimulatorStub && !w.debug.isDebugging }
        say("detached=\(detached); console tail: \(w.console.split(separator: "\n").suffix(3).joined(separator: " | "))")
        await shot(prefix, "detached", w)
    }
}
#endif
