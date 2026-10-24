import AppKit

/// The preview canvas (reference-ui-4.md §10): a header with one tab per
/// preview (spinner while building, then an eye), the body (the "Canvas
/// paused" capsule until the first build, then the selected preview in a
/// device frame, every preview as cards in Grid mode, or an error card),
/// and a bottom bar (four mode buttons, the zoom pop-up, zoom to fit,
/// device settings, canvas settings). See `specs/ide/previews.md` §Canvas.
@MainActor
public final class PreviewCanvasController: NSViewController {
    public enum State: Equatable {
        case empty(String)
        case building
        case rendered([PreviewRenderer.Rendered])
        case failed(String)
    }

    public enum Layout: Int { case grid, single }

    public private(set) var state: State = .empty("No Previews")
    public private(set) var selectedIndex = 0
    public private(set) var layout: Layout = .single
    public private(set) var colorScheme: PreviewRenderer.ColorScheme = .light
    /// Until resumed, the canvas shows the paused capsule and does not build.
    public private(set) var isPaused = true
    /// Live (the default) or Selectable; Variants and Grid are toggles.
    public private(set) var mode: PreviewCanvasMode = .live
    public private(set) var showsVariants = false
    /// Zoom factor; nil fits the preview in the canvas.
    public private(set) var zoom: CGFloat?
    public static let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2]
    /// Refresh (the window rebuilds and renders); also called on resume.
    public var onRefresh: (() -> Void)?
    let tabStrip = NSStackView()
    let modeButtons: [NSButton] = PreviewCanvasMode.allCases.map { m in
        let b = NSButton(image: NSImage(systemSymbolName: m.symbol, accessibilityDescription: m.title) ?? NSImage(), target: nil, action: nil)
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.toolTip = m.title
        b.tag = m.rawValue
        return b
    }
    let zoomPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let fitButton = NSButton(image: NSImage(systemSymbolName: "camera", accessibilityDescription: "Capture") ?? NSImage(), target: nil, action: nil)
    let deviceButton = NSButton(image: NSImage(systemSymbolName: "rectangle.portrait", accessibilityDescription: "Device") ?? NSImage(), target: nil, action: nil)
    /// The device menu's content and choice.
    public var devices = PreviewDeviceMenuModel()
    /// Canvas settings switches.
    public private(set) var settings = PreviewCanvasSettings()
    let settingsButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Canvas Settings") ?? NSImage(), target: nil, action: nil)
    lazy var pausedCapsule = PreviewPausedCapsule(target: self, action: #selector(resumeClicked))
    let statusLabel = NSTextField(labelWithString: "")
    let body = NSView()
    public private(set) var names: [String] = []
    /// Header titles: `#Preview("name")`, else the view type.
    public var tabTitles: [String] = [] { didSet { if isViewLoaded { show() } } }
    /// Card views in the grid (tests read their titles).
    public private(set) var cardTitles: [String] = []
    /// Header tabs as shown: title and badge (tests).
    public private(set) var headerTabs: [(title: String, badge: String)] = []

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        tabStrip.spacing = 2
        tabStrip.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [tabStrip, NSView(), statusLabel])
        header.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        for b in modeButtons { b.target = self; b.action = #selector(modeClicked(_:)) }
        zoomPopUp.controlSize = .small
        zoomPopUp.font = .systemFont(ofSize: 11)
        zoomPopUp.isBordered = false
        zoomPopUp.target = self
        zoomPopUp.action = #selector(zoomChosen)
        for (b, sel, tip) in [(fitButton, #selector(capture(_:)), "Capture"), (deviceButton, #selector(deviceSettings(_:)), "Device"),
                              (settingsButton, #selector(canvasSettings(_:)), "Canvas Settings")] {
            b.isBordered = false
            b.target = self
            b.action = sel
            b.toolTip = tip
        }
        let left = NSStackView(views: modeButtons)
        left.spacing = 4
        let right = NSStackView(views: [fitButton, deviceButton, settingsButton])
        right.spacing = 6
        let bar = NSView()
        for v in [left, zoomPopUp, right] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(v) }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8), left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            zoomPopUp.centerXAnchor.constraint(equalTo: bar.centerXAnchor), zoomPopUp.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8), right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        let sep = NSBox(), sep2 = NSBox()
        sep.boxType = .separator
        sep2.boxType = .separator
        for v in [header, sep, body, sep2, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 28),
            sep.topAnchor.constraint(equalTo: header.bottomAnchor), sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: sep.bottomAnchor), body.bottomAnchor.constraint(equalTo: sep2.topAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor), body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep2.leadingAnchor.constraint(equalTo: root.leadingAnchor), sep2.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep2.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor), bar.heightAnchor.constraint(equalToConstant: 28),
        ])
        view = root
        show()
    }

    /// The preview names of the file (shown before rendering).
    public func setNames(_ list: [String]) {
        names = list
        if tabTitles.count != list.count { tabTitles = list }
        if selectedIndex >= list.count { selectedIndex = 0 }
        if isViewLoaded { show() }
    }

    public func setState(_ s: State) {
        state = s
        if case .rendered = s {
            names = shown.map(\.name)
            if tabTitles.count != names.count { tabTitles = names }
            if selectedIndex >= names.count { selectedIndex = 0 }
        }
        if isViewLoaded { show() }
    }

    /// Leaves the paused state and asks for the first build.
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        if isViewLoaded { show() }
        onRefresh?()
    }

    /// Selects a preview; in the grid this zooms into it (single layout).
    public func select(_ i: Int, zoom: Bool = false) {
        selectedIndex = i
        if zoom { layout = .single }
        if isViewLoaded { show() }
    }

    public func setLayout(_ l: Layout) {
        layout = l
        if isViewLoaded { show() }
    }

    public func setColorScheme(_ s: PreviewRenderer.ColorScheme) {
        colorScheme = s
        if isViewLoaded { show() }
    }

    /// Mode buttons: Live and Selectable are exclusive; Variants (light
    /// and dark side by side) and Grid toggle.
    public func setMode(_ m: PreviewCanvasMode) {
        switch m {
        case .live, .selectable: mode = m
        case .variants: showsVariants.toggle()
        case .grid: layout = layout == .grid ? .single : .grid
        }
        if isViewLoaded { show() }
    }

    public func setZoom(_ z: CGFloat?) {
        zoom = z
        if isViewLoaded { show() }
    }

    /// The zoom pop-up's title ("Fit" or "<n>%").
    public var zoomTitle: String { zoom.map { "\(Int(($0 * 100).rounded()))%" } ?? "Fit" }

    /// The rendered previews for the current color scheme.
    public var shown: [PreviewRenderer.Rendered] {
        guard case .rendered(let all) = state else { return [] }
        let match = all.filter { $0.scheme == colorScheme }
        return match.isEmpty ? all.filter { $0.scheme == .light } : match
    }

    @objc private func resumeClicked() { resume() }
    @objc private func modeClicked(_ b: NSButton) { setMode(PreviewCanvasMode(rawValue: b.tag) ?? .live) }
    @objc private func tabClicked(_ g: NSClickGestureRecognizer) { if let v = g.view as? PreviewTabView { select(v.index, zoom: true) } }
    @objc private func refreshClicked() { onRefresh?() }
    @objc private func cardClicked(_ g: NSClickGestureRecognizer) { if let v = g.view as? PreviewCard { select(v.index, zoom: true) } }
    @objc private func zoomChosen() {
        let i = zoomPopUp.indexOfSelectedItem
        setZoom(i <= 0 ? nil : Self.zoomSteps[i - 1])
    }
    @objc public func zoomToFit(_ sender: Any?) { setZoom(nil) }

    /// The device menu (§17 item 3).
    func deviceMenu() -> NSMenu {
        let m = NSMenu()
        for r in devices.rows {
            if r == "—" { m.addItem(.separator()); continue }
            if r.hasPrefix("#") { m.addItem(NSMenuItem.sectionHeader(title: String(r.dropFirst()))); continue }
            let i = NSMenuItem(title: r, action: #selector(deviceItem(_:)), keyEquivalent: "")
            i.target = self
            if let g = PreviewDeviceMenuModel.generics.first(where: { "\($0.title) \($0.detail)" == r }) {
                let t = NSMutableAttributedString(string: g.title + " ")
                t.append(NSAttributedString(string: g.detail, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
                i.attributedTitle = t
            }
            if r == "More" { i.submenu = NSMenu(); i.action = nil }
            i.state = (devices.chosen == nil && r.hasPrefix("Automatic")) || devices.chosen == r ? .on : .off
            m.addItem(i)
        }
        return m
    }

    @objc private func deviceItem(_ i: NSMenuItem) { chooseDevice(i.title.hasPrefix("Automatic") ? nil : i.title) }
    public func chooseDevice(_ d: String?) { devices.chosen = d }

    /// Canvas settings (§17 item 4): a popover of switches, all off.
    public func setSetting(_ name: String, _ on: Bool) {
        if on { settings.on.insert(name) } else { settings.on.remove(name) }
        if name == "Color Scheme" { setColorScheme(on ? .dark : .light) } else if isViewLoaded { show() }
    }

    func settingsView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for n in PreviewCanvasSettings.names {
            let sw = NSSwitch()
            sw.controlSize = .mini
            sw.state = settings.on.contains(n) ? .on : .off
            sw.identifier = .init(n)
            sw.target = self
            sw.action = #selector(switchFlipped(_:))
            stack.addArrangedSubview(NSStackView(views: [sw, NSTextField(labelWithString: n)]))
        }
        return stack
    }

    @objc private func switchFlipped(_ s: NSSwitch) { if let n = s.identifier?.rawValue { setSetting(n, s.state == .on) } }

    /// Capture: copies the shown preview image to the pasteboard.
    @discardableResult
    @objc public func capture(_ sender: Any?) -> Bool {
        let list = shown
        guard !list.isEmpty, let img = NSImage(contentsOf: list[min(selectedIndex, list.count - 1)].png) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([img])
    }

    @objc func deviceSettings(_ sender: NSButton) { deviceMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender) }
    @objc func canvasSettings(_ sender: NSButton) {
        let pop = NSPopover()
        pop.behavior = .transient
        let vc = NSViewController()
        vc.view = settingsView()
        pop.contentViewController = vc
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// The status line (for tests).
    public var statusText: String { statusLabel.stringValue }

    func show() {
        for b in modeButtons {
            let m = PreviewCanvasMode(rawValue: b.tag)!
            let on = m == mode || (m == .variants && showsVariants) || (m == .grid && layout == .grid)
            b.state = on ? .on : .off
            b.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        }
        zoomPopUp.removeAllItems()
        zoomPopUp.addItems(withTitles: ["Fit"] + Self.zoomSteps.map { "\(Int($0 * 100))%" })
        zoomPopUp.selectItem(withTitle: zoomTitle)
        reloadTabs()
        body.subviews.forEach { $0.removeFromSuperview() }
        cardTitles = []
        framedCount = 0
        let content: NSView
        if isPaused && !names.isEmpty {
            statusLabel.stringValue = ""
            content = centered(pausedCapsule)
        } else { switch state {
        case .empty(let message):
            statusLabel.stringValue = message
            content = centered(NSTextField(labelWithString: message))
        case .building:
            statusLabel.stringValue = "Building…"
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.startAnimation(nil)
            content = centered(spinner)
        case .failed(let message):
            statusLabel.stringValue = "Build failed"
            content = errorCard(message)
        case .rendered:
            let list = shown
            if list.isEmpty {
                statusLabel.stringValue = "No Previews"
                content = centered(NSTextField(labelWithString: "No Previews"))
            } else if layout == .grid {
                statusLabel.stringValue = "\(list.count) preview\(list.count == 1 ? "" : "s")"
                content = grid(list)
            } else {
                let i = min(selectedIndex, list.count - 1)
                statusLabel.stringValue = ""
                if showsVariants, case .rendered(let all) = state {
                    let both = all.filter { $0.name == list[i].name }
                    let row = NSStackView(views: both.map { framed($0) })
                    row.spacing = 16
                    content = centered(row)
                } else {
                    content = centered(framed(list[i]))
                }
            }
        } }
        content.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: body.topAnchor), content.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor), content.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
    }

    /// The device frames shown (tests).
    public private(set) var framedCount = 0

    /// A rendered preview at the zoom (or fitting) inside a device frame.
    private func framed(_ r: PreviewRenderer.Rendered) -> NSView {
        let image = NSImage(contentsOf: r.png) ?? NSImage()
        if let z = zoom { image.size = NSSize(width: image.size.width * z, height: image.size.height * z) }
        let iv = NSImageView(image: image)
        iv.imageScaling = .scaleProportionallyDown
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        framedCount += 1
        cardTitles.append(r.name)
        return PreviewDeviceFrameView(content: iv)
    }

    /// Header tabs: one per preview, spinner while building, eye when rendered.
    func reloadTabs() {
        tabStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        headerTabs = []
        guard !isPaused else { return }
        let titles = tabTitles.count == names.count ? tabTitles : names
        let badge: PreviewTabView.Badge
        switch state {
        case .building: badge = .spinner
        case .rendered: badge = .eye
        default: badge = .none
        }
        for (i, t) in titles.enumerated() {
            let tab = PreviewTabView(title: t)
            tab.index = i
            tab.badge = badge
            tab.isSelected = i == selectedIndex && layout == .single
            tab.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tabClicked(_:))))
            tabStrip.addArrangedSubview(tab)
            headerTabs.append((t, badge == .spinner ? "spinner" : badge == .eye ? "eye" : ""))
        }
    }

    /// One card: name above the image; a selected card has an accent ring.
    private func card(_ r: PreviewRenderer.Rendered, index: Int, large: Bool) -> NSView {
        let image = NSImage(contentsOf: r.png) ?? NSImage()
        if !large {
            // Thumbnails fit in 180 points.
            let scale = min(1, 180 / max(image.size.width, image.size.height, 1))
            image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        let iv = NSImageView(image: image)
        iv.imageScaling = .scaleProportionallyDown
        let name = NSTextField(labelWithString: r.name)
        name.font = .systemFont(ofSize: 11)
        name.textColor = .secondaryLabelColor
        let stack = PreviewCard(views: [name, iv])
        stack.index = index
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 8
        stack.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.08).cgColor
        stack.layer?.borderWidth = index == selectedIndex && !large ? 2 : 1
        stack.layer?.borderColor = (index == selectedIndex && !large ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked(_:)))
        stack.addGestureRecognizer(click)
        cardTitles.append(r.name)
        return stack
    }

    /// Cards in rows of two, in a scroll view.
    private func grid(_ list: [PreviewRenderer.Rendered]) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        var i = 0
        while i < list.count {
            let row = NSStackView(views: list[i..<min(i + 2, list.count)].enumerated().map { card($0.element, index: i + $0.offset, large: false) })
            row.alignment = .top
            row.spacing = 12
            rows.addArrangedSubview(row)
            i += 2
        }
        let flipped = FlippedView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(rows)
        NSLayoutConstraint.activate([rows.topAnchor.constraint(equalTo: flipped.topAnchor), rows.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
                                     rows.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
                                     rows.trailingAnchor.constraint(lessThanOrEqualTo: flipped.trailingAnchor)])
        let scroll = NSScrollView()
        scroll.documentView = flipped
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    private func centered(_ v: NSView) -> NSView {
        let box = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: box.centerXAnchor), v.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            v.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -24),
            v.heightAnchor.constraint(lessThanOrEqualTo: box.heightAnchor, constant: -24),
        ])
        return box
    }

    /// The error card: a red-edged box with the first diagnostic.
    private func errorCard(_ message: String) -> NSView {
        let title = NSTextField(labelWithString: "Preview build failed")
        title.font = .boldSystemFont(ofSize: 12)
        let text = NSTextField(wrappingLabelWithString: message)
        text.font = Theme.font
        text.preferredMaxLayoutWidth = 320
        text.isSelectable = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: "Error") ?? NSImage())
        icon.contentTintColor = Theme.errorColor
        let stack = NSStackView(views: [NSStackView(views: [icon, title]), text])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 8
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = Theme.errorColor.cgColor
        stack.layer?.backgroundColor = Theme.errorColor.withAlphaComponent(0.08).cgColor
        return centered(stack)
    }
}

final class PreviewCard: NSStackView {
    var index = 0
}
