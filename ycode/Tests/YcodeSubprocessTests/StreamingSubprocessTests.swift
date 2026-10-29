import Foundation
import Testing
import YcodeSubprocess

@Suite struct StreamingSubprocessTests {
    @Test func streamsLinesAndReadsStandardInput() async throws {
        var lines: [String] = []
        for try await l in StreamingSubprocess.lines(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo first; cat; printf 'last'"],
                                                     input: Data("from stdin\nsecond\r\n".utf8)) {
            lines.append(l)
        }
        #expect(lines == ["first", "from stdin", "second", "last"])
    }

    @Test func nonZeroExitThrowsWithStandardError() async throws {
        do {
            for try await _ in StreamingSubprocess.lines(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo 'please log in' >&2; exit 4"]) {}
            Issue.record("expected an error")
        } catch let e as StreamingSubprocess.ExitError {
            #expect(e.status == 4)
            #expect(e.stderrTail.contains("please log in"))
            #expect(!e.wasInterrupted)
        }
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            for try await _ in StreamingSubprocess.lines(URL(fileURLWithPath: "/nonexistent/tool"), []) {}
        }
    }

    /// Stopping the consumer interrupts the child (SIGINT, then SIGTERM).
    @Test func cancellingInterruptsTheChild() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("interrupted")
        // Traps SIGINT, records it and exits; otherwise it would run 30 s.
        let script = "trap 'echo yes > \"\(marker.path)\"; exit 130' INT; echo ready; i=0; while [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done"
        let started = Date()
        let task = Task {
            var n = 0
            for try await _ in StreamingSubprocess.lines(URL(fileURLWithPath: "/bin/sh"), ["-c", script]) { n += 1 }
            return n
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        _ = try? await task.value
        // The trap runs once the current `sleep 0.1` returns.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
