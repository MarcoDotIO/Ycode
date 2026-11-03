import AppKit
import YcodeDeviceUI
import YcodeDisplayStream
import YcodeIDECore

/// A tile on the canvas: the region of the preview device's picture, and in
/// Live mode the mouse acts as a finger on it (`display-stream.md` §5.1).
final class PreviewLiveTileView: NSView {
    var tile: PreviewLiveTile
    weak var input: DeviceInputHandler?
    var interactive = true
    var onClick: ((Int) -> Void)?
    var isSelected = false { didSet { layer?.borderWidth = isSelected ? 2 : 0.5; layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor } }
    private var down = false
    /// A visionOS preview device (its hello says `spatial`): the mouse is the
    /// gaze and a right-hand pinch instead of a finger (visionos.md "Ycode
    /// implementation"; the Vision Pro's display is 1920 × 1080 points).
    private var spatial = SpatialInteraction()

    init(tile: PreviewLiveTile) {
        self.tile = tile
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.12).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityRole(.image)
        setAccessibilityLabel(tile.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The tile's part of the device picture (drawn in `draw`, so window
    /// snapshots made with `cacheDisplay` include it).
    private(set) var picture: CGImage?

    /// Shows the device picture's part for this tile.
    func show(_ image: CGImage?, screen: CGSize) {
        guard let image else { return }
        let rect = PreviewCanvasLayout.pixelRect(tile.region, screen: screen, imageSize: CGSize(width: image.width, height: image.height))
        picture = rect.isEmpty ? nil : image.cropping(to: rect)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let picture else { return }
        NSImage(cgImage: picture, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactive, let input, input.isSpatial, !down else { return }
        let d = PreviewCanvasLayout.devicePoint(convert(event.locationInWindow, from: nil), in: bounds.size, region: tile.region)
        input.sendSelection(spatial.hover(x: d.x, y: d.y), label: nil)
    }

    private func touch(_ event: NSEvent, _ phase: TouchPhase) {
        let p = convert(event.locationInWindow, from: nil)
        let d = PreviewCanvasLayout.devicePoint(p, in: bounds.size, region: tile.region)
        if let input, input.isSpatial {
            let s: SpatialSelection?
            switch phase {
            case .began: s = spatial.press(x: d.x, y: d.y, twoHands: event.modifierFlags.contains(.option))
            case .moved: s = spatial.drag(x: d.x, y: d.y, depth: event.modifierFlags.contains(.shift))
            default: s = spatial.release()
            }
            if let s { input.sendSelection(s, label: phase == .began ? "preview pinch" : nil) }
            return
        }
        input?.sendTouch([TouchContact(finger: 0, phase: phase, x: Float(d.x), y: Float(d.y))], label: phase == .began ? "preview touch" : nil)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(tile.preview)
        guard interactive else { return }
        down = true
        touch(event, .began)
    }

    override func mouseDragged(with event: NSEvent) { if down && interactive { touch(event, .moved) } }

    override func mouseUp(with event: NSEvent) {
        guard down else { return }
        down = false
        touch(event, .ended)
    }
}

/// The banner over a canvas whose last update failed (`previews.md`
/// §Errors): the first issue, a button per issue that has a source position.
final class PreviewBannerView: NSView {
    var onIssue: ((PreviewIssue) -> Void)?
    private(set) var issues: [PreviewIssue] = []

    init(title: String, issues: [PreviewIssue], message: String?) {
        self.issues = issues
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = Theme.errorColor.withAlphaComponent(0.92).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error") ?? NSImage())
        icon.contentTintColor = .white
        let head = NSTextField(labelWithString: title)
        head.font = .boldSystemFont(ofSize: 12)
        head.textColor = .white
        var rows: [NSView] = [NSStackView(views: [icon, head])]
        for (i, issue) in issues.prefix(3).enumerated() {
            let b = NSButton(title: issue.description, target: self, action: #selector(issueClicked(_:)))
            b.tag = i
            b.isBordered = false
            b.contentTintColor = .white
            b.attributedTitle = NSAttributedString(string: issue.description, attributes: [
                .foregroundColor: NSColor.white, .font: Theme.font,
                .underlineStyle: issue.file != nil ? NSUnderlineStyle.single.rawValue : 0])
            b.toolTip = issue.file.map { "Go to \($0.lastPathComponent):\(issue.line)" }
            b.lineBreakMode = .byTruncatingTail
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rows.append(b)
        }
        if issues.isEmpty, let message {
            let t = NSTextField(wrappingLabelWithString: message)
            t.textColor = .white
            t.font = Theme.font
            t.preferredMaxLayoutWidth = 360
            rows.append(t)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func issueClicked(_ b: NSButton) { if b.tag < issues.count { onIssue?(issues[b.tag]) } }
    /// Clicks the first issue with a position (tests).
    func clickFirstIssue() { if let i = issues.first(where: { $0.file != nil }) { onIssue?(i) } }
}

/// A flipped container (the live tiles' document view).
final class PreviewLiveDocumentView: NSView {
    override var isFlipped: Bool { true }
}

extension PreviewCanvasController: DeviceLiveSessionObserver {
    public func session(_ s: DeviceLiveSession, changed: DeviceSessionChange) {
        switch changed {
        case .image:
            for v in liveTileViews { (v as? PreviewLiveTileView)?.show(s.image, screen: liveScreen) }
        case .hello:
            if let h = s.hello { liveScreen = CGSize(width: h.pointWidth, height: h.pointHeight) }
        default: break
        }
    }

    /// The zoom live tiles are shown at: the chosen one, else Fit.
    func liveZoom(_ tiles: [PreviewLiveTile]) -> CGFloat {
        if let z = zoom { return z }
        let area = CGSize(width: max(body.bounds.width, 200), height: max(body.bounds.height, 200))
        return PreviewCanvasLayout.fitZoom(tiles, area: area)
    }

    /// The live tiles in device-screen order, each with its caption, in a
    /// scroll view; the banner (if any) on top.
    func liveContent(_ tiles: [PreviewLiveTile]) -> NSView {
        liveTileViews = []
        let z = liveZoom(tiles)
        let (frames, size) = PreviewCanvasLayout.frames(tiles, zoom: z)
        let doc = PreviewLiveDocumentView(frame: CGRect(origin: .zero, size: size))
        for (i, t) in tiles.enumerated() {
            let v = PreviewLiveTileView(tile: t)
            v.frame = frames[i]
            v.input = liveSession
            v.interactive = mode == .live
            v.isSelected = layout == .grid && t.preview == selectedIndex
            v.onClick = { [weak self] p in self?.tileClicked(p) }
            v.show(liveSession?.image, screen: liveScreen)
            doc.addSubview(v)
            let caption = NSTextField(labelWithString: t.title)
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            caption.lineBreakMode = .byTruncatingTail
            caption.frame = CGRect(x: frames[i].minX, y: frames[i].minY - PreviewCanvasLayout.captionHeight, width: frames[i].width,
                                   height: PreviewCanvasLayout.captionHeight - 2)
            doc.addSubview(caption)
            liveTileViews.append(v)
            cardTitles.append(t.title)
        }
        framedCount = tiles.count
        // Centre the tiles horizontally when they are narrower than the canvas.
        let centring = PreviewLiveDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        centring.addSubview(doc)
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalToConstant: size.width), doc.heightAnchor.constraint(equalToConstant: size.height),
            doc.topAnchor.constraint(equalTo: centring.topAnchor), doc.bottomAnchor.constraint(equalTo: centring.bottomAnchor),
            doc.centerXAnchor.constraint(equalTo: centring.centerXAnchor),
            doc.leadingAnchor.constraint(greaterThanOrEqualTo: centring.leadingAnchor),
        ])
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = centring
        centring.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([centring.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
                                     centring.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                                     centring.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)])
        guard let b = banner else { return scroll }
        let box = NSView()
        let bv = PreviewBannerView(title: b.title, issues: b.issues, message: b.message)
        bv.onIssue = { [weak self] i in self?.onIssue?(i) }
        for v in [scroll, bv] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: box.topAnchor), scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            bv.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), bv.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            bv.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -24),
        ])
        bannerView = bv
        return box
    }
}
