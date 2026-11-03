import Foundation
import Testing
@testable import YcodeProfiler

@Suite struct CLITests {
    func run(_ args: [String]) -> (Int32, String, String) {
        var out = "", err = ""
        let status = GaugeCLI.run(args, out: { out += $0 }, err: { err += $0 })
        return (status, out, err)
    }

    func withTrace(_ body: (String, URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gauge-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var t = Synthetic.trace()
        t.images[0].files = [dir.appendingPathComponent("app.c").path]
        try (1...15).map { "source line \($0)" }.joined(separator: "\n").write(to: dir.appendingPathComponent("app.c"), atomically: true, encoding: .utf8)
        let path = dir.appendingPathComponent("t.gaugetrace").path
        try GaugeTraceCodec.write(t, to: URL(fileURLWithPath: path))
        try body(path, dir)
    }

    @Test func summaryTreeFlameAnnotate() throws {
        try withTrace { path, dir in
            var (s, out, _) = run(["summary", path])
            #expect(s == 0 && out.contains("work (App)"))
            (s, out, _) = run(["tree", path, "--invert", "--min-percent", "0"])
            #expect(s == 0 && out.split(separator: "\n")[1].contains("work"))
            (s, out, _) = run(["tree", path, "--charge", "libsys.so", "--threads"])
            #expect(s == 0 && out.contains("Main Thread") && !out.contains("memcpy"))
            (s, out, _) = run(["tree", path, "--range", "0:3", "--thread", "7"])
            #expect(s == 0 && out.contains("   3.0 ms  100.0 %"))
            let svg = dir.appendingPathComponent("f.svg").path
            (s, _, _) = run(["flame", path, "-o", svg])
            #expect(s == 0 && ((try? String(contentsOfFile: svg, encoding: .utf8)) ?? "").contains("<svg"))
            (s, out, _) = run(["annotate", path, "work"])
            #expect(s == 0 && out.contains("work (App): 12 samples"))
            #expect(out.contains("     11  source line 11"))
            let copy = dir.appendingPathComponent("s.gaugetrace").path
            (s, _, _) = run(["symbolicate", path, "--search", dir.path, "-o", copy])
            #expect(s == 0 && FileManager.default.fileExists(atPath: copy))
        }
    }

    @Test func errors() throws {
        #expect(run([]).0 == 2)
        #expect(run(["bogus"]).0 == 2)
        try withTrace { path, _ in
            let (s, _, err) = run(["tree", path, "--range", "5"])
            #expect(s == 1 && err.contains("--range"))
            #expect(run(["annotate", path, "nosuchfunction"]).0 == 1)
        }
        #expect(run(["record", "--linux", "--", "/bin/true"]).2.contains("-o"))
        #expect(run(["summary", "/nonexistent.gaugetrace"]).0 == 1)
    }

    #if os(Linux)
    /// A real recording of a shell loop with the back end the host allows
    /// (perf_event_open, else the LD_PRELOAD agent from this build).
    @Test func recordsALinuxCommand() throws {
        var o = LinuxRecordOptions(command: ["/bin/sh", "-c", "i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done"])
        let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build")
        for config in ["debug", "release"] {
            let p = build.appendingPathComponent(config).appendingPathComponent("libYcodeGaugeAgent.so").path
            if FileManager.default.fileExists(atPath: p) { o.agentPath = p; break }
        }
        o.rate = 500
        let t = try LinuxRecorder.record(o)
        #expect(t.samples.count > 20)
        #expect(t.images.contains { $0.kind == .app })
        #expect(t.recording.durationNs > 0)
    }
    #endif
}
