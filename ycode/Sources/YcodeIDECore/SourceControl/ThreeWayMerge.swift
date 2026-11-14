import Foundation

/// A three-way line merge: the base (common ancestor) and two changed
/// versions, "ours" (left) and "theirs" (right), split into chunks that
/// are unchanged, changed on one side, changed the same way on both, or
/// in conflict. This is the textbook diff3 procedure: line-diff the base
/// against each side (`LineDiff`), take the base lines both diffs keep as
/// sync points, and classify what lies between them. Ycode's conflict
/// editor and Compare Files show these chunks
/// (`specs/ide/comparison.md`, "Ycode implementation").
public enum ThreeWayMerge {
    public struct Chunk: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case unchanged
            /// Only ours (left) differs from the base.
            case oursOnly
            /// Only theirs (right) differs from the base.
            case theirsOnly
            /// Both sides made the same change.
            case bothSame
            /// The sides changed the same base lines differently.
            case conflict
        }
        public var kind: Kind
        public var base: [String]
        public var ours: [String]
        public var theirs: [String]

        public init(kind: Kind, base: [String], ours: [String], theirs: [String]) {
            self.kind = kind
            self.base = base
            self.ours = ours
            self.theirs = theirs
        }
    }

    /// For each line of `base`, the line of `other` the diff matches it
    /// with, if any.
    static func matches(_ base: [String], _ other: [String]) -> [Int?] {
        var out = [Int?](repeating: nil, count: base.count)
        var i = 0, j = 0
        for op in LineDiff.diff(base, other) {
            switch op {
            case .same: out[i] = j; i += 1; j += 1
            case .removed: i += 1
            case .added: j += 1
            }
        }
        return out
    }

    /// The chunks merging `ours` and `theirs` against `base`.
    public static func merge(base: [String], ours: [String], theirs: [String]) -> [Chunk] {
        let mo = matches(base, ours), mt = matches(base, theirs)
        var chunks: [Chunk] = []
        var i = 0, j = 0, k = 0
        var stable: [String] = []
        func flushStable() {
            guard !stable.isEmpty else { return }
            chunks.append(Chunk(kind: .unchanged, base: stable, ours: stable, theirs: stable))
            stable = []
        }
        while true {
            // A run of base lines kept, in order, by both sides.
            while i < base.count, mo[i] == j, mt[i] == k {
                stable.append(base[i])
                i += 1; j += 1; k += 1
            }
            flushStable()
            if i == base.count, j == ours.count, k == theirs.count { break }
            // The next sync point: a base line both sides keep.
            var b = i
            while b < base.count, mo[b] == nil || mt[b] == nil { b += 1 }
            let jEnd = b < base.count ? mo[b]! : ours.count
            let kEnd = b < base.count ? mt[b]! : theirs.count
            let B = Array(base[i..<b]), O = Array(ours[j..<jEnd]), T = Array(theirs[k..<kEnd])
            let kind: Chunk.Kind
            if O == B, T == B { kind = .unchanged }
            else if O == B { kind = .theirsOnly }
            else if T == B { kind = .oursOnly }
            else if O == T { kind = .bothSame }
            else { kind = .conflict }
            if kind == .unchanged { stable += B; flushStable() } else { chunks.append(Chunk(kind: kind, base: B, ours: O, theirs: T)) }
            i = b; j = jEnd; k = kEnd
        }
        return coalesced(chunks)
    }

    /// Joins neighbouring unchanged chunks.
    static func coalesced(_ chunks: [Chunk]) -> [Chunk] {
        var out: [Chunk] = []
        for c in chunks {
            if c.kind == .unchanged, let last = out.last, last.kind == .unchanged {
                out[out.count - 1].base += c.base
                out[out.count - 1].ours += c.ours
                out[out.count - 1].theirs += c.theirs
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// A two-way comparison as merge chunks: every difference is a
    /// "theirs only" change (the right file's version, chosen by default),
    /// as a file-compare tool merges two files without an ancestor.
    public static func compare(left: [String], right: [String]) -> [Chunk] {
        merge(base: left, ours: left, theirs: right)
    }
}

/// Text with git's conflict markers (`<<<<<<<`, optional `|||||||` base
/// section, `=======`, `>>>>>>>`; git's merge documentation) as merge
/// chunks, for a conflicted file whose index stages are gone or a file
/// someone saved with markers.
public enum ConflictMarkers {
    public struct Parsed: Equatable, Sendable {
        public var chunks: [ThreeWayMerge.Chunk]
        /// The labels after `<<<<<<<` and `>>>>>>>` of the first conflict.
        public var oursLabel: String?
        public var theirsLabel: String?
    }

    /// Whether `text` has at least one complete conflict.
    public static func hasConflicts(_ text: String) -> Bool { (parse(text)?.chunks.contains { $0.kind == .conflict }) ?? false }

    /// The chunks of `text`; nil when a conflict is not closed.
    public static func parse(_ text: String) -> Parsed? {
        enum Section { case outside, ours, base, theirs }
        var out = Parsed(chunks: [])
        var section = Section.outside
        var plain: [String] = [], ours: [String] = [], base: [String] = [], theirs: [String] = []
        func flushPlain() {
            guard !plain.isEmpty else { return }
            out.chunks.append(.init(kind: .unchanged, base: plain, ours: plain, theirs: plain))
            plain = []
        }
        func marker(_ line: String, _ c: Character) -> String? {
            guard line.count >= 7, line.prefix(7).allSatisfy({ $0 == c }) else { return nil }
            let rest = line.dropFirst(7)
            if rest.isEmpty { return "" }
            guard rest.first == " " else { return nil }
            return String(rest.dropFirst())
        }
        for line in LineDiff.lines(text) {
            switch section {
            case .outside:
                if let label = marker(line, "<") {
                    flushPlain()
                    if out.oursLabel == nil { out.oursLabel = label.isEmpty ? nil : label }
                    section = .ours
                } else { plain.append(line) }
            case .ours:
                if marker(line, "|") != nil { section = .base }
                else if line == "=======" { section = .theirs }
                else { ours.append(line) }
            case .base:
                if line == "=======" { section = .theirs } else { base.append(line) }
            case .theirs:
                if let label = marker(line, ">") {
                    if out.theirsLabel == nil { out.theirsLabel = label.isEmpty ? nil : label }
                    let kind: ThreeWayMerge.Chunk.Kind = ours == theirs ? .bothSame : .conflict
                    out.chunks.append(.init(kind: kind, base: base, ours: ours, theirs: theirs))
                    ours = []; base = []; theirs = []
                    section = .outside
                } else { theirs.append(line) }
            }
        }
        guard section == .outside else { return nil }
        flushPlain()
        return out
    }
}

/// The resolution of one merge: chunks, a choice per changed chunk (a
/// "hunk"), and the text that results. The conflict editor and Compare
/// Files edit one of these; it has no user interface of its own, so the
/// Linux IDE can use it too.
public struct MergeDocument: Equatable, Sendable {
    public enum Choice: Equatable, Sendable {
        /// Not decided: the result shows the conflict with markers.
        case unresolved
        /// Left (ours), right (theirs), both in either order, or the base.
        case ours, theirs, oursThenTheirs, theirsThenOurs, base
        /// Text written by hand.
        case custom([String])
    }

    public private(set) var chunks: [ThreeWayMerge.Chunk]
    /// Indices into `chunks` of the hunks (every chunk that is not unchanged).
    public private(set) var hunks: [Int]
    /// One choice per hunk.
    public private(set) var choices: [Choice]
    public var oursLabel: String
    public var theirsLabel: String
    public var baseLabel: String
    /// Whether the right side's text ends with a line break, so an editor
    /// counts one more (empty) line after its last (the overview ruler's
    /// share, `merge-sheet.md` §15.3). Documents built from chunks assume
    /// the usual final line break.
    public var theirsEndsWithNewline = true
    /// The same for the left side's text (the current branch's): its pane
    /// numbers the empty line after a final line break too (`editor-area.md`
    /// I.3, council row 178).
    public var oursEndsWithNewline = true

    public init(chunks: [ThreeWayMerge.Chunk], oursLabel: String = "Ours", theirsLabel: String = "Theirs", baseLabel: String = "Base") {
        self.chunks = chunks
        hunks = chunks.indices.filter { chunks[$0].kind != .unchanged }
        choices = hunks.map { Self.defaultChoice(chunks[$0].kind) }
        self.oursLabel = oursLabel
        self.theirsLabel = theirsLabel
        self.baseLabel = baseLabel
    }

    /// The three-way merge of three texts.
    public init(base: String, ours: String, theirs: String, oursLabel: String = "Ours", theirsLabel: String = "Theirs", baseLabel: String = "Base") {
        self.init(chunks: ThreeWayMerge.merge(base: LineDiff.lines(base), ours: LineDiff.lines(ours), theirs: LineDiff.lines(theirs)),
                  oursLabel: oursLabel, theirsLabel: theirsLabel, baseLabel: baseLabel)
        theirsEndsWithNewline = theirs.hasSuffix("\n")
        oursEndsWithNewline = ours.hasSuffix("\n")
    }

    /// A one-sided change takes that side; the same change on both sides
    /// takes it once; a conflict waits for a choice.
    public static func defaultChoice(_ kind: ThreeWayMerge.Chunk.Kind) -> Choice {
        switch kind {
        case .unchanged, .oursOnly, .bothSame: .ours
        case .theirsOnly: .theirs
        case .conflict: .unresolved
        }
    }

    public var conflictCount: Int { hunks.filter { chunks[$0].kind == .conflict }.count }
    public var unresolvedCount: Int { choices.filter { $0 == .unresolved }.count }
    public var isResolved: Bool { unresolvedCount == 0 }

    public mutating func choose(_ choice: Choice, hunk: Int) {
        guard choices.indices.contains(hunk) else { return }
        choices[hunk] = choice
    }

    /// Gives every hunk the same choice (Choose All Left / Right).
    public mutating func chooseAll(_ choice: Choice) {
        for h in choices.indices { choices[h] = choice }
    }

    /// The next or previous hunk from `hunk` (wrapping), optionally only
    /// unresolved ones; nil when there is none.
    public func step(from hunk: Int?, forward: Bool, unresolvedOnly: Bool = false) -> Int? {
        let candidates = choices.indices.filter { !unresolvedOnly || choices[$0] == .unresolved }
        guard !candidates.isEmpty else { return nil }
        guard let hunk else { return forward ? candidates.first : candidates.last }
        if forward { return candidates.first { $0 > hunk } ?? candidates.first }
        return candidates.last { $0 < hunk } ?? candidates.last
    }

    /// The lines one hunk contributes to the result.
    public func lines(forHunk h: Int) -> [String] {
        let c = chunks[hunks[h]]
        switch choices[h] {
        case .ours: return c.ours
        case .theirs: return c.theirs
        case .oursThenTheirs: return c.ours + c.theirs
        case .theirsThenOurs: return c.theirs + c.ours
        case .base: return c.base
        case .custom(let l): return l
        case .unresolved:
            return ["<<<<<<< " + oursLabel] + c.ours + ["======="] + c.theirs + [">>>>>>> " + theirsLabel]
        }
    }

    /// The merged lines and, per hunk, the result lines it covers
    /// (0-based, half open).
    public func layout() -> (lines: [String], hunkRanges: [Range<Int>]) {
        var lines: [String] = []
        var ranges: [Range<Int>] = []
        var h = 0
        for (i, c) in chunks.enumerated() {
            if h < hunks.count, hunks[h] == i {
                let start = lines.count
                lines += self.lines(forHunk: h)
                ranges.append(start..<lines.count)
                h += 1
            } else {
                lines += c.base
            }
        }
        return (lines, ranges)
    }

    /// The merged text (a final newline when there is any line).
    public var result: String {
        let l = layout().lines
        return l.isEmpty ? "" : l.joined(separator: "\n") + "\n"
    }

    /// The three sides' full texts, rebuilt from the chunks.
    public var oursText: String { Self.text(chunks.flatMap(\.ours)) }
    public var theirsText: String { Self.text(chunks.flatMap(\.theirs)) }
    public var baseText: String { Self.text(chunks.flatMap(\.base)) }
    static func text(_ l: [String]) -> String { l.isEmpty ? "" : l.joined(separator: "\n") + "\n" }

    /// Where a hunk starts on each side (0-based line), for scrolling the
    /// columns to it.
    public func sideStarts(forHunk h: Int) -> (base: Int, ours: Int, theirs: Int) {
        var b = 0, o = 0, t = 0
        for c in chunks[..<hunks[h]] { b += c.base.count; o += c.ours.count; t += c.theirs.count }
        return (b, o, t)
    }
}
