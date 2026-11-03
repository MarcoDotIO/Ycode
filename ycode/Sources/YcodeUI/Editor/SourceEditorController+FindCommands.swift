import AppKit
import YcodeIDECore

/// The Find menu's in-file items beyond the find bar's own
/// (`specs/ide/reference-ui-5.md` §2.5): Find and Select Next / Previous,
/// Replace and Find Previous, Use Selection for Replace, Select Next /
/// Previous Occurrence; and selecting a workspace search match.
extension SourceEditorController {
    /// Selects a match of the workspace search (clamped to the text).
    public func selectFindMatch(_ range: NSRange) {
        _ = view
        let len = (textView.string as NSString).length
        let r = NSRange(location: min(range.location, len), length: max(0, min(range.length, len - min(range.location, len))))
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
    }

    // MARK: Find menu

    @objc public func findAndSelectNext(_ sender: Any?) { findAndSelect(forward: true) }
    @objc public func findAndSelectPrevious(_ sender: Any?) { findAndSelect(forward: false) }

    /// Find and Select Next / Previous: the next find-bar match after the
    /// selection (before it, going back), wrapping, added to the selection.
    public func findAndSelect(forward: Bool) {
        if find.matches.isEmpty { findChanged() }
        addToSelection(find.matches, forward: forward)
    }

    @objc public func selectNextOccurrence(_ sender: Any?) { selectOccurrence(forward: true) }
    @objc public func selectPreviousOccurrence(_ sender: Any?) { selectOccurrence(forward: false) }

    /// Select Next / Previous Occurrence: the next occurrence of the
    /// selected text (exact case), added to the selection. With only an
    /// insertion point, the word around it is selected first.
    public func selectOccurrence(forward: Bool) {
        _ = view
        let ns = textView.string as NSString
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard let anchor = forward ? ranges.last : ranges.first else {
            let r = Self.wordRange(in: ns, at: textView.selectedRange().location)
            if r.length > 0 { textView.setSelectedRange(r) } else { NSSound.beep() }
            return
        }
        let needle = ns.substring(with: anchor)
        var all: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, options: [.literal], range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { break }
            all.append(r)
            from = r.location + max(1, r.length)
        }
        addToSelection(all, forward: forward)
    }

    func addToSelection(_ candidates: [NSRange], forward: Bool) {
        let ranges = textView.selectedRanges.map(\.rangeValue)
        let chosen = Set(ranges.filter { $0.length > 0 }.map { "\($0.location):\($0.length)" })
        let free = candidates.filter { !chosen.contains("\($0.location):\($0.length)") }
        guard !free.isEmpty else { NSSound.beep(); return }
        let next: NSRange
        if forward {
            let end = ranges.map { NSMaxRange($0) }.max() ?? 0
            next = free.first { $0.location >= end } ?? free[0]
        } else {
            let start = ranges.map(\.location).min() ?? 0
            next = free.last { NSMaxRange($0) <= start } ?? free[free.count - 1]
        }
        let kept = ranges.filter { $0.length > 0 }
        textView.setSelectedRanges((kept + [next]).sorted { $0.location < $1.location }.map { NSValue(range: $0) },
                                   affinity: .downstream, stillSelecting: false)
        textView.scrollRangeToVisible(next)
    }

    @objc public func replaceAndFindPrevious(_ sender: Any?) {
        replaceCurrent()
        findStep(forward: false)
    }

    /// Use Selection for Replace (⇧⌘E): the selection becomes the
    /// replacement text.
    @objc public func useSelectionForReplace(_ sender: Any?) {
        _ = view
        let sel = textView.selectedRange()
        guard sel.length > 0 else { NSSound.beep(); return }
        findBar.replaceField.stringValue = (textView.string as NSString).substring(with: sel)
    }

    /// The find bar's replacement text (tests).
    public var findBarReplacement: String { findBar.replaceField.stringValue }

    static func wordRange(in ns: NSString, at offset: Int) -> NSRange {
        func isWord(_ c: unichar) -> Bool {
            guard let s = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(s) || c == 95
        }
        var a = min(offset, ns.length), b = a
        while a > 0, isWord(ns.character(at: a - 1)) { a -= 1 }
        while b < ns.length, isWord(ns.character(at: b)) { b += 1 }
        return NSRange(location: a, length: b - a)
    }
}
