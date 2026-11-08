import AppKit
import YcodeIDECore

// The controls of council round 5 in Settings (`specs/ide/settings.md`
// R5.1–R5.5), drawn by Ycode with the shared numbers
// (`SettingsAppearanceLayout`, `SettingsComponentsLayout`) and colours
// (`SettingsR5Palette`), as the Linux IDE draws them: the Appearance
// thumbnails and their ring, the preview box, the full-width separators,
// the Theme / Fonts / Editor control, the push button, the colour slider
// and well, Components' symbols, rows and info button.

@MainActor
enum SettingsR5Colors {
    static func dynamic(_ pair: SettingsPaletteHex.Pair) -> NSColor { SettingsColors.dynamic(pair) }
    static func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor { SettingsColors.rgb(v, a) }

    static let ring = dynamic(SettingsR5Palette.ring)
    static let caption = dynamic(SettingsR5Palette.caption)
    static let captionSelected = dynamic(SettingsR5Palette.captionSelected)
    static let previewBorder = dynamic(SettingsR5Palette.previewBorder)
    static let lineNumber = dynamic(SettingsR5Palette.lineNumber)
    static let paneSeparator = dynamic(SettingsR5Palette.paneSeparator)
    static let segmentsTrack = dynamic(SettingsR5Palette.segmentsTrack)
    static let segmentsDivider = dynamic(SettingsR5Palette.segmentsDivider)
    static let segmentsLabel = dynamic(SettingsR5Palette.segmentsLabel)
    static let segmentSelected = dynamic(SettingsR5Palette.segmentSelected)
    static let pushButton = dynamic(SettingsR5Palette.pushButton)
    static let pushButtonLabel = dynamic(SettingsR5Palette.pushButtonLabel)
    static let wellRim = dynamic(SettingsR5Palette.wellRim)
    static let subtitle = dynamic(SettingsR5Palette.subtitle)
    static let platformSymbol = dynamic(SettingsR5Palette.platformSymbol)
}

// MARK: Appearance thumbnails (R5.1)

/// One appearance's thumbnail: a 67 × 44 window-on-wallpaper picture,
/// with the 3-point ring 1 point outside it when chosen. The button's frame
/// is the picture plus 4 points on every side (the ring's room).
final class AppearanceThumbnailButton: NSButton {
    let appearanceChoice: Preferences.Appearance
    var onChoose: (() -> Void)?
    static let margin = SettingsAppearanceLayout.ringGap + SettingsAppearanceLayout.ringWidth

