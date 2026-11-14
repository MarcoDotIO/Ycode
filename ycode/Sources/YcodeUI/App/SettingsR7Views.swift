import AppKit
import YcodeIDECore

// Settings ▸ Appearance's colour rows (`specs/ide/settings.md` R6.1,
// R7.1–R7.3; checklist rows 182–184), drawn as the Linux IDE draws them
// (ycode-ide `SettingsR7Controls.swift`): the slider (a track of colour
// stops from `ThemeColorTrack`, a knob, a 202.5 × 36 frame that is its
// accessibility element), the colour button (48 × 28 in a slider row, 48 ×
// 24 alone), and the row (56 with a slider, 47 with the button only).

/// The colour slider: a 14-point capsule track through the track's stops
/// with a 1-point darker edge, a knob about 28 across (a white rim around
/// the colour under it) at the row's strength. The view is the track plus
/// 11 above and below (202.5 × 36), its accessibility element: a slider
/// titled by the row, its value a percentage, with increment and decrement.
final class ThemeColorSlider: NSControl {
    typealias RGB = ThemeColorRows.RGB
    var track: ThemeColorTrack { didSet { needsDisplay = true } }
    var value: Double {
        get { track.strength }
        set { track.strength = min(max(newValue, 0), 1); needsDisplay = true }
    }
    var onChange: ((Double) -> Void)?

    init(track: ThemeColorTrack) {
        self.track = track
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: SettingsAppearanceLayout.sliderWidth, height: SettingsAppearanceR7.sliderFrameHeight) }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    /// The colour at the knob.
    var color: RGB { track.knobColor }

    // MARK: Accessibility (R7.3)

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { NSNumber(value: Int((value * 100).rounded())) }
    override func accessibilityValueDescription() -> String? { ThemeColorRows.percent(value) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 100) }
    override func accessibilityPerformIncrement() -> Bool { step(up: true) }
    override func accessibilityPerformDecrement() -> Bool { step(up: false) }

    /// One accessibility step (5 %), reported as a drag would.
    @discardableResult
    func step(up: Bool) -> Bool {
        guard isEnabled else { return false }
        set(ThemeColorRows.stepped(value, up: up))
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let k = SettingsAppearanceLayout.sliderKnob, th = SettingsAppearanceLayout.sliderTrackHeight
        let rect = NSRect(x: 0, y: bounds.midY - th / 2, width: bounds.width, height: th)
        func ns(_ c: RGB) -> NSColor { NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1) }
        func gradient(_ factor: Double) -> NSGradient? {
            let colors = track.stops.map { ns(ThemeColorRows.darker($0.color, factor)) }
            var locations = track.stops.map { CGFloat($0.position) }
            return NSGradient(colors: colors, atLocations: &locations, colorSpace: .sRGB)
        }
        // The darker edge, then the gradient 1 point inside it.
        gradient(SettingsAppearanceR6.trackEdgeFactor)?.draw(in: NSBezierPath(roundedRect: rect, xRadius: th / 2, yRadius: th / 2), angle: 0)
        let w = SettingsAppearanceR6.edgeWidth
        let inner = rect.insetBy(dx: w, dy: w)
        gradient(1)?.draw(in: NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2), angle: 0)
        let x = k / 2 + CGFloat(value) * (bounds.width - k)
        let knob = NSRect(x: x - k / 2, y: bounds.midY - k / 2, width: k, height: k)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
        ns(color).setFill()
        NSBezierPath(ovalIn: knob.insetBy(dx: SettingsAppearanceR6.knobRim, dy: SettingsAppearanceR6.knobRim)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        follow(event)
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            follow(e)
            if e.type == .leftMouseUp { break }
        }
    }

    func follow(_ e: NSEvent) {
        let k = SettingsAppearanceLayout.sliderKnob
        let p = convert(e.locationInWindow, from: nil)
        set(Double((p.x - k / 2) / max(1, bounds.width - k)))
    }

    /// Moves the knob (0–1) and reports it.
    func set(_ v: Double) {
        value = v
        onChange?(value)
    }
}

/// The colour button: a capsule with a 3-point rim (#DFDFDF light) around
/// the colour, edged 1 point darker; 48 × 28 in a slider row, 48 × 24 in a
/// colour-only row (R7.1). A click shows the colour as #RRGGBB in a popover
/// to edit (Ycode's own editor, the same on Linux); an empty value is the
/// system's. To accessibility it is a button whose value is the colour
/// ("rgb 1 0.619608 0.768627 1", R7.3).
final class ThemeColorWellButton: NSButton, NSTextFieldDelegate {
    var color: NSColor { didSet { needsDisplay = true } }
    var hexValue: String
    var onCommit: ((String?) -> Void)?
    let size: CGSize
    private var popover: NSPopover?

