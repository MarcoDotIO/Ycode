import AppKit
import YcodeIDECore

/// The Quick Help inspector body (`specs/ide/reference-ui-4.md` §7): title
/// and summary, a wrapped declaration box, the file link, Parameters,
/// Return Value, Throws, Discussion, boxed callouts, then "Open in
/// Developer Documentation".
@MainActor
public enum QuickHelpView {
    /// Opens the defining file (set by the window).
    public static var onOpenFile: ((String) -> Void)?
    /// "Open in Developer Documentation" (set by the window).
    public static var onOpenDocumentation: ((String) -> Void)?

    /// - Parameter popover: the popover's look (§4.2): a borderless 385-wide
    ///   declaration box with modifiers on their own line and the file's
    ///   own glyph; otherwise the inspector's.
    public static func make(_ doc: QuickHelpDocument, width: CGFloat = 230, popover: Bool = false) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        func label(_ s: String, size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
            // Inline styles (P-083): italic, bold and code voice.
            if !mono { l.attributedStringValue = attributed(doc.runs(for: s), size: size, weight: weight, color: color) }
            l.textColor = color
            l.preferredMaxLayoutWidth = width
            l.isSelectable = true
            l.setAccessibilityIdentifier("quickhelp.text")
            return l
        }
        func box(_ content: [NSView], tint: NSColor) -> NSView {
            let b = NSStackView(views: content)
            b.orientation = .vertical
            b.alignment = .leading
            b.spacing = 3
            b.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
            b.layer?.borderColor = tint.withAlphaComponent(0.35).cgColor
            b.layer?.borderWidth = 1
            return b
        }
        func section(_ name: String) -> NSTextField {
            let l = label(name, size: 11, weight: .semibold, color: .secondaryLabelColor)
            l.setAccessibilityIdentifier("quickhelp.section")
            return l
        }
        let title = label(doc.title, size: 15, weight: .bold)
        title.setAccessibilityIdentifier("quickhelp.title")
        stack.addArrangedSubview(title)
        if let s = doc.summary { stack.addArrangedSubview(label(s)) }
        if !doc.declaration.isEmpty, popover {
            let d = QuickHelpDeclarationBox(doc.declaration)
            d.setAccessibilityIdentifier("quickhelp.declaration")
            stack.addArrangedSubview(d)
            stack.setCustomSpacing(CGFloat(QuickHelpPopoverMetrics.titleToDeclaration), after: stack.arrangedSubviews[max(0, stack.arrangedSubviews.count - 2)])
            stack.setCustomSpacing(CGFloat(QuickHelpPopoverMetrics.declarationToFile), after: d)
        } else if !doc.declaration.isEmpty {
            let d = box([label(doc.declaration, mono: true)], tint: .tertiaryLabelColor)
            d.setAccessibilityIdentifier("quickhelp.declaration")
            stack.addArrangedSubview(d)
        }
        if let f = doc.file, doc.showsFileLink, popover {
            let link = QuickHelpFileLink(path: f)
            link.setAccessibilityIdentifier("quickhelp.file")
            stack.addArrangedSubview(link)
        } else if let f = doc.file, doc.showsFileLink {
            let link = NSButton(title: (f as NSString).lastPathComponent, target: nil, action: nil)
            link.isBordered = false
            link.contentTintColor = .linkColor
            link.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            link.imagePosition = .imageLeading
            link.setAccessibilityIdentifier("quickhelp.file")
            let action = ClosureTarget { onOpenFile?(f) }
            link.target = action
            link.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(link, &ClosureTarget.key, action, .OBJC_ASSOCIATION_RETAIN)
            stack.addArrangedSubview(link)
        }
        if !doc.parameters.isEmpty {
            stack.addArrangedSubview(section("Parameters"))
            for p in doc.parameters {
                stack.addArrangedSubview(label(p.name, weight: .semibold, mono: true))
                stack.addArrangedSubview(label(p.text))
            }
        }
        if let r = doc.returns { stack.addArrangedSubview(section("Return Value")); stack.addArrangedSubview(label(r)) }
        if let t = doc.throwsText { stack.addArrangedSubview(section("Throws")); stack.addArrangedSubview(label(t)) }
        if !doc.discussionBlocks.isEmpty {
            stack.addArrangedSubview(section("Discussion"))
            for b in doc.discussionBlocks { stack.addArrangedSubview(block(b, width: width)) }
        }
        for c in doc.callouts {
            let tint: NSColor = ["Warning", "Important", "Attention", "Bug"].contains(c.title) ? .systemOrange : .systemBlue
            let b = box([label(c.title, weight: .semibold), label(c.text)], tint: tint)
            b.setAccessibilityIdentifier("quickhelp.callout")
            stack.addArrangedSubview(b)
        }
        guard doc.showsDocumentationLink else { return stack }
        let open = NSButton(title: "Open in Developer Documentation", target: nil, action: nil)
        open.isBordered = false
        open.contentTintColor = .linkColor
        let action = ClosureTarget { onOpenDocumentation?(doc.title) }
        open.target = action
        open.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(open, &ClosureTarget.key, action, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(open)
        return stack
    }
}

