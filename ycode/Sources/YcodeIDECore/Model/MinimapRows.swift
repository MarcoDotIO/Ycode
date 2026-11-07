import Foundation

/// The minimap's bars for one line (`specs/ide/editor-area.md` §C.5, §D.6,
/// G.3; `fidelity-council.md` row 116), shared by the macOS and Linux
/// editors: one row per **visual** row of the text, broken where the text
/// breaks (`EditorTextGeometry.rowStarts`, F.1), so a line that takes three
/// rows in the editor takes three 3-point rows in the minimap.
///
/// A bar is a run of ink in one colour. White space breaks a bar, except
/// inside a token that may hold it (a comment, a string), so a comment is
/// one bar; indentation and white space at a bar's end are never drawn.
public enum MinimapRows {
    public struct Bar<Key: Equatable>: Equatable {
        public var column: Int
        public var length: Int
        public var key: Key
        public init(column: Int, length: Int, key: Key) {
            self.column = column
            self.length = length
            self.key = key
        }
    }

    /// The rows of one line. `chars` is the line with tabs expanded,
    /// `keys[i]` the colour of `chars[i]` and `joins[i]` whether white space
    /// at `i` keeps its bar open; `starts` are the offsets where the
    /// continuation rows start and `indent` their indentation in columns.
    public static func rows<Key: Equatable>(chars: [Character], keys: [Key], joins: [Bool], starts: [Int], indent: Int) -> [[Bar<Key>]] {
        var out: [[Bar<Key>]] = [[]]
        var open: (column: Int, key: Key)?
        var inkEnd = 0
        var rowStart = 0, rowIndent = 0, next = 0
        var leading = true
        func close() {
            if let o = open, inkEnd > o.column { out[out.count - 1].append(Bar(column: o.column, length: inkEnd - o.column, key: o.key)) }
            open = nil
        }
        for i in chars.indices {
            if next < starts.count, i == starts[next] {
                close()
                out.append([])
                rowStart = i
                rowIndent = indent
                next += 1
            }
            let column = rowIndent + i - rowStart
            if chars[i] == " " || chars[i] == "\t" {
                if leading || !joins[i] { close() }
                continue
            }
            leading = false
            if let o = open, o.key != keys[i] { close() }
            if open == nil { open = (column, keys[i]) }
            inkEnd = column + 1
        }
        close()
        return out
    }

    /// The continuation rows of a line for a text `columns` wide: where they
    /// start and their indentation in columns, as the editor indents them.
    public static func wrap(_ chars: [Character], columns: Int, indent: Int) -> (starts: [Int], indent: Int) {
        let cols = max(8, columns)
        return (EditorTextGeometry.rowStarts(of: chars, firstColumns: cols, continuationColumns: max(1, cols - indent)), indent)
    }
}
