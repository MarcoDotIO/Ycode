import AppKit

/// The bars over the text redraw what is beneath them when it moves or
/// changes (`liquid-glass.md` §9.1, checklist row 68).
extension SourceEditorController {
    /// The text under the bars scrolled or changed: the band behind the
    /// toolbar and the jump bar redraws, and so does the window's bottom
    /// bar (`onContentMovedUnderBars`).
    func contentMovedUnderBars() {
        bandBackdrop.needsDisplay = true
        onContentMovedUnderBars?()
    }
}
