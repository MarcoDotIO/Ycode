import AppKit

/// Interface Builder chrome (reference-ui-4.md §11): the jump bar, the
/// document outline column with its Filter at the bottom, and the canvas
/// bottom bar (outline toggle, +, issues, appearance, orientation,
/// layout; device pop-up; zoom − n% +; update frames, align, pin,
/// resolve, embed in).
@MainActor
final class IBCanvasBar: NSView {
    let outlineToggle = IBCanvasBar.button("sidebar.left", "Hide Document Outline")
    let addButton = IBCanvasBar.button("plus", "Library")
    let issues = IBCanvasBar.button("checkmark.circle", "No Issues")
    let appearanceToggle = IBCanvasBar.button("circle.lefthalf.filled", "Appearance")
    let orientationToggle = IBCanvasBar.button("rectangle.portrait.rotate", "Orientation")
    let layoutButton = IBCanvasBar.button("rectangle.split.2x1", "Layout")
    let devicePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let zoomOut = IBCanvasBar.button("minus", "Zoom Out")
    let zoomLabel = NSTextField(labelWithString: "100%")
    let zoomIn = IBCanvasBar.button("plus", "Zoom In")
    let updateFrames = IBCanvasBar.button("arrow.triangle.2.circlepath", "Update Frames")
    let align = IBCanvasBar.button("align.horizontal.left", "Align")
    let pin = IBCanvasBar.button("square.split.bottomrightquarter", "Add New Constraints")
    let resolve = IBCanvasBar.button("exclamationmark.triangle", "Resolve Auto Layout Issues")
    let embed = IBCanvasBar.button("square.on.square", "Embed In")

    static func button(_ symbol: String, _ tip: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: nil, action: nil)
        b.isBordered = false
        b.toolTip = tip
        return b
    }

    var left: [NSButton] { [outlineToggle, addButton, issues, appearanceToggle, orientationToggle, layoutButton] }
    var right: [NSButton] { [updateFrames, align, pin, resolve, embed] }
    /// Tooltips in bar order (tests).
    var itemTitles: [String] {
        left.map { $0.toolTip ?? "" } + ["device:" + (devicePopUp.titleOfSelectedItem ?? "")] + ["−", zoomLabel.stringValue, "+"] + right.map { $0.toolTip ?? "" }
    }

    init() {
        super.init(frame: .zero)
        devicePopUp.controlSize = .small
        devicePopUp.font = .systemFont(ofSize: 11)
        devicePopUp.isBordered = false
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let l = NSStackView(views: left), r = NSStackView(views: right)
        let mid = NSStackView(views: [devicePopUp, zoomOut, zoomLabel, zoomIn])
        for st in [l, r, mid] { st.spacing = 8; st.translatesAutoresizingMaskIntoConstraints = false; addSubview(st) }
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), l.centerYAnchor.constraint(equalTo: centerYAnchor),
            mid.centerXAnchor.constraint(equalTo: centerXAnchor), mid.centerYAnchor.constraint(equalTo: centerYAnchor),
            r.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), r.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

extension InterfaceBuilderController {
    /// Device pop-up choices: iOS documents list phones and tablets.
    public var deviceChoices: [String] {
        document.isFlippedRuntime ? ["iPhone 16", "iPhone 16 Pro", "iPhone 16 Pro Max", "iPhone SE (3rd generation)", "iPad (A16)", "iPad Pro 11-inch", "iPad Pro 13-inch"] : ["Mac"]
    }

    public var zoomText: String { "\(Int((zoom * 100).rounded()))%" }
    public var isOutlineVisible: Bool { !outlineColumn.isHidden }
    public var canvasBarItems: [String] { bar.itemTitles }
    public var jumpBarText: String { jumpBar.stringValue }

