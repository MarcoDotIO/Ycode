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

    public static func make(_ doc: QuickHelpDocument, width: CGFloat = 230) -> NSStackView {
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
        if !doc.declaration.isEmpty {
            let d = box([label(doc.declaration, mono: true)], tint: .tertiaryLabelColor)
            d.setAccessibilityIdentifier("quickhelp.declaration")
            stack.addArrangedSubview(d)
        }
        if let f = doc.file, doc.showsFileLink {
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
