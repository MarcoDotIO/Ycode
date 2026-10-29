// The device-control row under the device (device-hub.md §4.4): glass
// capsules about 37 points tall, 8 apart, centred under the device.
//
//   iPhone, iPad      [Home · Screenshot · Record] [Rotate]
//   iPhone Duo        [Home · Screenshot · Record] [Rotate │ Closed · Partially Open · Open]
//                     (Closed and Open are Ycode's own glyphs, DeviceGlyphs.swift)
//   visionOS          [Home · Screenshot · Record]
//
// Rotate: click = Rotate Left, Option-click = Rotate Right. The current
// pose's button is highlighted; Option-dragging on a pose button shows the
// hinge slider (the canvas draws it). Symbols are public SF Symbols chosen
// to match the reference's descriptions (Ycode decision, §8).

#if os(macOS)
import AppKit
import YcodeDeviceModel

/// A glass capsule (`NSGlassEffectView` on macOS 26 and later; a rounded
/// material view before) holding controls.
@MainActor
public final class GlassCapsule: NSView {
    public let content: NSView
    private let glass: NSView

    public init(content: NSView, height: CGFloat = 37) {
        self.content = content
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = height / 2
            g.style = .regular
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = height / 2
            v.layer?.masksToBounds = true
            glass = v
        }
        super.init(frame: .zero)
        for v in [glass, content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The recessed pill under a selected segment (the selected pose).
@MainActor
final class PillView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = bounds.height / 2
        layer?.cornerCurve = .continuous
    }
}

/// A row button. Option-drag on it reports the horizontal distance (the
/// pose buttons' hinge slider).
@MainActor
final class RowButton: NSButton {
    var command: DeviceCommand = .home
    var onOptionDrag: ((CGFloat?) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), let onOptionDrag, let window else { super.mouseDown(with: event); return }
        let start = event.locationInWindow.x
        onOptionDrag(0)
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            onOptionDrag(e.locationInWindow.x - start)
        }
        onOptionDrag(nil)
    }
}

@MainActor
public final class DeviceControlsRow: NSView {
    public static let height: CGFloat = 37
    /// A control was used.
    public var onCommand: ((DeviceCommand) -> Void)?
    /// Option-drag on a pose button: the distance in points, then nil.
    public var onHingeDrag: ((CGFloat?) -> Void)?

    private let stack = NSStackView()
    private var buttons: [DeviceCommand: RowButton] = [:]
    private let pill = PillView()
    private var poseGroup: NSView?
    public private(set) var configuration = Configuration()

    public struct Configuration: Equatable {
        public var foldable = false
        public var canRotate = false
        public var recording = false
        public var posture: DevicePosture?
        public var enabled = false
        public var showsRotate = true
        public init(foldable: Bool = false, canRotate: Bool = false, recording: Bool = false, posture: DevicePosture? = nil,
                    enabled: Bool = false, showsRotate: Bool = true) {
            self.foldable = foldable
            self.canRotate = canRotate
            self.recording = recording
            self.posture = posture
            self.enabled = enabled
            self.showsRotate = showsRotate
        }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Device Controls")
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The symbol and help text of each control.
    static func look(_ c: DeviceCommand, recording: Bool) -> (symbol: String, help: String) {
        switch c {
        case .home: ("circle.grid.3x3.fill", "Home")
        case .screenshot: ("camera.viewfinder", "Screenshot")
        case .recordScreen: recording ? ("stop.circle.fill", "Stop Recording") : ("record.circle", "Record Screen")
        case .rotateLeft: ("rotate.left", "Rotate (Option-click to rotate right)")
        case .poseClosed: ("", "Closed")
        case .posePartiallyOpen: ("book", "Partially Open (Option-drag to set any angle)")
        case .poseOpen: ("", "Open")
        default: ("questionmark", c.title)
        }
    }

