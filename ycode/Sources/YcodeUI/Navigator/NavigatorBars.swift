import AppKit
import YcodeIDECore

extension NavigatorAreaController {
    /// The Test navigator's header (reference-ui-5.md §5.2): the test-plan
    /// pop-up and the Mode radio buttons.
    func configureTestHeader() {
        testPlanPopUp.controlSize = .small
        testPlanPopUp.font = .systemFont(ofSize: 11)
        // reference-ui-6.md §5.4 (N5): a bordered pop-up 194 wide (it gives
        // way in a narrower navigator).
        testPlanPopUp.isBordered = true
        let width = testPlanPopUp.widthAnchor.constraint(equalToConstant: NavigatorBars.testPlanPopUpWidth)
        width.priority = .defaultHigh
        width.isActive = true
        testPlanPopUp.addItem(withTitle: testPlanName)
        testPlanPopUp.setAccessibilityLabel("Test Plan")
        testModeControl.controlSize = .small
        testModeControl.selectedSegment = 0
        testModeControl.setAccessibilityLabel("Mode")
        for (i, t) in NavigatorBars.testModes.enumerated() {
            testModeControl.setToolTip(t, forSegment: i)
            testModeControl.setLabel("", forSegment: i)
        }
        testModeControl.target = self
        testModeControl.action = #selector(testModeChosen)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        testPlanPopUp.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        for v in [testPlanPopUp, spacer, testModeControl] as [NSView] { testHeader.addArrangedSubview(v) }
        testHeader.orientation = .horizontal
        testHeader.spacing = 4
        testHeader.isHidden = true
    }

    @objc func testModeChosen() { groupTestsByTags = testModeControl.selectedSegment == 1 }

    /// Adds a glyph at a row's right end.
    func addTrailingGlyph(_ symbol: String, tint: NSColor?, to cell: NSView, label: NSView) {
        let v = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        v.contentTintColor = tint ?? .secondaryLabelColor
        v.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(v)
        NSLayoutConstraint.activate([
            v.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            v.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: v.leadingAnchor, constant: -4),
        ])
    }

    /// A bookmark row's context-menu items.
    public func bookmarkMenuItems(_ b: Bookmark) -> [NSMenuItem] {
        let done = b.done == true
        let item = NSMenuItem(title: done ? "Mark as Not Done" : "Mark as Done", action: #selector(bookmarkDoneChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = BookmarkBox(b)
        return [item]
    }

    @objc func bookmarkDoneChosen(_ item: NSMenuItem) {
        guard let b = (item.representedObject as? BookmarkBox)?.bookmark else { return }
        onSetBookmarkDone?(b, b.done != true)
    }
}

/// A navigator's filter field (reference-ui-6.md §5.6, N7): no magnifier;
/// the filter-options pull-down sits inside it at the leading end and the
/// in-field toggles at the trailing end (both are the navigator's views,
/// laid over the field), so the text and the clear button keep between
/// them.
final class NavigatorFilterField: NSSearchField {
    /// The options pull-down's width (its glyph image's) and a toggle's width.
    static let optionsWidth: CGFloat = 23.5
    /// The options pull-down's leading edge from the field's (its alignment
    /// rectangle's): the glyph's ink, 1.2 into its image, then starts 7.5
    /// into the glass capsule, which begins 4 before the field
    /// (metrics.md §15).
    static let optionsLeading: CGFloat = 2.3
    static let toggleWidth: CGFloat = 18
    /// A toggle's height: the small search field's.
    static let toggleHeight: CGFloat = 16
    /// Room kept at the leading end (the options pull-down and a gap; the
    /// glass layout sets its own, `NavigatorAreaController.filterTextInset`).
    var leadingInset: CGFloat = 30 { didSet { needsLayout = true; needsDisplay = true } }
    /// Room kept at the trailing end (the shown toggles).
    var trailingInset: CGFloat = 0 { didSet { needsLayout = true; needsDisplay = true } }

