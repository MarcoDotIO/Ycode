// The device-control capsules (device-hub.md §4.4, §11.1; council round 3
// row 65): two glass capsules 36.5 points tall floating at the bottom of the
// canvas, 7.5 apart, glyphs on a 34-point pitch (DeviceControlsLayout, shared
// with the Linux device window).
//
//   iPhone, iPad      [Home · Screenshot · Record] [Rotate]
//   iPhone Duo        [Home · Screenshot · Record] [Rotate │ Closed · Partially Open · Open]
//                     (Closed and Open are Ycode's own glyphs, DeviceGlyphs.swift)
//   Apple Watch       [Screenshot · Record]
//   visionOS          [Home · Screenshot · Record] [Reset Camera]
//
// Rotate: click = Rotate Left, Option-click = Rotate Right. The current
// pose's glyph is drawn in the accent colour; Option-dragging on a pose
// button shows the hinge slider (the canvas draws it). Symbols are public
// SF Symbols chosen to match the reference's descriptions (Ycode decision,
// §8).

#if os(macOS)
import AppKit
import YcodeDeviceModel

/// A glass capsule (`NSGlassEffectView` on macOS 26 and later; a rounded
/// material view before) holding controls.
@MainActor
public final class GlassCapsule: NSView {
    public let content: NSView
    private let glass: NSView

    public init(content: NSView, height: CGFloat = 37, inset: CGFloat = 4) {
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
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
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
    public static let height = CGFloat(DeviceControlsLayout.height)
    /// A control was used.
    public var onCommand: ((DeviceCommand) -> Void)?
    /// Option-drag on a pose button: the distance in points, then nil.
    public var onHingeDrag: ((CGFloat?) -> Void)?

    private var buttons: [DeviceCommand: RowButton] = [:]
    /// The capsules, left to right (tests: their frames).
    public private(set) var capsules: [GlassCapsule] = []
    public private(set) var configuration = Configuration()

    public struct Configuration: Equatable {
        public var foldable = false
        public var canRotate = false
        public var recording = false
        public var posture: DevicePosture?
        public var enabled = false
        public var showsRotate = true
        /// Home in the first group (a watch has none: its crown on the
        /// frame is its Home, and its row is [Screenshot · Record]).
        public var showsHome = true
        /// A Vision Pro: Reset Camera in place of Rotate (§4.4).
        public var spatial = false
        public init(foldable: Bool = false, canRotate: Bool = false, recording: Bool = false, posture: DevicePosture? = nil,
                    enabled: Bool = false, showsRotate: Bool = true, showsHome: Bool = true, spatial: Bool = false) {
            self.foldable = foldable
            self.canRotate = canRotate
            self.recording = recording
            self.posture = posture
            self.enabled = enabled
            self.showsRotate = showsRotate
            self.showsHome = showsHome
            self.spatial = spatial
        }

        var device: DeviceControlsLayout.Device {
            .init(showsHome: showsHome, rotates: showsRotate, foldable: foldable, spatial: spatial)
        }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Device Controls")
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// The symbol and help text of each control.
    static func look(_ c: DeviceCommand, recording: Bool) -> (symbol: String, help: String) {
        switch c {
        case .home: ("circle.grid.3x3.fill", "Home")
        case .screenshot: ("camera.viewfinder", "Screenshot")
        case .recordScreen: recording ? ("stop.circle.fill", "Stop Recording") : ("record.circle", "Record Screen")
        case .rotateLeft: ("rotate.left", "Rotate (Option-click to rotate right)")
        case .resetCamera: ("arrow.counterclockwise", "Reset Camera")
        case .poseClosed: ("", "Closed")
        case .posePartiallyOpen: ("book", "Partially Open (Option-drag to set any angle)")
        case .poseOpen: ("", "Open")
        default: ("questionmark", c.title)
        }
    }

    /// The controls shown, by capsule (tests).
    public var groups: [[DeviceCommand]] { DeviceControlsLayout.groups(configuration.device) }

    public func configure(_ c: Configuration) {
        guard c != configuration else { return }
        let rebuildNeeded = c.device != configuration.device
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
        b.identifier = .init("device-control-\(c.rawValue)")
        if [.poseClosed, .posePartiallyOpen, .poseOpen].contains(c) {
            b.onOptionDrag = { [weak self] d in self?.onHingeDrag?(d) }
        }
        buttons[c] = b
        return b
    }

    private func rebuild() {
        capsules.forEach { $0.removeFromSuperview() }
        capsules = []
        buttons = [:]
        for (i, group) in groups.enumerated() {
            let inner = FlippedView()
            let w = CGFloat(DeviceControlsLayout.width(of: group))
            for (c, cx) in zip(group, DeviceControlsLayout.glyphCentres(of: group)) {
                let b = makeButton(c)
                b.frame = CGRect(x: CGFloat(cx - DeviceControlsLayout.buttonWidth / 2), y: 0,
                                 width: CGFloat(DeviceControlsLayout.buttonWidth), height: Self.height)
                inner.addSubview(b)
            }
            if let d = DeviceControlsLayout.dividerCentre(of: group) {
                let dh = CGFloat(DeviceControlsLayout.dividerHeight)
                let sep = DividerLine(frame: CGRect(x: CGFloat(d) - 0.5, y: (Self.height - dh) / 2, width: 1, height: dh))
                sep.identifier = .init("device-controls-divider")
                inner.addSubview(sep)
            }
            inner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([inner.widthAnchor.constraint(equalToConstant: w), inner.heightAnchor.constraint(equalToConstant: Self.height)])
            let capsule = GlassCapsule(content: inner, height: Self.height, inset: 0)
            capsule.identifier = .init(i == 0 ? "device-controls-capture" : "device-controls-orientation")
            capsule.translatesAutoresizingMaskIntoConstraints = true
            addSubview(capsule)
            capsules.append(capsule)
        }
        update()
        needsLayout = true
    }

    private func update() {
        for (c, b) in buttons {
            let look = Self.look(c, recording: configuration.recording)
            // Closed and Open are Ycode's own glyphs (no product symbols, AGENTS.md rule 5).
            switch c {
            case .poseClosed: b.image = DeviceGlyph.phone.image(height: 16, lit: true)
            case .poseOpen: b.image = DeviceGlyph.openFlat.image(height: 13, lit: true)
            default:
                b.image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: look.help)?
                    .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            }
            b.toolTip = look.help
            b.setAccessibilityLabel(look.help)
            // Glyphs black (white in dark, §12.1), the current pose in the accent colour (§11.1).
            b.contentTintColor = c == .recordScreen && configuration.recording ? .systemRed
                : Self.isCurrentPose(c, configuration.posture) ? .controlAccentColor : Self.glyphColor
            switch c {
            case .rotateLeft: b.isEnabled = configuration.enabled && configuration.canRotate
            default: b.isEnabled = configuration.enabled
            }
        }
    }

    /// The glyphs: black on the light glass, white on the dark (§11.1, §12.1).
    static let glyphColor = NSColor(name: "ycode.deviceControls.glyph") { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }

    /// The divider between Rotate and the poses: #E9E9E9 on the light glass,
    /// #505052 on the dark (§11.1, §12.1).
    static let dividerColor = NSColor(name: "ycode.deviceControls.divider") { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x50 / 255, green: 0x50 / 255, blue: 0x52 / 255, alpha: 1)
            : NSColor(srgbRed: 0xE9 / 255, green: 0xE9 / 255, blue: 0xE9 / 255, alpha: 1)
    }