    init(_ a: Preferences.Appearance) {
        appearanceChoice = a
        super.init(frame: .zero)
        title = a.rawValue
        setButtonType(.onOff)
        isBordered = false
        imagePosition = .noImage
        target = self
        action = #selector(fire)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(a.rawValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func fire() { onChoose?() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let s = SettingsAppearanceLayout.thumbnailSize
        return NSSize(width: s.width + 2 * Self.margin, height: s.height + 2 * Self.margin)
    }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let m = Self.margin
        let r = NSRect(x: m, y: m, width: SettingsAppearanceLayout.thumbnailSize.width, height: SettingsAppearanceLayout.thumbnailSize.height)
        Self.drawThumbnail(appearanceChoice, in: r)
        if state == .on {
            let w = SettingsAppearanceLayout.ringWidth
            let ring = r.insetBy(dx: -(SettingsAppearanceLayout.ringGap + w / 2), dy: -(SettingsAppearanceLayout.ringGap + w / 2))
            let p = NSBezierPath(roundedRect: ring, xRadius: SettingsAppearanceLayout.ringRadius - w / 2,
                                 yRadius: SettingsAppearanceLayout.ringRadius - w / 2)
            p.lineWidth = w
            SettingsR5Colors.ring.setStroke()
            p.stroke()
        }
    }

    /// The picture (`AppearanceThumbnailArt`) in `r` (a flipped context).
    static func drawThumbnail(_ a: Preferences.Appearance, in r: NSRect) {
        let clip = NSBezierPath(roundedRect: r, xRadius: SettingsAppearanceLayout.thumbnailRadius, yRadius: SettingsAppearanceLayout.thumbnailRadius)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        switch a {
        case .light: drawLook(AppearanceThumbnailArt.light, in: r)
        case .dark: drawLook(AppearanceThumbnailArt.dark, in: r)
        case .system:
            drawLook(AppearanceThumbnailArt.light, in: r)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: r.minX + AppearanceThumbnailArt.splitX, y: r.minY, width: r.width - AppearanceThumbnailArt.splitX, height: r.height).clip()
            drawLook(AppearanceThumbnailArt.dark, in: r)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawLook(_ l: AppearanceThumbnailArt.Look, in r: NSRect) {
        func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor { SettingsR5Colors.rgb(v, a) }
        // The wallpaper: lighter at the top (the view is flipped).
        NSGradient(starting: rgb(l.wallpaperTop, 1), ending: rgb(l.wallpaperBottom, 1))?.draw(in: r, angle: 90)
        let wave = NSBezierPath()
        for (i, p) in AppearanceThumbnailArt.wave.enumerated() {
            let q = NSPoint(x: r.minX + p.x, y: r.minY + p.y)
            if i == 0 { wave.move(to: q) } else { wave.line(to: q) }
        }
        wave.close()
        rgb(l.wave, CGFloat(l.waveOpacity)).setFill()
        wave.fill()
        // The window, its title area and its buttons.
        let w = AppearanceThumbnailArt.window.offsetBy(dx: r.minX, dy: r.minY)
        let shape = NSBezierPath(roundedRect: w, xRadius: AppearanceThumbnailArt.windowRadius, yRadius: AppearanceThumbnailArt.windowRadius)
        rgb(l.window).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        rgb(l.titleArea).setFill()
        NSRect(x: w.minX, y: w.minY, width: w.width, height: AppearanceThumbnailArt.titleAreaHeight).fill()
        NSGraphicsContext.restoreGraphicsState()
        rgb(l.windowEdge).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        let d = AppearanceThumbnailArt.dotDiameter
        for dot in AppearanceThumbnailArt.dots {
            rgb(dot.color).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + dot.x - d / 2, y: r.minY + AppearanceThumbnailArt.dotY - d / 2, width: d, height: d)).fill()
        }
    }
}

// MARK: Separators, segments, push button

/// A line across the detail pane (x 180–710), `lineHeight` thick at the
/// top of its frame (the frame is a whole point, so a 0.5-point line stays
/// when the window lays out at scale 1).
final class SettingsPaneSeparator: NSView {
    let lineHeight: CGFloat
    init(lineHeight: CGFloat) {
        self.lineHeight = lineHeight
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        SettingsR5Colors.paneSeparator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: lineHeight).fill()
    }
}

/// Theme / Fonts / Editor (R5.1): a fully rounded #ECECEC track, 210 × 28,
/// segments 70 wide; the selected one a full-height accent capsule with a
/// white label; a divider only between two unselected segments.
final class SettingsSegmentsControl: NSControl {
    let titles: [String]
    var selectedSegment: Int { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?

    init(titles: [String], selected: Int) {
        self.titles = titles
        selectedSegment = selected
        super.init(frame: .zero)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Appearance settings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { SettingsAppearanceLayout.segmentsSize }

    var segmentWidth: CGFloat { bounds.width / CGFloat(max(1, titles.count)) }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        SettingsR5Colors.segmentsTrack.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: h / 2, yRadius: h / 2).fill()
        let w = segmentWidth
        for i in titles.indices {
            let seg = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
            let on = i == selectedSegment
            if on {
                SettingsR5Colors.segmentSelected.setFill()
                NSBezierPath(roundedRect: seg, xRadius: h / 2, yRadius: h / 2).fill()
            }
            if i > 0, !on, i - 1 != selectedSegment {
                SettingsR5Colors.segmentsDivider.setFill()
                let dh = SettingsAppearanceLayout.segmentDividerHeight
                NSRect(x: seg.minX - 0.5, y: (h - dh) / 2, width: 1, height: dh).fill()
            }
            let text = NSAttributedString(string: titles[i], attributes: [
                .font: NSFont.systemFont(ofSize: SettingsMetrics.fontSize, weight: on ? .medium : .regular),
                .foregroundColor: on ? NSColor.white : SettingsR5Colors.segmentsLabel,
            ])
            let s = text.size()
            text.draw(at: NSPoint(x: seg.midX - s.width / 2, y: seg.midY - s.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        select(Int(p.x / segmentWidth))
    }

    func select(_ i: Int) {
        guard titles.indices.contains(i), i != selectedSegment else { return }
        selectedSegment = i
        onChange?(i)
    }

    override func accessibilityChildren() -> [Any]? {
        titles.indices.map { i in
            let e = NSAccessibilityElement.element(withRole: .radioButton, frame: NSAccessibility.screenRect(fromView: self,
                                                   rect: NSRect(x: CGFloat(i) * segmentWidth, y: 0, width: segmentWidth, height: bounds.height)),
                                                   label: titles[i], parent: self) as? NSAccessibilityElement
            e?.setAccessibilityValue(i == selectedSegment ? 1 : 0)
            return e as Any
        }
    }
}

/// A push button in the card style (R5.1's "Choose…"): 24 tall, a rounded
/// rectangle of radius 6 (R6.1), #E4E4E4 with a #232323 label 12.25 from
/// each end.
final class SettingsPushButton: NSButton {
    var onPress: ((SettingsPushButton) -> Void)?

    init(_ title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        action = #selector(fire)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func fire() { onPress?(self) }

    override var isFlipped: Bool { true }
    var labelFont: NSFont { .systemFont(ofSize: SettingsMetrics.fontSize) }
    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: labelFont]).width
        return NSSize(width: ceil(w) + 2 * SettingsAppearanceLayout.pushButtonPadding, height: SettingsAppearanceLayout.pushButtonHeight)
    }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.45
        let r = bounds
        (isHighlighted ? SettingsR5Colors.pushButton.blended(withFraction: 0.12, of: .black) ?? SettingsR5Colors.pushButton
            : SettingsR5Colors.pushButton).withAlphaComponent(alpha).setFill()
        let radius = SettingsAppearanceR6.pushButtonRadius
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        let text = NSAttributedString(string: title, attributes: [.font: labelFont, .foregroundColor: SettingsR5Colors.pushButtonLabel.withAlphaComponent(alpha)])
        let s = text.size()
        text.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
    }
}

