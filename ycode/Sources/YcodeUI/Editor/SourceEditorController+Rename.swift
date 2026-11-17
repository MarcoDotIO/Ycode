import AppKit
import YcodeIDECore

/// Rename in place (P-084, `specs/ide/parity-inventory.md`): the edit box
/// sits exactly on the identifier, the text after it untouched, and every
/// other occurrence in the file is boxed the same way (no yellow find
/// fill). The box grows with what is typed. Return renames, Escape
/// cancels.
extension SourceEditorController {
    /// The rename state of the editors, by editor (an extension cannot add
    /// stored properties).
    @MainActor static var renameOverlays: [ObjectIdentifier: RenameBoxesView] = [:]

    /// Whether the rename boxes are shown (the find fill steps aside).
    public var isShowingRenameBoxes: Bool { Self.renameOverlays[ObjectIdentifier(self)] != nil }
    /// The boxes drawn around the other occurrences, in text-view
    /// coordinates (tests).
    public var renameBoxRects: [NSRect] { Self.renameOverlays[ObjectIdentifier(self)]?.boxes ?? [] }
    /// The edit box's frame in text-view coordinates (tests).
    public var renameFieldFrame: NSRect? { Self.renameOverlays[ObjectIdentifier(self)]?.field?.frame }

    /// The box around an identifier's text rectangle.
    static func renameBox(_ r: NSRect) -> NSRect { r.insetBy(dx: -2, dy: 0) }

    /// Shows the edit box on `range` (the identifier) and boxes around the
    /// other whole-word occurrences of `name`.
    func showRenameField(name: String, at range: NSRange, onCommit: @escaping (String) -> Void) {
        _ = view
        hideRenameBoxes()
        let rect = textView.segmentRects(range).first ?? .zero
        let others = highlightedOccurrences.isEmpty ? Self.wordOccurrences(of: name, in: textView.string) : highlightedOccurrences
        let overlay = RenameBoxesView(frame: textView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.boxes = others.filter { $0 != range }.flatMap { textView.segmentRects($0).map(Self.renameBox) }
        textView.addSubview(overlay)
        let field = RenameField(string: name)
        field.font = Theme.font
        field.textColor = Theme.textColor
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = Theme.backgroundColor
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 3
        field.layer?.borderWidth = 1
        field.layer?.borderColor = RenameBoxesView.boxColor.cgColor
        field.cell?.usesSingleLineMode = true
        let origin = Self.renameBox(rect)
        func fit(_ text: String) {
            let w = (text as NSString).size(withAttributes: [.font: Theme.font]).width
            field.frame = NSRect(x: origin.minX, y: origin.minY, width: ceil(w) + RenameField.textInset * 2, height: origin.height)
        }
        fit(name)
        field.onCommit = { [weak self] text in
            self?.hideRenameBoxes()
            self?.view.window?.makeFirstResponder(self?.textView)
            if let text { onCommit(text) } else { self?.highlightOccurrences(of: nil) }
        }
        field.onChange = { text in fit(text) }
        overlay.field = field
        textView.addSubview(field)
        Self.renameOverlays[ObjectIdentifier(self)] = overlay
        textView.needsDisplay = true
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Removes the edit box and the boxes.
    public func hideRenameBoxes() {
        guard let o = Self.renameOverlays.removeValue(forKey: ObjectIdentifier(self)) else { return }
        o.field?.removeFromSuperview()
        o.removeFromSuperview()
        textView.needsDisplay = true
    }

    /// Whole-word occurrences of `name`.
    static func wordOccurrences(of name: String, in text: String) -> [NSRange] {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
        let re = try? NSRegularExpression(pattern: pattern)
        return re?.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range) ?? []
    }
}

/// Outlines around a rename's other occurrences; clicks pass through.
@MainActor
public final class RenameBoxesView: NSView {
    /// The outline colour: the editor's secondary text over its background.
    static var boxColor: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.6) }

    var boxes: [NSRect] = [] { didSet { needsDisplay = true } }
    weak var field: RenameField?

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        Self.boxColor.setStroke()
        for r in boxes where r.intersects(dirtyRect) {
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            p.lineWidth = 1
            p.stroke()
        }
    }
}
