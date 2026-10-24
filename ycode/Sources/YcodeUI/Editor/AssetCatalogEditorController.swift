import AppKit

/// One image slot: a drop target that shows its image (or a dashed box) and
/// its title; a click opens a file picker.
@MainActor
final class SlotWell: NSView {
    let index: Int
    var image: NSImage? { didSet { needsDisplay = true } }
    let title: String
    var captions: [String] = []
    var boxLabel: String?
    var onFile: ((Int, URL) -> Void)?
    /// Clears the slot (Delete key or the context menu's Remove).
    var onClear: ((Int) -> Void)?

    init(index: Int, title: String, image: NSImage?) {
        self.index = index
        self.title = title
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 116))
        registerForDraggedTypes([.fileURL])
        widthAnchor.constraint(equalToConstant: 96).isActive = true
        heightAnchor.constraint(equalToConstant: 116).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 8, y: 4, width: 80, height: 80)
        if let image {
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let p = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            p.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            p.stroke()
            if let boxLabel {
                let l = NSAttributedString(string: boxLabel, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor])
                l.draw(at: NSPoint(x: box.midX - l.size().width / 2, y: box.midY - l.size().height / 2))
            }
        }
        for (i, line) in (captions.isEmpty ? [title] : captions).enumerated() {
            let t = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            t.draw(at: NSPoint(x: (bounds.width - t.size().width) / 2, y: 88 + CGFloat(i) * 13))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return false }
        onFile?(index, url)
        return true
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if image != nil, event.charactersIgnoringModifiers == "\u{7F}" || event.charactersIgnoringModifiers == "\u{F728}" { onClear?(index) } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard image != nil else { return nil }
        let m = NSMenu()
        let item = NSMenuItem(title: "Remove", action: #selector(removeChosen), keyEquivalent: "")
        item.target = self
        m.addItem(item)
        return m
    }

    @objc func removeChosen() { onClear?(index) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard window?.isVisible == true else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { onFile?(index, url) }
    }
}

