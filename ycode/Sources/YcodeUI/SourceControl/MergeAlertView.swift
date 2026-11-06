import AppKit
import YcodeIDECore

/// The merge confirmation (`specs/ide/merge-sheet.md` §1.2): a 420 × 133
/// window-modal alert centred on the workspace window, Ycode's icon, the
/// bold title and the message, then Cancel and **Merge** (the default:
/// Return; Cancel answers Escape). Integrate ▸ Merge… adds a pop-up of
/// the branches to merge from (Ycode's choice).
@MainActor
public final class MergeAlertView: NSView {
    public let iconView = NSImageView()
    public let titleField = NSTextField(wrappingLabelWithString: "")
    public let messageField = NSTextField(wrappingLabelWithString: "")
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
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.font = .boldSystemFont(ofSize: 13)
        messageField.font = .systemFont(ofSize: 11)
        for f in [titleField, messageField] {
            f.isSelectable = false
            f.maximumNumberOfLines = 2
            f.lineBreakMode = .byWordWrapping
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
        for v in [iconView, titleField, messageField, cancelButton, mergeButton] as [NSView] { addSubview(v) }
        updateTexts()
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityLabel(titleField.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    func updateTexts() {
        titleField.stringValue = MergeSheetText.alertTitle(branch: branch)
        messageField.stringValue = MergeSheetText.alertMessage(branch: branch, current: current)
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
