import AppKit
import YcodeIDECore

/// The editor under the toolbar band (`liquid-glass.md` §7.3,
/// `fidelity-council.md` row 5, `liquid-glass-ycode.md` §12.8): the
/// editor / debug area split starts below the toolbar, so the debug area
/// keeps exactly the height asked for, while the editor area's own view
/// reaches up to the window's top. Its text, minimap and band backdrop
/// draw under the toolbar; its safe area keeps the jump bar and the first
/// line where they were. Nothing between the column and the editor clips.
extension WorkspaceWindowController {
    func extendEditorUnderToolbar(column: NSView, centerColumn: NSView) {
        let v = editorArea.view
        guard GlassBars.enabled else {
            v.topAnchor.constraint(equalTo: column.topAnchor).isActive = true
            return
        }
        v.topAnchor.constraint(equalTo: centerColumn.topAnchor).isActive = true
        _ = column
        // AppKit gives a view that reaches outside its superview no safe
        // area there, so the editor's top inset is the column's: the
        // toolbar band (none when the toolbar is hidden).
        (centerColumn as? CenterColumnView)?.onLayout = { [weak self] col in self?.followToolbarBand(col.safeAreaInsets.top) }
    }

    private func followToolbarBand(_ top: CGFloat) {
        let v = editorArea.view
        // The split view and its item wrappers (made as the split loads)
        // must not clip the part above them.
        var a = v.superview
        while let x = a, !(x is CenterColumnView) {
            if x.clipsToBounds { x.clipsToBounds = false }
            a = x.superview
        }
        var insets = v.additionalSafeAreaInsets
        guard abs(insets.top - top) > 0.25 else { return }
        insets.top = top
        v.additionalSafeAreaInsets = insets
    }

    /// How far the editor area reaches above the editor / debug area split
    /// (tests): the toolbar band's height with the Liquid Glass layout.
    public var editorOverhang: CGFloat {
        guard isWindowLoaded, let content = window?.contentView else { return 0 }
        let editor = editorArea.view.convert(editorArea.view.bounds, to: content)
        let split = centerSplit.view.convert(centerSplit.view.bounds, to: content)
        return content.isFlipped ? split.minY - editor.minY : editor.maxY - split.maxY
    }
}

/// The center column: the editor / debug area split below the toolbar,
/// with the editor area reaching up under it. It reports each layout so
/// the editor's top inset follows the toolbar band.
final class CenterColumnView: NSView {
    var onLayout: ((NSView) -> Void)?
    override func layout() {
        super.layout()
        onLayout?(self)
    }
}