// MARK: Colour rows (R5.1's Foreground)

/// The colour slider (R6.1): a 14-point capsule track in one hue, from a
/// pale tint at the left to the full colour at the right
/// (`ThemeColorRows.paleTint`), with a 1-point darker edge, and a knob
/// about 28 across (a white rim around the colour under it) at the row's
/// strength. A built-in theme's row is read-only but drawn in full.
final class ThemeColorSlider: NSControl {
    typealias RGB = (r: Double, g: Double, b: Double)
    /// The full colour (the track's right end).
    var base: RGB { didSet { needsDisplay = true } }
    var value = ThemeColorRows.defaultStrength { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?

    init(base: RGB) {
        self.base = base
        super.init(frame: .zero)
        setAccessibilityRole(.slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: SettingsAppearanceLayout.sliderWidth, height: SettingsAppearanceLayout.sliderKnob) }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func accessibilityValue() -> Any? { value }

    /// The colour at the knob.
    var color: RGB { ThemeColorRows.paleTint(base, strength: value) }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = 1
        let k = SettingsAppearanceLayout.sliderKnob, th = SettingsAppearanceLayout.sliderTrackHeight
        let track = NSRect(x: 0, y: bounds.midY - th / 2, width: bounds.width, height: th)
        func ns(_ c: RGB) -> NSColor { NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: alpha) }
        let pale = ThemeColorRows.paleTint(base, strength: 0)
        let f = ThemeColorRows.self, e = SettingsAppearanceR6.trackEdgeFactor
        // The darker edge, then the gradient 1 point inside it.
        let shape = NSBezierPath(roundedRect: track, xRadius: th / 2, yRadius: th / 2)
        NSGradient(starting: ns(f.darker(pale, e)), ending: ns(f.darker(base, e)))?.draw(in: shape, angle: 0)
        let w = SettingsAppearanceR6.edgeWidth
        let inner = track.insetBy(dx: w, dy: w)
        let innerShape = NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2)
        NSGradient(starting: ns(pale), ending: ns(base))?.draw(in: innerShape, angle: 0)
        let x = k / 2 + CGFloat(value) * (bounds.width - k)
        let knob = NSRect(x: x - k / 2, y: bounds.midY - k / 2, width: k, height: k)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
        ns(color).setFill()
        NSBezierPath(ovalIn: knob.insetBy(dx: SettingsAppearanceR6.knobRim, dy: SettingsAppearanceR6.knobRim)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        track(event)
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            track(e)
            if e.type == .leftMouseUp { break }
        }
    }

    func track(_ e: NSEvent) {
        let k = SettingsAppearanceLayout.sliderKnob
        let p = convert(e.locationInWindow, from: nil)
        set(Double((p.x - k / 2) / max(1, bounds.width - k)))
    }

    /// Moves the knob (0–1) and reports it.
    func set(_ v: Double) {
        value = min(max(v, 0), 1)
        onChange?(value)
    }
}

