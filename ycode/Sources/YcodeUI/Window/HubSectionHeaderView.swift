import AppKit

/// A section header of Device Hub's sidebar (device-hub.md §5.1; council
/// round 9 row 235): plain secondary text, "Available" or "Unavailable", its
/// ink 16 from the sidebar's left edge, in the reference's grey (#737374 in
/// dark), with **no chevron** while the section is open. A click collapses
/// or expands the section, as before; a collapsed section shows a small
/// chevron after its title so that its state stays visible (a Ycode
/// decision: the reference's collapsed header was not captured).
final class HubSectionHeaderView: NSView {
    /// The text's grey: #737374 in dark (measured); in light #8B8B8C, the
    /// same contrast against the light sidebar (a Ycode decision: light was
    /// not captured).
    static let textColor = NSColor(name: "ycode.deviceHub.sectionHeader") { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x73 / 255, green: 0x73 / 255, blue: 0x74 / 255, alpha: 1)
            : NSColor(srgbRed: 0x8B / 255, green: 0x8B / 255, blue: 0x8C / 255, alpha: 1)
    }
    /// The title's ink starts this far from the sidebar's left edge.
    static let inkX: CGFloat = 16
    static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// The label's leading inset in the header's cell that puts its ink at
    /// `inkX` (the source list places its cells, and a label its text, a
    /// little inside).
    static let labelLeading: CGFloat = 0
    /// The label's top in the 28-point header row: the capital's top 110
    /// from the window's top under the search field, as measured (cap height
    /// y 110–119), the device rows where they were.
    static let labelTop: CGFloat = 3

    let title: String
    let collapsed: Bool
    let label: NSTextField
    private(set) var chevron: NSImageView?
    private let onClick: () -> Void

    init(title: String, collapsed: Bool, onClick: @escaping () -> Void) {
        self.title = title
        self.collapsed = collapsed
        self.onClick = onClick
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = Self.font
        label.textColor = Self.textColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelLeading),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.labelTop),
        ])
        if collapsed, let img = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
            let v = NSImageView(image: img)
            v.contentTintColor = Self.textColor
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
                v.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ])
            chevron = v
        }
        identifier = .init(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityValue(collapsed ? "collapsed" : "expanded")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
