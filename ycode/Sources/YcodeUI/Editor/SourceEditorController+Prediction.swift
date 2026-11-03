import AppKit
import YcodeCompletion
import YcodeIDECore

/// The suggestion drawn after the caret (grey ghost text).
struct GhostText: Equatable {
    var anchor: Int
    var text: String
    /// Option is held: every line shows, not only the first.
    var expanded: Bool
}

/// The editor's predictive completion state (specs/ide/predictive-completion.md §3).
@MainActor
final class PredictionState {
    let session = PredictionSession()
    /// The edit between `shouldChangeText` and `textDidChange`.
    var pendingEdit: (location: Int, removed: Int, inserted: String)?
    /// More than one edit arrived before the change notification.
    var severalEdits = false
    var expanded = false
    var settingsOverride: PredictiveCompletionSettings?
}

// Predictive code completion in the source editor: the session follows
// edits and caret moves; Tab accepts what is shown (⌥Tab all, ⌃Tab the
// next word), Escape dismisses, ⌥ shows every line; Show Predictive
// Completion (⌃⌥Space) asks at once.
extension SourceEditorController {
    var prediction: PredictionSession { predictionState.session }

    /// The suggestion shown, if any (tests).
    public var predictionSuggestion: PredictionSession.Suggestion? { prediction.suggestion }
    /// What the editor draws: the collapsed or expanded ghost text (tests).
    public var shownPredictionText: String? {
        textView.ghostText.map { $0.expanded ? $0.text : PredictionSession.collapsed($0.text) }
    }
    /// The session (tests and the window read its status).
    public var predictionSession: PredictionSession { prediction }

    func setUpPrediction() {
        prediction.onSuggestionChange = { [weak self] s in self?.showPrediction(s) }
        prediction.onStatusChange = { [weak self] s in self?.onPredictionStatus?(s) }
        applyPredictionPreferences()
    }

    func applyPredictionPreferences() {
        let p = Preferences.shared
        prediction.assistantOllamaURL = p.sharedOllamaURL
        prediction.settings = predictionState.settingsOverride ?? p.predictiveCompletion
    }

    /// Settings that replace the user's for this editor (tests: other suites
    /// swap `Preferences.shared` while they run). Nil: the user's settings.
    public var predictionSettingsOverride: PredictiveCompletionSettings? {
        get { predictionState.settingsOverride }
        set {
            predictionState.settingsOverride = newValue
            applyPredictionPreferences()
        }
    }

    func showPrediction(_ s: PredictionSession.Suggestion?) {
        textView.ghostText = s.map { GhostText(anchor: $0.anchor, text: $0.text, expanded: predictionState.expanded) }
    }

    /// The document as the session sees it.
    func predictionSnapshot() -> PredictionSession.Snapshot? {
        guard let url = fileURL, textView.isEditable else { return nil }
        let sel = textView.selectedRange()
        let others = predictionOtherFiles?().filter { $0.path != url.path }.map { (path: ($0.path as NSString).lastPathComponent, text: $0.text) } ?? []
        return PredictionSession.Snapshot(text: textView.string, caret: sel.location, selectionLength: sel.length,
                                          path: predictionPath?(url) ?? url.lastPathComponent,
                                          language: CompletionContext.language(forPath: url.path), otherFiles: others)
    }

    /// From `shouldChangeText`.
    func notePredictionEdit(range: NSRange, replacement: String) {
        if predictionState.pendingEdit != nil { predictionState.severalEdits = true }
        predictionState.pendingEdit = (range.location, range.length, replacement)
    }

    /// From `textDidChange`.
    func predictionTextDidChange() {
        defer {
            predictionState.pendingEdit = nil
            predictionState.severalEdits = false
        }
        guard let snap = predictionSnapshot(), textView.multipleRanges.isEmpty, !isShowingCompletions else { return prediction.dismiss() }
        let e = predictionState.pendingEdit ?? (snap.caret, 1, "")
        prediction.textDidChange(snap, location: e.location, removed: predictionState.severalEdits ? max(1, e.removed) : e.removed, inserted: e.inserted)
    }

    /// From `textViewDidChangeSelection` (ignored while an edit is in progress).
    func predictionSelectionDidChange() {
        guard predictionState.pendingEdit == nil else { return }
        let sel = textView.selectedRange()
        prediction.selectionDidChange(caret: sel.location, length: sel.length)
    }

    /// Editor ▸ Show Predictive Completion (⌃⌥Space).
    @objc public func showPredictiveCompletion(_ sender: Any?) {
        guard let snap = predictionSnapshot() else { return }
        hideCompletions()
        prediction.forceRequest(snap)
    }