extension QuickHelpView {
    /// Runs as attributed text: emphasis italic, strong bold, code voice in
    /// the monospaced face.
    static func attributed(_ runs: [QuickHelpRun], size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        for r in runs {
            let font: NSFont = switch r.style {
            case .plain: base
            case .emphasis: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            case .strong: NSFont.systemFont(ofSize: size, weight: .bold)
            case .code: NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            }
            out.append(NSAttributedString(string: r.text, attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }

    /// One Discussion block: a paragraph, a heading, a list item with its
    /// marker hanging, or a code block with its line breaks.
    static func block(_ b: QuickHelpBlock, width: CGFloat) -> NSView {
        func text(_ a: NSAttributedString, _ w: CGFloat) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: "")
            l.attributedStringValue = a
            l.preferredMaxLayoutWidth = w
            l.isSelectable = true
            l.setAccessibilityIdentifier("quickhelp.text")
            return l
        }
        switch b {
        case .paragraph(let r):
            return text(attributed(r, size: 11), width)
        case .heading(let r):
            let l = text(attributed(r, size: 13, weight: .bold), width)
            l.setAccessibilityIdentifier("quickhelp.heading")
            return l
        case .code(let code):
            let l = text(NSAttributedString(string: code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                                                       .foregroundColor: NSColor.labelColor]), width - 16)
            l.lineBreakMode = .byCharWrapping
            let box = NSStackView(views: [l])
            box.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
            box.wantsLayer = true
            box.layer?.cornerRadius = 5
            box.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.12).cgColor
            box.setAccessibilityIdentifier("quickhelp.code")
            return box
        case .listItem(let marker, let r):
            let m = NSTextField(labelWithString: marker)
            m.font = .systemFont(ofSize: 11)
            m.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [m, text(attributed(r, size: 11), width - 18)])
            row.alignment = .firstBaseline
            row.spacing = 4
            row.setAccessibilityIdentifier("quickhelp.listItem")
            return row
        }
    }
}

/// A target that runs a closure (keeps button wiring local).
final class ClosureTarget: NSObject {
    nonisolated(unsafe) static var key = 0
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}

/// Quick Help over the editor (`specs/ide/popovers.md` §4, P-083): an
/// anchored popover always **above** the symbol, its arrow pointing down
/// with the tip 3 points over the symbol's line, centred on the symbol;
/// never flipped below and never clipped to the window (the popover is a
/// window of its own; only the screen limits it). The body is 417 points
/// wide (§4.2) and as tall as its content: the bold title, the borderless
/// declaration box (385 wide, modifiers on their own line), the file link
/// with the file's glyph, then the inspector's sections; for a module
/// (§4.1) the title, the abstract, a hairline, Overview and the
/// documentation link at the bottom right.
@MainActor
public enum QuickHelpPopover {
    /// The body's inner padding (sides).
    public static let padding = CGFloat(QuickHelpPopoverMetrics.sideInset)