    /// The controls shown, by group (tests).
    public var groups: [[DeviceCommand]] {
        var g: [[DeviceCommand]] = [[.home, .screenshot, .recordScreen]]
        var second: [DeviceCommand] = configuration.showsRotate ? [.rotateLeft] : []
        if configuration.foldable { second += [.poseClosed, .posePartiallyOpen, .poseOpen] }
        if !second.isEmpty { g.append(second) }
        return g
    }

    public func configure(_ c: Configuration) {
        guard c != configuration else { return }
        let rebuildNeeded = c.foldable != configuration.foldable || c.showsRotate != configuration.showsRotate
        configuration = c
        if rebuildNeeded { rebuild() } else { update() }
    }

    /// The button of a control (tests, the script runner).
    public func button(for c: DeviceCommand) -> NSButton? { buttons[c] }

    private func makeButton(_ c: DeviceCommand) -> RowButton {
        let b = RowButton(title: "", target: self, action: #selector(clicked(_:)))
        b.command = c
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleNone
        b.refusesFirstResponder = true
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 37), b.heightAnchor.constraint(equalToConstant: 33)])
        if [.poseClosed, .posePartiallyOpen, .poseOpen].contains(c) {
            b.onOptionDrag = { [weak self] d in self?.onHingeDrag?(d) }
        }
        buttons[c] = b
        return b
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = [:]
        poseGroup = nil
        for (i, group) in groups.enumerated() {
            let inner = NSStackView()
            inner.orientation = .horizontal
            inner.spacing = 0
            for c in group {
                if c == .poseClosed {
                    let sep = NSBox()
                    sep.boxType = .separator
                    sep.translatesAutoresizingMaskIntoConstraints = false
                    sep.heightAnchor.constraint(equalToConstant: 20).isActive = true
                    inner.addArrangedSubview(sep)
                    inner.setCustomSpacing(4, after: inner.arrangedSubviews.last!)
                }
                inner.addArrangedSubview(makeButton(c))
                if c == .rotateLeft, configuration.foldable { inner.setCustomSpacing(4, after: inner.arrangedSubviews.last!) }
            }
            let capsule = GlassCapsule(content: inner, height: Self.height)
            capsule.identifier = .init(i == 0 ? "device-controls-capture" : "device-controls-orientation")
            if configuration.foldable && i == 1 { poseGroup = inner; inner.addSubview(pill, positioned: .below, relativeTo: nil) }
            stack.addArrangedSubview(capsule)
        }
        update()
    }

    private func update() {
        for (c, b) in buttons {
            let look = Self.look(c, recording: configuration.recording)
            // Closed and Open are Ycode's own glyphs (no product symbols, AGENTS.md rule 5).
            switch c {
            case .poseClosed: b.image = DeviceGlyph.phone.image(height: 17)
            case .poseOpen: b.image = DeviceGlyph.openFlat.image(height: 13)
            default:
                b.image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: look.help)?
                    .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            }
            b.toolTip = look.help
            b.setAccessibilityLabel(look.help)
            b.contentTintColor = c == .recordScreen && configuration.recording ? .systemRed : nil
            switch c {
            case .rotateLeft: b.isEnabled = configuration.enabled && configuration.canRotate
            default: b.isEnabled = configuration.enabled
            }
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        // The pill under the current pose's button.
        guard let p = configuration.posture, let group = poseGroup,
              let b = buttons[p == .closed ? .poseClosed : p == .halfOpen ? .posePartiallyOpen : .poseOpen] else { pill.isHidden = true; return }
        group.layoutSubtreeIfNeeded()
        let r = b.frame
        pill.frame = NSRect(x: r.midX - 16, y: r.midY - 13, width: 32, height: 26)
        pill.isHidden = false
    }

    @objc private func clicked(_ sender: RowButton) {
        var c = sender.command
        if c == .rotateLeft, NSApp.currentEvent?.modifierFlags.contains(.option) == true { c = .rotateRight }
        onCommand?(c)
    }

    public override var intrinsicContentSize: NSSize { stack.fittingSize }
}
#endif
