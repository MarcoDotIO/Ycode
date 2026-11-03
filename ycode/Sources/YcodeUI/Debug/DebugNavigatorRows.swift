import AppKit
import YcodeDebug
import YcodeIDECore

/// Builds the Debug and Breakpoint navigator trees
/// (specs/ide/reference-ui-4.md §5.3, §6).
@MainActor
public enum DebugNavigatorRows {
    // MARK: Debug navigator

    /// The process row ("<product>  PID <pid>") with the gauge rows and the
    /// threads (or queue groups) under it.
    /// `compressed`: fold runs of system frames (the bottom bar's "Show
    /// compressed stack frames"); `interestingOnly`: while stopped, only
    /// the stopped thread (the one whose frames, with debug symbols, are
    /// known) — reference-ui-5.md §5.2.
    /// `runningBlocksOnly` (the third toggle, on by default): in the queue
    /// view, only queues with a thread running one of their blocks; the
    /// threads not running a queue's block ("Threads") are left out.
    /// DAP reports no pending blocks, so there are none to list when off.
    public static func debugTree(process: DebugProcessInfo?, gauges showGauges: Bool = true, threads: [DebugThread], stoppedThread: Int?, frames: [StackFrame],
                                 byQueue: Bool, compressed: Bool = true, interestingOnly: Bool = false, runningBlocksOnly: Bool = false) -> [OutlineItem] {
        func threadItem(_ t: DebugThread) -> OutlineItem {
            let item = OutlineItem(title: DebugPresentation.threadRow(t), symbol: t.id == stoppedThread ? "pause.circle" : "circle.dashed",
                                   children: t.id == stoppedThread ? (compressed ? frameItems(frames) : allFrameItems(frames)) : [])
            item.middleTruncation = true
            return item
        }
        let threads = interestingOnly && stoppedThread != nil
            ? threads.filter { $0.id == stoppedThread }
            : threads
        var body: [OutlineItem]
        if byQueue {
            var groups: [(String, [DebugThread])] = []
            for t in threads {
                let q = t.queue ?? "Threads"
                if let i = groups.firstIndex(where: { $0.0 == q }) { groups[i].1.append(t) } else { groups.append((q, [t])) }
            }
            if runningBlocksOnly { groups.removeAll { g in g.1.allSatisfy { $0.queue == nil } } }
            body = groups.map { OutlineItem(title: $0.0, symbol: "list.bullet.rectangle", children: $0.1.map(threadItem)) }
        } else {
            body = threads.map(threadItem)
        }
        guard let process else { return body }
        let gauges = !showGauges ? [] : process.gauges.rows.map { title, value -> OutlineItem in
            let symbol = ["CPU": "cpu", "Memory": "memorychip", "Energy Impact": "bolt", "Disk": "internaldrive", "Network": "network"][title] ?? "gauge"
            let g = OutlineItem(title: title, symbol: symbol, tint: .secondaryLabelColor)
            g.badge = value
            if title == "Energy Impact" { g.level = process.gauges.energyLevel }
            return g
        }
        let root = OutlineItem(title: process.product + (process.pid.map { "  PID \($0)" } ?? ""), symbol: "app.dashed", children: gauges + body)
        root.rowButtons = processRowButtons
        return [root]
    }

    /// The process row's two buttons at its right (reference-ui-4.md §5.3,
    /// D3): (symbol, tooltip, action sent up the responder chain). Their
    /// reference functions were not observed; Ycode's are Pause/Continue
    /// and Stop.
    public static let processRowButtons: [(symbol: String, toolTip: String, action: String)] = [
        ("pause.circle", "Pause or continue the process", "pauseOrContinue:"),
        ("stop.circle", "Stop the process", "stopProduct:"),
    ]

    /// Frame rows: user frames (person icon), a dotted separator, the
    /// first system frame of each collapsed run greyed.
    public static func frameItems(_ frames: [StackFrame]) -> [OutlineItem] {
        DebugPresentation.groupFrames(frames).map { row in
            switch row {
            case .separator:
                let s = OutlineItem(title: "┈┈┈┈┈┈┈┈┈┈┈┈", symbol: "ellipsis", tint: .tertiaryLabelColor)
                s.isSeparator = true
                s.dimmed = true
                return s
            case .frame(let i, let f, let user):
                let item = OutlineItem(title: "\(i) \(f.name)", symbol: user ? "person.fill" : "cpu",
                                       tint: user ? .controlAccentColor : .secondaryLabelColor, path: f.file, line: f.line, frameID: f.id)
                item.dimmed = !user
                return item
            }
        }
    }

