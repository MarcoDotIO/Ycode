import Foundation
import YcodeSyntax

/// Characters drawn on the editor's cell grid however wide their face's
/// glyph is (`editor-area.md` E.7: a full block advances one cell, 8.0 at
/// the default size; a narrower glyph is centred in its cell and a wider
/// one clipped). The same set as the macOS editor's.
public enum EditorCellCharacters {
    /// Box Drawing, Block Elements, Geometric Shapes; Braille Patterns.
    public static func isCell(_ v: UInt32) -> Bool { (0x2500...0x25FF).contains(v) || (0x2800...0x28FF).contains(v) }

    public static func isCell(_ c: Character) -> Bool {
        c.unicodeScalars.count == 1 && isCell(c.unicodeScalars.first!.value)
    }

    /// Whether `s` has any cell character.
    public static func contains(_ s: String) -> Bool { s.unicodeScalars.contains { isCell($0.value) } }
}

/// One colored stretch of a drawn line.
public struct EditorRun: Equatable, Sendable {
    public var text: String
    public var role: SyntaxTokenKind.Role?
    public init(_ text: String, role: SyntaxTokenKind.Role? = nil) {
        self.text = text
        self.role = role
    }
}

/// A line as it is drawn: tabs become spaces up to the next tab stop.
public struct EditorDisplayLine: Equatable, Sendable {
    public var runs: [EditorRun]
    /// The drawn text starts this many columns into the line (a very long
    /// ASCII line draws only the columns in view).
    public var firstColumn: Int
    public init(runs: [EditorRun], firstColumn: Int = 0) {
        self.runs = runs
        self.firstColumn = firstColumn
    }
}

extension EditorDisplayLine {
    /// The runs before and after a drawn column.
    public func split(atColumn column: Int) -> (before: [EditorRun], after: [EditorRun]) {
        var before: [EditorRun] = [], after: [EditorRun] = []
        var left = column
        for r in runs {
            let n = r.text.count
            if left >= n {
                before.append(r)
                left -= n
            } else if left <= 0 {
                after.append(r)
            } else {
                before.append(EditorRun(String(r.text.prefix(left)), role: r.role))
                after.append(EditorRun(String(r.text.dropFirst(left)), role: r.role))
                left = 0
            }
        }
        return (before, after)
    }
}

/// Maps offsets to x positions and back, and builds the drawn lines. Text is
/// monospaced, so ASCII lines need no measuring; other characters' widths come
/// from `characterWidth` (the view measures them once per character; shaping
/// that changes widths between neighbours, as in Arabic, is not modelled).
public final class EditorLineLayout {
    public var tabWidth: Int
    /// The width of one cell of the monospaced font.
    public var advance: CGFloat
    private let characterWidth: (Character) -> CGFloat
    private var widths: [Character: CGFloat] = [:]

    /// Lines longer than this draw only what is in view (ASCII) or their
    /// beginning (other text): shaping megabytes per frame would hang.
    public static let longLine = 4096

    public init(tabWidth: Int = 4, advance: CGFloat = 7, characterWidth: @escaping (Character) -> CGFloat = { _ in 7 }) {
        self.tabWidth = max(1, tabWidth)
        self.advance = advance
        self.characterWidth = characterWidth
    }

    /// Forgets measured widths (the font changed).
    public func reset(advance: CGFloat) {
        self.advance = advance
        widths = [:]
    }

    /// A character's advance: one cell for ASCII and for the cell
    /// characters (box drawing, block elements, geometric shapes, braille),
    /// whatever face draws them (`editor-area.md` E.7, checklist row 75);
    /// other characters their measured width.
    public func width(of c: Character) -> CGFloat {
        if c.isASCII || EditorCellCharacters.isCell(c) { return advance }
        if let w = widths[c] { return w }
        let w = characterWidth(c)
        widths[c] = w
        return w
    }

    /// Whether the units are ASCII without tabs.
    private func isPlain(_ u: ArraySlice<UInt16>) -> Bool {
        u.allSatisfy { $0 < 0x80 && $0 != 9 }
    }

    /// The x of `offset` from the start of its line's text.
    public func x(ofOffset offset: Int, in buffer: EditorBuffer) -> CGFloat {
        x(ofOffset: offset, line: buffer.document.line(containing: offset), in: buffer)
    }

    public func x(ofOffset offset: Int, line n: Int, in buffer: EditorBuffer) -> CGFloat {
        let doc = buffer.document
        let r = doc.lineRange(n)
        let end = min(max(offset, r.lowerBound), r.upperBound)
        let u = doc.units[r.lowerBound..<end]
        if isPlain(u) { return CGFloat(u.count) * advance }
        var x: CGFloat = 0
        var column = 0
        var at = r.lowerBound
        for c in String(decoding: doc.units[r], as: UTF16.self) {
            if at >= end { break }
            if c == "\t" {
                let k = tabWidth - column % tabWidth
                x += CGFloat(k) * advance
                column += k
            } else {
                x += width(of: c)
                column += 1
            }
            at += c.utf16.count
        }
        return x
    }

