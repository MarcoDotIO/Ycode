import Foundation
import YcodeSyntax

/// How far a caret movement or a deletion reaches.
public enum EditorMovement: Equatable, Hashable, Sendable {
    /// One user-perceived character (grapheme cluster).
    case character
    /// To the next or previous word boundary: words are letters, digits and
    /// underscores; any other non-space run is its own word.
    case word
    /// To the line's start (the first non-blank first, then column 0) or end.
    case line
    /// To the line's very start or end.
    case hardLine
    case document
}

extension EditorBuffer {
    // MARK: Character classes

    enum UnitKind { case word, punctuation, space, newline }

    static func kind(_ u: UInt16) -> UnitKind {
        switch u {
        case 10, 13: return .newline
        case 32, 9, 0xA0, 0x3000: return .space
        case 48...57, 65...90, 97...122, 95: return .word
        case 0..<0x80: return .punctuation
        default: return .word
        }
    }

    // MARK: Targets

    /// Where `unit` from `offset` lands.
    public func target(of unit: EditorMovement, from offset: Int, forward: Bool) -> Int {
        let u = document.units
        let o = normalized(offset)
        switch unit {
        case .document:
            return forward ? length : 0
        case .hardLine:
            let r = document.lineRange(document.line(containing: o))
            return forward ? r.upperBound : r.lowerBound
        case .line:
            let r = document.lineRange(document.line(containing: o))
            if forward { return r.upperBound }
            var first = r.lowerBound
            while first < r.upperBound, u[first] == 32 || u[first] == 9 { first += 1 }
            return o == first ? r.lowerBound : first
        case .character:
            return forward ? characterBoundary(after: o) : characterBoundary(before: o)
        case .word:
            return forward ? wordBoundary(after: o) : wordBoundary(before: o)
        }
    }

    /// The offset one grapheme cluster after `o` (a line ending counts as one).
    public func characterBoundary(after o: Int) -> Int {
        let u = document.units
        guard o < u.count else { return u.count }
        let n = document.line(containing: o)
        let r = document.lineRange(n)
        if o >= r.upperBound { return n + 1 < document.lineCount ? document.lineStart(n + 1) : u.count }
        // ASCII followed by ASCII (or the line's end) is a cluster of its own.
        if u[o] < 0x80, o + 1 >= r.upperBound || u[o + 1] < 0x80 { return o + 1 }
        var at = r.lowerBound
        for c in String(decoding: u[r], as: UTF16.self) {
            at += c.utf16.count
            if at > o { return at }
        }
        return r.upperBound
    }

    /// The offset one grapheme cluster before `o`.
    public func characterBoundary(before o: Int) -> Int {
        let u = document.units
        guard o > 0 else { return 0 }
        let n = document.line(containing: o)
        let r = document.lineRange(n)
        if o <= r.lowerBound { return n > 0 ? document.lineRange(n - 1).upperBound : 0 }
        if u[o - 1] < 0x80, o >= u.count || u[o] < 0x80 || o >= r.upperBound { return o - 1 }
        var at = r.lowerBound
        var last = at
        for c in String(decoding: u[r], as: UTF16.self) {
            let next = at + c.utf16.count
            if next >= o { return at }
            last = next
            at = next
        }
        return last
    }

    func wordBoundary(after start: Int) -> Int {
        let u = document.units
        var o = start
        guard o < u.count else { return u.count }
        if Self.kind(u[o]) == .newline { return characterBoundary(after: o) }
        while o < u.count, Self.kind(u[o]) == .space { o += 1 }
        guard o < u.count else { return o }
        let k = Self.kind(u[o])
        if k == .newline { return o }
        while o < u.count, Self.kind(u[o]) == k { o += 1 }
        return o
    }

    func wordBoundary(before start: Int) -> Int {
        let u = document.units
        var o = start
        guard o > 0 else { return 0 }
        if Self.kind(u[o - 1]) == .newline { return characterBoundary(before: o) }
        while o > 0, Self.kind(u[o - 1]) == .space { o -= 1 }
        guard o > 0 else { return 0 }
        let k = Self.kind(u[o - 1])
        if k == .newline { return o }
        while o > 0, Self.kind(u[o - 1]) == k { o -= 1 }
        return o
    }

