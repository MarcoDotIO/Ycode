import Foundation

/// Documentation comments in the source editor (P-054,
/// `specs/ide/parity-inventory.md`): the text after `///` (and inside
/// `/** … */`) is drawn in the proportional system face at the source
/// font's size, in the theme's doc-comment colour (the comment grey in the
/// default theme); the delimiters stay in the source font, so a comment's
/// text starts in the code's column. One rule for both IDEs: the macOS
/// editor's `Theme`, the Linux editor's `EditorLineLayout`.
public enum EditorDocCommentStyle {
    /// The proportional face's size: the source font's.
    public static func pointSize(sourceSize: Double) -> Double { sourceSize }

    /// The delimiters of a documentation comment token (or of one line's
    /// piece of a block comment) at `token` in `text`: each line's `///`,
    /// a block's `/**` and its closing `*/`.
    public static func delimiters(in text: NSString, token: NSRange) -> [NSRange] {
        guard token.location >= 0, token.length > 0, NSMaxRange(token) <= text.length else { return [] }
        let s = text.substring(with: token) as NSString
        var out: [NSRange] = []
        var lineComment = false
        // `///` after each line's leading blanks.
        var i = 0
        while i < s.length {
            var j = i
            while j < s.length, [32, 9].contains(s.character(at: j)) { j += 1 }
            if j + 3 <= s.length, s.substring(with: NSRange(location: j, length: 3)) == "///" {
                out.append(NSRange(location: token.location + j, length: 3))
                lineComment = true
            } else if i == 0, j + 3 <= s.length, s.substring(with: NSRange(location: j, length: 3)) == "/**" {
                out.append(NSRange(location: token.location + j, length: 3))
            }
            let newline = s.range(of: "\n", range: NSRange(location: i, length: s.length - i))
            guard newline.location != NSNotFound else { break }
            i = NSMaxRange(newline)
        }
        // A block's end (in its last line's piece too).
        var end = s.length
        while end > 0, [10, 13, 32, 9].contains(s.character(at: end - 1)) { end -= 1 }
        if !lineComment, end >= 2, s.substring(with: NSRange(location: end - 2, length: 2)) == "*/",
           out.last.map({ NSMaxRange($0) <= token.location + end - 2 }) ?? true {
            out.append(NSRange(location: token.location + end - 2, length: 2))
        }
        return out
    }

    /// The text ranges of a documentation comment token drawn in the
    /// proportional face: the token without its delimiters.
    public static func proportionalRanges(in text: NSString, token: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var at = token.location
        for d in delimiters(in: text, token: token) {
            if d.location > at { out.append(NSRange(location: at, length: d.location - at)) }
            at = NSMaxRange(d)
        }
        if NSMaxRange(token) > at { out.append(NSRange(location: at, length: NSMaxRange(token) - at)) }
        return out
    }
}
