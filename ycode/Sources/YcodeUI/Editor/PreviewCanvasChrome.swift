import AppKit

/// One tab of the canvas header: a name with a spinner (building) or an
/// eye (rendered).
final class PreviewTabView: NSView {
    enum Badge { case none, spinner, eye }
    let label = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let eye = NSImageView(image: NSImage(systemSymbolName: "eye", accessibilityDescription: "Rendered") ?? NSImage())
    var index = 0
    var isSelected = false { didSet { needsDisplay = true } }
    var badge: Badge = .none {
        didSet {
            spinner.isHidden = badge != .spinner
            if badge == .spinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            eye.isHidden = badge != .eye
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: 11)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        eye.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [spinner, eye, label])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     spinner.widthAnchor.constraint(equalToConstant: 12), spinner.heightAnchor.constraint(equalToConstant: 12)])
        badge = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(white: 0.5, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5).fill()
    }
}

/// A rounded device bezel drawn around its single subview.
final class PreviewDeviceFrameView: NSView {
    static let bezel: CGFloat = 10

    init(content: NSView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let b = Self.bezel
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: topAnchor, constant: b),
                                     content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -b),
                                     content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: b),
                                     content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -b)])
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 22, yRadius: 22)
        NSColor(white: 0.12, alpha: 1).setFill()
        outer.fill()
        NSColor(white: 0.35, alpha: 1).setStroke()
        outer.lineWidth = 1
        outer.stroke()
        let inner = bounds.insetBy(dx: Self.bezel, dy: Self.bezel)
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(roundedRect: inner, xRadius: 13, yRadius: 13).fill()
    }
}

/// The "Canvas paused" capsule with its resume button.
final class PreviewPausedCapsule: NSView {
    let resume: NSButton

    init(target: AnyObject, action: Selector) {
        resume = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Resume") ?? NSImage(),
                          target: target, action: action)
        super.init(frame: .zero)
        resume.isBordered = false
        resume.toolTip = "Resume"
        resume.setAccessibilityLabel("Resume")
        let label = NSTextField(labelWithString: "Canvas paused")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let stack = NSStackView(views: [label, resume])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.controlBackgroundColor.setFill()
        p.fill()
        NSColor.separatorColor.setStroke()
        p.stroke()
    }
}
