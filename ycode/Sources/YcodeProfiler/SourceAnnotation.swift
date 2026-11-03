import Foundation

/// Samples per source line of one function (`specs/ide/profiler.md` §4.4).
public struct SourceAnnotation: Sendable, Equatable {
    public struct LineCount: Sendable, Equatable {
        public var line: Int
        /// Samples whose leaf address is at this line.
        public var selfCount: Int
        /// Self plus samples whose frame in the function is a call at this line.
        public var total: Int
    }

    /// The source file most of the function's samples map to.
    public var file: String?
    public var lines: [LineCount]
    /// Samples through the function (some may have no line).
    public var samples: Int

    public init(trace t: GaugeTrace, function f: FunctionRef, filter: SampleFilter = SampleFilter()) {
        let names = SymbolNames(trace: t)
        var stackCounts: [Int: Int] = [:]
        for i in 0..<t.samples.count where filter.includes(t, i) { stackCounts[t.samples.stack[i], default: 0] += 1 }
        var selfBy: [String: [Int: Int]] = [:], totalBy: [String: [Int: Int]] = [:]
        var fileWeight: [String: Int] = [:]
        var samples = 0
        let image = names.image(f.image)
        for (stack, n) in stackCounts {
            let ids = t.frameIDs(ofStack: stack)
            var touched = false
            var seen: Set<String> = []
            for (p, fid) in ids.enumerated() where names.function(ofFrame: fid) == f {
                touched = true
                let isLeaf = p == ids.count - 1
                let offset = t.frames[fid].offset
                guard let img = image, let (file, line) = img.line(at: isLeaf ? offset : offset &- 1) else { continue }
                let key = "\(file):\(line)"
                if !seen.contains(key) {
                    seen.insert(key)
                    totalBy[file, default: [:]][line, default: 0] += n
                    fileWeight[file, default: 0] += n
                }
                if isLeaf { selfBy[file, default: [:]][line, default: 0] += n }
            }
            if touched { samples += n }
        }
        let file = fileWeight.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        self.file = file
        self.samples = samples
        if let file {
            let s = selfBy[file] ?? [:], tot = totalBy[file] ?? [:]
            lines = Set(s.keys).union(tot.keys).sorted().map { LineCount(line: $0, selfCount: s[$0] ?? 0, total: tot[$0] ?? 0) }
        } else {
            lines = []
        }
    }

    /// The source text with a count column ("self total | line"), only the
    /// lines from `context` before the first counted line to `context`
    /// after the last.
    public func render(source: String, context: Int = 3) -> String {
        let text = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first?.line, let last = lines.last?.line else { return "" }
        let by = Dictionary(uniqueKeysWithValues: lines.map { ($0.line, $0) })
        var out = "   self   total   line  source\n"
        for n in max(1, first - context)...min(text.count, last + context) {
            let c = by[n]
            let s = c.map { String($0.selfCount) } ?? ""
            let tot = c.map { String($0.total) } ?? ""
            out += s.leftPadded(7) + " " + tot.leftPadded(7) + "  " + String(n).leftPadded(5) + "  " + String(text[n - 1]) + "\n"
        }
        return out
    }
}

extension String {
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
    func rightPadded(_ width: Int) -> String { count >= width ? self : self + String(repeating: " ", count: width - count) }
}
