import Foundation
import Testing
@testable import YcodeProfiler

/// A synthetic trace: an app image (main, work, helper, recurse) and a
/// system image (start, memcpy, syscall), two threads, 1 ms samples.
enum Synthetic {
    static let app = 0, sys = 1
    static func f(_ image: Int, _ offset: UInt64) -> GaugeTrace.Frame { .init(image: image, offset: offset) }
    // Function addresses.
    static let main = f(app, 0x10), work = f(app, 0x110), helper = f(app, 0x210), recurse = f(app, 0x310)
    static let start = f(sys, 0x8), memcpy = f(sys, 0x58), syscall = f(sys, 0xA0)

    static func trace() -> GaugeTrace {
        var b = GaugeTraceBuilder(recording: .init(target: "linux", durationNs: 20_000_000, sampleIntervalNs: 1_000_000, hangThresholdNs: 5_000_000))
        b.addImage(.init(id: 0, name: "App", path: "/app/App", uuid: "AAAA", kind: .app, base: 0x1000, size: 0x1000, symbols: [
            .init(start: 0, end: 0x100, name: "main"), .init(start: 0x100, end: 0x200, name: "work"),
            .init(start: 0x200, end: 0x300, name: "helper"), .init(start: 0x300, end: 0x400, name: "recurse"),
        ], files: ["/src/app.c"], lines: [
            .init(offset: 0x110, file: 0, line: 10), .init(offset: 0x118, file: 0, line: 11), .init(offset: 0x210, file: 0, line: 20),
            .init(offset: 0x10, file: 0, line: 3), .init(offset: 0x0F, file: 0, line: 3), .init(offset: 0x117, file: 0, line: 11),
        ]))
        b.addImage(.init(id: 0, name: "libsys.so", path: "/lib/libsys.so", kind: .system, base: 0x9000, size: 0x1000, symbols: [
            .init(start: 0, end: 0x50, name: "start"), .init(start: 0x50, end: 0x90, name: "memcpy"), .init(start: 0x90, end: 0x100, name: "syscall"),
        ]))
        b.update {
            $0.processes = [.init(pid: 7, name: "App")]
            $0.threads = [.init(id: 7, pid: 7, name: "", isMain: true, kind: "main"), .init(id: 8, pid: 7, name: "worker")]
        }
        // Thread 7 (main): 6 × start>main>work (leaf in work at line 10), 2 × start>main>work>memcpy,
        // 1 × start>main>helper, then idle 3, then 4 × start>main>work at line 11.
        var time: UInt64 = 0
        func add(_ thread: UInt64, _ frames: [GaugeTrace.Frame], _ state: GaugeTrace.SampleState = .user, n: Int = 1) {
            for _ in 0..<n {
                b.addSample(time: time, thread: thread, state: state, frames: frames)
                time += 1_000_000
            }
        }
        add(7, [start, main, work], n: 6)
        add(7, [start, main, f(app, 0x118), memcpy], n: 2)
        add(7, [start, main, helper])
        add(7, [start, main, f(app, 0x40), syscall], .idle, n: 3)
        add(7, [start, main, f(app, 0x118)], n: 4)
        // Thread 8: recursion recurse>recurse>recurse>helper (3), kernel time in syscall (2).
        time = 500_000
        add(8, [start, recurse, f(app, 0x320), f(app, 0x330), helper], n: 3)
        add(8, [start, syscall], .kernel, n: 2)
        return b.finish()
    }
}

@Suite struct CallTreeTests {
    let t = Synthetic.trace()

    func child(_ n: CallTreeNode, _ name: String) -> CallTreeNode? { n.children.first { $0.name == name } }

    struct Missing: Error {}
    /// Follows children by name.
    func node(_ n: CallTreeNode, _ names: String...) throws -> CallTreeNode {
        var c = n
        for name in names {
            guard let next = child(c, name) else { throw Missing() }
            c = next
        }
        return c
    }