    /// Every frame, user frames marked, nothing folded.
    public static func allFrameItems(_ frames: [StackFrame]) -> [OutlineItem] {
        frames.enumerated().map { i, f in
            let user = DebugPresentation.isUserFrame(f)
            let item = OutlineItem(title: "\(i) \(f.name)", symbol: user ? "person.fill" : "cpu",
                                   tint: user ? .controlAccentColor : .secondaryLabelColor, path: f.file, line: f.line, frameID: f.id)
            item.dimmed = !user
            return item
        }
    }

    // MARK: Breakpoint navigator

    /// Filters of the Breakpoint navigator's bottom bar.
    public struct BreakpointFilter: Equatable {
        public var enabledOnly = false
        public var customizedOnly = false
        public init() {}
    }

    /// The "+" menu's kinds, in order.
    public static let addKinds: [(String, NavigatorAreaController.NewBreakpointKind)] = [
        ("Swift Error Breakpoint", .swiftError), ("Exception Breakpoint…", .exception), ("Symbolic Breakpoint…", .symbolic),
        ("Runtime Issue Breakpoint…", .runtimeIssue), ("Constraint Error Breakpoint", .constraintError), ("Test Failure Breakpoint", .testFailure),
    ]

    /// Root "<project>  n Breakpoint(s)", the exception, symbolic and
    /// watchpoint groups, then one group per file with rows "symbol  line",
    /// "ID n.m" and the enabled marker.
    public static func breakpointTree(project: String, store: BreakpointStore, watchpoints: [OutlineItem], ids: [String: String],
                                      filter: BreakpointFilter = BreakpointFilter(),
                                      symbolAt: @MainActor (String, Int) -> (name: String, method: Bool)? = SourceSymbolLocator.symbol) -> [OutlineItem] {
        let exceptionNames = ["objc_throw": "Objective-C exceptions", "cpp_throw": "C++ exceptions", "swift_throw": "Swift errors"]
        var groups: [OutlineItem] = []
        if !store.exceptionFilters.isEmpty && !filter.customizedOnly {
            groups.append(OutlineItem(title: "Exception Breakpoints", symbol: "exclamationmark.octagon", children: store.exceptionFilters.map {
                OutlineItem(title: exceptionNames[$0] ?? $0, symbol: "tag.fill", tint: Theme.breakpointColor)
            }))
        }
        let symbolic = store.symbolic.filter { (!filter.enabledOnly || $0.isEnabled) && (!filter.customizedOnly || !$0.condition.isEmpty) }
        if !symbolic.isEmpty {
            groups.append(OutlineItem(title: "Symbolic Breakpoints", symbol: "function", children: symbolic.map {
                OutlineItem(title: $0.condition.isEmpty ? $0.name : "\($0.name) [\($0.condition)]", symbol: "tag.fill",
                            tint: Theme.breakpointColor.withAlphaComponent($0.isEnabled && store.isActive ? 1 : 0.35))
            }))
        }
        if !filter.customizedOnly { groups += watchpoints }
        let shown = store.all.filter { (!filter.enabledOnly || $0.isEnabled) && (!filter.customizedOnly || $0.isCustomized) }
        let byFile = Dictionary(grouping: shown, by: \.file)
        var ordinal = 0
        let ordinals = Dictionary(store.all.map { b -> (String, Int) in ordinal += 1; return ("\(b.file):\(b.line)", ordinal) }, uniquingKeysWith: { a, _ in a })
        for file in byFile.keys.sorted() {
            let rows = byFile[file]!.sorted { $0.line < $1.line }.map { b -> OutlineItem in
                let sym = symbolAt(b.file, b.line)
                let base = sym.map { "\($0.name)  \(b.line)" } ?? "line \(b.line)"
                let item = OutlineItem(title: b.condition.isEmpty ? base : "\(base) [\(b.condition)]",
                                       symbol: sym?.method == true ? "m.square.fill" : (sym == nil ? "tag.fill" : "f.square.fill"),
                                       tint: Theme.breakpointColor.withAlphaComponent(b.isEnabled && store.isActive ? 1 : 0.35),
                                       path: b.file, line: b.line)
                let key = "\(b.file):\(b.line)"
                item.detail = "ID " + (ids[key] ?? "\(ordinals[key] ?? 0).1")
                item.enabledMarker = b.isEnabled
                return item
            }
            groups.append(OutlineItem(title: URL(fileURLWithPath: file).lastPathComponent, symbol: "doc.text", children: rows))
        }
        guard !groups.isEmpty else { return [] }
        let n = store.all.count + store.symbolic.count + store.exceptionFilters.count
        return [OutlineItem(title: "\(project)  \(n) Breakpoint\(n == 1 ? "" : "s")", symbol: "folder.badge.gearshape", children: groups)]
    }
}