    /// The symbol's rectangle in `tv`: the word at `anchor`'s start (the
    /// caret's or the clicked character's rectangle), else `anchor`.
    public static func symbolRect(in tv: NSTextView, near anchor: NSRect) -> NSRect {
        // TextKit 2 (the source editor's view): no layout manager here.
        guard let sv = tv as? SourceTextView, !tv.string.isEmpty else { return anchor }
        let i = tv.characterIndexForInsertion(at: NSPoint(x: anchor.minX + 1, y: anchor.midY))
        let n = (tv.string as NSString).length
        guard i != NSNotFound, n > 0 else { return anchor }
        let word = tv.selectionRange(forProposedRange: NSRange(location: min(i, n - 1), length: 0), granularity: .selectByWord)
        guard word.length > 0, let r = sv.segmentRects(word).first else { return anchor }
        return r
    }

    /// The content: the rendered document, `width` wide.
    public static func content(_ doc: QuickHelpDocument, width: CGFloat = CGFloat(QuickHelpPopoverMetrics.width)) -> NSViewController {
        let m = QuickHelpPopoverMetrics.self
        let inner = width - 2 * padding
        let stack = doc.isModule ? moduleStack(doc, width: inner) : QuickHelpView.make(doc, width: inner, popover: true)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = FlippedView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: CGFloat(m.topInset)),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            stack.widthAnchor.constraint(equalToConstant: inner),
        ])
        let fit = stack.fittingSize
        root.frame = NSRect(x: 0, y: 0, width: width, height: fit.height + CGFloat(m.topInset + m.bottomInset))
        root.setAccessibilityIdentifier("quickhelp.popover")
        let vc = NSViewController()
        vc.view = root
        vc.preferredContentSize = root.frame.size
        return vc
    }

    /// A module's Quick Help (§4.1): title, abstract, hairline, Overview
    /// and its text, then "Open in Developer Documentation" at the bottom
    /// right. No declaration box, no file link.
    static func moduleStack(_ doc: QuickHelpDocument, width: CGFloat) -> NSStackView {
        let m = QuickHelpPopoverMetrics.self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        func text(_ a: NSAttributedString, id: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: "")
            l.attributedStringValue = a
            l.preferredMaxLayoutWidth = width
            l.isSelectable = true
            l.setAccessibilityIdentifier(id)
            return l
        }
        let title = text(NSAttributedString(string: doc.title, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(m.titleFontSize), weight: .bold),
                                                                           .foregroundColor: NSColor.labelColor]), id: "quickhelp.title")
        stack.addArrangedSubview(title)
        if let s = doc.summary {
            stack.addArrangedSubview(text(QuickHelpView.attributed(doc.runs(for: s), size: CGFloat(m.bodyFontSize)), id: "quickhelp.text"))
        }
        if !doc.overview.isEmpty {
            let rule = QuickHelpHairline()
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.setAccessibilityIdentifier("quickhelp.hairline")
            NSLayoutConstraint.activate([rule.heightAnchor.constraint(equalToConstant: 1), rule.widthAnchor.constraint(equalToConstant: width)])
            stack.addArrangedSubview(rule)
            stack.setCustomSpacing(10, after: rule)
            let heading = text(NSAttributedString(string: "Overview", attributes: [.font: NSFont.systemFont(ofSize: CGFloat(m.overviewFontSize), weight: .bold),
                                                                                    .foregroundColor: NSColor.labelColor]), id: "quickhelp.heading")
            stack.addArrangedSubview(heading)
            for b in doc.overview { stack.addArrangedSubview(QuickHelpView.block(b, width: width)) }
        }
        let open = NSButton(title: "Open in Developer Documentation", target: nil, action: nil)
        open.isBordered = false
        open.font = .systemFont(ofSize: CGFloat(m.linkFontSize))
        open.contentTintColor = .linkColor
        open.setAccessibilityIdentifier("quickhelp.documentation")
        let action = ClosureTarget { QuickHelpView.onOpenDocumentation?(doc.title) }
        open.target = action
        open.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(open, &ClosureTarget.key, action, .OBJC_ASSOCIATION_RETAIN)
        // Bottom right.
        let row = NSStackView(views: [NSView(), open])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last ?? title)
        stack.addArrangedSubview(row)
        return stack
    }

    /// The anchor the popover hangs from: the symbol's rectangle, raised
    /// by the 3-point gap so the arrow's tip stops short of the line.
    public static func anchor(symbol r: NSRect, flipped: Bool) -> NSRect {
        let gap = CGFloat(PopoverMetrics.textAnchorGap)
        return flipped ? NSRect(x: r.minX, y: r.minY - gap, width: r.width, height: r.height + gap)
            : NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height + gap)
    }

    /// Shows Quick Help for `doc` above the symbol at `anchor` in `tv`.
    /// Returns the content (shown only while `tv` is on screen).
    @discardableResult
    public static func show(_ doc: QuickHelpDocument, at anchor: NSRect, in tv: NSTextView) -> NSViewController {
        let c = content(doc)
        let r = Self.anchor(symbol: symbolRect(in: tv, near: anchor), flipped: tv.isFlipped)
        AnchoredPopover.show(c, anchor: r, of: tv, edge: .above)
        return c
    }
}

