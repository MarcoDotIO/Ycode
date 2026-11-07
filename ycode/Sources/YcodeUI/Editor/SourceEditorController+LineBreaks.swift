import AppKit
import YcodeIDECore

/// Where wrapped lines break (`editor-area.md` F.1 and F.6, checklist rows
/// 83 and 88; this supersedes E.7's row 75). The rows come from
/// `EditorTextGeometry.rowStarts` with the text system's own break
/// opportunities (`NSAttributedString.lineBreak(before:within:)`, UAX #14):
/// a run with no opportunity (a run of full blocks) is one word and starts
/// the next row when it does not fit the rest of this one; only a word
/// longer than an empty row breaks inside; and the space after a word
/// must fit before the next word starts on the row. TextKit proposes each
/// break; the editor allows only the rule's.
extension SourceEditorController: NSTextLayoutManagerDelegate {
    public nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, shouldBreakLineBefore location: any NSTextLocation,
                                              hyphenating: Bool) -> Bool {
        guard let storage = (textLayoutManager.textContentManager as? NSTextContentStorage)?.textStorage,
              let container = textLayoutManager.textContainer else { return true }
        let snap = wrapSnapshot
        let width = container.size.width - 2 * container.lineFragmentPadding
        guard snap.advance > 0, width.isFinite, width < 100_000 else { return true }
        let offset = textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: location)
        return lineBreaks.allowsBreak(before: offset, in: storage, width: width, advance: snap.advance,
                                      indents: snap.wraps, tabWidth: snap.tabWidth)
    }
}

/// The rule on a text alone, with the last paragraph's rows remembered
/// (TextKit asks several times per row).
public final class EditorLineBreaks: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (text: String, width: CGFloat, advance: CGFloat, indents: Bool, tabWidth: Int, starts: Set<Int>)?

    public init() {}

    /// Lines longer than this keep the text system's breaks.
    public static let longest = 4096

    /// Whether a wrapped line may break before `offset` (in `text`) in a
    /// container `width` wide with cells `advance` wide; `indents`:
    /// continuation rows start four columns past the line's indentation.
    public func allowsBreak(before offset: Int, in text: NSAttributedString, width: CGFloat, advance: CGFloat,
                            indents: Bool, tabWidth: Int) -> Bool {
        let ns = text.string as NSString
        guard offset > 0, offset < ns.length, advance > 0 else { return true }
        var para = ns.paragraphRange(for: NSRange(location: offset, length: 0))
        while para.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(para) - 1)) { para.length -= 1 }
        guard offset > para.location, offset < NSMaxRange(para), para.length <= Self.longest else { return true }
        let line = ns.substring(with: para)
        lock.lock()
        defer { lock.unlock() }
        if let c = cached, c.width == width, c.advance == advance, c.indents == indents, c.tabWidth == tabWidth, c.text == line {
            return c.starts.contains(offset - para.location)
        }
        guard let starts = Self.rowStarts(line, in: text, at: para.location, width: width, advance: advance,
                                          indents: indents, tabWidth: tabWidth) else { return true }
        cached = (line, width, advance, indents, tabWidth, Set(starts))
        return starts.contains(offset - para.location)
    }

    /// The continuation rows' starts of `line` (at `location` in `text`), or
    /// nil when the line is not on the cell grid (tabs, or characters
    /// wider or narrower than a cell): those keep the text system's breaks.
    static func rowStarts(_ line: String, in text: NSAttributedString, at location: Int, width: CGFloat, advance: CGFloat,
                          indents: Bool, tabWidth: Int) -> [Int]? {
        let units = Array(line.utf16)
        guard units.allSatisfy({ $0 != 9 && ($0 < 0x0300 || Theme.isCellCharacter($0)) }) else { return nil }
        let indent = indents ? EditorMetrics.wrappedIndent(of: Substring(line), tabWidth: tabWidth) : 0
        let first = Int((width + 0.01) / advance)
        let rest = Int((width - CGFloat(indent) * advance + 0.01) / advance)
        let whole = NSRange(location: location, length: units.count)
        return EditorTextGeometry.rowStarts(length: units.count, firstColumns: first, continuationColumns: rest,
                                            isSpace: { units[$0] == 32 }) { start, limit in
            // The break before `limit` itself counts: ask before the next.
            let range = NSRange(location: location + start, length: NSMaxRange(whole) - location - start)
            let b = text.lineBreak(before: location + min(limit + 1, units.count), within: range)
            return b == NSNotFound ? nil : b - location
        }
    }
}
