import AppKit
import YcodeDebug

/// What the Debug navigator shows about the debugged process.
public struct DebugProcessInfo: Equatable {
    public var product: String
    public var pid: Int?
    public var gauges: ProcessGauges
    public init(product: String, pid: Int?, gauges: ProcessGauges = ProcessGauges()) {
        self.product = product
        self.pid = pid
        self.gauges = gauges
    }
}

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

/// Finds the function enclosing a line by scanning the source text
/// (a cheap heuristic: Swift `func`/`init`/`subscript` and C-style
/// definitions; "method" when inside a type).
@MainActor
public enum SourceSymbolLocator {
    private static var cache: [String: (Date, [Substring])] = [:]

    public static func symbol(file: String, line: Int) -> (name: String, method: Bool)? {
        let date = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? .distantPast
        let lines: [Substring]
        if let c = cache[file], c.0 == date { lines = c.1 } else {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
            lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            cache[file] = (date, lines)
        }
        return symbol(in: lines, line: line)
    }

    public static func symbol(in lines: [Substring], line: Int) -> (name: String, method: Bool)? {
        guard line >= 1, line <= lines.count else { return nil }
        var i = line - 1
        while i >= 0 {
            let l = lines[i]
            if let name = swiftFunction(l) ?? cFunction(l) {
                let indent = l.prefix { $0 == " " || $0 == "\t" }.count
                var method = false
                if indent > 0 {
                    var j = i - 1
                    while j >= 0 {
                        let t = lines[j]
                        let ti = t.prefix { $0 == " " || $0 == "\t" }.count
                        if ti < indent, t.range(of: #"\b(class|struct|enum|extension|actor|protocol)\b"#, options: .regularExpression) != nil { method = true; break }
                        j -= 1
                    }
                }
                return (name, method)
            }
            i -= 1
        }
        return nil
    }

    /// `func name(a: T, _ b: U)` → "name(a:_:)".
    static func swiftFunction(_ l: Substring) -> String? {
        guard let r = l.range(of: #"\b(func\s+[^\s(<]+|init[?!]?|subscript)\s*(<[^>]*>)?\s*\("#, options: .regularExpression) else { return nil }
        var head = l[r].replacingOccurrences(of: "func", with: "").trimmingCharacters(in: .whitespaces)
        head = String(head.prefix { $0 != "(" && $0 != "<" }).trimmingCharacters(in: .whitespaces)
        let rest = l[r.upperBound...]
        var depth = 1
        var params = ""
        for c in rest { if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth == 0 { break } }; params.append(c) }
        let labels = params.split(separator: ",").compactMap { p -> String? in
            let t = p.trimmingCharacters(in: .whitespaces)
            guard let colon = t.firstIndex(of: ":") else { return nil }
            return (t[..<colon].split(separator: " ").first.map(String.init) ?? "_") + ":"
        }
        return head + "(" + labels.joined() + ")"
    }

    /// `int add(int a, int b) {` → "add".
    static func cFunction(_ l: Substring) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), !t.hasPrefix("//"), !l.hasPrefix(" "), !l.hasPrefix("\t"),
              let m = t.range(of: #"^[A-Za-z_][\w\s\*]*\s\**([A-Za-z_]\w*)\s*\([^;]*\)\s*\{?$"#, options: .regularExpression) else { return nil }
        let s = t[m]
        let name = s[..<s.firstIndex(of: "(")!].split(whereSeparator: { $0 == " " || $0 == "*" }).last
        guard let name, !["if", "while", "for", "switch", "return"].contains(String(name)) else { return nil }
        return String(name)
    }
}