/// The popover's declaration box (§4.2): 385 × (17.5 per line + 15), no
/// border, corners 6, #262626 in dark; the declaration in the editor's
/// monospaced face, syntax-coloured, attributes and modifiers on their own
/// line.
@MainActor
public final class QuickHelpDeclarationBox: NSView {
    public let lines: [String]

    public init(_ declaration: String) {
        lines = QuickHelpDeclarationLines.lines(declaration)
        let m = QuickHelpPopoverMetrics.self
        super.init(frame: NSRect(x: 0, y: 0, width: m.declarationWidth, height: m.declarationHeight(lines: lines.count)))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: CGFloat(m.declarationWidth)),
            heightAnchor.constraint(equalToConstant: CGFloat(m.declarationHeight(lines: lines.count))),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(lines.joined(separator: "\n"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        let m = QuickHelpPopoverMetrics.self
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let v = m.declarationFill(dark: dark)
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: CGFloat(m.declarationRadius), yRadius: CGFloat(m.declarationRadius)).fill()
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(m.declarationFontSize), weight: .regular)
        let runs = MergeSheetLayout.highlight(lines, fileName: "Declaration.swift")
        for (i, line) in runs.enumerated() {
            let a = NSMutableAttributedString()
            for r in line {
                let color = r.role.map { DefaultTheme.color(for: $0, fallback: .labelColor) } ?? .labelColor
                a.append(NSAttributedString(string: r.text, attributes: [.font: font, .foregroundColor: color]))
            }
            let h = a.size().height
            let center = m.declarationVerticalPadding + (Double(i) + 0.5) * m.declarationLinePitch
            a.draw(with: NSRect(x: CGFloat(m.declarationHorizontalPadding), y: CGFloat(center) - h / 2,
                                width: bounds.width - CGFloat(2 * m.declarationHorizontalPadding), height: h),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

/// The popover's file link (§4.2): the file's own glyph in its type's tint
/// (a Swift file's orange), then its name in the accent colour; a click
/// opens it.
@MainActor
public final class QuickHelpFileLink: NSButton {
    let path: String
    let action_: ClosureTarget

    public init(path: String) {
        self.path = path
        action_ = ClosureTarget { QuickHelpView.onOpenFile?(path) }
        super.init(frame: .zero)
        title = (path as NSString).lastPathComponent
        isBordered = false
        font = .systemFont(ofSize: 12)
        contentTintColor = .linkColor
        let name = title
        image = NSImage(size: NSSize(width: 14, height: 14), flipped: true) { r in
            MergeDraw.fileIcon(name, in: r, color: MergeDraw.fileTint(name), pointSize: 11, box: (11.5, 11.5))
            return true
        }
        imagePosition = .imageLeading
        target = action_
        action = #selector(ClosureTarget.fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A module popover's hairline (§4.1).
@MainActor
final class QuickHelpHairline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let v = QuickHelpPopoverMetrics.hairline(dark: dark)
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1).setFill()
        bounds.fill()
    }
}
