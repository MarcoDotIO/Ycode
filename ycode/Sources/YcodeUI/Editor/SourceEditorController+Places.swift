import AppKit
import YcodeIDECore

/// Each document keeps its selection and scroll position while the window
/// is open (`fidelity-council.md` row 226, `editor-area.md` §History, K.4):
/// showing a file again restores both, and the status bar shows the caret's
/// line and column. A file opened for the first time starts at line 1,
/// column 1 (reference-ui-6.md §4.2.2).
extension SourceEditorController {
    /// Where a document was left: its selection and the logical line at the
    /// text's top (nil: the top of the document).
    struct DocumentPlace: Equatable {
        var selection: NSRange
        var top: SourceTextView.TopAnchor?
    }

    /// Notes the shown file's selection and top line (before another file
    /// replaces it).
    func rememberPlace() {
        guard let url = fileURL, !showsNoDocument else { return }
        places.byPath[url.standardizedFileURL.path] = DocumentPlace(selection: textView.selectedRange(), top: textView.topAnchor())
    }

    /// Restores `url`'s selection and top line, when this editor showed it
    /// before; false for a file shown for the first time.
    @discardableResult
    func restorePlace(of url: URL) -> Bool {
        guard let place = places.byPath[url.standardizedFileURL.path] else { return false }
        let length = (textView.string as NSString).length
        let start = min(place.selection.location, length)
        let selection = NSRange(location: start, length: min(place.selection.length, length - start))
        textView.setSelectedRange(selection)
        if let top = place.top {
            // The clip view learns the new text's height in the scroll
            // view's layout: without it, it keeps the old document's limits.
            scrollView.layoutSubtreeIfNeeded()
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.restore(top)
        } else {
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: -scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(clip)
        }
        return true
    }

    /// The selection a document had when it was last shown here (tests).
    func rememberedSelection(of url: URL) -> NSRange? { places.byPath[url.standardizedFileURL.path]?.selection }
}

/// The documents' places (one per editor).
@MainActor
final class EditorPlaces {
    var byPath: [String: SourceEditorController.DocumentPlace] = [:]
}