    @Test func topDownCountsSelfAndTotal() throws {
        let tree = CallTree(trace: t)
        // CPU samples: 6 + 2 + 1 + 4 (main thread) + 3 + 2 (worker) = 18; idle excluded.
        #expect(tree.root.total == 18)
        let start = try #require(child(tree.root, "start"))
        #expect(start.total == 18 && start.selfCount == 0)
        let main = try #require(child(start, "main"))
        #expect(main.total == 13)
        let work = try #require(child(main, "work"))
        #expect(work.total == 12 && work.selfCount == 10)
        #expect(child(work, "memcpy")?.selfCount == 2)
        #expect(child(start, "syscall")?.total == 2)
        // Children by weight.
        #expect(start.children.map(\.name) == ["main", "recurse", "syscall"])
        #expect(tree.milliseconds(work.total) == 12)
        #expect(start.heaviestPath.map(\.name) == ["start", "main", "work", "memcpy"])
    }

    @Test func allStatesAndRangeAndThreadFilters() throws {
        #expect(CallTree(trace: t, filter: .init(allStates: true)).root.total == 21)
        // [0, 8 ms): the first 8 main-thread samples and worker samples at 0.5…7.5 ms (5).
        #expect(CallTree(trace: t, filter: .init(range: 0..<8_000_000)).root.total == 8 + 5)
        #expect(CallTree(trace: t, filter: .init(threads: [8])).root.total == 5)
    }

    @Test func invertedTreeStartsAtLeaves() throws {
        let tree = CallTree(trace: t, options: .init(invert: true))
        #expect(tree.root.children.map(\.name) == ["work", "helper", "memcpy", "syscall"])
        let work = try #require(child(tree.root, "work"))
        #expect(work.selfCount == 10 && work.total == 10)
        #expect(child(work, "main")?.total == 10)
        let helper = try #require(child(tree.root, "helper"))
        #expect(helper.total == 4)
        #expect(child(helper, "main")?.total == 1)
        #expect(child(helper, "recurse")?.total == 3)
    }

    @Test func separateByThreadAddsThreadNodes() throws {
        let tree = CallTree(trace: t, options: .init(separateByThread: true))
        #expect(tree.root.children.count == 2)
        let main = try #require(tree.root.children.first)
        #expect(main.key == .thread(7) && main.total == 13)
        #expect(main.name.hasPrefix("Main Thread"))
        #expect(tree.root.children[1].name.hasPrefix("worker"))
    }

    @Test func hideSystemLibrariesChargesCallers() throws {
        let tree = CallTree(trace: t, options: .init(hideSystemLibraries: true))
        // memcpy's 2 samples go to work; syscall (kernel) samples have no app frame: <system>.
        #expect(tree.root.children.map(\.name) == ["main", "recurse", "<system>"])
        let work = try node(tree.root, "main", "work")
        #expect(work.selfCount == 12 && work.children.isEmpty)
        #expect(child(tree.root, "<system>")?.total == 2)
    }

    @Test func flattenRecursionKeepsTheFirstCall() throws {
        let plain = CallTree(trace: t)
        let deep = try node(plain.root, "start", "recurse")
        #expect(deep.children.first?.name == "recurse")
        let flat = CallTree(trace: t, options: .init(flattenRecursion: true))
        let r = try node(flat.root, "start", "recurse")
        #expect(r.children.map(\.name) == ["helper"])
        #expect(r.total == 3)
    }

    @Test func chargeToCallers() throws {
        let work = FunctionRef(image: Synthetic.app, start: 0x100)
        let tree = CallTree(trace: t, options: .init(chargedFunctions: [work]))
        let main = try node(tree.root, "start", "main")
        #expect(main.selfCount == 10)
        #expect(child(main, "memcpy")?.total == 2)
        let byImage = CallTree(trace: t, options: .init(chargedImages: [Synthetic.sys]))
        // Every system frame removed: the kernel samples (only system frames) stay on the root.
        #expect(byImage.root.children.map(\.name) == ["main", "recurse"])
        #expect(byImage.root.children.first?.total == 13 && byImage.root.selfCount == 2)
    }

    @Test func topFunctions() {
        let top = CallTree.topFunctions(trace: t)
        #expect(top.first?.name == "work" && top.first?.selfCount == 10 && top.first?.total == 12)
        // recurse appears three times on its path but counts once per sample.
        #expect(top.first { $0.name == "recurse" }?.total == 3)
    }