    init(color: NSColor, hex: String?, size: CGSize = SettingsAppearanceLayout.wellSize) {
        self.color = color
        self.size = size
        hexValue = hex ?? ""
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(editColor)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { size }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityValue() -> Any? {
        let c = color.usingColorSpace(.sRGB) ?? color
        return ThemeColorRows.accessibilityValue((Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        SettingsR5Colors.wellRim.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        let inner = r.insetBy(dx: SettingsAppearanceLayout.wellRim, dy: SettingsAppearanceLayout.wellRim)
        let c = color.usingColorSpace(.sRGB) ?? color
        let e = CGFloat(SettingsAppearanceR6.wellEdgeFactor)
        NSColor(srgbRed: c.redComponent * e, green: c.greenComponent * e, blue: c.blueComponent * e, alpha: 1).setFill()
        NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
        let w = SettingsAppearanceR6.edgeWidth
        let core = inner.insetBy(dx: w, dy: w)
        c.setFill()
        NSBezierPath(roundedRect: core, xRadius: core.height / 2, yRadius: core.height / 2).fill()
    }

    @objc func editColor() {
        guard isEnabled, let w = window, w.isVisible else { return }
        let field = NSTextField(string: hexValue)
        field.placeholderString = "System"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.delegate = self
        field.frame = NSRect(x: 12, y: 12, width: 110, height: 22)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 134, height: 46))
        content.view.addSubview(field)
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = content
        popover = p
        p.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        commit(f.stringValue)
        popover?.close()
    }

    /// Saves a typed value: "#RRGGBB" (with or without "#"), or empty for
    /// the system colour; anything else is ignored.
    func commit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { hexValue = ""; onCommit?(nil); return }
        guard let c = ThemeColorRows.components(t) else { return }
        hexValue = ThemeColorRows.hex(c.r, c.g, c.b)
        color = NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
        onCommit?(hexValue)
    }
}

/// A colour row of the Theme list (R7.1): the label at the top-left (cap
/// top 13 under the row's top); a slider row (56) has the slider and a
/// 48 × 28 button centred in the row, a colour-only row (47) a 48 × 24
/// button. The track and the knob come from `ThemeColorRows.track` in the
/// row's appearance; a colour-only button shows the colour the editor draws.
final class ThemeColorRowView: NSView {
    enum Style { case slider, colorOnly }
    let style: Style
    let label: NSTextField
    /// The slider (in the view only for a slider row).
    let slider: ThemeColorSlider
    let well: ThemeColorWellButton
    let key: String
    /// The theme the row shows.
    var theme: EditorTheme
    /// The theme's colour as given (system colours are dynamic): resolved
    /// in the row's own appearance, flattened over the background, whenever
    /// the appearance changes.
    var dynamicColor: NSColor
    let dynamicBackground: NSColor

    init(title: String, key: String, theme: EditorTheme, color: NSColor, background: NSColor, style: Style = .slider) {
        self.style = style
        label = NSTextField(labelWithString: title)
        self.key = key
        self.theme = theme
        dynamicColor = color
        dynamicBackground = background
        slider = ThemeColorSlider(track: ThemeColorTrack(stops: [(0, (1, 1, 1)), (1, (1, 1, 1))], strength: ThemeColorRows.defaultStrength))
        let R = SettingsAppearanceR7.self
        well = ThemeColorWellButton(color: color, hex: ThemeColorRows.value(key, in: theme),
                                    size: style == .slider ? R.sliderButtonSize : R.colorButtonSize)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: SettingsMetrics.fontSize)
        label.textColor = SettingsColors.label
        label.lineBreakMode = .byTruncatingTail
        slider.setAccessibilityLabel(title)
        well.setAccessibilityLabel(title)
        let views: [NSView] = style == .slider ? [label, slider, well] : [label, well]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let L = SettingsAppearanceLayout.self
        // A 13-point label's cap top is about 3 inside its frame.
        var cs: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: style == .slider ? R.sliderRowHeight : R.colorRowHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.labelInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: R.labelCapTop - 3),
            well.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.controlInset),
            well.widthAnchor.constraint(equalToConstant: well.size.width),
            well.heightAnchor.constraint(equalToConstant: well.size.height),
            well.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if style == .slider {
            cs += [
                label.trailingAnchor.constraint(lessThanOrEqualTo: slider.leadingAnchor, constant: -8),
                slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: L.sliderX),
                slider.widthAnchor.constraint(equalToConstant: L.sliderWidth),
                slider.heightAnchor.constraint(equalToConstant: R.sliderFrameHeight),
                slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        } else {
            cs.append(label.trailingAnchor.constraint(lessThanOrEqualTo: well.leadingAnchor, constant: -8))
        }
        NSLayoutConstraint.activate(cs)
        resolve()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolve()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolve()
    }

    /// Whether the row is drawn dark.
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// The colours as drawn in this row's appearance: the track and the
    /// knob, the button's colour (the knob's in a slider row).
    func resolve() {
        var c = NSColor.black
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = Self.opaque(self.dynamicBackground, over: .white)
            c = Self.opaque(self.dynamicColor, over: bg)
        }
        let rgb = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        switch style {
        case .slider:
            slider.track = ThemeColorRows.track(key, in: theme, resolved: rgb, dark: isDark)
            showKnobColor()
        case .colorOnly:
            well.color = c
        }
    }

    /// The button shows the colour under the knob.
    func showKnobColor() {
        let k = slider.color
        well.color = NSColor(srgbRed: CGFloat(k.r), green: CGFloat(k.g), blue: CGFloat(k.b), alpha: 1)
    }

    /// `c` in sRGB with its transparency flattened over `bg`.
    static func opaque(_ c: NSColor, over bg: NSColor) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? .black
        let b = bg.usingColorSpace(.sRGB) ?? .white
        let a = s.alphaComponent
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * a + y * (1 - a) }
        return NSColor(srgbRed: mix(s.redComponent, b.redComponent), green: mix(s.greenComponent, b.greenComponent),
                       blue: mix(s.blueComponent, b.blueComponent), alpha: 1)
    }
}