/// The colour well: a 48 × 28 capsule with a 3-point #DFDFDF rim around
/// the colour (the knob's), the colour edged 1 point darker (R6.1). A click shows the colour as #RRGGBB in a popover to edit
/// (Ycode's own editor, the same on Linux); an empty value is the system's.
final class ThemeColorWellButton: NSButton, NSTextFieldDelegate {
    var color: NSColor { didSet { needsDisplay = true } }
    var hexValue: String
    var onCommit: ((String?) -> Void)?
    private var popover: NSPopover?

    init(color: NSColor, hex: String?) {
        self.color = color
        hexValue = hex ?? ""
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(editColor)
        setAccessibilityRole(.colorWell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { SettingsAppearanceLayout.wellSize }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func accessibilityValue() -> Any? { hexValue.isEmpty ? "System" : hexValue }

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

/// A 56-point colour row (R5.1, R6.1): the label at the top-left (cap top
/// 13 under the row's top), the slider and the well centred in the row.
/// The track's hue, the knob's strength and the well's colour come from
/// `ThemeColorRows.display` (a grey takes Ycode's hue for the row).
final class ThemeColorRowView: NSView {
    let label: NSTextField
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

    init(title: String, key: String, theme: EditorTheme, color: NSColor, background: NSColor) {
        label = NSTextField(labelWithString: title)
        self.key = key
        self.theme = theme
        dynamicColor = color
        dynamicBackground = background
        slider = ThemeColorSlider(base: ThemeColorRows.rgb(0xE35590))
        well = ThemeColorWellButton(color: color, hex: ThemeColorRows.value(key, in: theme))
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: SettingsMetrics.fontSize)
        label.textColor = SettingsColors.label
        label.lineBreakMode = .byTruncatingTail
        slider.setAccessibilityLabel(title)
        well.setAccessibilityLabel(title)
        for v in [label, slider, well] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let L = SettingsAppearanceLayout.self
        // A 13-point label's cap top is about 3 inside its frame.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: L.colorRowHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.labelInset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: L.colorLabelCapTop - 3),
            label.trailingAnchor.constraint(lessThanOrEqualTo: slider.leadingAnchor, constant: -8),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: L.sliderX),
            slider.widthAnchor.constraint(equalToConstant: L.sliderWidth),
            slider.heightAnchor.constraint(equalToConstant: L.sliderKnob),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.controlInset),
            well.widthAnchor.constraint(equalToConstant: L.wellSize.width),
            well.heightAnchor.constraint(equalToConstant: L.wellSize.height),
            well.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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

    /// The colours as drawn in this row's appearance: the track's full
    /// colour, the knob's strength, the well's colour (the knob's).
    func resolve() {
        var c = NSColor.black
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg = Self.opaque(self.dynamicBackground, over: .white)
            c = Self.opaque(self.dynamicColor, over: bg)
        }
        let shown = ThemeColorRows.display(key, in: theme, resolved: (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
        slider.base = shown.full
        slider.value = shown.strength
        showKnobColor()
    }

    /// The well shows the colour under the knob.
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

// MARK: The preview (R5.1)

/// The theme preview: a bordered box (1 point, radius 5) in the theme's
/// background, line numbers right-aligned ending 28 inside it, the code
/// from 43 inside on an 18-point pitch, not wrapped, with its own scrollers.
final class ThemePreviewBox: NSView {
    let textView: NSTextView
    let scroll = NSScrollView()
    let numbers: ThemePreviewNumbers

    init(textView: NSTextView) {
        self.textView = textView
        numbers = ThemePreviewNumbers()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = SettingsAppearanceLayout.previewRadius
        layer?.masksToBounds = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 10_000, height: 10_000)
        textView.textContainer?.lineFragmentPadding = 0
        textView.maxSize = NSSize(width: 10_000, height: 10_000)
        textView.minSize = NSSize(width: 0, height: 0)
        let L = SettingsAppearanceLayout.self
        textView.textContainerInset = NSSize(width: 0, height: L.firstLineTop)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        for v in [numbers, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: L.previewHeight),
            numbers.leadingAnchor.constraint(equalTo: leadingAnchor), numbers.topAnchor.constraint(equalTo: topAnchor),
            numbers.bottomAnchor.constraint(equalTo: bottomAnchor), numbers.widthAnchor.constraint(equalToConstant: L.codeInset),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: L.codeInset), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Shows `code` in the theme's colours on the 18-point pitch.
    func show(_ code: String, background: NSColor) {
        textView.backgroundColor = background
        numbers.background = background
        numbers.lines = code.components(separatedBy: "\n").count
        textView.string = code
        if let ts = textView.textStorage {
            Theme.highlight(ts, language: .swift)
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = SettingsAppearanceLayout.linePitch
            p.maximumLineHeight = SettingsAppearanceLayout.linePitch
            ts.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: ts.length))
        }
        numbers.font = Theme.font
        // Each line's baseline, so the numbers sit on the code's.
        var baselines: [CGFloat] = []
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            let origin = textView.textContainerOrigin.y
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { r, _, _, range, _ in
                baselines.append(origin + r.minY + lm.location(forGlyphAt: range.location).y)
            }
        }
        numbers.baselines = baselines
        numbers.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        numbers.background.setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        // The border over everything, drawn by the layer.
        layer?.borderWidth = 1
        layer?.borderColor = SettingsR5Colors.previewBorder.resolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// The preview's line numbers (#B8B3B4), right-aligned at 28 points.
final class ThemePreviewNumbers: NSView {
    var lines = 0
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var background: NSColor = .textBackgroundColor
    override var isFlipped: Bool { true }