    @Test func flameGraphLayout() throws {
        let fg = FlameGraph(tree: CallTree(trace: t))
        #expect(fg.total == 18)
        let start = try #require(fg.boxes.first { $0.name == "start" })
        #expect(start.depth == 0 && start.start == 0 && start.width == 18)
        // Children by name: main (13) then recurse (3) then syscall (2).
        let main = try #require(fg.boxes.first { $0.name == "main" })
        let recurse = try #require(fg.boxes.first { $0.name == "recurse" && $0.depth == 1 })
        let sys = try #require(fg.boxes.first { $0.name == "syscall" && $0.depth == 1 })
        #expect(main.start == 0 && recurse.start == 13 && sys.start == 16)
        #expect(fg.maxDepth == 4)
        #expect(fg.box(atSample: 14, depth: 1)?.name == "recurse")
        let svg = fg.svg(title: "t")
        #expect(svg.hasPrefix("<?xml") && svg.contains("<title>work (App): 12 samples"))
    }

    @Test func sourceAnnotationCountsLines() throws {
        let a = SourceAnnotation(trace: t, function: FunctionRef(image: Synthetic.app, start: 0x100))
        #expect(a.file == "/src/app.c")
        #expect(a.samples == 12)
        // Line 10: 6 self; line 11: 4 self + 2 calls into memcpy (return address 0x118 − 1 → line 11).
        #expect(a.lines == [.init(line: 10, selfCount: 6, total: 6), .init(line: 11, selfCount: 4, total: 6)])
        let text = a.render(source: (1...15).map { "line \($0)" }.joined(separator: "\n"), context: 1)
        #expect(text.contains("      6       6     10  line 10"))
        #expect(text.contains("      4       6     11  line 11"))
    }
}

@Suite struct TimelineTests {
    @Test func hangsFromMainThreadStates() {
        let t = Synthetic.trace()
        // Main thread: 9 busy samples (0–8 ms), 3 idle, 4 busy: threshold 5 ms → one hang of 9 ms.
        let h = GaugeTimeline.hangs(t)
        #expect(h == [GaugeTrace.Hang(thread: 7, begin: 0, end: 9_000_000)])
        #expect(GaugeTimeline.hangs(t, threshold: 3_000_000).count == 2)
        #expect(GaugeTimeline.severity(h[0], threshold: 2_000_000) == "Severe Hang")
        #expect(GaugeTimeline.severity(h[0], threshold: 5_000_000) == "Hang")
    }

    @Test func hangsBridgeShortSampleGaps() {
        // A busy main thread whose samples skip 3 ms (a dropped kick) and,
        // later, 30 ms (the recorder paused): threshold 20 ms, so the
        // short gap stays inside the hang and the long one ends it.
        var b = GaugeTraceBuilder(recording: .init(target: "t", durationNs: 100_000_000, sampleIntervalNs: 1_000_000, hangThresholdNs: 20_000_000))
        b.update { $0.threads = [.init(id: 1, pid: 1, name: "", isMain: true, kind: "main")] }
        var times: [UInt64] = Array(0..<10).map { $0 * 1_000_000 }
        times += Array(13..<30).map { $0 * 1_000_000 }   // 3 ms gap: bridged
        times += Array(60..<70).map { $0 * 1_000_000 }   // 30 ms gap: a new run (too short to be a hang)
        for t in times { b.addSample(time: t, thread: 1, state: .user, frames: []) }
        let h = GaugeTimeline.hangs(b.finish())
        #expect(h == [GaugeTrace.Hang(thread: 1, begin: 0, end: 30_000_000)])
        #expect(GaugeTimeline.hangGapLimit(interval: 1_000_000, threshold: 250_000_000) == 62_500_000)
        #expect(GaugeTimeline.hangGapLimit(interval: 1_000_000, threshold: 8_000_000) == 4_000_000)
    }

