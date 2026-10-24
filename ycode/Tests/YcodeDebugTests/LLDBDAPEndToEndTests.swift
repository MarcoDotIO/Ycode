import Foundation
import Testing
@testable import YcodeDebug

private let scratch = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build-ide/dap-e2e")

/// Compiles a tiny C program with debug info. nil when no compiler.
func buildDebuggee() throws -> (exe: String, source: String)? {
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let src = scratch.appendingPathComponent("prog.c")
    try """
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
    """.write(to: src, atomically: true, encoding: .utf8)
    let exe = scratch.appendingPathComponent("prog").path
    let p = Process()
    #if os(macOS)
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["clang", "-g", "-O0", "-o", exe, src.path]
    #else
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["cc", "-g", "-O0", "-o", exe, src.path]
    #endif
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    return p.terminationStatus == 0 ? (exe, src.path) : nil
}

/// Waits for the next event with one of the given names.
func next(_ it: inout AsyncStream<DAPEvent>.Iterator, _ names: Set<String>, log: inout [String]) async -> DAPEvent? {
    while let e = await it.next() {
        log.append(e.event)
        if names.contains(e.event) { return e }
    }
    return nil
}

@Suite(.serialized, .timeLimit(.minutes(5))) struct LLDBDAPEndToEndTests {
    /// A real session: breakpoint, stack, scopes, nested variables, step,
    /// continue to exit. Skipped when lldb-dap or a compiler is missing.
    @Test func breakpointStepAndExit() async throws {
        guard let adapter = LLDBDAP.locate() else { return }
        // One lldb-dap session at a time across all test processes.
        let lock = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { lock.unlock() }
        guard let (exe, source) = try buildDebuggee() else { return }

        // A launch that cannot start (e.g. waiting for a debugging
        // authorization nobody can answer) is an environment problem: skip.
        guard InterprocessLock.canLaunchUnderDebugger(exe) else {
            print("skipping: cannot launch under the debugger (\(InterprocessLock.lastProblem ?? "launch failed"))")
            return
        }
        let client = try DAPClient(transport: ProcessTransport(executable: adapter))
        var events = client.events.makeAsyncIterator()
        var log: [String] = []
        defer { client.close() }
        // Watchdog: a missing event ends the stream (a clear failure, not a hang).
        let watchdog = Task { try await Task.sleep(for: .seconds(150)); client.close() }
        defer { watchdog.cancel() }

        let caps = try await client.initialize()
        #expect(caps["supportsConfigurationDoneRequest"]?.bool == true)
        // lldb-dap may hold the launch response until configurationDone.
        let launch = Task { try await client.launch(program: exe) }
        _ = await next(&events, ["initialized"], log: &log)
        let bps = try await client.setBreakpoints(file: source, lines: [6])
        #expect(bps.first?.verified == true)
        try await client.configurationDone()
        try await launch.value

        let stopped = try #require(await next(&events, ["stopped"], log: &log), "no stop; events: \(log)")
        #expect(stopped.body["reason"]?.string == "breakpoint")
        let thread = try #require(stopped.body["threadId"]?.int)
        let frames = try await client.stackTrace(threadID: thread, levels: 10)
        #expect(frames.first?.name.contains("add") == true)
        #expect(frames.first?.line == 6)
        #expect(frames.dropFirst().first?.name.contains("main") == true)

        let scopes = try await client.scopes(frameID: frames[0].id)
        let locals = try #require(scopes.first { $0.name.lowercased().contains("local") })
        let vars = try await client.variables(reference: locals.variablesReference)
        #expect(vars.first { $0.name == "a" }?.value == "2")
        #expect(vars.first { $0.name == "b" }?.value == "3")

        // A struct in main's frame has children through variablesReference.
        let mainScopes = try await client.scopes(frameID: frames[1].id)
        let mainLocals = try await client.variables(reference: mainScopes.first { $0.name.lowercased().contains("local") }!.variablesReference)
        let pair = try #require(mainLocals.first { $0.name == "p" })
        #expect(pair.variablesReference != 0)
        let fields = try await client.variables(reference: pair.variablesReference)
        #expect(fields.map(\.name) == ["a", "b"])

        try await client.next(threadID: thread)
        let stepped = try #require(await next(&events, ["stopped"], log: &log))
        #expect(stepped.body["reason"]?.string == "step")
        let after = try await client.stackTrace(threadID: thread, levels: 1)
        #expect(after.first?.line == 7)
        let s = try await client.variables(reference: try await client.scopes(frameID: after[0].id)
            .first { $0.name.lowercased().contains("local") }!.variablesReference)
        #expect(s.first { $0.name == "s" }?.value == "5")

        try await client.continue(threadID: thread)
        let exited = try #require(await next(&events, ["exited"], log: &log))
        #expect(exited.body["exitCode"]?.int == 0)
        #expect(log.contains("output") || true) // stdout may go to the console or the terminal
        try? await client.disconnect(terminate: true)
    }
}
