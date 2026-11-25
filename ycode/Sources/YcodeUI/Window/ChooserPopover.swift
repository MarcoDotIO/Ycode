import AppKit
import YcodeIDECore

// The anchored popover of `specs/ide/popovers.md` §11.1 on macOS: the
// system popover (its arrow, glass and outside-click dismissal), anchored
// to a control or a text range on the preferred edge, opening and closing
// in one frame (P-195), its parent window keeping its active look (P-031:
// a popover window never becomes main). `ChooserPopoverController` is the
// chooser built on it (P-111, P-113): a Filter field over `ChooserList`
// rows, the Linux IDE's `ChooserPopoverView` drawing the same rows.

/// Shows view controllers in the system popover, one at a time per
/// window, with the parameters of §11.1.
@MainActor
public enum AnchoredPopover {
    /// The popover shown last (closing it is how a new one replaces it).
    public private(set) static weak var shown: NSPopover?

    /// Shows `content` at `anchor` (in `view`'s coordinates) on `edge`,
    /// `content.preferredContentSize` being the body. Returns the popover,
    /// or nil when `view` is in no visible window (tests then use the
    /// controller alone). `onClose` runs once when it closes.
    @discardableResult
    public static func show(_ content: NSViewController, anchor: NSRect, of view: NSView, edge: PopoverEdge,
                            onClose: (() -> Void)? = nil) -> NSPopover? {
        shown?.performClose(nil)
        guard view.window?.isVisible == true else { return nil }
        let popover = NSPopover()
        // §2.6: in and out in one frame, never the menu's fade.
        popover.animates = false
        // A click outside closes it; Escape closes it (the content handles
        // it first, see `ChooserPopoverController`).
        popover.behavior = .transient
        popover.contentViewController = content
        popover.contentSize = content.preferredContentSize
        let delegate = Delegate(onClose)
        popover.delegate = delegate
        objc_setAssociatedObject(popover, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        popover.show(relativeTo: anchor, of: view, preferredEdge: rectEdge(edge, flipped: view.isFlipped))
        shown = popover
        return popover
    }

    /// The `NSRectEdge` for an edge on screen in a view that is or is not
    /// flipped: below is the smaller y of a flipped view.
    public static func rectEdge(_ edge: PopoverEdge, flipped: Bool) -> NSRectEdge {
        switch edge {
        case .below: flipped ? .maxY : .minY
        case .above: flipped ? .minY : .maxY
        }
    }

    final class Delegate: NSObject, NSPopoverDelegate {
        nonisolated(unsafe) static var key = 0
        let onClose: (() -> Void)?
        init(_ onClose: (() -> Void)?) { self.onClose = onClose }
        func popoverDidClose(_ notification: Notification) {
            MainActor.assumeIsolated { onClose?() }
        }
    }
}

/// A chooser: the Filter field, then the rows. The owner supplies the rows
/// for a filter and an expansion state, and what choosing a row does.
@MainActor
public final class ChooserPopoverController: NSViewController, NSSearchFieldDelegate {
    public let field = NSSearchField()
    public let rowsView = ChooserRowsView()
    public let bodyWidth: CGFloat
    /// The rows for a filter and whether Incompatible is expanded.
    let rows: (String, Bool) -> ChooserList
    /// Runs a chosen row (after the popover closes, for commands that open sheets).
    public var onChoose: ((ChooserRow) -> Void)?
    /// Closes the presentation (the popover).
    public var onDismiss: (() -> Void)?
    public private(set) var expanded: Bool
    public var list: ChooserList { rowsView.list }

