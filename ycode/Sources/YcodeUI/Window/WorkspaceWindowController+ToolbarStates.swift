import AppKit
import YcodeIDECore

/// Toolbar states (`liquid-glass.md` §8.1, `fidelity-council.md` row 37):
/// a toggle that is on carries only the recessed grey pill, never an
/// accent fill; a button that cannot act now is drawn dimmed (Stop with
/// nothing running, Go Back and Go Forward with no history).
extension WorkspaceWindowController {
    /// The selected segment's fill in the toggles: a quiet grey, as the
    /// glass bars' pills (`SelectionPillView`).
    static var togglePillColor: NSColor { .quaternaryLabelColor }

    /// The toggles' look, set once.
    func styleToolbarToggles() {
        for c in [toolbarControls.leftPanes, toolbarControls.editorModes] {
            c.selectedSegmentBezelColor = Self.togglePillColor
        }
    }

    /// Whether each joined pair's halves can act now.
    func updateToolbarAvailability() {
        for item in window?.toolbar?.items ?? [] {
            guard let c = item.view as? NSSegmentedControl, c.segmentCount >= 2 else { continue }
            switch item.itemIdentifier {
            case Self.runID:
                c.setEnabled(true, forSegment: 0)
                c.setEnabled(session.isBusy, forSegment: 1)
            case Self.historyID:
                c.setEnabled(editor.history.canGoBack, forSegment: 0)
                c.setEnabled(editor.history.canGoForward, forSegment: 1)
            default: break
            }
        }
    }
}
