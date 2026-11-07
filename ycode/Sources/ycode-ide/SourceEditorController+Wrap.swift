import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore

/// Wrapped lines in the Linux editor (Settings ▸ Editing ▸ Wrap lines to
/// editor width), as the AppKit editor wraps them (`editor-area.md` §C.1,
/// F.1, F.6; checklist rows 83 and 88): the text ends 10 points before the
/// minimap; continuation rows start four columns past the line's own
/// indentation; a run with no break opportunity (a run of full blocks) is
/// one word and starts the next row when it does not fit the rest of this
/// one, broken by character only when it does not fit an empty row; the
/// space after a word must fit before the next word starts on the row.
/// Rows are counted in display columns (tabs expanded), one per character.
@MainActor
final class EditorWrapState {
    /// Settings, read when the preferences change.
    var wraps = true
    var indents = true
    /// What the rows were made for: text revision, columns, tab width.
    fileprivate var key: (revision: Int, columns: Int, tab: Int, indents: Bool)?
    /// The display columns where each wrapped line's continuation rows
    /// start, and those rows' indentation in columns.
    fileprivate var starts: [Int: [Int]] = [:]
    fileprivate var indent: [Int: Int] = [:]
    /// The visual row each line starts on (one more entry: the total).
    fileprivate var firstRow: [Int] = [0, 1]

    func readPreferences() {
        wraps = Preferences.shared.wrapLines
        indents = Preferences.shared.wrappedLineIndent > 0
        key = nil
    }
}

extension SourceEditorController {
    /// The cells a row holds, or nil when lines do not wrap.
    var wrapColumns: Int? {
        guard wrap.wraps, measured, layout.advance > 0 else { return nil }
        let room = viewport.width - textOrigin - CGFloat(EditorMetrics.textToMinimap)
        return room > layout.advance * 8 ? EditorMetrics.wrapColumns(room: Double(room), advance: Double(layout.advance)) : nil
    }

    /// The rows, made again when the text, the width or the settings changed.
    @discardableResult func wrapRows() -> EditorWrapState {
        let w = wrap
        let columns = wrapColumns ?? 0
        let key = (buffer.textRevision, columns, layout.tabWidth, w.indents)
        if let k = w.key, k == key { return w }
        w.key = key
        w.starts = [:]
        w.indent = [:]
        let doc = buffer.document
        let count = doc.lineCount
        var first = [Int](repeating: 0, count: count + 1)
        var row = 0
        let units = doc.units
        let tab = layout.tabWidth
        for n in 0..<count {
            first[n] = row
            row += 1
            guard columns > 0 else { continue }
            let r = doc.lineRange(n)
            if r.count <= columns, r.count * tab <= columns || !units[r].contains(9) { continue }
            if r.count > EditorLineLayout.longLine { continue }
            let text = String(decoding: units[r], as: UTF16.self)
            let chars = Self.expandingTabs(text, tabWidth: tab)
            guard chars.count > columns else { continue }
            let extra = w.indents ? EditorMetrics.wrappedIndent(of: Substring(text), tabWidth: tab) : 0
            // The line's own indentation plus four, as the macOS editor's
            // head indent (no cap: a deep line's rows are narrow there too).
            let indent = extra
            let s = EditorTextGeometry.rowStarts(of: chars, firstColumns: columns, continuationColumns: max(1, columns - indent))
            guard !s.isEmpty else { continue }
            w.starts[n] = s
            w.indent[n] = indent
            row += s.count
        }
        first[count] = row
        w.firstRow = first
        return w
    }

    /// The display columns where line `n`'s continuation rows start.
    func rowStarts(_ n: Int) -> [Int] { wrapRows().starts[n] ?? [] }

    /// Where row `k` (0: the first) of line `n` starts, in points from the
    /// text's left edge.
    func rowIndent(_ n: Int, row k: Int) -> CGFloat {
        k == 0 ? 0 : CGFloat(wrapRows().indent[n] ?? 0) * layout.advance
    }

    /// The visual row line `n` starts on.
    func firstRow(of n: Int) -> Int {
        let f = wrapRows().firstRow
        return f[min(max(0, n), f.count - 1)]
    }

    var visualRowCount: Int { wrapRows().firstRow.last ?? buffer.lineCount }

    /// The line visual row `row` belongs to.
    func line(atRow row: Int) -> Int {
        let f = wrapRows().firstRow
        var lo = 0, hi = max(0, f.count - 2)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if f[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// An offset's row in its line and x from the text's left edge.
    func position(ofOffset offset: Int, line n: Int) -> (row: Int, x: CGFloat) {
        let starts = rowStarts(n)
        guard !starts.isEmpty else { return (0, layout.x(ofOffset: offset, line: n, in: buffer)) }
        let col = layout.displayColumn(ofOffset: offset, line: n, in: buffer)
        let k = starts.lastIndex { $0 <= col }.map { $0 + 1 } ?? 0
        let start = k == 0 ? 0 : starts[k - 1]
        return (k, rowIndent(n, row: k) + CGFloat(col - start) * layout.advance)
    }

    /// The offset at display column `col` of line `n`.
    func offset(atDisplayColumn col: Int, line n: Int) -> Int {
        let r = buffer.document.lineRange(n)
        var column = 0
        var at = r.lowerBound
        for c in String(decoding: buffer.document.units[r], as: UTF16.self) {
            let w = c == "\t" ? layout.tabWidth - column % layout.tabWidth : 1
            if col < column + (w + 1) / 2 { return at }
            column += w
            at += c.utf16.count
        }
        return r.upperBound
    }

    /// The offset under `x` (from the text's left edge) on row `k` of line `n`.
    func offset(atX x: CGFloat, line n: Int, row k: Int) -> Int {
        let starts = rowStarts(n)
        guard !starts.isEmpty else { return layout.offset(atX: x, line: n, in: buffer) }
        let start = k == 0 ? 0 : starts[k - 1]
        let end = k < starts.count ? starts[k] : Int.max
        let col = start + max(0, Int(((x - rowIndent(n, row: k)) / layout.advance).rounded()))
        return offset(atDisplayColumn: min(col, end), line: n)
    }

    /// A line's characters with tabs as spaces to the next stop.
    static func expandingTabs(_ s: String, tabWidth: Int) -> [Character] {
        var out: [Character] = []
        for ch in s {
            if ch == "\t" {
                out += Array(repeating: " ", count: tabWidth - out.count % max(1, tabWidth))
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