    override class var cellClass: AnyClass? {
        get { NavigatorFilterFieldCell.self }
        set {}
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        (cell as? NSSearchFieldCell)?.searchButtonCell = nil
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The cancel button's width.
    static let cancelWidth: CGFloat = 16

    func textRect(_ bounds: NSRect) -> NSRect {
        var r = bounds
        r.origin.x += leadingInset
        r.size.width = max(0, bounds.width - leadingInset - trailingInset - Self.cancelWidth - 2)
        return r
    }

    func cancelRect(_ bounds: NSRect) -> NSRect {
        NSRect(x: bounds.maxX - trailingInset - Self.cancelWidth - 2, y: bounds.midY - Self.cancelWidth / 2,
               width: Self.cancelWidth, height: Self.cancelWidth)
    }

    override func rectForSearchText(whenCentered isCentered: Bool) -> NSRect {
        let r = super.rectForSearchText(whenCentered: isCentered)
        let t = textRect(bounds)
        return NSRect(x: t.minX, y: r.minY, width: t.width, height: r.height)
    }
    override func rectForSearchButton(whenCentered isCentered: Bool) -> NSRect { .zero }
    override func rectForCancelButton(whenCentered isCentered: Bool) -> NSRect {
        let r = super.rectForCancelButton(whenCentered: isCentered)
        let c = cancelRect(bounds)
        return NSRect(x: c.minX, y: r.minY, width: r.width, height: r.height)
    }

    /// The lines in a circle with a chevron 1.5 after it, one template
    /// image (metrics.md §15: ink 13 and 6 × 3.5). The symbols draw with
    /// padding inside their rects (the circle's ink is 13 in a 15.5 rect,
    /// starting 1.2 in; the chevron's 6 × 3.5 in its natural 8 × 5), so
    /// the rects are larger than the ink.
    static let optionsGlyph: NSImage = {
        let funnel = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6.5, weight: .semibold))
        let circle: CGFloat = 15.5, chevronX: CGFloat = 15.1, chevronSize = NSSize(width: 8, height: 5)
        let size = NSSize(width: optionsWidth, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            if let f = funnel {
                f.draw(in: NSRect(x: 0, y: (size.height - circle) / 2, width: circle, height: circle))
            }
            if let c = chevron {
                c.draw(in: NSRect(x: chevronX, y: (size.height - chevronSize.height) / 2, width: chevronSize.width, height: chevronSize.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Filter options"
        return image
    }()
}

/// The filter field's options pull-down. It draws its glyph itself, from
/// its leading edge and in its tint (a pull-down cell places and clips its
/// image in an area of its own), and its frame is its alignment rectangle,
/// so the layout places that glyph (metrics.md §15).
final class NavigatorOptionsButton: NSPopUpButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func draw(_ dirtyRect: NSRect) {
        let glyph = NavigatorFilterField.optionsGlyph
        let tint = isEnabled ? (contentTintColor ?? .secondaryLabelColor) : .tertiaryLabelColor
        let tinted = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: 0, y: (bounds.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
    }
}

/// An in-field toggle of the navigator's filter field: its frame is its
/// alignment rectangle, so a 16-point toggle centred on the 16-point field
/// covers exactly the field's height (a borderless button's frame otherwise
/// reaches 3 points above and below, and its glyph's own height put it on a
/// half point that a 1x screen rounded out of the field; `metrics.md` §14).
final class NavigatorFilterToggle: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

/// The cell side of `NavigatorFilterField`'s layout (the field editor's
/// frame comes from here).
final class NavigatorFilterFieldCell: NSSearchFieldCell {
    private var field: NavigatorFilterField? { controlView as? NavigatorFilterField }
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let r = super.searchTextRect(forBounds: rect)
        guard let f = field else { return r }
        let t = f.textRect(rect)
        return NSRect(x: t.minX, y: r.minY, width: t.width, height: r.height)
    }
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect { .zero }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        let r = super.cancelButtonRect(forBounds: rect)
        guard let f = field else { return r }
        return NSRect(x: f.cancelRect(rect).minX, y: r.minY, width: r.width, height: r.height)
    }
}

/// A bookmark carried by a menu item.
final class BookmarkBox: NSObject {
    let bookmark: Bookmark
    init(_ b: Bookmark) { bookmark = b }
}

/// Colours of the navigator's bottom bar.
enum NavigatorBarColors {
    /// The filter-options glyph (funnel lines and chevron): in dark #ABABAC
    /// on the capsule (`editor-area.md` F.9, checklist row 110; it was the
    /// secondary label colour, #807F7F there); in light the secondary label
    /// colour (`metrics.md` §15).
    static let optionsGlyph = NSColor(name: "NavigatorOptionsGlyph") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: CGFloat((WorkspaceChrome.filterGlyphDark >> 16) & 0xFF) / 255,
                                                                    green: CGFloat((WorkspaceChrome.filterGlyphDark >> 8) & 0xFF) / 255,
                                                                    blue: CGFloat(WorkspaceChrome.filterGlyphDark & 0xFF) / 255, alpha: 1)
            : .secondaryLabelColor
    }
}
