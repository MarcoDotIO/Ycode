import AppKit

/// The File inspector's control look (`specs/ide/metrics.md` §12.4):
/// filled fields and pop-ups with no border, a bordered Target Membership
/// box, path values that break after "/" and "-".
@MainActor
enum InspectorStyle {
    /// From a key's ink to its value.
    static let keyToValue: CGFloat = 5
    /// A section rule keeps this far from the controls on each side.
    static let ruleGap: CGFloat = 6
    static let headingRowHeight: CGFloat = 20
    static let membershipTableHeight: CGFloat = 110
    static let membershipFooterHeight: CGFloat = 19
    /// Multi-line values: a 14-point line pitch.
    static let pathLineHeight: CGFloat = 14

    /// #A6A6A7 on the inspector's background.
    static var tableBorder: NSColor { NSColor.labelColor.withAlphaComponent(0.35) }

    /// A filled control: #E5E5E6 behind a text field, #E1E1E2 behind a
    /// pop-up (light), corners about 6, no border.
    static func fill(_ c: NSControl) {
        let popUp = c is NSPopUpButton
        if let f = c as? NSTextField {
            f.isBezeled = false
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .default
            if !(f.cell is InsetTextFieldCell) {
                let cell = InsetTextFieldCell(textCell: f.stringValue)
                cell.isEditable = f.isEditable
                cell.isSelectable = true
                cell.isScrollable = true
                cell.font = f.font
                cell.target = f.target
                cell.action = f.action
                f.cell = cell
            }
            f.heightAnchor.constraint(equalToConstant: 22).isActive = true
        } else if let b = c as? NSPopUpButton {
            b.isBordered = false
            b.heightAnchor.constraint(equalToConstant: 16).isActive = true
        }
        c.wantsLayer = true
        c.layer?.cornerRadius = popUp ? 5 : 6
        c.layer?.cornerCurve = .continuous
        c.layer?.backgroundColor = (popUp ? popUpFill : fieldFill).cgColor
    }

    static var fieldFill: NSColor { NSColor.labelColor.withAlphaComponent(0.10) }
    static var popUpFill: NSColor { NSColor.labelColor.withAlphaComponent(0.115) }

    /// Greys the first item's title ("No Explicit Encoding").
    static func dimFirstTitle(_ p: NSPopUpButton) {
        guard let first = p.itemArray.first, first.title.hasPrefix("No Explicit") else { return }
        first.attributedTitle = NSAttributedString(string: first.title, attributes: [.font: p.font ?? .systemFont(ofSize: 11),
                                                                                    .foregroundColor: NSColor.secondaryLabelColor])
    }

    /// A path value: breaks after "/" and after "-", each line filled
    /// first, on a 14-point pitch.
    static func pathLabel(_ value: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: "")
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.minimumLineHeight = pathLineHeight
        para.maximumLineHeight = pathLineHeight
        l.attributedStringValue = NSAttributedString(string: breakable(value), attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                                           .paragraphStyle: para,
                                                                                           .foregroundColor: NSColor.labelColor])
        return l
    }

    /// The value with a zero-width break opportunity after every "/" and
    /// "-" (copying the label's text still gives the plain value).
    static func breakable(_ s: String) -> String {
        var out = ""
        for ch in s {
            out.append(ch)
            if ch == "/" || ch == "-" { out.append("\u{200B}") }
        }
        return out
    }
}

/// A text field cell whose text sits 6 points in and is centred
/// vertically (the filled Name field).
final class InsetTextFieldCell: NSTextFieldCell {
    private func inset(_ r: NSRect) -> NSRect {
        let h = cellSize(forBounds: r).height
        return NSRect(x: r.minX + 6, y: r.minY + max(0, (r.height - h) / 2), width: max(0, r.width - 12), height: h)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { inset(super.drawingRect(forBounds: rect)) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// A fixed-height row holding one view at the content's leading edge.
final class InspectorRowBox: NSView {
    let inner: NSView
    init(_ inner: NSView, height: CGFloat, inset: CGFloat = 0) {
        self.inner = inner
        super.init(frame: .zero)
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            inner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            inner.centerYAnchor.constraint(equalTo: centerYAnchor),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The heading's text (tests read headings through it).
    var stringValue: String { (inner as? NSTextField)?.stringValue ?? "" }
}
