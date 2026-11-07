import Foundation
import YcodeEditorKit
import YcodeIDECore
import YcodeSyntax

/// The minimap's rows (`MinimapRows`; `editor-area.md` G.3, row 116): one
/// per visual row of the text, broken where the editor breaks it
/// (+Wrap.swift), in the tokens' roles. A line's bars are made when the
/// minimap first draws it and kept until the text, the wrap width or the
/// highlighting changes, so opening a long file costs only the rows in view
/// (row 136).
extension SourceEditorController {
    typealias MinimapBars = [[MinimapRows.Bar<SyntaxTokenKind.Role?>]]

    /// The minimap's row count: the text's visual rows.
    var minimapRowCount: Int { visualRowCount }

    /// The bars of visual row `row`.
    func minimapBars(row: Int) -> [MinimapRows.Bar<SyntaxTokenKind.Role?>] {
        let n = line(atRow: row)
        let k = row - firstRow(of: n)
        let rows = minimapBars(line: n)
        return k < rows.count ? rows[k] : []
    }

    /// The bars of line `n`, one array per visual row.
    func minimapBars(line n: Int) -> MinimapBars {
        let key = [buffer.textRevision, wrapColumns ?? 0, layout.tabWidth, highlightGeneration, wrap.indents ? 1 : 0]
        if minimapCache?.key != key { minimapCache = (key, [:]) }
        if let rows = minimapCache?.lines[n] { return rows }
        var chars: [Character] = []
        var keys: [SyntaxTokenKind.Role?] = []
        var joins: [Bool] = []
        for r in layout.displayLine(n, in: buffer).runs {
            // White space inside a comment or a string keeps its bar.
            let joined = r.role != nil
            for ch in r.text {
                chars.append(ch)
                keys.append(r.role)
                joins.append(joined)
            }
        }
        let starts = rowStarts(n)
        let indent = starts.isEmpty ? 0 : Int((rowIndent(n, row: 1) / max(1, layout.advance)).rounded())
        let rows = MinimapRows.rows(chars: chars, keys: keys, joins: joins, starts: starts, indent: indent)
        minimapCache?.lines[n] = rows
        return rows
    }
}
