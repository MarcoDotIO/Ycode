import AppKit
import Foundation
import Testing
import YcodeDebug
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

let depthProgram = """
#include <stdio.h>
#include <unistd.h>
int counter = 0;
int add(int a, int b) {
    int s = a + b;
    return s;
}
int main(int argc, char **argv) {
    if (argc > 1) { while (1) { counter++; usleep(1000); } }
    int total = 0;
    for (int i = 0; i < 3; i++) {
        total = add(total, i + 1);
    }
    printf("total=%d\\n", total);
    return 0;
}
"""

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(10))) struct DebuggerDepthTests {
    func build() throws -> (dir: URL, exe: String, source: String)? {
        let dir = ycodeDir.appendingPathComponent(".build-ide/debug-depth")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("depth.c")
        try depthProgram.write(to: src, atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"D\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let exe = dir.appendingPathComponent("depth").path
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        cc.arguments = ["clang", "-g", "-O0", "-o", exe, src.path]
        try cc.run()
        cc.waitUntilExit()
        return cc.terminationStatus == 0 ? (dir, exe, src.path) : nil
    }

    @Test func consoleVariablesWatchpointsDisassembly() async throws {
        guard LLDBDAP.locate() != nil else { return }
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        guard let (dir, exe, source) = try build() else { return }
        guard InterprocessLock.canLaunchUnderDebugger(exe) else {
            print("skipping: cannot launch under the debugger (\(InterprocessLock.lastProblem ?? "launch failed"))")
            return
        }
        _ = NSApplication.shared
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        session.breakpoints.click(file: source, line: 5)
        await session.debug(program: exe)
        #expect(await waitUntil(90) { session.stoppedThread != nil && !session.variables.isEmpty })

        // Console input: expressions and LLDB commands, with history.
        let r = await session.evaluateInConsole("p a + 40")
        #expect(r?.contains("40") == true)
        _ = await session.evaluateInConsole("expr b")
        #expect(session.consoleHistory == ["p a + 40", "expr b"])
        #expect(session.consoleText(.debugger).contains("(lldb) p a + 40"))
        #expect(!session.consoleText(.target).contains("(lldb)"))
        wc.debugArea.consoleField.stringValue = "p 6 * 7"
        await wc.debugArea.submitConsoleLine()
        #expect(session.console.contains("42"))
        #expect(wc.debugArea.historyItem(back: 1) == "p 6 * 7")

        // Edit a value, print its description, watch expressions.
        #expect(await session.setValue("7", of: "a") == "7")
        #expect(session.variables.first { $0.name == "a" }?.value == "7")
        _ = await session.printDescription(of: "b")
        #expect(session.consoleText(.all).contains("(lldb) po b"))
        session.watchExpressions = ["a * 2"]
        #expect(await waitUntil(20) { session.watchValues.first?.value == "14" })
        #expect(wc.debugArea.roots.first?.variable.name == "a * 2")

        // Threads by queue (lldb names the main thread's queue).
        #expect(!session.threads.isEmpty)
        #expect(session.threadsByQueue.contains { $0.queue.contains("main-thread") } || session.threadsByQueue.first?.queue == "Threads")
        wc.navigator.showThreadsByQueue = true
        wc.navigator.setDebugState(threads: session.threads, stoppedThread: session.stoppedThread, frames: session.frames)
        #expect(!wc.navigator.rows(6).isEmpty)

        // Disassembly with the PC marked, then an instruction step.
        session.alwaysShowDisassembly = true
        #expect(await waitUntil(20) { !session.disassembly.isEmpty && session.disassemblyPCIndex != nil })
        let pc = session.disassembly[session.disassemblyPCIndex!].address
        #expect(await waitUntil(10) { wc.editor.text.contains(pc) })
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "debug-disassembly.png")
        await session.step("over")
        #expect(await waitUntil(30) {
            session.disassemblyPCIndex.map { session.disassembly[$0].address } != pc && session.disassemblyPCIndex != nil
        })
        session.alwaysShowDisassembly = false

        // Watchpoint on `s` (written by the line we are stopped at).
        let w = await session.watch("s")
        #expect(w != nil && w?.verified == true, "watchpoint \(String(describing: w))")
        #expect(wc.navigator.breakpointGroups.first { $0.title == "Watchpoints" }?.children.contains { $0.title.hasPrefix("s") && $0.symbol == "eye" } == true)
        await session.continueOrPause()
        let hit = await waitUntil(60) {
            if case .paused(let s) = session.activity { return s.contains("data") || s.contains("watch") }
            return false
        }
        #expect(hit, "activity: \(session.activity) \(session.lastStopDescription ?? "-") w: \(String(describing: w)) console: \(session.console.suffix(600))")
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "debug-console.png")
        session.stop()
        #expect(await waitUntil(30) { session.debugClient == nil })
    }

    @Test func attachToOwnProcess() async throws {
        guard LLDBDAP.locate() != nil else { return }
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        guard let (dir, exe, _) = try build() else { return }
        guard InterprocessLock.canLaunchUnderDebugger(exe) else { print("skipping: cannot debug"); return }
        // Our own looping test program.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["loop"]
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        await session.attach(to: "\(p.processIdentifier)")
        #expect(session.debugClient != nil)
        // Attaching stops the process; pause again if it was resumed.
        if !(await waitUntil(30) { session.stoppedThread != nil }) { await session.continueOrPause() }
        #expect(await waitUntil(30) { session.stoppedThread != nil && !session.threads.isEmpty })
        #expect(await session.evaluateInConsole("p counter") != nil)
        session.stop()
        #expect(await waitUntil(30) { session.debugClient == nil })
    }

    @Test func consoleFilterModel() {
        #expect(ConsoleEntry.Filter.all.includes(.target) && ConsoleEntry.Filter.debugger.includes(.input))
        #expect(!ConsoleEntry.Filter.debugger.includes(.target) && !ConsoleEntry.Filter.target.includes(.debugger))
        let t = DebugThread(id: 1, name: "Thread 1 name = worker queue = com.example.q")
        #expect(t.queue == "com.example.q")
        #expect(WorkspaceSession.sameAddress("0x0000000100003F40", "0x100003f40"))
    }
}
