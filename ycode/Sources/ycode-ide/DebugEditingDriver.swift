import Foundation
import SwiftUI
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_DEBUG2=<prefix>  the debugger's editing walk (B2-DEBUG2) with the
//                            pointer and keys, on a package whose
//                            YCODE_IDE_DEBUG_FILE (main.swift) has a loop at
//                            YCODE_IDE_DEBUG_LINE calling `report(_:stats:)`
//                            with `i`, and a `check(_:)` that throws:
//                            1. a conditional breakpoint (double-click in the
//                               gutter, Condition "i == 3"), run, stop;
//                            2. the gutter's context menu ▸ Edit Breakpoint…:
//                               a log action that continues, run to the end;
//                            3. "+" ▸ Symbolic Breakpoint… "report", run, stop;
//                            4. "+" ▸ Swift Error Breakpoint, run, stop;
//                            5. a plain breakpoint: Watch "i", Add Expression…,
//                               Edit Value of stats.total, Continue, View
//                               Memory, Debug Workflow ▸ Always Show Disassembly.
//                            Writes <prefix>-<state>.png after each.

#if os(Linux)
@MainActor
enum DebugEditingDriver {
    static let env = ProcessInfo.processInfo.environment
    static func say(_ s: String) { ShellDriver.say(s) }

