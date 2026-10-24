import Foundation

/// Fuzzy matching for Open Quickly. See `specs/ide/open-quickly.md`.
public enum FuzzyMatch {
    /// A score when every query character appears in `candidate` in order
    /// (ignoring case), else nil. Higher is better: matches at the start,
    /// at word starts (after `/ . _ -` or a lower→upper case change) and in
    /// runs score more; long candidates score slightly less.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate)
        let lower = c.map { Character($0.lowercased()) }
        var score = 0, qi = 0, run = 0
        var last: Int?
        for (i, ch) in lower.enumerated() where qi < q.count {
            guard ch == q[qi] else { run = 0; continue }
            var s = 1
            if i == 0 { s += 8 }
            else {
                let prev = c[i - 1]
                if "/._- ".contains(prev) { s += 6 }
                else if prev.isLowercase && c[i].isUppercase { s += 5 }
            }
            if let l = last, l == i - 1 { run += 1; s += 3 * run } else { run = 0 }
            score += s
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score * 10 - c.count
    }

    public struct Candidate: Equatable, Sendable {
        public enum Kind: String, Sendable { case file, symbol }
        public var title: String
        /// Shown under the title: the folder for files, the file for symbols.
        public var detail: String
        public var path: String
        public var line: Int?
        public var kind: Kind
        public var symbolKind: SymbolScanner.Symbol.Kind?
    }

    /// Files and declarations (with members) of a workspace tree.
    public static func candidates(in root: NavigatorNode) -> [Candidate] {
        var out: [Candidate] = []
        for f in root.allFiles {
            guard let path = f.path else { continue }
            out.append(Candidate(title: f.name, detail: (path as NSString).deletingLastPathComponent, path: path, kind: .file))
            let lang = SourceTokenizer.Language(fileName: f.name)
            guard lang != .plain, let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            func add(_ s: SymbolScanner.Symbol) {
                out.append(Candidate(title: s.name, detail: f.name, path: path, line: s.line, kind: .symbol, symbolKind: s.kind))
                s.children.forEach(add)
            }
            SymbolScanner.symbols(in: text, language: lang).forEach(add)
        }
        return out
    }

    /// The best `limit` candidates for `query`; ties keep files first.
    public static func search(_ query: String, in candidates: [Candidate], limit: Int = 20) -> [Candidate] {
        var scored: [(candidate: Candidate, score: Int)] = []
        for c in candidates {
            if let s = score(query, c.title) { scored.append((c, s)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.candidate.kind == .file && b.candidate.kind != .file
        }
        return scored.prefix(limit).map { $0.candidate }
    }
}