    // MARK: Moving

    /// Moves the caret. Without `extending`, a selection collapses to its
    /// edge on `.character`.
    public func move(_ unit: EditorMovement, forward: Bool, extending: Bool = false) {
        if !extending, !selection.isEmpty, unit == .character {
            setCaret(forward ? selection.range.upperBound : selection.range.lowerBound)
            return
        }
        let to = target(of: unit, from: selection.head, forward: forward)
        if extending { extendSelection(to: to) } else { setCaret(to) }
    }

    /// Moves the caret `lines` lines down (negative: up), keeping its x.
    public func moveVertically(lines: Int, extending: Bool = false, layout: EditorLineLayout) {
        let keptGoal = goalX
        let from = !extending && !selection.isEmpty ? (lines > 0 ? selection.range.upperBound : selection.range.lowerBound) : selection.head
        let line = document.line(containing: from)
        let x = keptGoal ?? layout.x(ofOffset: from, in: self)
        let target = line + lines
        let to: Int
        if target < 0 {
            to = 0
        } else if target >= lineCount {
            to = length
        } else {
            to = layout.offset(atX: x, line: target, in: self)
        }
        if extending { extendSelection(to: to) } else { setCaret(to) }
        goalX = x
    }

    // MARK: Word and line selection

    /// The word (or run of spaces, or single punctuation mark) at `offset`.
    public func wordRange(at offset: Int) -> Range<Int> {
        let u = document.units
        guard !u.isEmpty else { return 0..<0 }
        let n = document.line(containing: min(max(offset, 0), u.count))
        let line = document.lineRange(n)
        guard !line.isEmpty else { return line }
        var i = min(max(offset, line.lowerBound), line.upperBound - 1)
        // Past the line's end or between a word and a space: the word before.
        if offset >= line.upperBound || (offset > line.lowerBound && Self.kind(u[i]) != .word && Self.kind(u[offset - 1]) == .word) {
            i = max(line.lowerBound, min(offset, line.upperBound) - 1)
        }
        let k = Self.kind(u[i])
        if k == .punctuation { return i..<characterBoundary(after: i) }
        var lo = i, hi = i + 1
        while lo > line.lowerBound, Self.kind(u[lo - 1]) == k { lo -= 1 }
        while hi < line.upperBound, Self.kind(u[hi]) == k { hi += 1 }
        return lo..<hi
    }

    /// The line at `offset`, with its line ending.
    public func lineRangeIncludingEnding(at offset: Int) -> Range<Int> {
        let n = document.line(containing: min(max(offset, 0), length))
        return document.lineStart(n)..<(n + 1 < lineCount ? document.lineStart(n + 1) : length)
    }

    public func selectWord(at offset: Int) {
        let r = wordRange(at: offset)
        setSelection(EditorSelection(anchor: r.lowerBound, head: r.upperBound))
    }

    public func selectLine(at offset: Int) {
        let r = lineRangeIncludingEnding(at: offset)
        setSelection(EditorSelection(anchor: r.lowerBound, head: r.upperBound))
    }

    /// Extends a word or line selection started at `start` to `offset`
    /// (double- and triple-click drags).
    public func extendGranular(from start: Range<Int>, to offset: Int, lines: Bool) {
        let w = lines ? lineRangeIncludingEnding(at: offset) : wordRange(at: offset)
        let lo = min(start.lowerBound, w.lowerBound), hi = max(start.upperBound, w.upperBound)
        setSelection(offset < start.lowerBound ? EditorSelection(anchor: hi, head: lo) : EditorSelection(anchor: lo, head: hi))
    }

    /// Selects the 1-based line `line`, clamped (Jump to Line).
    public func selectLine(number line: Int) {
        let n = min(max(line - 1, 0), lineCount - 1)
        setCaret(document.lineStart(n))
    }
}