    @Test func signpostRowsPutTheTargetsOwnFirst() {
        var t = Synthetic.trace()
        t.recording.command = "dev.example.App"
        typealias S = GaugeTrace.Signpost
        t.signposts = [
            S(name: "LaunchEvent", subsystem: "os.framework", begin: 1, kind: .event),
            S(name: "LaunchEvent", subsystem: "os.framework", begin: 2, kind: .event),
            S(name: "Layout", subsystem: "os.framework", begin: 3, end: 4),
            S(name: "Tick", subsystem: "dev.example.App", begin: 5, kind: .event),
            S(name: "Work", subsystem: "dev.example.App", begin: 6, end: 9),
            S(name: "Work", subsystem: "dev.example.App", begin: 10, end: 12),
            S(name: "Load", subsystem: "dev.example.App", begin: 13, end: 14),
        ]
        #expect(GaugeTimeline.signpostRows(t) == ["Work", "Load", "Tick", "Layout", "LaunchEvent"])
        #expect(GaugeTimeline.signpostRows(t, limit: 2) == ["Work", "Load"])
        t.recording.command = ""
        #expect(GaugeTimeline.signpostRows(t) == ["Work", "Layout", "Load", "LaunchEvent", "Tick"])
    }

    @Test func signpostMatching() {
        typealias E = GaugeTimeline.SignpostEvent
        func e(_ time: UInt64, _ k: E.Kind, _ id: UInt64, _ name: String, _ msg: String = "") -> E {
            E(time: time, kind: k, id: id, thread: 1, subsystem: "s", category: "c", name: name, message: msg)
        }
        let s = GaugeTimeline.intervals([
            e(10, .begin, 1, "Load", "a"), e(12, .begin, 2, "Load"), e(15, .end, 2, "Load"), e(20, .end, 1, "Load", "b"),
            e(25, .event, 9, "Tick"), e(30, .end, 5, "Orphan"), e(40, .begin, GaugeTimeline.exclusiveID, "Excl"), e(41, .end, 3, "Open"),
            e(50, .end, GaugeTimeline.exclusiveID, "Excl"),
        ], recordingEnd: 100)
        #expect(s.count == 6)
        #expect(s[0].begin == 10 && s[0].end == 20 && s[0].message == "a — b")
        #expect(s[1].begin == 12 && s[1].end == 15)
        #expect(s[2].kind == .event && s[2].name == "Tick")
        #expect(s[3].flags == ["unmatched"])
        #expect(s[4].name == "Excl" && s[4].end == 50)
        #expect(s[5].name == "Open" && s[5].flags == ["unmatched"])
        let sum = GaugeTimeline.summarize(s)
        #expect(sum.first?.name == "Excl" || sum.first?.name == "Load")
        #expect(sum.first { $0.name == "Load" }?.count == 2 && sum.first { $0.name == "Load" }?.totalNs == 13)
        let open = GaugeTimeline.intervals([e(5, .begin, 1, "Never")], recordingEnd: 100)
        #expect(open[0].end == 100 && open[0].flags == ["open"])
    }

    @Test func cpuColumnsAndLongFrames() {
        let t = Synthetic.trace()
        let cols = GaugeTimeline.cpuColumns(t, range: 0..<20_000_000, columns: 4)
        #expect(cols.count == 4)
        #expect(cols.reduce(0) { $0 + $1.user + $1.kernel } == 18)
        #expect(cols.reduce(0) { $0 + $1.kernel } == 2)
        let long = GaugeTimeline.longFrames([0, 16, 32, 48, 100, 116])
        #expect(long.count == 1 && long[0].time == 100 && long[0].interval == 52)
    }
}

@Suite struct ReportTests {
    @Test func summaryNamesTheHotFunction() {
        var t = Synthetic.trace()
        t.signposts = [.init(name: "Load", begin: 0, end: 3_000_000)]
        t.presents = [0, 16_000_000, 33_000_000]
        let s = GaugeReport.summary(t)
        #expect(s.contains("Top functions by self time"))
        let firstTop = s.components(separatedBy: "function\n").dropFirst().first?.split(separator: "\n").first ?? ""
        #expect(firstTop.contains("work (App)"))
        #expect(s.contains("Load: 1× total 3.0 ms"))
        #expect(s.contains("Hangs (main thread busy ≥ 5.0 ms): 1"))
        #expect(s.contains("Frames: 3 presents"))
        let tree = GaugeReport.tree(CallTree(trace: t))
        #expect(tree.contains("      work  [App]"))
    }
}