    /// The code's baseline in each row (from the text view's layout).
    var baselines: [CGFloat] = []

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        let L = SettingsAppearanceLayout.self
        let f = NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 1), weight: .regular)
        for i in 0..<lines {
            let s = NSAttributedString(string: "\(i + 1)", attributes: [.font: f, .foregroundColor: SettingsR5Colors.lineNumber])
            // The ink, not the advance, ends at 28.
            let ink = s.boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
            let baseline = i < baselines.count ? baselines[i] : L.firstLineTop + CGFloat(i + 1) * L.linePitch - 4
            s.draw(with: NSRect(x: L.lineNumberEnd - ink.maxX, y: baseline, width: 100, height: 0), options: [])
        }
    }
}

extension NSColor {
    /// The colour as drawn in `appearance`.
    func resolvedCGColor(for appearance: NSAppearance) -> CGColor {
        var out = cgColor
        appearance.performAsCurrentDrawingAppearance { out = self.cgColor }
        return out
    }
}

// MARK: Components (R5.2)

/// A Components symbol in the accent colour (`ComponentGlyph`).
final class ComponentGlyphView: NSView {
    let glyph: ComponentGlyph
    init(_ g: ComponentGlyph) {
        glyph = g
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { glyph.size }

    override func draw(_ dirtyRect: NSRect) {
        let ink = SettingsR5Colors.platformSymbol
        let lw = ComponentGlyph.lineWidth
        for part in glyph.parts {
            switch part {
            case .roundedRect(let r, let radius, let knockout):
                let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
                if knockout {
                    SettingsColors.card.setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: -lw, dy: -lw), xRadius: radius + lw, yRadius: radius + lw).fill()
                }
                p.lineWidth = lw
                ink.setStroke()
                p.stroke()
            case .polyline(let pts):
                let p = NSBezierPath()
                for (i, q) in pts.enumerated() { if i == 0 { p.move(to: q) } else { p.line(to: q) } }
                p.lineWidth = lw
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                ink.setStroke()
                p.stroke()
            case .dot(let c, let d):
                ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
            case .sparkle(let c, let r):
                let p = NSBezierPath()
                for (i, q) in ComponentGlyph.sparklePoints(c, r).enumerated() { if i == 0 { p.move(to: q) } else { p.line(to: q) } }
                p.close()
                ink.setFill()
                p.fill()
            }
        }
    }
}

/// The 13 × 13 info button: a circle outline with a small "i", in the
/// subtitle colour.
final class SettingsInfoButton: NSButton {
    var onPress: ((SettingsInfoButton) -> Void)?