    /// The offset nearest to `x` on line `n`.
    public func offset(atX x: CGFloat, line n: Int, in buffer: EditorBuffer) -> Int {
        let doc = buffer.document
        let r = doc.lineRange(n)
        let u = doc.units[r]
        if isPlain(u) {
            let c = Int((x / advance).rounded())
            return r.lowerBound + min(max(c, 0), u.count)
        }
        var pos: CGFloat = 0
        var column = 0
        var at = r.lowerBound
        for c in String(decoding: u, as: UTF16.self) {
            let w: CGFloat
            if c == "\t" {
                let k = tabWidth - column % tabWidth
                w = CGFloat(k) * advance
                column += k
            } else {
                w = width(of: c)
                column += 1
            }
            if x < pos + w / 2 { return at }
            pos += w
            at += c.utf16.count
        }
        return r.upperBound
    }

    /// The width of some text without tabs.
    public func width(ofText s: String) -> CGFloat {
        s.reduce(0) { $0 + width(of: $1) }
    }

    /// The column of `offset` in the drawn line (tabs expanded).
    public func displayColumn(ofOffset offset: Int, line n: Int, in buffer: EditorBuffer) -> Int {
        let doc = buffer.document
        let r = doc.lineRange(n)
        var column = 0
        var at = r.lowerBound
        for c in String(decoding: doc.units[r], as: UTF16.self) {
            if at >= offset { break }
            column += c == "\t" ? tabWidth - column % tabWidth : 1
            at += c.utf16.count
        }
        return column
    }

    /// The width of line `n`.
    public func width(ofLine n: Int, in buffer: EditorBuffer) -> CGFloat {
        let r = buffer.document.lineRange(n)
        return x(ofOffset: r.upperBound, line: n, in: buffer)
    }

    /// The runs to draw for line `n`. `columns` limits a long ASCII line to
    /// the columns in view.
    public func displayLine(_ n: Int, in buffer: EditorBuffer, columns: Range<Int>? = nil) -> EditorDisplayLine {
        let doc = buffer.document
        var line = doc.lineRange(n)
        var firstColumn = 0
        let units = doc.units
        if line.count > Self.longLine {
            if isPlain(units[line]), let columns {
                firstColumn = max(0, columns.lowerBound)
                let a = min(line.lowerBound + firstColumn, line.upperBound)
                line = a..<min(a + max(columns.count, 0), line.upperBound)
            } else {
                line = line.lowerBound..<min(line.lowerBound + Self.longLine, line.upperBound)
            }
        }
        var out: [EditorRun] = []
        var column = firstColumn
        func add(_ r: Range<Int>, _ role: SyntaxTokenKind.Role?) {
            guard !r.isEmpty else { return }
            let s = expandTabs(String(decoding: units[r], as: UTF16.self), column: &column)
            if let last = out.last, last.role == role {
                out[out.count - 1].text += s
            } else {
                out.append(EditorRun(s, role: role))
            }
        }
        var at = line.lowerBound
        for t in doc.tokens(onLine: n).sorted(by: { $0.location < $1.location }) {
            let a = max(t.location, at), b = min(t.end, line.upperBound)
            guard a < b else { continue }
            add(at..<a, nil)
            add(a..<b, t.kind.role == .identifier ? nil : t.kind.role)
            at = b
        }
        add(at..<line.upperBound, nil)
        return EditorDisplayLine(runs: out, firstColumn: firstColumn)
    }

    func expandTabs(_ s: String, column: inout Int) -> String {
        guard s.contains("\t") else {
            column += s.count
            return s
        }
        var out = ""
        for ch in s {
            if ch == "\t" {
                let n = tabWidth - column % tabWidth
                out += String(repeating: " ", count: n)
                column += n
            } else {
                out.append(ch)
                column += 1
            }
        }
        return out
    }

    /// The longest line's width over a whole buffer.
    public func maxLineWidth(in buffer: EditorBuffer) -> CGFloat {
        var longest: CGFloat = 0
        let doc = buffer.document
        for n in 0..<doc.lineCount {
            let r = doc.lineRange(n)
            // A line can't be wider than its units at two cells each, tabs at a tab stop each.
            if CGFloat(r.count) * advance * CGFloat(max(2, tabWidth)) <= longest { continue }
            longest = max(longest, width(ofLine: n, in: buffer))
        }
        return longest
    }
}
