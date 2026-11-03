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
    /// The options pull-down's width and a toggle's width.
    static let optionsWidth: CGFloat = 28
    static let toggleWidth: CGFloat = 18
    /// Room kept at the leading end (the options pull-down).
    var leadingInset: CGFloat = optionsWidth + 2 { didSet { needsLayout = true; needsDisplay = true } }
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

    /// The funnel with a chevron, one template image.
    static let optionsGlyph: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let funnel = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold))
        let size = NSSize(width: 22, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            if let f = funnel {
                f.draw(in: NSRect(x: 0, y: (size.height - f.size.height) / 2, width: f.size.width, height: f.size.height))
            }
            if let c = chevron {
                c.draw(in: NSRect(x: size.width - c.size.width, y: (size.height - c.size.height) / 2, width: c.size.width, height: c.size.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Filter options"
        return image
    }()
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