    init(label: String) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(fire)
        setAccessibilityLabel(label)
        toolTip = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func fire() { onPress?(self) }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: SettingsComponentsLayout.infoSize, height: SettingsComponentsLayout.infoSize) }

    override func draw(_ dirtyRect: NSRect) {
        let ink = SettingsR5Colors.subtitle
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let c = NSBezierPath(ovalIn: r)
        c.lineWidth = 1
        ink.setStroke()
        c.stroke()
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 0.75, y: bounds.minY + 3, width: 1.5, height: 1.5)).fill()
        NSRect(x: bounds.midX - 0.6, y: bounds.minY + 5.3, width: 1.2, height: 4.7).fill()
    }
}

/// One Components row (R5.2): 51.5 tall, the symbol centred on x 26 of the
/// card, the title from x 51 (cap top 13.5 under the row's top), the
/// subtitle 15 under it (a size 3.25 further right), "Last used …" at the
/// subtitle's size right-aligned 34.5 inside, the info button 11.5 inside.
final class ComponentsRowView: NSView {
    let row: ComponentsRow
    let glyph: ComponentGlyphView
    let title: NSTextField
    let subtitle: NSTextField
    let lastUsed: NSTextField?
    let info: SettingsInfoButton

    init(_ row: ComponentsRow) {
        self.row = row
        glyph = ComponentGlyphView(row.glyph)
        title = NSTextField(labelWithString: row.title)
        subtitle = NSTextField(labelWithString: row.subtitle)
        lastUsed = row.lastUsed.map { NSTextField(labelWithString: $0) }
        info = SettingsInfoButton(label: "About \(row.title)")
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: SettingsMetrics.fontSize)
        title.textColor = SettingsColors.label
        subtitle.font = .systemFont(ofSize: SettingsComponentsLayout.subtitleFontSize)
        subtitle.textColor = SettingsR5Colors.subtitle
        // "Last used …" at the subtitle's size (R6.2).
        lastUsed?.font = .systemFont(ofSize: SettingsComponentsR6.lastUsedFontSize)
        lastUsed?.textColor = SettingsR5Colors.subtitle
        for v in [glyph, title, subtitle, info] + (lastUsed.map { [$0] } ?? []) as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let L = SettingsComponentsLayout.self
        // Ink offsets in a label's frame: 13 points: ink 1 after the
        // frame's leading edge, cap top 3 under its top; 11 points: the
        // baseline 15 under the title's.
        var cs: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: L.rowHeight),
            glyph.centerXAnchor.constraint(equalTo: leadingAnchor, constant: L.iconCenterInset),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: row.glyph.size.width),
            glyph.heightAnchor.constraint(equalToConstant: row.glyph.size.height),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: L.titleInset - 1),
            title.topAnchor.constraint(equalTo: topAnchor, constant: L.titleCapTop - 3),
            // A size starts 3.25 right of the title; "Built-in" does not (R6.2).
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: row.subtitleInset),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: L.subtitleBaselineGap),
            info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -L.infoTrailingInset),
            info.centerYAnchor.constraint(equalTo: centerYAnchor),
            info.widthAnchor.constraint(equalToConstant: L.infoSize), info.heightAnchor.constraint(equalToConstant: L.infoSize),
            title.trailingAnchor.constraint(lessThanOrEqualTo: info.leadingAnchor, constant: -12),
        ]
        if let lastUsed {
            cs += [lastUsed.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -L.lastUsedTrailingInset + 1),
                   lastUsed.centerYAnchor.constraint(equalTo: centerYAnchor)]
        }
        NSLayoutConstraint.activate(cs)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([row.title, row.subtitle, row.lastUsed].compactMap { $0 }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
}

/// The info popover's content: the row's lines and, for the platform rows
/// and the host, a button.
final class ComponentsInfoView: NSView {
    init(_ row: ComponentsRow, button: NSButton?) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        let head = NSTextField(labelWithString: row.title)
        head.font = .boldSystemFont(ofSize: SettingsMetrics.fontSize)
        stack.addArrangedSubview(head)
        for line in row.details {
            let l = NSTextField(wrappingLabelWithString: line)
            l.font = .systemFont(ofSize: SettingsMetrics.helpFontSize)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = 280
            stack.addArrangedSubview(l)
        }
        if let button { stack.addArrangedSubview(button) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 310),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
