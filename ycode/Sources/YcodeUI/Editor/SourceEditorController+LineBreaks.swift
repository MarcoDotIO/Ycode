import AppKit
import YcodeIDECore

/// Wrapping a word longer than a line (`editor-area.md` E.7, checklist
/// row 75): the reference keeps such a word on the line it starts on and
/// breaks it at the container's edge ("// " and the first 76 full blocks
/// of a 110-block band on one row, the rest on the next), where the
/// system's word wrap moved it to a row of its own first. Every other break
/// is the system's.
extension SourceEditorController: NSTextLayoutManagerDelegate {
    public nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, shouldBreakLineBefore location: any NSTextLocation,
                                              hyphenating: Bool) -> Bool {
        guard let storage = (textLayoutManager.textContentManager as? NSTextContentStorage)?.textStorage,
              let width = textLayoutManager.textContainer?.size.width else { return true }
        let advance = wrapSnapshot.advance
        guard advance > 0, width.isFinite, width < 100_000 else { return true }
        let offset = textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: location)
        return EditorLineBreaks.allowsBreak(before: offset, in: storage.string as NSString, columns: Int(width / advance))
    }
}

/// The rule, on the text alone.
public enum EditorLineBreaks {
    /// Whether a line may break before `offset`: not before a word that
    /// would not fit on a line of `columns` by itself anyway.
    public static func allowsBreak(before offset: Int, in text: NSString, columns: Int) -> Bool {
        guard offset > 0, offset < text.length, columns > 0 else { return true }
        func isSpace(_ u: unichar) -> Bool { u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D }
        // Only the break before a word (after white space) is in question.
        guard !isSpace(text.character(at: offset)), isSpace(text.character(at: offset - 1)) else { return true }
        var end = offset
        while end < text.length, !isSpace(text.character(at: end)), end - offset <= columns { end += 1 }
        return end - offset <= columns
    }
}