    public init(bodyWidth: CGFloat, expanded: Bool = false, rows: @escaping (String, Bool) -> ChooserList) {
        self.bodyWidth = bodyWidth
        self.rows = rows
        self.expanded = expanded
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let m = PopoverMetrics.self
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: bodyWidth, height: 100))
        field.placeholderString = m.filterPlaceholder
        field.delegate = self
        field.sendsSearchStringImmediately = true
        // §8: a borderless field, a caret and no focus ring.
        field.focusRingType = .none
        field.controlSize = .large
        field.frame = NSRect(x: m.filterInset, y: m.filterInset, width: bodyWidth - 2 * m.filterInset, height: m.filterHeight)
        field.autoresizingMask = [.width]
        field.setAccessibilityIdentifier("chooser.filter")
        rowsView.frame = NSRect(x: 0, y: 0, width: bodyWidth, height: 100)
        rowsView.autoresizingMask = [.width, .height]
        rowsView.onClick = { [weak self] i in self?.choose(i) }
        root.addSubview(rowsView)
        root.addSubview(field)
        view = root
        reload()
    }

    /// Lists the rows for the current filter and expansion and resizes.
    public func reload() {
        rowsView.list = rows(field.stringValue, expanded)
        let size = NSSize(width: bodyWidth, height: CGFloat(rowsView.list.bodyHeight))
        preferredContentSize = size
        view.setFrameSize(size)
        rowsView.frame = view.bounds
        rowsView.needsDisplay = true
    }

    /// Types `text` into the Filter field.
    public func setFilter(_ text: String) {
        _ = view
        field.stringValue = text
        reload()
    }

    public func controlTextDidChange(_ obj: Notification) { reload() }

    /// Keys from the Filter field (§2.5): Up and Down move the highlight,
    /// Right expands a disclosure row, Return chooses, Escape closes.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.moveRight(_:)):
            guard let r = list.current, r.isDisclosure else { return false }
            setExpanded(true)
            return true
        case #selector(NSResponder.moveLeft(_:)):
            guard list.current?.isDisclosure == true, expanded else { return false }
            setExpanded(false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let h = list.highlighted { choose(h) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
            return true
        default: return false
        }
    }

    public override func cancelOperation(_ sender: Any?) { onDismiss?() }

    /// Moves the highlight.
    public func move(_ delta: Int) {
        _ = view
        rowsView.list.move(delta)
        rowsView.needsDisplay = true
    }

    /// Expands or collapses Incompatible in place (§2.4): the popover
    /// grows downward in one frame.
    public func setExpanded(_ on: Bool) {
        _ = view
        guard on != expanded else { return }
        let highlighted = list.current?.key
        expanded = on
        reload()
        if let highlighted, let i = list.rows.firstIndex(where: { $0.key == highlighted }) { rowsView.list.highlighted = i }
    }

    /// Chooses row `i`: a disclosure toggles; other rows close the popover
    /// and run.
    public func choose(_ i: Int) {
        _ = view
        guard list.rows.indices.contains(i) else { return }
        let r = list.rows[i]
        guard r.isSelectable else { return }
        if r.isDisclosure {
            rowsView.list.highlighted = i
            setExpanded(!expanded)
            return
        }
        onDismiss?()
        onChoose?(r)
    }
}

