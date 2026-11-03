import Foundation

/// Text renderings of a trace for `ycode profile` (`specs/ide/profiler.md` §7).
public enum GaugeReport {
    static func ms(_ ns: UInt64) -> String { String(format: "%.1f ms", Double(ns) / 1e6) }

    /// Recording, threads, top functions by self time, the heaviest stack,
    /// signposts, hangs, frames and GPU.
    public static func summary(_ t: GaugeTrace, top: Int = 15, filter: SampleFilter = SampleFilter()) -> String {
        let r = t.recording
        var out = "Gauge trace: \(r.target)" + (r.command.isEmpty ? "" : " — \(r.command)") + "\n"
        if !r.device.isEmpty { out += "Device: \(r.device)\n" }
        out += "Recorder: \(r.recorder)\(r.host.isEmpty ? "" : " on \(r.host)")\n"
        out += String(format: "Duration: %.3f s, sample interval %.3f ms, %d samples, %d threads\n",
                      Double(r.durationNs) / 1e9, Double(r.sampleIntervalNs) / 1e6, t.samples.count, t.threads.count)
        for n in r.notes { out += "Note: \(n)\n" }

        // Threads by CPU samples.
        var cpu: [UInt64: (user: Int, kernel: Int, other: Int)] = [:]
        for i in 0..<t.samples.count where filter.range.map({ $0.contains(t.samples.time[i]) }) ?? true {
            var c = cpu[t.samples.thread[i]] ?? (0, 0, 0)
            switch t.samples.state[i] {
            case .user: c.user += 1
            case .kernel: c.kernel += 1
            case .blocked, .idle: c.other += 1
            }
            cpu[t.samples.thread[i]] = c
        }
        let step = Double(r.sampleIntervalNs) / 1e6
        out += "\nThreads (CPU = user + kernel samples × interval):\n"
        for (tid, c) in cpu.sorted(by: { ($0.value.user + $0.value.kernel) > ($1.value.user + $1.value.kernel) }).prefix(12) {
            out += String(format: "  %9.1f ms  (user %.1f, kernel %.1f)  ", Double(c.user + c.kernel) * step, Double(c.user) * step, Double(c.kernel) * step)
                + t.threadTitle(tid) + "\n"
        }

        let tops = CallTree.topFunctions(trace: t, filter: filter)
        let cpuSamples = max(1, tops.isEmpty ? 1 : (0..<t.samples.count).filter { filter.includes(t, $0) }.count)
        out += "\nTop functions by self time:\n"
        out += "     self        %     total        %  function\n"
        for f in tops.prefix(top) {
            out += String(format: "%9.1f ms %6.1f %% %9.1f ms %6.1f %%  ", Double(f.selfCount) * step, 100 * Double(f.selfCount) / Double(cpuSamples),
                          Double(f.total) * step, 100 * Double(f.total) / Double(cpuSamples)) + "\(f.name) (\(f.image))\n"
        }

        let tree = CallTree(trace: t, filter: filter)
        if let first = tree.root.children.first {
            out += "\nHeaviest stack:\n"
            for n in first.heaviestPath {
                out += String(format: "  %9.1f ms  ", Double(n.total) * step) + n.name + (n.imageName.isEmpty ? "" : " (\(n.imageName))") + "\n"
            }
        }

        if !t.signposts.isEmpty {
            out += "\nSignposts:\n"
            for s in GaugeTimeline.summarize(t.signposts) {
                out += "  \(s.name): \(s.count)× total \(ms(s.totalNs)), mean \(ms(s.meanNs)), max \(ms(s.maxNs))\n"
            }
        }
        let hangs = t.hangs.isEmpty ? GaugeTimeline.hangs(t) : t.hangs
        out += "\nHangs (main thread busy ≥ \(ms(r.hangThresholdNs))): \(hangs.count)\n"
        for h in hangs.prefix(10) {
            out += "  \(GaugeTimeline.severity(h, threshold: r.hangThresholdNs)) \(ms(h.duration)) at \(ms(h.begin))\n"
        }
        if t.presents.count > 1 {
            let span = Double(t.presents.last! - t.presents.first!) / 1e9
            let long = GaugeTimeline.longFrames(t.presents)
            out += String(format: "\nFrames: %d presents, %.1f per second, %d long frames\n", t.presents.count,
                          span > 0 ? Double(t.presents.count - 1) / span : 0, long.count)
        }
        if !t.gpu.isEmpty {
            var by: [String: (n: Int, ns: UInt64)] = [:]
            for g in t.gpu { by[g.process, default: (0, 0)].n += 1; by[g.process, default: (0, 0)].ns += g.gpuNs }
            out += "\nGPU command buffers:\n"
            for (p, v) in by.sorted(by: { $0.value.ns > $1.value.ns }) { out += "  \(p): \(v.n), GPU time \(ms(v.ns))\n" }
        }
        return out
    }

    /// An indented call tree; nodes below `minPercent` of the root are cut.
    public static func tree(_ tree: CallTree, maxDepth: Int = 40, minPercent: Double = 0.5) -> String {
        let total = max(1, tree.root.total)
        var out = "   weight        %     self  symbol\n"
        func visit(_ n: CallTreeNode, depth: Int) {
            guard depth <= maxDepth, 100 * Double(n.total) / Double(total) >= minPercent else { return }
            out += String(format: "%9.1f ms %6.1f %% %6.1f  ", tree.milliseconds(n.total), 100 * Double(n.total) / Double(total), tree.milliseconds(n.selfCount))
                + String(repeating: "  ", count: depth) + n.name + (n.imageName.isEmpty ? "" : "  [\(n.imageName)]") + "\n"
            for c in n.children { visit(c, depth: depth + 1) }
        }
        for c in tree.root.children { visit(c, depth: 0) }
        return out
    }
}
