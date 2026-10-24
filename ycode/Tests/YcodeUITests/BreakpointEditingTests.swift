import AppKit
import Foundation
import Testing
import YcodeDebug
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private let loopProgram = """
#include <stdio.h>
int add(int a, int b) {
    int s = a + b;
    return s;
}
int main(void) {
    int total = 0;
    for (int i = 0; i < 5; i++) {
        total = add(i, 1);
    }
    printf("total=%d\\n", total);
    return 0;
}

"""

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct BreakpointEditingTests {
    @Test func dapMapping() {
        var b = BreakpointStore.Breakpoint(file: "/a.c", line: 3, isEnabled: true)
        #expect(!b.isCustomized && b.dap == SourceBreakpoint(line: 3))
        b.condition = "a == 3"
        b.ignoreCount = 2
        #expect(b.dap == SourceBreakpoint(line: 3, condition: "a == 3", hitCondition: "2"))
        b.actions = [.log("a={a}")]
        #expect(b.dap.logMessage == nil) // logging without continuing still stops
        b.autoContinue = true
        #expect(b.dap.logMessage == "a={a}" && b.isCustomized)
        var s = BreakpointStore()
        s.symbolic = [.init(name: "add", condition: "a == 4"), .init(name: "off", isEnabled: false)]
        #expect(s.effectiveFunctionBreakpoints == [FunctionBreakpoint(name: "add", condition: "a == 4")])
        s.isActive = false
        #expect(s.effectiveFunctionBreakpoints.isEmpty)
    }

    @Test func editorPopoverAndNavigator() throws {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage()
        let main = dir.appendingPathComponent("Sources/Sample/main.swift").path
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        session.breakpoints.click(file: main, line: 8)
        let ed = try #require(wc.editBreakpoint(file: main, line: 8))
        _ = ed.view
        ed.conditionField.stringValue = "i == 2"
        ed.ignoreField.stringValue = "1"
        ed.actionPopUp.selectItem(at: 1)
        ed.actionField.stringValue = "i is {i}"
        ed.continueCheckbox.state = .on
        ed.changed()
        let b = try #require(session.breakpoints.breakpoint(file: main, line: 8))
        #expect(b.condition == "i == 2" && b.ignoreCount == 1 && b.actions == [.log("i is {i}")] && b.autoContinue)
        #expect(wc.editor.gutter.marks.customized == [8])
        let w = NSWindow(contentRect: ed.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = ed.view
        _ = try WindowSnapshotTests().render(ed.view, to: "breakpoint-editor.png")
        // The capture is opaque (no transparent background that viewers
        // show as black) and the "Condition" label is drawn in a dark color.
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: ycodeDir.appendingPathComponent(".build-ide/snapshots/breakpoint-editor.png"))))
        let corner = try #require(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        #expect(corner.alphaComponent == 1 && corner.brightnessComponent > 0.8, "background \(corner)")
        func find(_ v: NSView) -> NSTextField? {
            if let t = v as? NSTextField, t.stringValue == "Condition" { return t }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        let label = try #require(find(ed.view))
        let r = ed.view.convert(label.bounds, from: label)
        let scale = CGFloat(rep.pixelsWide) / ed.view.bounds.width
        var darkest: CGFloat = 1
        for x in stride(from: r.minX, to: r.maxX, by: 1) {
            for y in stride(from: r.minY, to: r.maxY, by: 1) {
                let px = Int(x * scale), py = Int((ed.view.bounds.height - y) * scale)
                if let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) { darkest = min(darkest, c.brightnessComponent) }
            }
        }
        #expect(darkest < 0.4, "label text not visible (darkest \(darkest))")

        wc.addExceptionBreakpoint(swift: false)
        wc.addExceptionBreakpoint(swift: true)
        wc.addSymbolicBreakpoint(name: "greet(times:)")
        #expect(session.breakpoints.exceptionFilters == ["objc_throw", "cpp_throw", "swift_throw"])
        wc.navigator.select(7)
        // Root "<project>  n Breakpoint(s)" (reference-ui-4.md §6.1).
        let root = try #require(wc.navigator.rows(7).first)
        #expect(root.title.hasSuffix("Breakpoints"))
        let rows = root.children
        #expect(rows.map(\.title) == ["Exception Breakpoints", "Symbolic Breakpoints", "main.swift"])
        #expect(rows.count == 3 && rows[2].children.first?.title.hasSuffix("8 [i == 2]") == true)
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "breakpoint-navigator.png")
    }

    /// Conditional, logging (auto-continue) and symbolic breakpoints against
    /// the real lldb-dap.
    @Test func conditionsLogPointsAndSymbolicBreakpoints() async throws {
        guard LLDBDAP.locate() != nil else { return }
        let lock = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { lock.unlock() }
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/bp-edit")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("loop.c")
        try loopProgram.write(to: src, atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"L\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let exe = dir.appendingPathComponent("loop").path
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        cc.arguments = ["clang", "-g", "-O0", "-o", exe, src.path]
        try cc.run()
        cc.waitUntilExit()

        // A launch that cannot start (e.g. waiting for a debugging
        // authorization nobody can answer) is an environment problem: skip.
        guard InterprocessLock.canLaunchUnderDebugger(exe) else {
            print("skipping: cannot launch under the debugger (\(InterprocessLock.lastProblem ?? "launch failed"))")
            return
        }

        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        session.breakpoints.click(file: src.path, line: 3)
        session.breakpoints.edit(file: src.path, line: 3) { $0.condition = "a == 3" }
        session.breakpoints.click(file: src.path, line: 9)
        session.breakpoints.edit(file: src.path, line: 9) { $0.actions = [.log("loop i={i}")]; $0.autoContinue = true }
        session.breakpoints.symbolic = [.init(name: "add", condition: "a == 4")]
        session.breakpoints.exceptionFilters = ["cpp_throw"]

        await session.debug(program: exe)
        // Variables load after the stop event; wait for the stop's own values
        // and for the log lines, which arrive as separate output events.
        #expect(await waitUntil(60) { session.stoppedThread != nil && session.variables.first { $0.name == "a" }?.value == "3" })
        #expect(await waitUntil(30) { session.console.contains("loop i=0") && session.console.contains("loop i=3") })
        #expect(session.debugClient?.exceptionFilters.isEmpty == false)

        await session.continueOrPause()
        #expect(await waitUntil(60) { session.stoppedThread != nil && session.variables.first { $0.name == "a" }?.value == "4" })
        await session.continueOrPause()
        #expect(await waitUntil(60) { session.debugClient == nil })
        #expect(await waitUntil(30) { session.console.contains("loop i=4") && session.console.contains("exit code: 0") })
    }
}
