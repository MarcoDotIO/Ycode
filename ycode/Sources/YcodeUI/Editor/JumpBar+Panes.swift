import AppKit
import YcodeIDECore

/// Jump bars in split panes (`editor-area.md` E.2, checklist rows 71 and
/// 78): each pane's bar has a close button before the Related Items
/// button and a divider after it; the path's middle components give way
/// first, cut with a short fade; the pane without focus draws its path in
/// grey (#7F7F7F) with grey icons, the focused one in #262626 with the
/// icons in their colours; chevrons are #7F7F7F in both.
extension JumpBar {
    /// The path rises this much from the bar's centre (metrics.md §16.1).
    static let pathRaise: CGFloat = -2.75
    /// The fade over a cut component's last points (E.2 item 4).
    static let truncationFade: CGFloat = 4

    /// Whether this pane has focus (always, with one pane).
    var isActivePane: Bool {
        get { paneState.active }
        set {
            guard paneState.active != newValue else { return }
            paneState.active = newValue
            setPath(lastComponents)
        }
    }

    /// Whether the pane's own close button shows (the editor is split).
    var showsPaneCloseButton: Bool {
        get { paneState.closable }
        set {
            guard paneState.closable != newValue else { return }
            paneState.closable = newValue
            setPath(lastComponents)
        }
    }

    /// The path's text colour: #262626 focused, #7F7F7F not.
    var pathTextColor: NSColor { isActivePane ? .labelColor : .secondaryLabelColor }

    func chevronLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "›")
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// A path component's name; a middle one truncates first, with a fade.
    func pathLabel(_ title: String, middle: Bool) -> NSTextField {
        let l = FadingTruncationLabel(labelWithString: title)
        l.font = .systemFont(ofSize: 11)
        l.textColor = pathTextColor
        l.lineBreakMode = .byClipping
        l.cell?.truncatesLastVisibleLine = false
        l.setContentCompressionResistancePriority(middle ? .defaultLow - 1 : .defaultHigh, for: .horizontal)
        return l
    }

    /// A path icon's tint: its kind's colour in the focused pane, grey in
    /// the other.
    func pathIconTint(symbol: String, title: String) -> NSColor? {
        guard isActivePane else { return .secondaryLabelColor }
        return OutlineItem.color(Self.iconTint(symbol: symbol, title: title)) ?? .controlAccentColor
    }

    /// The navigator's tint for a path component, from its symbol.
    static func iconTint(symbol: String, title: String) -> WorkspaceChrome.IconTint {
        switch symbol {
        case "folder.badge.gearshape", "shippingbox", "square.stack.3d.up": .blue
        case "folder.fill", "folder": .lightBlue
        case WorkspaceChrome.fileSymbol("a.swift"): .orange
        case WorkspaceChrome.fileSymbol("a.png"), WorkspaceChrome.fileSymbol("a.xcassets"): .blue
        default: .accent
        }
    }

    func addPaneCloseButton() {
        let b = iconButton("xmark", "Close this Editor Pane")
        b.target = self
        b.action = #selector(closeClicked)
        b.contentTintColor = .secondaryLabelColor
        b.widthAnchor.constraint(equalToConstant: 20).isActive = true
        paneState.closeButton = b
        stack.addArrangedSubview(b)
        stack.setCustomSpacing(10, after: b)
    }

    /// The 1-point divider after the Related Items button.
    func addPaneDivider() {
        let d = NSBox()
        d.boxType = .separator
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: 1).isActive = true
        d.heightAnchor.constraint(equalToConstant: 14).isActive = true
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(8, after: last) }
        stack.addArrangedSubview(d)
        stack.setCustomSpacing(10, after: d)
    }

    /// The empty bar's divider after the grid button (`editor-area.md`
    /// F.10): "No Selection" then starts `emptyTextStart` in.
    func addEmptyDivider() {
        let d = NSBox()
        d.boxType = .separator
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: 1).isActive = true
        d.heightAnchor.constraint(equalToConstant: 14).isActive = true
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(Self.emptyDividerGaps.before, after: last) }
        stack.addArrangedSubview(d)
        stack.setCustomSpacing(Self.emptyDividerGaps.after, after: d)
    }

    /// Room before and after the empty bar's divider.
    static let emptyDividerGaps: (before: CGFloat, after: CGFloat) = (12, 13.5)
    /// Where "No Selection" starts in the empty bar (its ink, from the bar's
    /// leading edge: x 337.5 in a bar at 290).
    static let emptyTextStart: CGFloat = 47.5

    /// The split pane's close button (tests).
    var paneCloseButton: NSButton? { showsPaneCloseButton ? paneState.closeButton : nil }
}

/// The jump bar's pane state.
final class JumpBarPaneState {
    var active = true
    var closable = false
    weak var closeButton: NSButton?
}

/// A label that, when cut, fades out over its last
/// `JumpBar.truncationFade` points instead of ending in an ellipsis.
final class FadingTruncationLabel: NSTextField {
    /// Whether the text is wider than the label (tests).
    var isTruncated: Bool { intrinsicContentSize.width > bounds.width + 0.5 }

    override func layout() {
        super.layout()
        updateFade()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateFade()
    }

    private func updateFade() {
        wantsLayer = true
        guard isTruncated, bounds.width > JumpBar.truncationFade else { layer?.mask = nil; return }
        let mask = (layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.frame = bounds
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0, NSNumber(value: Double((bounds.width - JumpBar.truncationFade) / bounds.width)), 1]
        layer?.mask = mask
    }
}
