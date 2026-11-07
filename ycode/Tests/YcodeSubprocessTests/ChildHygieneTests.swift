import Foundation
import Testing
@testable import YcodeSubprocess
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What a child gets from Ycode, and how it is stopped: no descriptor of
/// another run, no blocked signal, and a stop reaches what it started.
@Suite struct ChildHygieneTests {
    /// A process started without closing anything, as a child that another
    /// thread spawns at the same moment can be: it inherits every
    /// descriptor that is not close-on-exec.
    static func spawnInheritingEverything(_ path: String, _ args: [String]) -> pid_t {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let env: [UnsafeMutablePointer<CChar>?] = [nil]
        let rc = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in posix_spawn(&pid, path, nil, nil, a.baseAddress!, e.baseAddress!) } }
        return rc == 0 ? pid : -1
    }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Reads `stream` in a task until the child prints "ready", then cancels
    /// the task, as the stop button does.
    static func stopWhenReady(_ stream: AsyncThrowingStream<String, Error>) async throws {
        let (ready, readyIn) = AsyncStream<Void>.makeStream()
        let task = Task {
            for try await l in stream where l == "ready" { readyIn.yield() }
        }
        for await _ in ready { break }
        task.cancel()
        _ = await task.result
    }

    @Test func pipesAreCloseOnExec() throws {
        #expect(try SpawnPipe(childReads: true).isCloseOnExec)
        #expect(try SpawnPipe(childReads: false).isCloseOnExec)
    }

    /// The hang: an unrelated child that inherited the write end of a run's
    /// standard input kept `cat` waiting for end of file until it exited.
    @Test func anUnrelatedChildDoesNotHoldTheInputOpen() async throws {
        let input = Data(repeating: UInt8(ascii: "x"), count: 1 << 20)
        let started = Date()
        // The writer blocks on the full pipe for the first second, so the
        // input's write end is open while the unrelated child starts.
        let stream = StreamingSubprocess.lines(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 1; cat > /dev/null; echo done"], input: input)
        try await Task.sleep(nanoseconds: 200_000_000)
        let other = Self.spawnInheritingEverything("/bin/sleep", ["8"])
        #expect(other > 0)
        defer { if other > 0 { kill(other, SIGKILL); waitpid(other, nil, 0) } }
        var lines: [String] = []
        for try await l in stream { lines.append(l) }
        #expect(lines == ["done"])
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// Dispatch's worker threads block SIGINT and SIGTERM; a child started
    /// there must still get the stop button's SIGINT.
    @Test func aChildStartedOnADispatchThreadCanBeInterrupted() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("interrupted")
        let script = "trap 'echo yes > \"\(marker.path)\"; exit 130' INT; echo ready; while :; do sleep 0.1; done"
        let stream: AsyncThrowingStream<String, Error> = await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning: StreamingSubprocess.lines(URL(fileURLWithPath: "/bin/sh"), ["-c", script])) }
        }
        try await Self.stopWhenReady(stream)
        for _ in 0..<15 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    /// SIGINT goes to the child's process group, as Control-C in a terminal
    /// does: a shell running a long foreground command reacts at once.
    @Test func theStopReachesWhatTheChildStarted() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("interrupted")
        // "ready" comes from the foreground command once it runs: a shell
        // that gets SIGINT before it has started one runs the trap only after it.
        let script = "trap 'echo yes > \"\(marker.path)\"; exit 130' INT; /bin/sh -c 'echo ready; exec sleep 30'"
        let started = Date()
        try await Self.stopWhenReady(StreamingSubprocess.lines(URL(fileURLWithPath: "/bin/sh"), ["-c", script]))
        for _ in 0..<15 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// A stop asked for before the child has started is not lost.
    @Test func aStopBeforeTheStartIsCarriedOut() throws {
        let state = StreamingSubprocess.RunState()
        state.cancel()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.runWithSignalsUnblocked()
        let started = Date()
        state.started(p.processIdentifier)
        p.waitUntilExit()
        state.finished()
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGINT)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(state.wasCancelled)
    }

    /// The parent's ends see end of file when the child exits: the child
    /// ends are closed here once it has started, and also when it cannot.
    @Test func runClosesTheChildEnds() throws {
        let out = try SpawnPipe(childReads: false), inp = try SpawnPipe(childReads: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "cat; echo done"]
        p.standardInput = inp.childEnd
        p.standardOutput = out.childEnd
        try p.runWithSignalsUnblocked(closingChildEndsOf: out, inp)
        inp.parentEnd.writeQuietly(Data("in\n".utf8))
        try inp.parentEnd.close()
        #expect(String(decoding: out.parentEnd.readDataToEndOfFile(), as: UTF8.self) == "in\ndone\n")
        p.waitUntilExit()

        let missing = try SpawnPipe(childReads: false)
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/nonexistent/tool")
        q.standardOutput = missing.childEnd
        #expect(throws: (any Error).self) { try q.runWithSignalsUnblocked(closingChildEndsOf: missing, nil) }
        #expect(missing.parentEnd.readDataToEndOfFile().isEmpty)
    }

    /// Ending the iteration early (a `break`) also stops the child, once
    /// nothing holds the stream any more: dropping the last iterator of an
    /// `AsyncThrowingStream` ends it as cancelled.
    @Test func breakingOutOfTheLoopInterruptsTheChild() async throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("interrupted")
        let script = "trap 'echo yes > \"\(marker.path)\"; exit 130' INT; echo ready; while :; do sleep 0.1; done"
        let started = Date()
        for try await l in StreamingSubprocess.lines(URL(fileURLWithPath: "/bin/sh"), ["-c", script]) where l == "ready" { break }
        for _ in 0..<30 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(Date().timeIntervalSince(started) < 4)
    }

    /// A child that exits without reading its input does not take this
    /// process down with SIGPIPE.
    @Test func aChildThatIgnoresItsInputIsHarmless() async throws {
        var lines: [String] = []
        let input = Data(repeating: UInt8(ascii: "y"), count: 1 << 20)
        for try await l in StreamingSubprocess.lines(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo gone"], input: input) { lines.append(l) }
        #expect(lines == ["gone"])
        try await Task.sleep(nanoseconds: 300_000_000)
    }
}
