import AppKit

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
        if let f = doc.file {
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
        if !doc.discussion.isEmpty {
            stack.addArrangedSubview(section("Discussion"))
            for p in doc.discussion { stack.addArrangedSubview(label(p)) }
        }
        for c in doc.callouts {
            let tint: NSColor = ["Warning", "Important", "Attention", "Bug"].contains(c.title) ? .systemOrange : .systemBlue
            let b = box([label(c.title, weight: .semibold), label(c.text)], tint: tint)
            b.setAccessibilityIdentifier("quickhelp.callout")
            stack.addArrangedSubview(b)
        }
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

/// A target that runs a closure (keeps button wiring local).
final class ClosureTarget: NSObject {
    nonisolated(unsafe) static var key = 0
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}
