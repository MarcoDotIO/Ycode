import AppKit
import YcodeIDECore

/// The merge confirmation (`specs/ide/merge-sheet.md` §1.2): a 420 × 132
/// window-modal alert centred on the workspace window, Ycode's icon, the
/// bold title and the message, then Cancel and **Merge** (the default:
/// Return; Cancel answers Escape). Integrate ▸ Merge… adds a pop-up of
/// the branches to merge from (Ycode's choice).
@MainActor
public final class MergeAlertView: NSView {
    public let iconView = AlertIconView()
    public let titleField = AlertTextField(wrappingLabelWithString: "")
    public let messageField = AlertTextField(wrappingLabelWithString: "")
    /// The empty status image first among the children (§16.1, row 195).
    public let statusImage = AlertStatusImage()
    public let cancelButton = MergeButton(title: MergeSheetText.cancel)
    public let mergeButton = MergeButton(title: MergeSheetText.merge)
    /// Integrate ▸ Merge…: the branch to merge from.
    public private(set) var chooser: NSPopUpButton?
    public private(set) var branch: String
    let current: String
    var onMerge: ((String) -> Void)?
    var onCancel: (() -> Void)?

    public init(branch: String, current: String, choices: [String]? = nil) {
        self.branch = branch
        self.current = current
        super.init(frame: NSRect(x: 0, y: 0, width: MergeSheetMetrics.alertWidth, height: MergeSheetMetrics.alertHeight))
        wantsLayer = true
        layer?.cornerRadius = MergeSheetMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 24
            s.shadowOffset = NSSize(width: 0, height: -6)
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            return s
        }()
        // Ycode's icon, as on Linux (a process without its own icon file,
        // such as a test host, would show the system's generic one).
        iconView.image = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil ? ProductIcon.image : NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // An image with a description to accessibility (merge-sheet.md §15.4).
        iconView.setAccessibilityElement(true)
        iconView.setAccessibilityRole(.image)
        iconView.setAccessibilityLabel(MergeSheetText.alertIconDescription)
        titleField.font = .boldSystemFont(ofSize: 13)
        messageField.font = .systemFont(ofSize: 11)
        for f in [titleField, messageField] {
            f.isSelectable = false
            f.maximumNumberOfLines = 2
            f.lineBreakMode = .byWordWrapping
            // Static texts to accessibility (§13.2), whatever the field's cell says.
            f.setAccessibilityElement(true)
            f.setAccessibilityRole(.staticText)
        }
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        mergeButton.target = self
        mergeButton.action = #selector(merge(_:))
        mergeButton.keyEquivalent = "\r"
        mergeButton.isDefaultLook = true
        for b in [cancelButton, mergeButton] { b.fontSize = 13 }
        if let choices, !choices.isEmpty {
            let p = NSPopUpButton()
            p.addItems(withTitles: choices)
            p.selectItem(withTitle: branch)
            p.controlSize = .small
            p.target = self
            p.action = #selector(chosen(_:))
            p.setAccessibilityLabel("Branch to merge from")
            chooser = p
            addSubview(p)
        }
        for v in [statusImage, iconView, titleField, messageField, cancelButton, mergeButton] as [NSView] { addSubview(v) }
        // §16.1 (row 195): the elements' heights and the icon's square.
        titleField.elementHeight = CGFloat(MergeSheetText.alertMessageElementHeight)
        messageField.elementHeight = CGFloat(MergeSheetText.alertInformativeElementHeight)
        updateTexts()
        // An accessibility sheet (§13.2): the title and message are static
        // texts, Cancel and Merge buttons, Merge its default button and
        // Cancel its cancel button.
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityModal(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    func updateTexts() {
        titleField.stringValue = MergeSheetText.alertTitle(branch: branch)
        messageField.stringValue = MergeSheetText.alertMessage(branch: branch, current: current)
    }

    /// No description (§16.1): the sheet's title text names it.
    public override func accessibilityLabel() -> String? { nil }
    public override func accessibilityDefaultButton() -> Any? { mergeButton }
    public override func accessibilityCancelButton() -> Any? { cancelButton }
    /// The reference's order (`merge-sheet.md` §15.4, council row 168): the
    /// default button, the cancel button, the message, the application's
    /// icon (an image with a description), the informative text; then the
    /// branch pop-up when there is one. Round 7 (§16.1): an empty status
    /// image with no description before them all.
    public override func accessibilityChildren() -> [Any]? {
        var out: [Any] = [statusImage, mergeButton, cancelButton, titleField, iconView, messageField]
        if let chooser { out.append(chooser) }
        return out
    }

    var palette: MergeSheetPalette { MergeSheetPalette.forDark(effectiveAppearance.isDarkMerge) }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor(mergeHex: palette.sheet).cgColor
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func layout() {
        super.layout()
        typealias M = MergeSheetMetrics
        iconView.frame = NSRect(x: M.alertIconOrigin.x, y: M.alertIconOrigin.y, width: M.alertIcon, height: M.alertIcon)
        let side = CGFloat(MergeSheetText.alertStatusImageSide)
        statusImage.frame = NSRect(x: MergeSheetText.alertStatusImageOrigin.x, y: bounds.height - 20 - side, width: side, height: side)
        let textWidth = bounds.width - M.alertTextX - 20
        // The title's first cap top 20 below the alert's top.
        let titleFont = titleField.font ?? .boldSystemFont(ofSize: 13)
        let capOffset = (titleFont.ascender - titleFont.capHeight).rounded()
        titleField.frame = NSRect(x: M.alertTextX - 2, y: M.alertTitleTop - capOffset, width: textWidth + 4, height: 34)
        messageField.frame = NSRect(x: M.alertTextX - 2, y: M.alertMessageTop - 2, width: textWidth + 4, height: 30)
        var bottom = bounds.height - M.alertButtonBottom
        if let p = chooser {
            p.frame = NSRect(x: M.alertTextX, y: M.alertMessageTop + 30, width: textWidth, height: 22)
            bottom = bounds.height - M.alertButtonBottom
        }
        let y = bottom - M.alertButtonHeight
        let mergeX = bounds.width - M.alertButtonTrailing - M.alertMergeWidth
        mergeButton.frame = NSRect(x: mergeX, y: y, width: M.alertMergeWidth, height: M.alertButtonHeight)
        cancelButton.frame = NSRect(x: mergeX - M.alertButtonSpacing - M.alertCancelWidth, y: y, width: M.alertCancelWidth, height: M.alertButtonHeight)
    }

    @objc func chosen(_ sender: NSPopUpButton) {
        guard let t = sender.titleOfSelectedItem else { return }
        branch = t
        updateTexts()
    }

    @objc public func merge(_ sender: Any?) { onMerge?(branch) }
    @objc public func cancel(_ sender: Any?) { onCancel?() }

    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}": merge(nil)
        case "\u{1b}": cancel(nil)
        default: super.keyDown(with: event)
        }
    }

    public override func cancelOperation(_ sender: Any?) { cancel(sender) }
}

/// The alert's icon: drawn at its size, exposed as the reference's 66 × 66
/// element round it (§16.1, row 195).
public final class AlertIconView: NSImageView {
    public override func accessibilityFrame() -> NSRect {
        let f = super.accessibilityFrame()
        let side = CGFloat(MergeSheetText.alertIconElementSide)
        return NSRect(x: f.midX - side / 2, y: f.midY - side / 2, width: side, height: side)
    }
}

/// The alert's texts: exposed 296 wide and at the reference's height from
/// their top (§16.1: the message 34, the informative text 30).
public final class AlertTextField: NSTextField {
    var elementHeight: CGFloat?
    public override func accessibilityFrame() -> NSRect {
        var f = super.accessibilityFrame()
        guard let h = elementHeight else { return f }
        f.origin.x += (f.width - CGFloat(MergeSheetText.alertTextElementWidth)) / 2
        f.size.width = CGFloat(MergeSheetText.alertTextElementWidth)
        f.origin.y = f.maxY - h   // screen space: keep the top
        f.size.height = h
        return f
    }
}

/// The reference's empty status image: 18 × 18, no description, nothing drawn.
public final class AlertStatusImage: NSView {
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .image }
    public override func accessibilityLabel() -> String? { nil }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