    /// Accepts all, what is shown, a line or a word; false when nothing is shown.
    @discardableResult
    public func acceptPrediction(_ unit: PredictionSession.AcceptUnit) -> Bool {
        guard let s = prediction.suggestion, let text = prediction.acceptText(unit), !text.isEmpty else { return false }
        let at = NSRange(location: s.anchor, length: 0)
        textView.insertText(text, replacementRange: at)
        textView.setSelectedRange(NSRange(location: s.anchor + (text as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    public func dismissPrediction() { prediction.dismiss() }

    /// Tab, ⌥Tab, ⌃Tab and Escape while a suggestion shows.
    func handlePredictionKey(_ e: NSEvent) -> Bool {
        guard prediction.suggestion != nil else { return false }
        let flags = e.modifierFlags.intersection([.shift, .command, .option, .control])
        switch e.keyCode {
        case 48 where flags.isEmpty: return acceptPrediction(predictionState.expanded ? .all : .shown)
        case 48 where flags == .option: return acceptPrediction(.all)
        case 48 where flags == .control: return acceptPrediction(.word)
        case 53:
            dismissPrediction()
            return true
        default: return false
        }
    }

    /// Holding Option shows the whole suggestion.
    func predictionFlagsChanged(_ e: NSEvent) {
        let expanded = e.modifierFlags.intersection([.shift, .command, .option, .control]) == .option
        guard expanded != predictionState.expanded else { return }
        predictionState.expanded = expanded
        showPrediction(prediction.suggestion)
    }
}

/// A transparent view over the text view that draws the ghost text. TextKit
/// 2 draws text in fragment views above the text view's own drawing, so
/// the suggestion (which covers the rest of the caret line) needs a view
/// above them. Clicks go through.
final class GhostTextOverlay: NSView {
    weak var textView: SourceTextView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { textView?.drawGhostText(in: dirtyRect) }
}

extension SourceTextView {
    /// TextKit 2 adds layout-fragment views as it lays out: the overlay stays on top.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview !== ghostOverlay, ghostOverlay.superview === self { addSubview(ghostOverlay, positioned: .above, relativeTo: nil) }
    }

    /// Shows, moves or hides the overlay for `ghostText`.
    func updateGhostOverlay() {
        guard ghostText != nil else {
            ghostOverlay.removeFromSuperview()
            return
        }
        ghostOverlay.textView = self
        ghostOverlay.frame = bounds
        ghostOverlay.autoresizingMask = [.width, .height]
        if ghostOverlay.superview !== self || subviews.last !== ghostOverlay {
            addSubview(ghostOverlay, positioned: .above, relativeTo: nil)
        }
        ghostOverlay.needsDisplay = true
    }

    /// Draws the suggestion after the caret: its first line in the caret's
    /// line (what follows the caret on that line moves right of it), the
    /// other lines on a background-filled block over the lines below.
    func drawGhostText(in dirty: NSRect) {
        guard let g = ghostText, let caret = caretRect(at: g.anchor) else { return }
        let shown = g.expanded ? g.text : PredictionSession.collapsed(g.text)
        let lines = shown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let ghost: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: Theme.ghostTextColor]
        let plain: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: Theme.textColor]
        let background = backgroundColor
        let ns = string as NSString
        var lineEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &lineEnd, for: NSRange(location: min(g.anchor, ns.length), length: 0))
        let rest = ns.substring(with: NSRange(location: min(g.anchor, ns.length), length: max(0, lineEnd - g.anchor)))
        let first = lines.first ?? ""
        if !first.isEmpty {
            let width = (first as NSString).size(withAttributes: ghost).width
            // The caret (about 2 points wide) stays visible left of the suggestion.
            let x = caret.minX + 1
            if !rest.isEmpty {
                for r in segmentRects(NSRange(location: g.anchor, length: (rest as NSString).length)) {
                    let cover = NSRect(x: max(r.minX, x + 1), y: r.minY, width: r.maxX - max(r.minX, x + 1) + 1, height: r.height)
                    background.setFill()
                    cover.fill()
                    // The caret line's tint (drawBackground) over the cover.
                    if caretLine != nil, caretLine != highlightedLine {
                        NSColor.labelColor.withAlphaComponent(0.05).setFill()
                        cover.fill(using: .sourceOver)
                    }
                }
                (rest as NSString).draw(at: NSPoint(x: x + width, y: caret.minY), withAttributes: plain)
            }
            (first as NSString).draw(at: NSPoint(x: x, y: caret.minY), withAttributes: ghost)
        }
        guard lines.count > 1 else { return }
        let x0 = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let height = caret.height
        let widest = lines.dropFirst().map { ($0 as NSString).size(withAttributes: ghost).width }.max() ?? 0
        let block = NSRect(x: x0 - 2, y: caret.maxY, width: min(bounds.width - x0, widest + 12), height: height * CGFloat(lines.count - 1))
        background.setFill()
        block.fill()
        Theme.ghostTextColor.withAlphaComponent(0.35).setFill()
        NSRect(x: block.minX, y: block.minY, width: 1, height: block.height).fill()
        for (i, l) in lines.dropFirst().enumerated() {
            (l as NSString).draw(at: NSPoint(x: x0, y: caret.maxY + height * CGFloat(i)), withAttributes: ghost)
        }
    }
}
