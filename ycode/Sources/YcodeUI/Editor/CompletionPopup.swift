import AppKit
import YcodeIDECore
import YcodeLanguage

/// The popup view: up to eight rows (kind letter, label, detail) drawn
/// directly, the selected row highlighted, and an optional documentation
/// line at the bottom.
@MainActor
final class CompletionPopupView: NSView {
    var model = CompletionModel() { didSet { keepSelectionVisible(); needsDisplay = true } }
    var onAccept: (() -> Void)?
    /// The text the last edit inserted at an empty selection (one keystroke
    /// when it is one character); nil for other edits. Read by the trigger.
    var lastTyped: String?
    static let rowHeight: CGFloat = 20
    static let maxRows = 8
    static let docHeight: CGFloat = 22
    static let padding: CGFloat = 3
    /// Index of the first row shown.
    private(set) var firstVisible = 0

    /// Height for the visible rows plus the documentation line, if any.
    static func height(rows: Int, hasDoc: Bool) -> CGFloat {
        CGFloat(min(rows, maxRows)) * rowHeight + 2 * padding + (hasDoc ? docHeight : 0)
    }

    var hasDoc: Bool { !(model.current?.documentation ?? "").isEmpty }

    override var isFlipped: Bool { true }

    private func keepSelectionVisible() {
        if model.selected < firstVisible { firstVisible = model.selected }
        if model.selected >= firstVisible + Self.maxRows { firstVisible = model.selected - Self.maxRows + 1 }
        firstVisible = max(0, min(firstVisible, max(0, model.visible.count - Self.maxRows)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let end = min(model.visible.count, firstVisible + Self.maxRows)
        for i in firstVisible..<max(firstVisible, end) {
            let row = NSRect(x: 2, y: Self.padding + CGFloat(i - firstVisible) * Self.rowHeight, width: bounds.width - 4, height: Self.rowHeight)
            let selected = i == model.selected
            if selected {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: row, xRadius: 4, yRadius: 4).fill()
            }
            let item = model.visible[i]
            let s = NSMutableAttributedString(string: Self.kindLetter(item.kind) + "  ", attributes: [
                .font: Theme.boldFont, .foregroundColor: selected ? NSColor.white : NSColor.systemPurple])
            s.append(NSAttributedString(string: item.label, attributes: [
                .font: Theme.font, .foregroundColor: selected ? NSColor.white : NSColor.labelColor]))
            if let d = item.detail {
                s.append(NSAttributedString(string: "  " + d, attributes: [
                    .font: Theme.font, .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor]))
            }
            let h = s.size().height
            s.draw(with: NSRect(x: row.minX + 6, y: row.midY - h / 2, width: row.width - 12, height: h),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if hasDoc, let doc = model.current?.documentation {
            let top = bounds.height - Self.docHeight
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: top, width: bounds.width, height: 1).fill()
            let text = NSAttributedString(string: doc.replacingOccurrences(of: "\n", with: " "), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            let h = text.size().height
            text.draw(with: NSRect(x: 8, y: top + (Self.docHeight - h) / 2, width: bounds.width - 16, height: h),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// The row index under a point, if any.
    func row(at p: NSPoint) -> Int? {
        let i = firstVisible + Int(floor((p.y - Self.padding) / Self.rowHeight))
        return p.y >= Self.padding && i < min(model.visible.count, firstVisible + Self.maxRows) ? i : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = row(at: convert(event.locationInWindow, from: nil)) else { return }
        model.selected = i
        if event.clickCount >= 2 { onAccept?() }
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.scrollingDeltaY > 0 ? -1 : (event.scrollingDeltaY < 0 ? 1 : 0)
        firstVisible = max(0, min(firstVisible + step, max(0, model.visible.count - Self.maxRows)))
        needsDisplay = true
    }

    /// LSP CompletionItemKind → one letter (our own badge style).
    static func kindLetter(_ kind: Int?) -> String {
        switch kind {
        case 2, 3, 4: "M"     // method, function, constructor
        case 5, 10: "P"       // field, property
        case 6: "V"           // variable
        case 7: "C"           // class
        case 8: "R"           // interface/protocol
        case 9: "K"           // module
        case 13: "E"          // enum
        case 14: "K"          // keyword
        case 20: "e"          // enum member
        case 22: "S"          // struct
        default: "·"
        }
    }
}

// MARK: Opening the list while typing (P-080)

extension SourceEditorController {
    /// Notes an edit for the trigger: what was typed at an empty selection.
    func noteEditForCompletion(range: NSRange, replacement: String) {
        completionPopup.lastTyped = range.length == 0 ? replacement : nil
    }

    /// After a keystroke: asks for completions when it starts a word or is
    /// a "." in Swift (`CompletionTrigger`, shared with the Linux editor),
    /// in Swift and the C family; while the word grows, asks again when the
    /// list was incomplete. Undo, paste and deletions never ask.
    func requestCompletionWhileTyping() {
        guard let typed = completionPopup.lastTyped, [.swift, .objc, .c, .cpp].contains(language) else { return }
        completionPopup.lastTyped = nil
        let caret = textView.selectedRange().location
        let ns = textView.string as NSString
        guard textView.selectedRange().length == 0, caret > 0, caret <= ns.length else { return }
        // The list shown (or emptied by filtering) is for this word: ask
        // again only when the server said it was incomplete.
        let start = CompletionModel.wordStart(in: ns, before: caret)
        let m = completionPopup.model
        let sameWord = !m.all.isEmpty && m.wordStart == start && caret - start > 1
        if isShowingCompletions || sameWord {
            if sameWord, m.all.first?.fromIncompleteList == true { requestCompletion() }
            return
        }
        let lineStart = ns.lineRange(for: NSRange(location: caret - 1, length: 0)).location
        let line = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        guard CompletionTrigger.kind(typed: typed, lineBeforeCaret: line, memberAccess: language == .swift) != nil else { return }
        requestCompletion()
    }

    /// Whether completions that arrive for `caret`'s word may still show:
    /// the insertion point is in the same word (typing went on while the
    /// server answered; the list is filtered by what was typed).
    func completionStillApplies(wordStart start: Int) -> Bool {
        let sel = textView.selectedRange()
        guard sel.length == 0, sel.location >= start else { return false }
        return CompletionModel.wordStart(in: textView.string as NSString, before: sel.location) == start
    }
}
