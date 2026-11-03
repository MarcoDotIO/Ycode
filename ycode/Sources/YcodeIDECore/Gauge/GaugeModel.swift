import Foundation
import YcodeProfiler

/// The state of a profiler window (`specs/ide/profiler.md` §6): the trace,
/// the time range and thread filter, the call-tree options, the view shown
/// and the selected node. Views read the derived values; every change calls
/// `onChange`.
@MainActor
public final class GaugeModel {
    public enum Content: Int, CaseIterable, Sendable {
        case callTree, flameGraph, source
        public var title: String {
            switch self {
            case .callTree: "Call Tree"
            case .flameGraph: "Flame Graph"
            case .source: "Source"
            }
        }
    }

    /// Recording (no trace yet), or showing one.
    public enum Phase: Equatable, Sendable {
        case recording(target: String, since: Date)
        case loaded
        case failed(String)
    }

    public private(set) var trace: GaugeTrace?
    public private(set) var traceURL: URL?
    public var phase: Phase = .loaded { didSet { changed() } }
    public var range: Range<UInt64>? { didSet { recompute() } }
    public var threads: Set<UInt64>? { didSet { recompute() } }
    public var options = CallTreeOptions() { didSet { recompute() } }
    public var allStates = false { didSet { recompute() } }
    public var content: Content = .callTree { didSet { changed() } }
    public var searchText = "" { didSet { changed() } }
    /// The selected node's key path (from the root's child).
    public var selectedPath: [CallTreeNode.Key]? { didSet { selectionChanged() } }

    public private(set) var tree: CallTree?
    public private(set) var flame: FlameGraph?
    public private(set) var hangs: [GaugeTrace.Hang] = []
    /// Stack ids whose frames include the selected function (CPU track highlight).
    public private(set) var selectedStacks: Set<Int> = []

    public var onChange: (() -> Void)?

    public init() {}

    public var filter: SampleFilter { SampleFilter(range: range, threads: threads, allStates: allStates) }

    public func load(_ trace: GaugeTrace, url: URL? = nil) {
        self.trace = trace
        traceURL = url
        hangs = trace.hangs.isEmpty ? GaugeTimeline.hangs(trace) : trace.hangs
        phase = .loaded
        recompute()
    }

    public func load(url: URL) throws {
        load(try GaugeTraceCodec.read(url), url: url)
    }

    private func recompute() {
        guard let t = trace else {
            tree = nil
            flame = nil
            changed()
            return
        }
        let tree = CallTree(trace: t, filter: filter, options: options)
        self.tree = tree
        var flameOptions = options
        flameOptions.invert = false
        flame = FlameGraph(tree: options.invert ? CallTree(trace: t, filter: filter, options: flameOptions) : tree)
        if let p = selectedPath, node(at: p) == nil { selectedPath = nil } else { selectionChanged() }
        changed()
    }

    private func changed() { onChange?() }

    private func selectionChanged() {
        selectedStacks = []
        if let t = trace, let f = selectedNode?.function {
            let names = SymbolNames(trace: t)
            var contains = [Bool](repeating: false, count: t.stacks.count)
            for (i, s) in t.stacks.enumerated() {
                contains[i] = (s.prefix >= 0 && contains[s.prefix]) || names.function(ofFrame: s.frame) == f
                if contains[i] { selectedStacks.insert(i) }
            }
        }
        changed()
    }

    /// The node at a key path in the current tree.
    public func node(at path: [CallTreeNode.Key]) -> CallTreeNode? {
        var n = tree?.root
        for k in path { n = n?.children.first { $0.key == k } }
        return n
    }

    public var selectedNode: CallTreeNode? { selectedPath.flatMap(node(at:)) }

    /// The selected function's per-line samples (Source).
    public var annotation: SourceAnnotation? {
        guard let t = trace, let f = selectedNode?.function else { return nil }
        return SourceAnnotation(trace: t, function: f, filter: filter)
    }

    /// Samples per thread in the range (thread filter menu).
    public var threadChoices: [(id: UInt64, title: String, samples: Int)] {
        guard let t = trace else { return [] }
        var counts: [UInt64: Int] = [:]
        for i in 0..<t.samples.count where t.samples.state[i].isCPU { counts[t.samples.thread[i], default: 0] += 1 }
        return t.threads.map { ($0.id, t.threadTitle($0.id), counts[$0.id] ?? 0) }.sorted { $0.samples > $1.samples }
    }

    /// "Charge to Callers" for the selected node's function or image.
    public func chargeSelectedToCallers(wholeImage: Bool) {
        guard let f = selectedNode?.function else { return }
        if wholeImage { options.chargedImages.insert(f.image) } else { options.chargedFunctions.insert(f) }
    }

    public func clearCharges() {
        options.chargedImages = []
        options.chargedFunctions = []
    }

    /// The whole recording, in ns.
    public var duration: UInt64 { max(1, trace?.recording.durationNs ?? 1) }

    /// One line describing the selection (inspector, status).
    public var selectionSummary: String {
        guard let tree, let n = selectedNode else { return "" }
        let pct = tree.sampleCount > 0 ? 100 * Double(n.total) / Double(tree.sampleCount) : 0
        return String(format: "%@ — %.1f ms (%.1f %%), self %.1f ms", n.name, tree.milliseconds(n.total), pct, tree.milliseconds(n.selfCount))
    }
}

/// Gauge's settings (user defaults only).
public enum GaugeSettings {
    /// Samples per second per thread (`Ycode.gauge.sampleRate`, 10…10000; default 1000).
    public static var sampleRate: Int {
        let v = UserDefaults.standard.integer(forKey: "Ycode.gauge.sampleRate")
        return v == 0 ? 1000 : max(10, min(10_000, v))
    }

    /// Paths of Gauge traces among launch arguments (opened in a profiler window).
    public static func tracePaths(_ paths: [String]) -> (traces: [String], others: [String]) {
        (paths.filter { $0.hasSuffix(".gaugetrace") }, paths.filter { !$0.hasSuffix(".gaugetrace") })
    }
}
