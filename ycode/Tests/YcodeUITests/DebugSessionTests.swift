import AppKit
import Foundation
import Testing
import YcodeDebug
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Polls `condition` on the main actor until true or `seconds` of waiting
/// pass; false when the test is cancelled (e.g. its time limit).
///
/// The budget counts only time the main actor was free to make progress:
/// each 50 ms poll adds its real duration, but at most 0.25 s. Debugger
/// events, language-server replies and build output are all handled on
/// the main actor, so while another suite holds it (a synchronous build,
/// git or simctl call in a test running in parallel) nothing the condition
/// waits for can happen. A wall-clock deadline expired during such stalls
/// (20 s and more under load) and failed waits whose events were already
/// queued.
@MainActor
func waitUntil(_ seconds: Double = 60, _ condition: () -> Bool) async -> Bool {
    ProcessAudit.arm()
    var waited = 0.0
    while !condition() {
        if waited > seconds || Task.isCancelled { return false }
        let start = Date()
        try? await Task.sleep(nanoseconds: 50_000_000)
        waited += min(Date().timeIntervalSince(start), 0.25)
    }
    return true
}

/// Ends a test's debug session and waits until it is over: `disconnect`
/// (the debuggee is terminated), and if the adapter does not answer, the
/// adapter process is stopped. Tests call it on every exit path, so a
/// failed or timed-out expectation never leaves lldb-dap running.
@MainActor
func endDebugSession(_ session: WorkspaceSession) async {
    guard let client = session.debugClient else { return }
    try? await client.disconnect(terminate: true, timeout: .seconds(5))
    client.close()
    _ = await waitUntil(15) { session.debugClient == nil }
}

private let program = """
#include <stdio.h>

struct Pair { int a; int b; };

int add(int a, int b) {
    int s = a + b;
    return s;
}

int main(void) {
    struct Pair p = { 2, 3 };
    int y = add(p.a, p.b);
    printf("sum=%d\\n", y);
    return 0;
}

"""

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct DebugSessionEndToEndTests {
    /// Builds the tiny C program with debug info, next to a Package.swift so
    /// the folder opens as a workspace.
    func debuggee() throws -> (exe: String, source: String)? {
        let dir = ycodeDir.appendingPathComponent(".build-ide/session-e2e")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("prog.c")
        try program.write(to: src, atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"E2E\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let exe = dir.appendingPathComponent("prog").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["clang", "-g", "-O0", "-o", exe, src.path]
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? (exe, src.path) : nil
    }

    /// Breakpoint → stopped state in the window (variables, Debug
    /// navigator, lazy children) → step → continue to exit.
    @Test func sessionDrivesTheWindow() async throws {
        guard LLDBDAP.locate() != nil else { return }
        let lock = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { lock.unlock() }
        guard let (exe, source) = try debuggee() else { return }

        // A launch that cannot start (e.g. waiting for a debugging
        // authorization nobody can answer) is an environment problem: skip.
        // The probe runs off the main actor, which other suites share.
        guard await Task.detached(operation: { InterprocessLock.canLaunchUnderDebugger(exe) }).value else {
            print("skipping: cannot launch under the debugger (\(InterprocessLock.lastProblem ?? "launch failed"))")
            return
        }
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: source).deletingLastPathComponent()
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        session.breakpoints.click(file: source, line: 6)
        do {
            try await drive(session, wc, exe: exe, source: source)
        } catch {
            await endDebugSession(session)
            throw error
        }
        await endDebugSession(session)
    }

    func drive(_ session: WorkspaceSession, _ wc: WorkspaceWindowController, exe: String, source: String) async throws {
        await session.debug(program: exe)
        #expect(await waitUntil(110) { session.stoppedThread != nil && !session.variables.isEmpty })
        #expect(session.currentLocation?.line == 6)
        #expect(Set(session.variables.map(\.name)).isSuperset(of: ["a", "b", "s"]))
        #expect(wc.editor.fileURL?.path == source)
        #expect(wc.editor.gutter.marks.currentLine == 6)

        // Debug navigator: the stopped thread lists add, then main.
        let stopped = try #require(wc.navigator.debugThreadRows.first { !$0.children.isEmpty })
        #expect(stopped.children.first?.title.contains("add") == true)
        let mainFrame = try #require(stopped.children.first { $0.title.contains("main") })

        // Selecting main's frame shows its locals; `p` expands lazily.
        await session.selectFrame(mainFrame.frameID!)
        let p = try #require(wc.debugArea.roots.first { $0.variable.name == "p" })
        #expect(p.isExpandable && p.children == nil)
        let fields = await wc.debugArea.expand(p)
        #expect(fields.map(\.variable.name) == ["a", "b"])
        #expect(fields.map(\.variable.value) == ["2", "3"])

        let window = try #require(wc.window)
        _ = try WindowSnapshotTests().render(window.contentView!.superview!, to: "debug-session.png")

        await session.selectFrame(stopped.children[0].frameID!)
        await session.step("over")
        #expect(await waitUntil { session.stoppedThread != nil && session.currentLocation?.line == 7 })
        // Frames arrive before variables: wait for the new values too.
        #expect(await waitUntil { session.variables.first { $0.name == "s" }?.value == "5" })

        await session.continueOrPause()
        #expect(await waitUntil { session.debugClient == nil })
        #expect(session.console.contains("exit code: 0"))
    }
}