    static func isCurrentPose(_ c: DeviceCommand, _ p: DevicePosture?) -> Bool {
        switch (c, p) {
        case (.poseClosed, .closed?), (.posePartiallyOpen, .halfOpen?), (.poseOpen, .openFlat?): true
        default: false
        }
    }

    /// The command whose glyph is drawn in the accent colour (tests).
    public var highlightedPose: DeviceCommand? {
        [DeviceCommand.poseClosed, .posePartiallyOpen, .poseOpen].first { Self.isCurrentPose($0, configuration.posture) }
    }

    public override func layout() {
        super.layout()
        // The capsules side by side, 7.5 apart, filling the row's height.
        var x: CGFloat = 0
        for (g, c) in zip(groups, capsules) {
            let w = CGFloat(DeviceControlsLayout.width(of: g))
            c.frame = CGRect(x: x, y: 0, width: w, height: Self.height)
            x += w + CGFloat(DeviceControlsLayout.gap)
        }
    }

    @objc private func clicked(_ sender: RowButton) {
        var c = sender.command
        if c == .rotateLeft, NSApp.currentEvent?.modifierFlags.contains(.option) == true { c = .rotateRight }
        onCommand?(c)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(DeviceControlsLayout.totalWidth(groups)), height: Self.height)
    }
}

/// The one-point line between Rotate and the poses (#E9E9E9 on the light
/// glass, #505052 on the dark), 15 tall in the reference's dark capture.
@MainActor
final class DividerLine: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        var c = NSColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance { c = DeviceControlsRow.dividerColor.usingColorSpace(.sRGB) ?? .gray }
        layer?.backgroundColor = c.cgColor
    }
}
#endif