/// The chooser's rows, drawn from a `ChooserList` (§2.2–§2.3): headings in
/// small secondary type, checked choices with their glyph and right-aligned
/// OS version, commands at the title column, hairline separators, the
/// disclosure's chevron; the highlight an accent rounded rectangle with
/// white text. Hover moves the highlight; a click chooses.
@MainActor
public final class ChooserRowsView: NSView {
    public var list = ChooserList(rows: []) { didSet { needsDisplay = true } }
    /// A row's picture (the scheme's app icon, this computer's laptop);
    /// nil draws the row's system symbol.
    public var image: ((ChooserRow) -> NSImage?)?
    var onClick: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    /// Hover moves the highlight only after the pointer has moved since
    /// the chooser opened (§2.7: it opens on the current row).
    public var pointerGate = ChooserPointerGate()

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { pointerGate = ChooserPointerGate(origin: NSEvent.mouseLocation) }
    }

    public override var isFlipped: Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    public override func mouseMoved(with event: NSEvent) {
        let screen = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        guard pointerGate.admit(screen) else { return }
        hover(atY: convert(event.locationInWindow, from: nil).y)
    }

    /// Hover at `y` in the rows (after the gate).
    public func hover(atY y: CGFloat) {
        let p = NSPoint(x: 0, y: y)
        let before = list.highlighted
        list.hover(list.row(atY: Double(p.y)))
        if list.highlighted != before { needsDisplay = true }
    }

    public override func mouseDown(with event: NSEvent) {}

    public override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = list.row(atY: Double(p.y)) { onClick?(i) }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let m = PopoverMetrics.self
        let w = Double(bounds.width)
        for (i, r) in list.rows.enumerated() {
            let f = list.rowFrame(i, bodyWidth: w)
            guard f.intersects(dirtyRect) else { continue }
            let lit = i == list.highlighted && r.isSelectable
            if lit {
                NSColor.controlAccentColor.setFill()
                let h = list.highlightFrame(i, bodyWidth: w)
                NSBezierPath(roundedRect: h, xRadius: CGFloat(m.highlightRadius), yRadius: CGFloat(m.highlightRadius)).fill()
            }
            drawRow(r, in: f, lit: lit)
        }
    }

    func drawRow(_ r: ChooserRow, in f: NSRect, lit: Bool) {
        let m = PopoverMetrics.self
        let ink: NSColor = lit ? .white : r.isEnabled ? .labelColor : .tertiaryLabelColor
        let dim: NSColor = lit ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
        func text(_ s: String, x: CGFloat, size: Double, color: NSColor, weight: NSFont.Weight = .regular, right: Bool = false) {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(size), weight: weight), .foregroundColor: color])
            let sz = a.size()
            let ox = right ? x - sz.width : x
            let limit = right ? sz.width : max(0, f.maxX - CGFloat(m.trailingInset) - ox)
            a.draw(with: NSRect(x: ox, y: f.midY - sz.height / 2, width: limit, height: sz.height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        switch r.kind {
        case .separator:
            NSColor.separatorColor.setFill()
            NSRect(x: f.minX + CGFloat(m.separatorInset), y: f.midY.rounded(.down), width: f.width - 2 * CGFloat(m.separatorInset), height: 1).fill()
        case .heading:
            text(r.title, x: f.minX + CGFloat(m.checkX), size: m.headingFontSize, color: .secondaryLabelColor, weight: .semibold)
        case .choice, .command, .disclosure:
            if r.isChecked {
                text("✓", x: f.minX + CGFloat(m.checkX) - 2, size: m.titleFontSize, color: ink, weight: .semibold)
            }
            if r.kind == .choice, let image = image?(r) ?? r.symbol.flatMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) }) {
                let s = CGFloat(m.glyphSide)
                let box = NSRect(x: f.minX + CGFloat(m.glyphX), y: f.midY - s / 2, width: s, height: s)
                drawImage(image, in: box, tint: image.isTemplate ? ink : nil)
            }
            text(r.title, x: f.minX + CGFloat(m.titleX), size: m.titleFontSize, color: ink)
            if let t = r.trailing {
                text(t, x: f.maxX - CGFloat(m.trailingInset), size: m.titleFontSize, color: dim, right: true)
            }
            if case .disclosure(let open) = r.kind,
               let chevron = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
                let s = chevron.size
                let box = NSRect(x: f.maxX - CGFloat(m.trailingInset) - s.width, y: f.midY - s.height / 2, width: s.width, height: s.height)
                drawImage(chevron, in: box, tint: lit ? .white : .secondaryLabelColor)
            }
        }
    }

    /// Draws an image in `box`, fitted, a template tinted `tint`.
    func drawImage(_ image: NSImage, in box: NSRect, tint: NSColor?) {
        let s = image.size
        let k = min(box.width / max(s.width, 1), box.height / max(s.height, 1), 1)
        let r = NSRect(x: box.midX - s.width * k / 2, y: box.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
        guard let tint else {
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let tinted = NSImage(size: s, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Accessibility: the rows as a list of buttons

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .list }
    public override func accessibilityLabel() -> String? { "Chooser" }
}