/// The asset catalog editor: the outline on the left (folders are rows of
/// their own, with their sets as children), the selected set on the right
/// (image slots, color components, app icon sizes). The set's attributes
/// inspector is a fourth inspector tab (reference-ui-5.md §7.6, I6). See
/// `specs/ide/asset-catalog.md`.
@MainActor
public final class AssetCatalogEditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let catalog: AssetCatalog
    /// Every set the filter keeps, depth-first.
    public private(set) var sets: [AssetCatalog.AssetSet] = []
    /// The outline rows shown (folders and sets).
    public private(set) var rows: [AssetCatalog.OutlineRow] = []
    /// Collapsed rows (outline IDs).
    public private(set) var collapsed: Set<String> = []
    public private(set) var selected: AssetCatalog.AssetSet?
    /// The selected folder, when a folder row is selected.
    public private(set) var selectedFolder: URL?
    /// The outline filter (bottom of the set list).
    public private(set) var filter = ""
    public let filterField = NSSearchField()
    /// The inspector's controls, by row label (tests drive them).
    public private(set) var inspectorControls: [String: NSControl] = [:]
    /// The attributes inspector of the selection (shown in the inspector
    /// area's fourth tab).
    public private(set) var attributesView: NSView?
    /// The selection or the inspector content changed.
    public var onSelectionChange: (() -> Void)?
    /// Asks for files (Import…, Sticker Sequence Frame); nil = an open panel.
    public var chooseFiles: ((_ images: Bool) -> [URL])?
    private let list = NSTableView()
    private let detail = NSView()
    let addButton = NSPopUpButton(frame: .zero, pullsDown: true)

    public init(url: URL) {
        catalog = AssetCatalog(url: url)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        let col = NSTableColumn(identifier: .init("s"))
        list.addTableColumn(col)
        list.headerView = nil
        list.rowHeight = 22
        list.dataSource = self
        list.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        addButton.isBordered = false
        rebuildAddMenu()
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: self, action: #selector(removeClicked))
        remove.isBordered = false
        let sep = NSBox(); sep.boxType = .separator
        filterField.placeholderString = "Filter"
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.controlSize = .small
        for v in [scroll, addButton, remove, filterField, sep, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 200), scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -4),
            addButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4), addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            addButton.widthAnchor.constraint(equalToConstant: 34),
            remove.leadingAnchor.constraint(equalTo: addButton.trailingAnchor), remove.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            filterField.leadingAnchor.constraint(equalTo: remove.trailingAnchor, constant: 4), filterField.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            filterField.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -4),
            sep.topAnchor.constraint(equalTo: root.topAnchor), sep.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: scroll.trailingAnchor), sep.widthAnchor.constraint(equalToConstant: 1),
            detail.topAnchor.constraint(equalTo: root.topAnchor), detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: sep.trailingAnchor), detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        reload(selecting: nil)
    }

    /// The "+" menu; sticker items are enabled inside a sticker pack.
    func rebuildAddMenu() {
        addButton.removeAllItems()
        addButton.addItem(withTitle: "")
        addButton.item(at: 0)?.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        addButton.menu?.autoenablesItems = false
        for item in buildMenuItems(AssetCatalog.addMenu(insideStickerPack: isInsideStickerPack)) { addButton.menu?.addItem(item) }
    }

    func reload(selecting name: String?) {
        sets = AssetCatalog.filtered(catalog.sets(), by: filter)
        rows = catalog.outline(collapsed: collapsed, filter: filter)
        list.reloadData()
        if let folder = selectedFolder, name == nil, let i = rows.firstIndex(where: { AssetCatalog.same($0.url, folder) }) {
            selectRow(i)
        } else {
            select(name ?? selected?.name ?? sets.first?.name)
        }
    }

    /// Selects the first set named `name` (nil: nothing).
    public func select(_ name: String?) {
        _ = view
        selected = sets.first { $0.name == name } ?? (name == nil ? nil : sets.first)
        selectedFolder = nil
        if let s = selected, let i = rows.firstIndex(where: { AssetCatalog.same($0.set?.url, s.url) }) {
            list.selectRowIndexes([i], byExtendingSelection: false)
        }
        selectionChanged()
    }

    /// Selects an outline row (a folder or a set).
    public func selectRow(_ index: Int) {
        _ = view
        guard rows.indices.contains(index) else { return }
        let r = rows[index]
        selected = r.set
        selectedFolder = r.isFolder ? r.url : nil
        list.selectRowIndexes([index], byExtendingSelection: false)
        selectionChanged()
    }

    /// Selects the row with this outline ID ("Brand", "Brand/Accent.colorset").
    @discardableResult
    public func selectRow(id: String) -> Bool {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return false }
        selectRow(i)
        return true
    }

    func selectionChanged() {
        rebuildAddMenu()
        showDetail()
    }

    /// Expands or collapses a row with children.
    public func toggleRow(id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        reload(selecting: selected?.name)
    }

    /// Narrows the outline to sets whose name contains `text`.
    public func setFilter(_ text: String) {
        _ = view
        filter = text
        if filterField.stringValue != text { filterField.stringValue = text }
        reload(selecting: selected?.name)
    }

    @objc private func filterChanged(_ f: NSSearchField) { setFilter(f.stringValue) }

    // MARK: Detail

    func showDetail() {
        detail.subviews.forEach { $0.removeFromSuperview() }
        inspectorControls = [:]
        attributesView = nil
        defer { onSelectionChange?() }
        if let folder = selectedFolder {
            let title = NSTextField(labelWithString: folder.lastPathComponent)
            title.font = .boldSystemFont(ofSize: 14)
            let typeLabel = NSTextField(labelWithString: "Folder")
            typeLabel.textColor = .secondaryLabelColor
            let header = NSStackView(views: [title, NSView(), typeLabel])
            header.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
            place([header])
            attributesView = folderInspectorView(folder)
            return
        }
        guard let set = selected else { return }
        let title = NSTextField(labelWithString: set.name)
        title.font = .boldSystemFont(ofSize: 14)
        let typeLabel = NSTextField(labelWithString: set.kind.typeLabel)
        typeLabel.textColor = .secondaryLabelColor
        typeLabel.alignment = .right
        let header = NSStackView(views: [title, NSView(), typeLabel])
        header.distribution = .fill
        header.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        var rows: [NSView] = [header]
        switch set.kind {
        case .imageSet, .appIconSet, .symbolSet, .dataSet, .arReferenceImage, .arReferenceObject, .launchImage, .stickersIconSet:
            let slots = AssetCatalog.slots(of: set)
            let wells = slots.enumerated().map { i, s -> SlotWell in
                let w = SlotWell(index: i, title: s.title, image: s.filename.flatMap { NSImage(contentsOf: set.url.appendingPathComponent($0)) })
                w.captions = s.captions
                w.boxLabel = s.boxLabel
                w.onFile = { [weak self] i, url in try? self?.setImage(url, slot: i) }
                w.onClear = { [weak self] i in try? self?.clearImage(slot: i) }
                return w
            }
            // Wrap rows of four slots.
            for chunk in stride(from: 0, to: wells.count, by: 4) {
                let row = NSStackView(views: Array(wells[chunk..<min(chunk + 4, wells.count)]))
                row.spacing = 8
                rows.append(row)
            }
            if set.kind == .imageSet, !slots.contains(where: { $0.appearance == "dark" }) {
                rows.append(NSButton(title: "Add Dark Appearance", target: self, action: #selector(addDark)))
            }
        case .colorSet:
            for (i, c) in AssetCatalog.colors(of: set).enumerated() {
                let caption = NSTextField(labelWithString: c.appearance.map { $0.capitalized } ?? "Universal")
                caption.textColor = .secondaryLabelColor
                rows.append(colorRow(c, index: i))
                rows.append(caption)
            }
        default:
            break
        }
        place(rows)
        attributesView = inspectorView(AssetCatalog.inspector(for: set))
    }

    private func place(_ rows: [NSView]) {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: detail.topAnchor), stack.leadingAnchor.constraint(equalTo: detail.leadingAnchor)])
    }

    /// The folder inspector: Name and Provides Namespace.
    func folderInspectorView(_ folder: URL) -> NSView {
        let heading = NSTextField(labelWithString: "Folder")
        heading.font = .boldSystemFont(ofSize: 11)
        let ns = NSButton(checkboxWithTitle: "Provides Namespace", target: self, action: #selector(namespaceToggled(_:)))
        ns.state = AssetCatalog.providesNamespace(folder) ? .on : .off
        inspectorControls["Provides Namespace"] = ns
        let name = NSTextField(labelWithString: folder.lastPathComponent)
        name.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, NSStackView(views: [NSTextField(labelWithString: "Name"), name]), ns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.identifier = .init("inspector")
        return stack
    }

    @objc private func namespaceToggled(_ b: NSButton) { try? setProvidesNamespace(b.state == .on) }

    /// The selected folder's Provides Namespace checkbox.
    public func setProvidesNamespace(_ on: Bool) throws {
        guard let f = selectedFolder else { return }
        try AssetCatalog.setProvidesNamespace(on, folder: f)
        showDetail()
    }

    /// The attributes inspector for the selected set.
    func inspectorView(_ section: AssetCatalog.InspectorSection) -> NSView {
        let heading = NSTextField(labelWithString: section.title)
        heading.font = .boldSystemFont(ofSize: 11)
        var views: [NSView] = [heading]
        let editable = selected?.kind == .colorSet
        for r in section.rows {
            if let c = r.checked {
                let b = NSButton(checkboxWithTitle: r.label, target: editable ? self : nil, action: editable ? #selector(inspectorCheckboxChanged(_:)) : nil)
                b.state = c ? .on : .off
                b.identifier = .init(r.label)
                inspectorControls[r.label] = b
                views.append(b)
            } else if editable, r.label == "Appearances" {
                let p = NSPopUpButton(frame: .zero, pullsDown: false)
                p.addItems(withTitles: ["None", "Any, Dark"])
                p.selectItem(withTitle: r.value ?? "None")
                p.target = self
                p.action = #selector(inspectorAppearancesChanged(_:))
                inspectorControls[r.label] = p
                views.append(NSStackView(views: [NSTextField(labelWithString: r.label), p]))
            } else if r.label == "Localization" {
                views.append(NSStackView(views: [NSTextField(labelWithString: r.label), NSButton(title: r.value ?? "", target: nil, action: nil)]))
            } else {
                let v = NSTextField(labelWithString: r.value ?? "")
                v.textColor = .secondaryLabelColor
                views.append(NSStackView(views: [NSTextField(labelWithString: r.label), v]))
            }
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.identifier = .init("inspector")
        return stack
    }

    func colorRow(_ c: AssetCatalog.ColorValue, index: Int) -> NSView {
        let colorBox = NSBox()
        colorBox.boxType = .custom
        colorBox.fillColor = Self.nsColor(c)
        colorBox.borderColor = .separatorColor
        colorBox.cornerRadius = 6
        colorBox.widthAnchor.constraint(equalToConstant: 64).isActive = true
        colorBox.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let space = NSPopUpButton(frame: .zero, pullsDown: false)
        space.addItems(withTitles: ["sRGB", "Display P3"])
        space.selectItem(at: c.space == .sRGB ? 0 : 1)
        space.tag = index
        space.target = self
        space.action = #selector(componentsEdited(_:))
        var fields: [NSView] = [space]
        for (k, v) in [("Red", c.red), ("Green", c.green), ("Blue", c.blue), ("Alpha", c.alpha)] {
            let f = NSTextField(string: String(format: "%.3f", v))
            f.identifier = .init(k)
            f.tag = index
            f.target = self
            f.action = #selector(componentsEdited(_:))
            f.widthAnchor.constraint(equalToConstant: 60).isActive = true
            fields += [NSTextField(labelWithString: k), f]
        }
        let appearance = NSTextField(labelWithString: c.appearance.map { $0.capitalized } ?? "Any Appearance")
        appearance.textColor = .secondaryLabelColor
        let controls = NSStackView(views: fields)
        let right = NSStackView(views: [appearance, controls])
        right.orientation = .vertical
        right.alignment = .leading
        let row = NSStackView(views: [colorBox, right])
        row.spacing = 12
        return row
    }

    static func nsColor(_ c: AssetCatalog.ColorValue) -> NSColor {
        c.space == .sRGB ? NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
            : NSColor(displayP3Red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    @objc private func componentsEdited(_ sender: NSControl) {
        guard let set = selected, let row = sender.superview else { return }
        let index = sender.tag
        var c = AssetCatalog.colors(of: set)[index]
        for v in row.subviews {
            if let p = v as? NSPopUpButton { c.space = p.indexOfSelectedItem == 0 ? .sRGB : .displayP3 }
            if let f = v as? NSTextField, f.isEditable, let x = Double(f.stringValue) {
                switch f.identifier?.rawValue { case "Red": c.red = x; case "Green": c.green = x; case "Blue": c.blue = x; case "Alpha": c.alpha = x; default: break }
            }
        }
        try? setColor(c, at: index)
    }

    // MARK: Edits (also used by tests)

    public func setImage(_ file: URL, slot: Int) throws {
        guard let set = selected else { return }
        try AssetCatalog.setImage(file, slot: slot, in: set)
        showDetail()
    }

    public func clearImage(slot: Int) throws {
        guard let set = selected else { return }
        try AssetCatalog.clearImage(slot: slot, in: set)
        showDetail()
    }

    public func setColor(_ c: AssetCatalog.ColorValue, at index: Int) throws {
        guard let set = selected else { return }
        try AssetCatalog.setColor(c, at: index, in: set)
        showDetail()
    }

    /// Applies a Color Set inspector checkbox (a device or High Contrast)
    /// to the Contents.json.
    public func setInspectorCheckbox(_ label: String, on: Bool) throws {
        guard let set = selected, set.kind == .colorSet else { return }
        if label == "High Contrast" {
            try AssetCatalog.setColorHighContrast(on, in: set)
        } else if let d = AssetCatalog.colorDevices.first(where: { $0.label == label }) {
            try AssetCatalog.setColorIdiom(d.idiom, included: on, in: set)
        }
        showDetail()
    }

    /// Applies the Color Set Appearances popup ("None" or "Any, Dark").
    public func setInspectorAppearances(_ value: String) throws {
        guard let set = selected, set.kind == .colorSet else { return }
        try AssetCatalog.setColorDarkAppearance(value == "Any, Dark", in: set)
        showDetail()
    }

    @objc private func inspectorCheckboxChanged(_ b: NSButton) {
        guard let label = b.identifier?.rawValue else { return }
        try? setInspectorCheckbox(label, on: b.state == .on)
    }

    @objc private func inspectorAppearancesChanged(_ p: NSPopUpButton) {
        try? setInspectorAppearances(p.titleOfSelectedItem ?? "None")
    }

    @objc func addDark() {
        guard let set = selected else { return }
        try? AssetCatalog.addDarkAppearance(to: set)
        showDetail()
    }

    // MARK: Adding

    /// Where new items go: the selected folder, the selected set when it
    /// holds others, else the selected set's folder; the catalog by default.
    public var insertionDirectory: URL {
        if let f = selectedFolder { return f }
        if let s = selected { return s.kind.isContainer ? s.url : s.url.deletingLastPathComponent() }
        return catalog.url
    }

    /// The selection is a sticker pack or inside one.
    public var isInsideStickerPack: Bool {
        let p = insertionDirectory.standardizedFileURL.path
        return p.hasSuffix(".stickerpack") || p.contains(".stickerpack/")
    }

    /// Adds a set of a kind (`creatable` tags) with a unique name in the
    /// insertion directory; selects it.
    @discardableResult
    public func addSet(kind: Int, name: String? = nil) throws -> AssetCatalog.AssetSet {
        let dir = insertionDirectory
        let group = catalog.relativePath(dir)
        let other = kind >= Self.otherKindBase && kind - Self.otherKindBase < AssetCatalog.otherSetTitles.count
            ? AssetCatalog.otherSetTitles[kind - Self.otherKindBase] : nil
        let (base, ext): (String, String) = switch kind {
        case 1: ("Color", "colorset")
        case 2, 3, Self.watchIconTag: ("AppIcon", "appiconset")
        case Self.visionIconTag: ("AppIcon", "solidimagestack")
        case Self.tvIconTag: ("App Icon & Top Shelf Image", "brandassets")
        case Self.messagesIconTag: ("iMessage App Icon", "stickersiconset")
        default: other.map { ($0.defaultName, $0.kind.rawValue) } ?? ("Image", "imageset")
        }
        let n = name ?? AssetCatalog.uniqueName(base, ext: ext, in: dir)
        var set: AssetCatalog.AssetSet = switch kind {
        case 1: try catalog.addColorSet(named: n, in: group)
        case 2: try catalog.addMacAppIconSet(named: n, in: dir)
        case 3: try catalog.addSingleSizeAppIcon(platform: "ios", named: n, in: dir)
        case Self.watchIconTag: try catalog.addSingleSizeAppIcon(platform: "watchos", named: n, in: dir)
        case Self.visionIconTag: try catalog.addVisionOSAppIcon(named: n, in: dir)
        case Self.tvIconTag: try catalog.addTVBrandAssets(named: n, in: dir)
        case Self.messagesIconTag: try catalog.addMessagesIcon(named: n, in: dir)
        default:
            if let other { try catalog.addSet(other.kind, named: n, in: group) } else { try catalog.addImageSet(named: n, in: group) }
        }
        set.group = catalog.sets().first { AssetCatalog.same($0.url, set.url) }?.group ?? set.group
        selectedFolder = nil
        reload(selecting: nil)
        if let i = rows.firstIndex(where: { AssetCatalog.same($0.set?.url, set.url) }) { selectRow(i) }
        return set
    }

    /// "+" menu titles Ycode can create, mapped to `addSet(kind:)`.
    /// Tags from here on index `AssetCatalog.otherSetTitles`.
    nonisolated static let otherKindBase = 10
    nonisolated static let watchIconTag = 40, visionIconTag = 41, tvIconTag = 42, messagesIconTag = 43
    nonisolated static let folderTag = 100
    nonisolated static let folderFromSelectionTag = 102, importTag = 103, stickerFrameTag = 104

    /// "+" ▸ Folder / Folder with Namespace: a uniquely named folder in the
    /// insertion directory; selects it.
    @discardableResult
    public func addFolder(namespace: Bool) throws -> URL {
        let dir = insertionDirectory
        let n = AssetCatalog.uniqueName("Folder", ext: nil, in: dir)
        let u = try catalog.addFolder(named: n, namespace: namespace, in: catalog.relativePath(dir))
        selectFolderAfterReload(u)
        return u
    }

    private func selectFolderAfterReload(_ u: URL) {
        selectedFolder = u
        selected = nil
        reload(selecting: nil)
    }

    /// "+" ▸ Folder from Selection: the selected item moves into a new folder.
    @discardableResult
    public func folderFromSelection() throws -> URL? {
        guard let item = selected?.url ?? selectedFolder else { return nil }
        let u = try catalog.folder(fromSelection: [item])
        selectFolderAfterReload(u)
        return u
    }

    /// "+" ▸ Import…: image files become image sets, others data sets.
    @discardableResult
    public func importFiles(_ files: [URL]) throws -> [AssetCatalog.AssetSet] {
        let made = try catalog.importFiles(files, into: insertionDirectory)
        selectedFolder = nil
        reload(selecting: nil)
        if let last = made.last, let i = rows.firstIndex(where: { AssetCatalog.same($0.set?.url, last.url) }) { selectRow(i) }
        return made
    }

    /// "+" ▸ Sticker Sequence Frame: appends a frame to the selected
    /// sticker sequence (a new sequence in the pack when none is selected).
    public func addStickerSequenceFrame(_ file: URL) throws {
        guard isInsideStickerPack else { return }
        let seq = selected?.kind == .stickerSequence ? selected! : try addSet(kind: Self.creatable["Sticker Sequence"]!)
        try AssetCatalog.addStickerSequenceFrame(file, to: seq)
        showDetail()
    }

    nonisolated static let creatable: [String: Int] = {
        var m = ["Image Set": 0, "Color Set": 1, "macOS App Icon": 2, "iOS App Icon": 3, "watchOS App Icon": watchIconTag,
                 "visionOS App Icon": visionIconTag, "tvOS App Icon and Top Shelf Image": tvIconTag, "Messages Extension Icon": messagesIconTag]
        for (i, t) in AssetCatalog.otherSetTitles.enumerated() { m[t.title] = otherKindBase + i }
        m["Folder"] = folderTag
        m["Folder with Namespace"] = folderTag + 1
        m["Folder from Selection"] = folderFromSelectionTag
        m["Import…"] = importTag
        m["Sticker Sequence Frame"] = stickerFrameTag
        return m
    }()

    /// Runs a "+" (or Editor ▸ Add New Asset) item by its tag.
    public func addAsset(tag: Int) {
        switch tag {
        case Self.folderTag, Self.folderTag + 1: _ = try? addFolder(namespace: tag == Self.folderTag + 1)
        case Self.folderFromSelectionTag: _ = try? folderFromSelection()
        case Self.importTag: if let files = pickFiles(images: false), !files.isEmpty { _ = try? importFiles(files) }
        case Self.stickerFrameTag: if let f = pickFiles(images: true)?.first { try? addStickerSequenceFrame(f) }
        default: _ = try? addSet(kind: tag)
        }
    }

    private func pickFiles(images: Bool) -> [URL]? {
        if let chooseFiles { return chooseFiles(images) }
        guard view.window?.isVisible == true else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = !images
        if images { panel.allowedContentTypes = [.image] }
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func buildMenuItems(_ entries: [AssetCatalog.AddMenuEntry]) -> [NSMenuItem] {
        entries.map { e in
            switch e {
            case .separator: return .separator()
            case let .submenu(t, children):
                let item = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                let m = NSMenu(title: t)
                m.autoenablesItems = false
                buildMenuItems(children).forEach(m.addItem)
                item.submenu = m
                return item
            case let .item(t, enabled):
                let kind = Self.creatable[t]
                let item = NSMenuItem(title: t, action: kind == nil ? nil : #selector(addChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = kind ?? -1
                item.isEnabled = enabled && kind != nil && (kind != Self.folderFromSelectionTag || selected != nil || selectedFolder != nil)
                return item
            }
        }
    }

    /// The "+" menu's items by title (tests).
    public var addMenuItems: [String: NSMenuItem] {
        _ = view
        var out: [String: NSMenuItem] = [:]
        func walk(_ m: NSMenu?) { for i in m?.items ?? [] { if !i.title.isEmpty { out[i.title] = i }; walk(i.submenu) } }
        walk(addButton.menu)
        return out
    }

    @objc private func addChosen(_ sender: NSMenuItem) { addAsset(tag: sender.tag) }

    @objc private func removeClicked() { removeSelected() }

    /// "−" and Editor ▸ Delete Selected Items.
    public func removeSelected() {
        if let f = selectedFolder {
            try? FileManager.default.removeItem(at: f)
            selectedFolder = nil
        } else if let set = selected {
            try? catalog.remove(set)
        }
        selected = nil
        reload(selecting: nil)
    }

    // MARK: List

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let symbol = r.set.map { s in
            switch s.kind {
            case .imageSet: "photo"; case .colorSet: "paintpalette"; case .appIconSet, .solidImageStack, .brandAssets, .stickersIconSet: "app"
            case .symbolSet: "star.square"; case .dataSet: "doc"; case .spriteAtlas, .arResourceGroup, .stickerPack: "folder"
            default: "square.stack.3d.up"
            }
        } ?? "folder"
        let disclosure = NSButton(title: r.hasChildren ? (collapsed.contains(r.id) ? "\u{25B8}" : "\u{25BE}") : " ", target: self,
                                  action: #selector(disclosureClicked(_:)))
        disclosure.isBordered = false
        disclosure.identifier = .init(r.id)
        disclosure.isEnabled = r.hasChildren
        disclosure.widthAnchor.constraint(equalToConstant: 12).isActive = true
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = r.isFolder ? .systemBlue : .secondaryLabelColor
        let label = NSTextField(labelWithString: r.name)
        let stack = NSStackView(views: [disclosure, icon, label])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(r.depth) * 14, bottom: 0, right: 0)
        return stack
    }

    @objc private func disclosureClicked(_ b: NSButton) { if let id = b.identifier?.rawValue { toggleRow(id: id) } }

    public func tableViewSelectionDidChange(_ n: Notification) {
        let i = list.selectedRow
        guard i >= 0, rows.indices.contains(i) else { return }
        let r = rows[i]
        if let s = selected, let rs = r.set, AssetCatalog.same(rs.url, s.url) { return }
        if let f = selectedFolder, r.isFolder, AssetCatalog.same(r.url, f) { return }
        selectRow(i)
    }
}

extension WorkspaceWindowController {
    /// While the asset catalog editor is shown, the inspector area adds its
    /// attributes inspector as a fourth tab (reference-ui-5.md §7.6, I6).
    func updateAssetInspector(previous: AssetCatalogEditorController?) {
        guard let a = assetEditor else {
            if previous != nil { inspector.setExtraInspectors([], provider: nil) }
            return
        }
        a.onSelectionChange = { [weak self] in self?.inspector.refresh() }
        inspector.setExtraInspectors([(AssetCatalogEditorController.inspectorTabTitle, "slider.horizontal.3")], provider: { [weak a] _ in
            a?.attributesView ?? NSView()
        }, select: CommandTable.inspectors.count)
    }
}

extension AssetCatalogEditorController {
    public static let inspectorTabTitle = "Attributes"
}
