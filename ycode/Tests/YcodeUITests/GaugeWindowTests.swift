#if os(macOS)
import AppKit
import Foundation
import Testing
import YcodeProfiler
@testable import YcodeUI

/// Gauge's window (specs/ide/profiler.md §6) on a synthetic trace, and the
/// remote profile commands (§5). No network, no simulator.
@MainActor
@Suite(.serialized) struct GaugeWindowTests {
    /// main → work (8 samples, lines 10/11) and main → helper (2), on two
    /// threads, with a signpost, presents and a hang.
    static func trace(sourceFile: String) -> GaugeTrace {
        var b = GaugeTraceBuilder(recording: .init(target: "ycode-simulator", recorder: "test", command: "dev.ycode.Demo",
                                                    device: "iPhone 18 Pro", durationNs: 20_000_000, sampleIntervalNs: 1_000_000,
                                                    hangThresholdNs: 4_000_000))
        b.addImage(.init(id: 0, name: "Demo", path: "/apps/Demo.app/Demo", uuid: "U", kind: .app, base: 0x1000, size: 0x1000,
                         symbols: [.init(start: 0, end: 0x100, name: "main"), .init(start: 0x100, end: 0x200, name: "work"),
                                   .init(start: 0x200, end: 0x300, name: "helper")],
                         files: [sourceFile], lines: [.init(offset: 0x110, file: 0, line: 10), .init(offset: 0x120, file: 0, line: 11)]))
        b.addImage(.init(id: 0, name: "libsystem.dylib", kind: .system, base: 0x9000, size: 0x100, symbols: [.init(start: 0, end: 0x100, name: "start")]))
        b.update {
            $0.processes = [.init(pid: 5, name: "Demo")]
            $0.threads = [.init(id: 1, pid: 5, name: "Main Thread", isMain: true, kind: "main"), .init(id: 2, pid: 5, name: "Thread 0x2")]
            $0.signposts = [.init(name: "Crunch", begin: 1_000_000, end: 9_000_000, message: "round 1")]
            $0.presents = [0, 16_000_000]
        }
        let start = GaugeTrace.Frame(image: 1, offset: 0x10), main = GaugeTrace.Frame(image: 0, offset: 0x10)
        for i in 0..<10 {
            let leaf = i < 6 ? GaugeTrace.Frame(image: 0, offset: 0x110) : i < 8 ? GaugeTrace.Frame(image: 0, offset: 0x120) : GaugeTrace.Frame(image: 0, offset: 0x210)
            b.addSample(time: UInt64(i) * 1_000_000, thread: 1, state: .user, frames: [start, main, leaf])
        }
        b.addSample(time: 10_000_000, thread: 2, state: .kernel, frames: [start])
        var t = b.finish()
        t.hangs = GaugeTimeline.hangs(t)
        return t
    }

    @Test func showsTheTraceAndFollowsTheSelection() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gauge-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("work.c")
        try (1...20).map { "line \($0);" }.joined(separator: "\n").write(to: source, atomically: true, encoding: .utf8)
        let url = dir.appendingPathComponent("t.gaugetrace")
        try GaugeTraceCodec.write(Self.trace(sourceFile: source.path), to: url)

        let w = GaugeWindowController(title: "t")
        w.load(url: url)
        defer { w.close() }
        #expect(w.model.phase == .loaded && w.model.trace?.samples.count == 11)
        #expect(w.targetLabel.stringValue == "Demo on iPhone 18 Pro")
        // The heaviest path is open: start > main > work.
        #expect(w.outline.numberOfRows >= 4)
        let rowNames = (0..<w.outline.numberOfRows).compactMap { (w.outline.item(atRow: $0) as? CallTreeNode)?.name }
        #expect(Array(rowNames.prefix(3)) == ["start", "main", "work"])
        // Select work: the flame graph and the source follow.
        let work = try #require(w.model.tree?.root.find("work"))
        w.model.selectedPath = work.path
        #expect(w.outline.selectedRow == w.outline.row(forItem: work))
        #expect(w.model.selectedStacks.count == 2)
        w.model.content = .source
        #expect(w.sourceView.string.contains("work — \(source.path)"))
        #expect(w.sourceView.string.contains("      6       6    10  line 10;"))
        // A time range and Invert.
        w.timeline.select(0..<5_000_000)
        #expect(w.model.tree?.sampleCount == 5)
        w.model.options.invert = true
        #expect(w.model.tree?.root.children.first?.name == "work")
        w.model.range = nil
        w.model.content = .flameGraph
        #expect(w.model.flame?.total == 11)
        // A hang of the main thread (10 busy samples ≥ 4 ms).
        #expect(w.model.hangs.count == 1)
        // A snapshot renders without the window on screen.
        let png = dir.appendingPathComponent("w.png")
        #expect(w.writeSnapshot(to: png))
        #expect(((try? Data(contentsOf: png))?.count ?? 0) > 1000)
    }

    @Test func recordingStateAndFailure() {
        _ = NSApplication.shared
        let w = GaugeWindowController()
        defer { w.close() }
        var stopped = false
        w.onStop = { stopped = true }
        w.beginRecording(target: "Demo on iPhone 18 Pro (Ycode)", rate: 1000)
        #expect(w.recordingView.stringValue.hasPrefix("Recording Demo on iPhone 18 Pro (Ycode)"))
        #expect(w.recordButton.isEnabled)
        w.recordButton.performClick(nil)
        #expect(stopped)
        w.fail("the build failed")
        #expect(w.recordingView.stringValue == "No trace: the build failed")
    }
}
#endif
