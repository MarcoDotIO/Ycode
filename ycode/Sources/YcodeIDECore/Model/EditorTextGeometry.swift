import Foundation

/// Council round 4 (`specs/ide/editor-area.md` F.1, F.2, F.4, F.6;
/// `fidelity-council.md` rows 83, 84, 87, 88): how wrapped rows break, the
/// cell advance at the backing scale, and where a block element's ink sits
/// in its row. Shared by the AppKit editor and the Linux IDE.
public enum EditorTextGeometry {
    // MARK: Cell advance (F.2, row 84)

    /// The cell advance for a font whose own advance is `fontAdvance`, on
    /// a display with `backingScale` device pixels per point: at 2x and
    /// above the font's own, unrounded advance (8.04 at 13 points), so
    /// glyph edges may fall between device pixels; below that, rounded to
    /// whole device pixels (8.0 at 1x).
    public static func cellAdvance(fontAdvance: Double, backingScale: Double) -> Double {
        guard fontAdvance > 0 else { return 1 }
        if backingScale >= 2 { return fontAdvance }
        let s = max(1, backingScale)
        return max(1 / s, (fontAdvance * s).rounded() / s)
    }

    // MARK: Word wrap (F.1, F.6; rows 83, 88)

    /// The offsets (from the line's start) where the line's continuation
    /// rows start, for a line of `length` cells. The first row holds
    /// `firstColumns` cells, every continuation row `continuationColumns`
    /// (the container less the continuation indent).
    ///
    /// - A run with no break opportunity is one word. A word that does not
    ///   fit the rest of the row starts the next row; only a word that does
    ///   not fit an empty row is broken, after its last cell that fits.
    /// - The white space after a word must fit too before the next word may
    ///   start on the same row ("0: a" / "comment" when "comment " would end
    ///   past the container). White space at the line's end may hang.
    ///
    /// `isSpace(i)` tells white space; `lastOpportunity(start, limit)` is
    /// the largest offset `b` with `start < b <= limit` before which the
    /// line may break, or nil.
    public static func rowStarts(length n: Int, firstColumns: Int, continuationColumns: Int,
                                 isSpace: (Int) -> Bool, lastOpportunity: (Int, Int) -> Int?) -> [Int] {
        var out: [Int] = []
        var start = 0
        var columns = max(1, firstColumns)
        while n - start > columns {
            let limit = start + columns
            // Only white space left: it hangs past the edge.
            if (limit..<n).allSatisfy(isSpace) { break }
            if let b = lastOpportunity(start, limit), b > start, b <= limit {
                start = b
            } else {
                start = limit
            }
            out.append(start)
            columns = max(1, continuationColumns)
        }
        return out
    }

    /// `rowStarts` over characters, with the opportunities of UAX #14 that
    /// matter for source text, as the macOS text system finds them
    /// (`isBreakOpportunity`); a toolkit with the full rules passes its own.
    public static func rowStarts(of line: [Character], firstColumns: Int, continuationColumns: Int) -> [Int] {
        func space(_ i: Int) -> Bool { line[i] == " " || line[i] == "\t" }
        return rowStarts(length: line.count, firstColumns: firstColumns, continuationColumns: continuationColumns, isSpace: space) { start, limit in
            var b = min(limit, line.count - 1)
            while b > start {
                if isBreakOpportunity(before: b, in: line) { return b }
                b -= 1
            }
            return nil
        }
    }

    /// Whether a line may break before `b` (UAX #14, the rules source text
    /// meets; `cross-platform-parity.md` §4: the Linux editor wraps where
    /// the macOS one does):
    /// - after white space (LB18), but never before closing punctuation, an
    ///   exclamation or question mark, an infix separator or a slash
    ///   (LB13: `}` `)` `]` `!` `?` `,` `.` `:` `;` `/` stay on the row);
    /// - after a hyphen before a letter or digit (LB21);
    /// - between a backslash and an opening bracket (a prefix before an
    ///   opening punctuation that does not start a number, LB25/LB31: the
    ///   `\(` of a string interpolation).
    public static func isBreakOpportunity(before b: Int, in line: [Character]) -> Bool {
        guard b > 0, b < line.count else { return false }
        let prev = line[b - 1], next = line[b]
        func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" }
        if isSpace(next) { return false }
        if "}])!?,.:;/".contains(next) { return false }
        if isSpace(prev) { return true }
        if prev == "-", next.isLetter || next.isNumber { return b >= 2 && !isSpace(line[b - 2]) }
        if prev == "\\", "([{".contains(next) { return true }
        return false
    }

    // MARK: Block elements (F.1, F.4; row 87)

    /// A full block's ink in its row: 13.5 of the 18-point pitch at 13
    /// points, its top 3.5 below the row's top and its bottom 1 above the
    /// row's bottom, scaled with the pitch. Relative to the row's top.
    public static func blockInk(rowHeight: Double) -> (top: Double, height: Double) {
        let k = rowHeight / 18
        return (3.5 * k, 13.5 * k)
    }

    /// Whether a character is a block element drawn as a filled shape
    /// (U+2580–U+2590, U+2594, U+2595): runs of them join with no seam.
    /// The shades (U+2591–U+2593) and the quadrants stay glyphs.
    public static func isSolidBlock(_ v: UInt32) -> Bool {
        (0x2580...0x2590).contains(v) || v == 0x2594 || v == 0x2595
    }

    /// The part of a cell's ink box (`x`, `width` across the cells, `top`,
    /// `height` from `blockInk`) a solid block element fills, as
    /// (x, y, width, height) in the same coordinates (y down).
    public static func blockShape(_ v: UInt32, x: Double, width: Double, top: Double, height: Double)
        -> (x: Double, y: Double, width: Double, height: Double)? {
        switch v {
        case 0x2580: return (x, top, width, height / 2)
        case 0x2581...0x2588:
            let h = height * Double(v - 0x2580) / 8
            return (x, top + height - h, width, h)
        case 0x2589...0x258F: return (x, top, width * Double(0x2590 - v) / 8, height)
        case 0x2590: return (x + width / 2, top, width / 2, height)
        case 0x2594: return (x, top, width, height / 8)
        case 0x2595: return (x + width * 7 / 8, top, width / 8, height)
        default: return nil
        }
    }
}