    func layoutChrome(root: NSView, outlineScroll: NSScrollView) {
        jumpBar.font = .systemFont(ofSize: 11)
        jumpBar.lineBreakMode = .byTruncatingHead
        filterField.placeholderString = "Filter"
        filterField.controlSize = .small
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        for v in [outlineScroll, filterField] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; outlineColumn.addSubview(v) }
        NSLayoutConstraint.activate([
            outlineScroll.topAnchor.constraint(equalTo: outlineColumn.topAnchor), outlineScroll.leadingAnchor.constraint(equalTo: outlineColumn.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: outlineColumn.trailingAnchor), outlineScroll.bottomAnchor.constraint(equalTo: filterField.topAnchor, constant: -4),
            filterField.leadingAnchor.constraint(equalTo: outlineColumn.leadingAnchor, constant: 6), filterField.trailingAnchor.constraint(equalTo: outlineColumn.trailingAnchor, constant: -6),
            filterField.bottomAnchor.constraint(equalTo: outlineColumn.bottomAnchor, constant: -4),
        ])
        bar.devicePopUp.addItems(withTitles: deviceChoices)
        let wire: [(NSButton, Selector)] = [(bar.outlineToggle, #selector(toggleOutline(_:))), (bar.addButton, #selector(showLibraryFromBar(_:))),
                                            (bar.appearanceToggle, #selector(toggleCanvasAppearance(_:))), (bar.orientationToggle, #selector(toggleOrientation(_:))),
                                            (bar.zoomOut, #selector(zoomOut(_:))), (bar.zoomIn, #selector(zoomIn(_:))),
                                            (bar.pin, #selector(pinClicked(_:))), (bar.updateFrames, #selector(updateFramesClicked(_:))),
                                            (bar.align, #selector(menuClicked(_:))), (bar.resolve, #selector(menuClicked(_:))),
                                            (bar.embed, #selector(menuClicked(_:))), (bar.layoutButton, #selector(menuClicked(_:)))]
        for (b, sel) in wire { b.target = self; b.action = sel }
        bar.devicePopUp.target = self
        bar.devicePopUp.action = #selector(deviceChosen(_:))
        let sep = NSBox(), top = NSBox(), barSep = NSBox()
        for b in [sep, top, barSep] { b.boxType = .separator }
        for v in [jumpBar, top, outlineColumn, sep, canvasScroll, barSep, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let w = outlineColumn.widthAnchor.constraint(equalToConstant: 230)
        outlineWidth = w
        NSLayoutConstraint.activate([
            jumpBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 5), jumpBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            jumpBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 24), top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outlineColumn.topAnchor.constraint(equalTo: top.bottomAnchor), outlineColumn.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            outlineColumn.leadingAnchor.constraint(equalTo: root.leadingAnchor), w,
            sep.topAnchor.constraint(equalTo: top.bottomAnchor), sep.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: outlineColumn.trailingAnchor),
            canvasScroll.topAnchor.constraint(equalTo: top.bottomAnchor), canvasScroll.bottomAnchor.constraint(equalTo: barSep.topAnchor),
            canvasScroll.leadingAnchor.constraint(equalTo: sep.trailingAnchor), canvasScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barSep.leadingAnchor.constraint(equalTo: sep.trailingAnchor), barSep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barSep.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: sep.trailingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor), bar.heightAnchor.constraint(equalToConstant: 28),
        ])
        bar.zoomLabel.stringValue = zoomText
        updateJumpBar()
    }

    func updateJumpBar() { jumpBar.stringValue = jumpBarPath.joined(separator: " › ") }

    @objc func filterChanged(_ f: NSSearchField) { outlineFilter = f.stringValue }
    @objc func magnificationChanged() { bar.zoomLabel.stringValue = zoomText }

    /// The outline toggle in the canvas bar.
    @objc public func toggleOutline(_ sender: Any?) {
        _ = view
        outlineColumn.isHidden.toggle()
        outlineWidth?.constant = outlineColumn.isHidden ? 0 : 230
        bar.outlineToggle.toolTip = outlineColumn.isHidden ? "Show Document Outline" : "Hide Document Outline"
    }

    @objc func showLibraryFromBar(_ sender: Any?) { NSApp.sendAction(Selector(("showLibrary:")), to: nil, from: sender) }

    /// Appearance toggle: the canvas renders dark or light.
    @objc public func toggleCanvasAppearance(_ sender: Any?) {
        let dark = canvas.appearance?.name == .darkAqua
        canvas.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        canvas.needsDisplay = true
    }

    @objc public func toggleOrientation(_ sender: Any?) { canvas.landscape.toggle() }
    @objc func deviceChosen(_ p: NSPopUpButton) { canvas.deviceName = p.titleOfSelectedItem ?? "" }
    @objc func pinClicked(_ sender: Any?) { _ = showAddConstraints(sender) }
    /// Update Frames: nothing to move while frames are written as stored.
    @objc func updateFramesClicked(_ sender: Any?) { canvas.needsDisplay = true }

    /// Align, Resolve, Embed In, Layout: menus of their commands; ones
    /// Ycode does not perform are disabled.
    @objc func menuClicked(_ sender: NSButton) {
        let items: [String]
        switch sender {
        case bar.align: items = ["Leading Edges", "Trailing Edges", "Top Edges", "Bottom Edges", "Horizontal Centers", "Vertical Centers", "Baselines",
                                 "Horizontally in Container", "Vertically in Container"]
        case bar.resolve: items = ["Update Constraint Constants", "Add Missing Constraints", "Reset to Suggested Constraints", "Clear Constraints"]
        case bar.embed: items = ["View", "Scroll View", "Stack View", "Navigation Controller", "Tab Bar Controller"]
        default: items = ["Portrait", "Landscape"]
        }
        let m = NSMenu()
        m.autoenablesItems = false
        for t in items { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i) }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
}