    static func shot(_ prefix: String, _ name: String, _ w: WorkspaceShellModel) async {
        await ShellDriver.pause(0.8)
        say("debug2 \(name): \(DebugDriver.state(w)) " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(name).png"))
    }

    static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool { await DebugDriver.wait(seconds, condition) }

    /// The gutter's point for a 1-based line of the open file.
    static func gutterPoint(_ w: WorkspaceShellModel, line: Int) -> CGPoint? {
        guard let source = ShellDriver.frame("source"), let editor = w.editor else { return nil }
        let c = SourceEditorController.of(editor)
        let y = source.minY + SourceEditorController.topInset + CGFloat(line - 1) * c.lineHeight - c.top + c.lineHeight / 2
        return CGPoint(x: source.minX + 16, y: y)
    }

    /// Two clicks 0.15 s apart: a press that comes in the same frame as the
    /// release before it finds the toolkit's press tracking still resolved.
    static func doubleClick(_ p: CGPoint) async {
        await OpenViewsAutomation.click(at: p)
        await ShellDriver.pause(0.15)
        await OpenViewsAutomation.click(at: p)
    }

    static func rightClick(_ p: CGPoint) async {
        OpenViewsAutomation.move(to: p)
        await ShellDriver.pause(0.3)
        await OpenViewsAutomation.click(at: p, button: 3)
        await ShellDriver.pause(0.5)
    }

    static func rightClick(target: String) async {
        guard let f = ShellDriver.frame(target) else { say("debug2: no target \(target)"); return }
        await rightClick(CGPoint(x: f.minX + 40, y: f.midY))
    }

    static func type(into target: String, _ text: String, replacing: Bool = false) async {
        await ShellDriver.click(target)
        if replacing {
            OpenViewsAutomation.press(.character("a"), modifiers: [.control])
            await ShellDriver.pause(0.1)
            OpenViewsAutomation.press(.backspace)
        }
        await ShellDriver.pause(0.2)
        OpenViewsAutomation.type(text)
        await ShellDriver.pause(0.3)
    }

    static func runAndWait(_ w: WorkspaceShellModel, paused: Bool) async -> Bool {
        await ShellDriver.clickText("Product", inPopup: false)
        await ShellDriver.clickText("Run", inPopup: true)
        var ok: Bool
        if paused {
            ok = await wait(300) { w.debug.isPaused && (!w.debug.variables.isEmpty || !w.debug.frames.isEmpty) || (!w.isBusy && !w.debug.isDebugging && w.activityText.contains("Failed")) }
            ok = ok && w.debug.isPaused
        } else {
            _ = await wait(300) { w.debug.isDebugging || w.activityText.contains("Failed") }
            ok = await wait(120) { !w.debug.isDebugging && !w.isBusy }
        }
        if w.activityText.contains("Failed") { say("debug2: build failed: \(w.buildLog.suffix(12).joined(separator: " | "))") }
        return ok
    }

    static func stop(_ w: WorkspaceShellModel) async {
        w.perform(.stop)
        _ = await wait(30) { !w.debug.isDebugging && !w.isBusy }
        await ShellDriver.pause(0.5)
    }

    static func value(_ w: WorkspaceShellModel, _ name: String) -> String? {
        w.debug.variableRows.first { $0.name == name && !$0.isWatch }?.value
    }

    static func run(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("debug2: no workspace"); return }
        let d = w.debug
        let name = env["YCODE_IDE_DEBUG_FILE"] ?? "main.swift"
        let line = Int(env["YCODE_IDE_DEBUG_LINE"] ?? "") ?? 19
        guard let file = w.root.allFiles.first(where: { $0.name == name }), let path = file.path else {
            say("debug2: no file \(name)")
            return
        }
        w.isInspectorShown = false
        w.perform(.deleteAllBreakpoints)
        w.session.watchExpressions = []
        w.open(path)
        await ShellDriver.pause(0.8)

        // 1. A conditional breakpoint: a click adds it, a double-click edits it.
        guard let g = gutterPoint(w, line: line) else { say("debug2: no source editor"); return }
        func state() -> String { d.breakpoints.breakpoint(file: path, line: line).map { $0.isEnabled ? "on" : "off" } ?? "none" }
        await OpenViewsAutomation.click(at: g)
        await ShellDriver.pause(1.0)
        say("debug2: after a click: \(state())")
        if state() == "none" {
            await OpenViewsAutomation.click(at: g)
            await ShellDriver.pause(1.0)
            say("debug2: after another click: \(state())")
        }
        await doubleClick(g)
        await ShellDriver.pause(1.0)
        say("debug2: after a double-click: \(state()) editor=\(d.breakpointEditor != nil)")
        let opened = await wait(5) { d.breakpointEditor != nil }
        if env["YCODE_IDE_DEBUG2_GUTTER_ONLY"] != nil {
            OpenViewsAutomation.terminate()
            return
        }
        if !opened {
            // Keep going through the gutter's context menu.
            await rightClick(g)
            await ShellDriver.clickText("Edit Breakpoint…", inPopup: true)
            _ = await wait(5) { d.breakpointEditor != nil }
        }
        say("debug2: editor opened by double-click=\(opened) enabled=\(d.breakpoints.breakpoint(file: path, line: line)?.isEnabled ?? false)")
        await shot(prefix, "1-editor", w)
        await type(into: "breakpoint condition", "i == 3")
        await shot(prefix, "1-editor-condition", w)
        await ShellDriver.click("breakpoint editor done")
        w.perform(.showBreakpointNavigator)
        await shot(prefix, "1-conditional-breakpoint", w)
        let stopped = await runAndWait(w, paused: true)
        say("debug2: conditional stopped=\(stopped) i=\(value(w, "i") ?? "-") condition=\(d.breakpoints.breakpoint(file: path, line: line)?.condition ?? "")")
        await shot(prefix, "1-conditional-stop", w)
        await stop(w)

        // 2. The gutter's context menu ▸ Edit Breakpoint…: a log message
        // that continues.
        w.perform(.showBreakpointNavigator)
        await rightClick(g)
        await shot(prefix, "2-gutter-menu", w)
        await ShellDriver.clickText("Edit Breakpoint…", inPopup: true)
        _ = await wait(5) { d.breakpointEditor != nil }
        await type(into: "breakpoint condition", "", replacing: true)
        await ShellDriver.click("breakpoint add action")
        await type(into: "breakpoint action text 0", "i is @i@, total @stats.total@ (hit %H)")
        await ShellDriver.click("breakpoint auto continue")
        await shot(prefix, "2-editor-log-action", w)
        await ShellDriver.click("breakpoint editor done")
        w.isDebugAreaShown = true
        w.perform(.clearConsole)
        let ended = await runAndWait(w, paused: false)
        let logged = w.console.split(separator: "\n").filter { $0.hasPrefix("i is ") }
        say("debug2: log run ended=\(ended) logged=\(logged) stops=\(w.session.stopCount)")
        await shot(prefix, "2-log-action-console", w)

        // 3. "+" ▸ Symbolic Breakpoint…: "report" with a condition.
        w.perform(.deleteAllBreakpoints)
        w.perform(.showBreakpointNavigator)
        await ShellDriver.click("navigator add")
        await shot(prefix, "3-plus-menu", w)
        await ShellDriver.clickText("Symbolic Breakpoint…", inPopup: true)
        _ = await wait(5) { d.breakpointEditor?.anchor != nil }
        await ShellDriver.pause(0.3)
        OpenViewsAutomation.type("report")
        await ShellDriver.pause(0.2)
        if d.editorSymbol != "report" { await type(into: "breakpoint symbol", "report", replacing: true) }
        await type(into: "breakpoint condition", "value == 4")
        await shot(prefix, "3-symbolic-editor", w)
        await ShellDriver.click("breakpoint editor done")
        await shot(prefix, "3-symbolic-navigator", w)
        let symbolic = await runAndWait(w, paused: true)
        say("debug2: symbolic stopped=\(symbolic) frame=\(d.frames.first?.name ?? "-") value=\(value(w, "value") ?? "-")")
        await shot(prefix, "3-symbolic-stop", w)
        await stop(w)

        // 4. "+" ▸ Swift Error Breakpoint.
        w.perform(.deleteAllBreakpoints)
        w.perform(.showBreakpointNavigator)
        await ShellDriver.click("navigator add")
        await ShellDriver.clickText("Swift Error Breakpoint", inPopup: true)
        await shot(prefix, "4-swift-error-navigator", w)
        let thrown = await runAndWait(w, paused: true)
        _ = await wait(10) { d.showsDisassembly }
        say("debug2: swift error stopped=\(thrown) activity=\"\(w.activityText)\" frames=\(d.frames.map(\.name).prefix(3)) disassembly=\(d.showsDisassembly)")
        await shot(prefix, "4-swift-error-stop", w)
        if let row = d.debugRows.first(where: { $0.title.hasSuffix("check(_:)") }), let f = ShellDriver.frame("row \(row.title)") {
            await OpenViewsAutomation.click(at: CGPoint(x: f.midX, y: f.midY))
            _ = await wait(5) { !d.showsDisassembly }
            await shot(prefix, "4-swift-error-user-frame", w)
        }
        await stop(w)

        // 5. Watch, Add Expression…, Edit Value, View Memory, disassembly.
        w.perform(.deleteAllBreakpoints)
        await OpenViewsAutomation.click(at: g)
        await ShellDriver.pause(0.4)
        let paused = await runAndWait(w, paused: true)
        _ = await wait(10) { d.variableRows.contains { $0.name == "stats" } }
        say("debug2: watch run paused=\(paused) rows=\(d.variableRows.map(\.text))")
        await rightClick(target: "variable i")
        await shot(prefix, "5-variable-menu", w)
        await ShellDriver.clickText("Watch \"i\"", inPopup: true)
        await rightClick(target: "variable i")
        await ShellDriver.clickText("Add Expression…", inPopup: true)
        _ = await wait(5) { ShellDriver.frame("new expression") != nil }
        await ShellDriver.pause(0.3)
        OpenViewsAutomation.type("stats.total * 10")
        OpenViewsAutomation.press(.return)
        _ = await wait(10) { d.variableRows.filter(\.isWatch).count == 2 }
        await shot(prefix, "5-watch-expressions", w)
        // Edit Value: stats.total (double-click its row).
        if let f = ShellDriver.frame("disclosure stats") {
            await OpenViewsAutomation.click(at: CGPoint(x: f.midX, y: f.midY))
            _ = await wait(10) { d.variableRows.contains { $0.id == "stats/total" } }
        }
        if let f = ShellDriver.frame("variable stats/total") {
            await doubleClick(CGPoint(x: f.minX + 60, y: f.midY))
            _ = await wait(5) { d.editingVariable != nil }
            await ShellDriver.pause(0.3)
            OpenViewsAutomation.press(.character("a"), modifiers: [.control])
            OpenViewsAutomation.press(.backspace)
            OpenViewsAutomation.type("100")
            await shot(prefix, "5-edit-value-field", w)
            OpenViewsAutomation.press(.return)
            _ = await wait(10) { d.variableRows.first { $0.id == "stats/total" }?.value == "100" }
        } else {
            say("debug2: no stats/total row")
        }
        say("debug2: edited total=\(d.variableRows.first { $0.id == "stats/total" }?.value ?? "-") watches=\(d.variableRows.filter(\.isWatch).map(\.text))")
        await shot(prefix, "5-edit-value", w)
        // Copy Value of i (the clipboard read back through the editor).
        await rightClick(target: "variable i")
        await ShellDriver.clickText("Copy Value", inPopup: true)
        let clip = w.editor.flatMap { SourceEditorController.of($0).connection?.clipboardText }
        say("debug2: clipboard after Copy Value=\(clip ?? "nil")")
        // Continue: the watches follow the next stop.
        let stops = w.session.stopCount
        await ShellDriver.click("bar continue")
        _ = await wait(30) { w.session.stopCount > stops && d.isPaused && !d.watchValues.isEmpty }
        await ShellDriver.pause(0.6)
        say("debug2: after continue watches=\(d.variableRows.filter(\.isWatch).map(\.text))")
        await shot(prefix, "5-watch-after-continue", w)
        // View Memory of "stats".
        await rightClick(target: "variable stats")
        await ShellDriver.clickText("View Memory of \"stats\"", inPopup: true)
        _ = await wait(10) { d.memoryBrowser?.block != nil || d.memoryBrowser?.message != nil }
        say("debug2: memory first line=\(d.memoryBrowser?.lines.first.map { "\($0.address) \($0.hex)" } ?? d.memoryBrowser?.message ?? "-")")
        await shot(prefix, "5-memory", w)
        await ShellDriver.click("memory next")
        await ShellDriver.pause(0.6)
        await ShellDriver.click("memory close")
        // Debug ▸ Debug Workflow ▸ Always Show Disassembly.
        await ShellDriver.clickText("Debug", inPopup: false)
        await ShellDriver.clickText("Debug Workflow", inPopup: true)
        await shot(prefix, "5-debug-workflow-menu", w)
        await ShellDriver.clickText("Always Show Disassembly", inPopup: true)
        _ = await wait(10) { d.showsDisassembly }
        say("debug2: always disassembly=\(d.showsDisassembly) lines=\(d.disassemblyLines.count)")
        await shot(prefix, "5-disassembly", w)
        w.perform(.toggleAlwaysShowDisassembly)
        await stop(w)
        w.perform(.deleteAllBreakpoints)
        OpenViewsAutomation.terminate()
    }
}
#endif
