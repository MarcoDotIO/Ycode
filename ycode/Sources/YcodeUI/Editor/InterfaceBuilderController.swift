import AppKit

/// The Interface Builder editor: Document Outline and a zoomable canvas.
/// Its inspectors (Identity, Attributes, Size, Connections) are shown by
/// the window's inspector area. Edits splice only the touched XML and are
/// written at once; undo/redo restore earlier bytes. See
/// `specs/ide/interface-builder.md`.
@MainActor
public final class InterfaceBuilderController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    public enum InspectorTab: Int, CaseIterable {
        case identity, attributes, size, connections
        public var title: String { ["Identity", "Attributes", "Size", "Connections"][rawValue] }
        public var symbol: String { ["person.crop.rectangle", "slider.horizontal.3", "ruler", "arrow.right.circle"][rawValue] }
    }

    public let url: URL
    public private(set) var document: IBDocument
    public private(set) var selected: IBDocument.Object?
    /// Called when the selection or the document changes (the window
    /// refreshes its inspectors).
    public var onChange: (() -> Void)?
    /// Whether edits are written to `url` (off for documents not from a file).
    public var writesFile: Bool
    let outline = IBOutlineView()
    let canvas: IBCanvasView
    let canvasScroll = NSScrollView()
    /// Chrome (InterfaceBuilderChrome.swift): bottom bar, jump bar, filter.
    let bar = IBCanvasBar()
    let jumpBar = NSTextField(labelWithString: "")
    let filterField = NSSearchField()
    let outlineColumn = NSView()
    var outlineWidth: NSLayoutConstraint?
    private var undoStack: [[UInt8]] = []
    private var redoStack: [[UInt8]] = []

    public init(document: IBDocument, url: URL = URL(fileURLWithPath: "/"), writesFile: Bool = false) {
        self.url = url
        self.document = document
        self.writesFile = writesFile
        canvas = IBCanvasView(document: document)
        super.init(nibName: nil, bundle: nil)
        canvas.controller = self
    }

    public convenience init(url: URL) throws {
        self.init(document: try IBDocument(url: url), url: url, writesFile: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let col = NSTableColumn(identifier: .init("o"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowSizeStyle = .small
        outline.registerForDraggedTypes([Self.rowType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.onDelete = { [weak self] in self?.deleteSelection() }
        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        canvasScroll.documentView = canvas
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.allowsMagnification = true
        canvasScroll.minMagnification = 0.1
        canvasScroll.maxMagnification = 4
        canvasScroll.backgroundColor = .underPageBackgroundColor
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: canvasScroll)
        layoutChrome(root: root, outlineScroll: outlineScroll)
        view = root
        reloadOutline()
        select(document.roots.first.flatMap(firstView) ?? document.roots.first)
    }

    func firstView(_ o: IBDocument.Object) -> IBDocument.Object? {
        if o.isView { return o }
        for c in o.children { if let v = firstView(c) { return v } }
        return nil
    }

    // MARK: Zoom

    public var zoom: CGFloat { canvasScroll.magnification }

    public func setZoom(_ z: CGFloat) {
        _ = view
        canvasScroll.magnification = min(max(z, canvasScroll.minMagnification), canvasScroll.maxMagnification)
        bar.zoomLabel.stringValue = zoomText
    }

    @objc public func zoomIn(_ sender: Any? = nil) { setZoom(zoom * 1.25) }
    @objc public func zoomOut(_ sender: Any? = nil) { setZoom(zoom / 1.25) }

    /// Fits every scene in the visible canvas area.
    @objc public func zoomToFit(_ sender: Any? = nil) {
        _ = view
        let content = canvas.contentBounds.insetBy(dx: -20, dy: -20)
        let visible = canvasScroll.contentSize
        guard content.width > 0, content.height > 0, visible.width > 0 else { return }
        setZoom(min(visible.width / content.width, visible.height / content.height, 1))
        canvasScroll.contentView.scroll(to: content.origin)
    }

    // MARK: Outline

    final class Row: NSObject {
        let object: IBDocument.Object?
        let constraint: IBDocument.Constraint?
        let children: [Row]
        let title: String
        /// Kind badge after a subview named by content ("Label").
        let badge: String?
        init(object: IBDocument.Object?, constraint: IBDocument.Constraint? = nil, title: String, badge: String? = nil, children: [Row]) {
            self.object = object
            self.constraint = constraint
            self.title = title
            self.badge = badge
            self.children = children
        }

        func filtered(_ q: String) -> Row? {
            let kids = children.compactMap { $0.filtered(q) }
            guard title.localizedCaseInsensitiveContains(q) || !kids.isEmpty else { return nil }
            return Row(object: object, constraint: constraint, title: title, badge: badge, children: kids)
        }
    }

    var rows: [Row] = []

    /// The outline's Filter (bottom of the column).
    public var outlineFilter = "" { didSet { reloadOutline() } }

    func reloadOutline() {
        rows = document.roots.map { row($0) }
        if !outlineFilter.isEmpty { rows = rows.compactMap { $0.filtered(outlineFilter) } }
        guard isViewLoaded else { return }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    func row(_ o: IBDocument.Object) -> Row {
        var kids = document.outlineChildren(o).map { row($0) }
        if !o.constraints.isEmpty {
            kids.append(Row(object: nil, title: "Constraints", children: o.constraints.map {
                Row(object: nil, constraint: $0, title: $0.text(document.name), children: [])
            }))
        }
        if o.element == "scene", document.isInitialScene(o) {
            kids.append(Row(object: nil, title: IBDocument.entryPointTitle, children: []))
        }
        return Row(object: o, title: document.outlineTitle(o), badge: document.outlineBadge(o), children: kids)
    }

    /// Outline titles, depth-first with indentation (for tests).
    public var outlineTitles: [String] {
        if rows.isEmpty { rows = document.roots.map { row($0) } }
        var out: [String] = []
        func walk(_ r: Row, _ d: Int) { out.append(String(repeating: "  ", count: d) + r.title); r.children.forEach { walk($0, d + 1) } }
        rows.forEach { walk($0, 0) }
        return out
    }

    /// Outline badges by title, depth-first (for tests): "title [badge]".
    public var outlineTitlesWithBadges: [String] {
        if rows.isEmpty { rows = document.roots.map { row($0) } }
        var out: [String] = []
        func walk(_ r: Row, _ d: Int) {
            out.append(String(repeating: "  ", count: d) + r.title + (r.badge.map { " [\($0)]" } ?? ""))
            r.children.forEach { walk($0, d + 1) }
        }
        rows.forEach { walk($0, 0) }
        return out
    }

    /// The jump bar's path down to the selection.
    public var jumpBarPath: [String] {
        guard let o = selected else { return [url.lastPathComponent] }
        var path = [url.lastPathComponent] + document.outlinePath(to: o)
        if let c = selectedConstraint, let con = document.constraints(involving: o.id).first(where: { $0.id == c }) {
            path += ["Constraints", con.text(document.name)]
        }
        return path
    }

    /// The selected constraint (outline row), if any.
    public private(set) var selectedConstraint: String?

    public func selectConstraint(_ id: String) {
        selectedConstraint = id
        canvas.selectedConstraint = id
        updateJumpBar()
        onChange?()
    }

    public func select(_ o: IBDocument.Object?) {
        selectedConstraint = nil
        selected = o
        canvas.selectedID = o?.id
        canvas.selectedConstraint = nil
        updateJumpBar()
        onChange?()
        guard isViewLoaded, let o else { return }
        func find(_ rs: [Row]) -> Row? {
            for r in rs { if r.object === o { return r }; if let f = find(r.children) { return f } }
            return nil
        }
        if let r = find(rows) {
            let i = outline.row(forItem: r)
            if i >= 0, outline.selectedRow != i { outline.selectRowIndexes([i], byExtendingSelection: false) }
        }
    }

    public func select(id: String) { select(document.byID[id]) }

    public func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Row)?.children.count ?? rows.count }
    public func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Row)?.children[index] ?? rows[index] }
    public func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Row)?.children.isEmpty ?? true) }

    public func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        guard let r = item as? Row else { return nil }
        let cell = NSTableCellView()
        let symbol = r.constraint != nil || r.title == "Constraints" ? "ruler" : r.object == nil ? "arrow.right"
            : r.object?.element == "scene" ? "rectangle.on.rectangle"
            : r.object?.isView == true ? "square.dashed" : "cube"
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: r.title)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [image, label]
        if let b = r.badge {
            let badge = NSTextField(labelWithString: b)
            badge.font = .systemFont(ofSize: 9, weight: .medium)
            badge.textColor = .secondaryLabelColor
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 3
            badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            views.append(badge)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = label
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                                     stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                                     stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    public func outlineViewSelectionDidChange(_ n: Notification) {
        guard let r = outline.item(atRow: outline.selectedRow) as? Row else { return }
        if let c = r.constraint { selectConstraint(c.id); return }
        guard let o = r.object, o !== selected || selectedConstraint != nil else { return }
        select(o)
    }

    // MARK: Outline drag: re-parenting

    static let rowType = NSPasteboard.PasteboardType("io.ycode.ib-outline-row")

    public func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let r = item as? Row, let obj = r.object, obj.isView, obj.parent?.isView == true else { return nil }
        let p = NSPasteboardItem()
        p.setString(obj.id, forType: Self.rowType)
        return p
    }

    public func outlineView(_ o: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let id = info.draggingPasteboard.string(forType: Self.rowType), let target = (item as? Row)?.object, target.isView,
              target.id != id else { return [] }
        return .move
    }

    public func outlineView(_ o: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: Self.rowType), let target = (item as? Row)?.object else { return false }
        return move(id, into: target.id)
    }

    // MARK: Editing

    /// Replaces the document with an edited one: records undo, writes the
    /// file, reloads, and keeps the selection.
    func commit(_ next: IBDocument) {
        guard next.source != document.source else { return }
        undoStack.append(document.source)
        redoStack = []
        replace(with: next)
    }

    private func replace(with next: IBDocument) {
        let keep = selected?.id
        document = next
        if writesFile { try? Data(next.source).write(to: url, options: .atomic) }
        canvas.document = next
        reloadOutline()
        select(keep.flatMap { next.byID[$0] } ?? next.roots.first.flatMap(firstView))
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    @objc public func undo(_ sender: Any? = nil) {
        guard let prev = undoStack.popLast(), let d = try? IBDocument(data: Data(prev)) else { return }
        redoStack.append(document.source)
        replace(with: d)
    }

    @objc public func redo(_ sender: Any? = nil) {
        guard let next = redoStack.popLast(), let d = try? IBDocument(data: Data(next)) else { return }
        undoStack.append(document.source)
        replace(with: d)
    }

    func apply(_ f: (IBDocument) throws -> IBDocument) {
        if let d = try? f(document) { commit(d) }
    }

    /// Sets the selected (or given) object's stored frame.
    public func setFrame(_ f: CGRect, of id: String? = nil) {
        guard let id = id ?? selected?.id else { return }
        apply { try $0.settingFrame(f, of: id) }
    }

    /// Sets a frame given in canvas root coordinates (move/resize).
    public func setRootFrame(_ r: CGRect, of id: String) {
        guard let f = document.storedFrame(forRootFrame: r, of: id) else { return }
        setFrame(f, of: id)
    }

    /// ⌫: deletes the selected constraint, else the selected object (not a
    /// scene's root view or a top-level object).
    public func deleteSelection() {
        if let c = selectedConstraint {
            selectedConstraint = nil
            apply { try $0.deletingConstraints([c]) }
            return
        }
        guard let o = selected, o.parent?.isView == true else { return }
        let parent = o.parent?.id
        apply { try $0.deleting([o.id]) }
        select(parent.flatMap { document.byID[$0] })
    }

    /// Moves a view into another view (Document Outline drag).
    @discardableResult
    public func move(_ id: String, into parent: String) -> Bool {
        guard let next = try? document.moving(id, into: parent), next.source != document.source else { return false }
        commit(next)
        select(id: id)
        return true
    }

    public func setConstant(_ v: CGFloat, ofConstraint id: String) { apply { try $0.settingConstant(v, ofConstraint: id) } }

    /// Adds constraints to the selected view. Returns the new IDs.
    @discardableResult
    public func addConstraints(_ spec: IBDocument.NewConstraints) -> [String] {
        guard let o = selected, let (next, ids) = try? document.addingConstraints(spec, to: o.id) else { return [] }
        commit(next)
        return ids
    }

    /// Editor ▸ Add New Constraints…: the popover for the selected view.
    @discardableResult
    @objc public func showAddConstraints(_ sender: Any? = nil) -> AddConstraintsController? {
        guard let o = selected, o.parent?.isView == true else { NSSound.beep(); return nil }
        let c = AddConstraintsController(document: document, viewID: o.id)
        c.onAdd = { [weak self] spec in self?.addConstraints(spec) }
        if view.window?.isVisible == true, let r = canvas.rect(of: o) {
            present(c, asPopoverRelativeTo: r, of: canvas, preferredEdge: .maxY, behavior: .transient)
        }
        return c
    }

    public func setTitle(_ s: String) { if let id = selected?.id { apply { try $0.settingTitle(s, of: id) } } }
    public func setPlaceholder(_ s: String) { if let id = selected?.id { apply { try $0.settingPlaceholder(s, of: id) } } }
    public func setHidden(_ b: Bool) { if let id = selected?.id { apply { try $0.settingHidden(b, of: id) } } }
    public func setEnabled(_ b: Bool) { if let id = selected?.id { apply { try $0.settingEnabled(b, of: id) } } }
    public func setAlignment(_ s: String) { if let id = selected?.id { apply { try $0.settingAlignment(s, of: id) } } }

    /// Inserts a Library object into the view under a canvas point (or the
    /// selected view), centered on the point. Returns the new ID.
    @discardableResult
    public func insert(_ kind: IBDocument.NewObject, atCanvasPoint p: CGPoint? = nil) -> String? {
        let target = p.flatMap { canvas.view(at: $0) } ?? (selected?.isView == true ? selected : nil)
        guard let parent = target, let parentRoot = canvas.rect(of: parent), let pf = parent.frame else { return nil }
        let size = kind.defaultSize
        let center = p ?? CGPoint(x: parentRoot.midX, y: parentRoot.midY)
        var local = CGRect(x: (center.x - parentRoot.minX - size.width / 2).rounded(), y: (center.y - parentRoot.minY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        if !document.isFlippedRuntime { local.origin.y = pf.height - local.maxY }
        guard let (next, id) = try? document.inserting(kind, into: parent.id, frame: local), !id.isEmpty else { return nil }
        commit(next)
        select(id: id)
        return id
    }

    // MARK: Inspectors (shown by the window's inspector area)

    /// Rows for an inspector: (label, value); an empty value is a heading.
    public func inspectorRows(_ t: InspectorTab) -> [(String, String)] {
        guard let o = selected else { return [("No Selection", "")] }
        switch t {
        case .identity:
            return [("Custom Class", ""), ("Class", o.attribute("customClass") ?? o.element),
                    ("Module", o.attribute("customModule") ?? "None"), ("Identity", ""),
                    ("Storyboard ID", o.attribute("storyboardIdentifier") ?? ""), ("Object ID", o.id),
                    ("Document", ""), ("Label", o.attribute("userLabel") ?? o.displayName)]
        case .attributes:
            var rows: [(String, String)] = [(IBDocument.words(o.element), "")]
            rows += o.attributes.filter { !["id", "key"].contains($0.0) }.map { ($0.0, $0.1) }
            for (name, attrs) in o.properties {
                rows.append((name, ""))
                rows += attrs.map { ($0.0, $0.1) }
            }
            for cell in o.children where cell.key == "cell" {
                rows.append(("\(IBDocument.words(cell.element)) (cell)", ""))
                rows += cell.attributes.filter { !["id", "key"].contains($0.0) }.map { ($0.0, $0.1) }
            }
            return rows
        case .size:
            var rows: [(String, String)] = [("View", "")]
            if let f = o.frame {
                rows += [("X", IBDocument.number(f.minX)), ("Y", IBDocument.number(f.minY)), ("Width", IBDocument.number(f.width)), ("Height", IBDocument.number(f.height))]
            } else {
                rows.append(("Frame", "None"))
            }
            if let mask = o.properties.first(where: { $0.0.hasPrefix("autoresizingMask") }) {
                rows.append(("Autoresizing", mask.1.filter { $0.1 == "YES" }.map(\.0).joined(separator: ", ")))
            }
            let cs = document.constraints(involving: o.id)
            rows.append(("Constraints", cs.isEmpty ? "None" : ""))
            rows += cs.map { ("", $0.text(document.name)) }
            return rows
        case .connections:
            var rows: [(String, String)] = []
            let groups: [(String, IBDocument.Connection.Kind)] = [("Outlets", .outlet), ("Outlet Collections", .outletCollection),
                                                                 ("Sent Actions", .action), ("Triggered Segues", .segue)]
            for (title, kind) in groups {
                let cs = o.connections.filter { $0.kind == kind }
                if cs.isEmpty { continue }
                rows.append((title, ""))
                rows += cs.map { ($0.name, "→ " + document.name($0.other)) }
            }
            let incoming = document.incomingConnections(to: o.id)
            if !incoming.isEmpty {
                rows.append(("Referencing", ""))
                rows += incoming.map { ($0.connection.name, "← " + $0.from.displayName) }
            }
            return rows.isEmpty ? [("Connections", "None")] : rows
        }
    }

    public static let alignments = ["left", "center", "right", "justified", "natural"]

    /// The view the window's inspector area shows for a tab. Size has X/Y/
    /// Width/Height fields; Attributes starts with Title, Placeholder,
    /// Alignment, Enabled and Hidden controls, then every attribute.
    public func inspectorView(_ t: InspectorTab) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        func label(_ s: String, bold: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = bold ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
            if !bold { l.textColor = .secondaryLabelColor; l.alignment = .right; l.widthAnchor.constraint(equalToConstant: 80).isActive = true }
            return l
        }
        func row(_ name: String, _ control: NSView) {
            let r = NSStackView(views: [label(name), control])
            r.alignment = .firstBaseline
            stack.addArrangedSubview(r)
        }
        func field(_ value: String, _ id: String) -> NSTextField {
            let f = IBInspectorField(string: value)
            f.identifier = .init(id)
            f.font = .systemFont(ofSize: 11)
            f.controlSize = .small
            f.target = self
            f.action = #selector(fieldChanged(_:))
            f.widthAnchor.constraint(equalToConstant: 130).isActive = true
            return f
        }
        // §13 sections first; Identity and Connections are only sections.
        let sections = inspectorSections(t)
        if t == .identity || t == .connections || (t == .size && selected?.frame == nil) {
            addSections(sections, to: stack)
            return stack
        }
        if t == .attributes { addSections(sections, to: stack) }
        if let o = selected, t == .size, let f = o.frame {
            stack.addArrangedSubview(label("Frame Rectangle", bold: true))
            for (name, v) in [("X", f.minX), ("Y", f.minY), ("Width", f.width), ("Height", f.height)] {
                row(name, field(IBDocument.number(v), "size.\(name)"))
            }
            for (l, v) in inspectorRows(.size).drop(while: { $0.0 != "Autoresizing" && $0.0 != "Constraints" }) where !l.isEmpty {
                if v.isEmpty { stack.addArrangedSubview(label(l, bold: true)) } else { row(l, NSTextField(wrappingLabelWithString: v)) }
            }
            // Each constraint: its text, and an editable constant.
            for c in document.constraints(involving: o.id) {
                let t = NSTextField(wrappingLabelWithString: c.text(document.name))
                t.font = .systemFont(ofSize: 10)
                t.preferredMaxLayoutWidth = 220
                stack.addArrangedSubview(t)
                row("Constant", field(c.constant, "constant.\(c.id)"))
            }
            addSections(sections, to: stack, skipping: ["X", "Y", "Width", "Height", "Show"])
            return stack
        }
        if let o = selected, t == .attributes, o.isView {
            stack.addArrangedSubview(label("Control", bold: true))
            if let title = document.title(of: o.id) { row("Title", field(title, "attr.title")) }
            if ["textField", "searchField"].contains(o.element) { row("Placeholder", field(document.placeholder(of: o.id) ?? "", "attr.placeholder")) }
            if let a = document.alignment(of: o.id) ?? (["textField", "label"].contains(o.element) ? "natural" : nil) {
                let pop = NSPopUpButton(frame: .zero, pullsDown: false)
                pop.addItems(withTitles: Self.alignments)
                pop.selectItem(withTitle: a)
                pop.controlSize = .small
                pop.target = self
                pop.action = #selector(alignmentChosen(_:))
                row("Alignment", pop)
            }
            let enabled = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(enabledToggled(_:)))
            enabled.state = document.isEnabled(o.id) ? .on : .off
            let hidden = NSButton(checkboxWithTitle: "Hidden", target: self, action: #selector(hiddenToggled(_:)))
            hidden.state = document.isHidden(o.id) ? .on : .off
            row("State", enabled)
            row("Drawing", hidden)
        }
        for (l, v) in inspectorRows(t) {
            if v.isEmpty { stack.addArrangedSubview(label(l, bold: true)); continue }
            let value = NSTextField(wrappingLabelWithString: v)
            value.font = .systemFont(ofSize: 11)
            value.preferredMaxLayoutWidth = 140
            value.isSelectable = true
            row(l, value)
        }
        return stack
    }

    @objc func fieldChanged(_ f: NSTextField) {
        guard let id = f.identifier?.rawValue, let o = selected else { return }
        switch id {
        case "attr.title": setTitle(f.stringValue)
        case "attr.placeholder": setPlaceholder(f.stringValue)
        case _ where id.hasPrefix("constant."):
            if let v = Double(f.stringValue) { setConstant(v, ofConstraint: String(id.dropFirst("constant.".count))) }
        default:
            guard id.hasPrefix("size."), var r = o.frame, let v = Double(f.stringValue) else { return }
            switch id {
            case "size.X": r.origin.x = v
            case "size.Y": r.origin.y = v
            case "size.Width": r.size.width = max(0, v)
            default: r.size.height = max(0, v)
            }
            setFrame(r)
        }
    }

    @objc func alignmentChosen(_ p: NSPopUpButton) { if let t = p.titleOfSelectedItem { setAlignment(t) } }
    @objc func enabledToggled(_ b: NSButton) { setEnabled(b.state == .on) }
    @objc func hiddenToggled(_ b: NSButton) { setHidden(b.state == .on) }
}

final class IBInspectorField: NSTextField {}

/// The canvas: scenes at their canvas locations (window scenes with a
/// title bar from `contentRect`), each root view as a white box with its
/// subviews as labeled rectangles, segue arrows between scenes and an
/// entry-point arrow. Selection handles move and resize views.
@MainActor
final class IBCanvasView: NSView {
    var document: IBDocument { didSet { layoutPlacements(); needsDisplay = true } }
    weak var controller: InterfaceBuilderController?
    var selectedID: String? { didSet { needsDisplay = true } }
    var selectedConstraint: String? { didSet { needsDisplay = true } }
    /// Bottom bar state: orientation and device (drawing only).
    var landscape = false { didSet { needsDisplay = true } }
    var deviceName = "" { didSet { needsDisplay = true } }
    /// Height of a scene's title bar, drawn above its frame.
    static let sceneBarHeight: CGFloat = 24
    struct Placement {
        var view: IBDocument.Object
        var scene: IBDocument.Object
        var title: String
        var origin: CGPoint
        /// Window chrome above the content (window scenes).
        var titleBar: CGFloat
    }
    private(set) var placements: [Placement] = []
    /// The union of all scene boxes.
    private(set) var contentBounds: CGRect = .zero
    override var isFlipped: Bool { true }
    static let margin: CGFloat = 200
    static let objectType = NSPasteboard.PasteboardType("io.ycode.ib-object")

    init(document: IBDocument) {
        self.document = document
        super.init(frame: .zero)
        registerForDraggedTypes([Self.objectType])
        layoutPlacements()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Scenes with a `canvasLocation` are centered there; others follow to
    /// the right of the last one.
    func layoutPlacements() {
        placements = []
        var nextX: CGFloat = 0
        var boxes: [CGRect] = []
        for r in document.roots {
            var views: [(IBDocument.Object, CGFloat)] = []
            func collect(_ o: IBDocument.Object) {
                if o.isView { views.append((o, (o.parent?.contentRect != nil) ? 28 : 0)); return }
                o.children.forEach(collect)
            }
            collect(r)
            for (v, bar) in views {
                let size = CGSize(width: v.frame!.width, height: v.frame!.height + bar)
                let origin: CGPoint
                if let c = r.canvasLocation, views.count == 1 {
                    origin = CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
                } else {
                    origin = CGPoint(x: nextX, y: 0)
                }
                nextX = max(nextX, origin.x + size.width + 80)
                // The scene title bar names the controller ("View Controller").
                let title = r.element == "scene" ? (r.children.first?.displayName ?? r.displayName) : (v.parent?.displayName ?? v.displayName)
                placements.append(Placement(view: v, scene: r, title: title, origin: CGPoint(x: origin.x, y: origin.y + bar), titleBar: bar))
                boxes.append(CGRect(origin: origin, size: size))
            }
        }
        // Shift everything so the canvas starts at a margin.
        let union = boxes.reduce(boxes.first ?? .zero) { $0.union($1) }
        let dx = Self.margin - union.minX, dy = Self.margin - union.minY
        for i in placements.indices { placements[i].origin.x += dx; placements[i].origin.y += dy }
        contentBounds = union.offsetBy(dx: dx, dy: dy)
        setFrameSize(NSSize(width: contentBounds.maxX + Self.margin, height: contentBounds.maxY + Self.margin))
    }

    func placement(of o: IBDocument.Object) -> Placement? {
        guard let root = document.rootView(of: o) else { return nil }
        return placements.first { $0.view.id == root.id }
    }

    func rect(of o: IBDocument.Object) -> CGRect? {
        guard let p = placement(of: o), let f = document.frameInRoot(o) else { return nil }
        return f.offsetBy(dx: p.origin.x, dy: p.origin.y)
    }

    /// The scene box (content plus title bar) of a scene object.
    func sceneBox(_ scene: IBDocument.Object) -> CGRect? {
        guard let p = placements.first(where: { $0.scene === scene }) else { return nil }
        return CGRect(x: p.origin.x, y: p.origin.y - p.titleBar, width: p.view.frame!.width, height: p.view.frame!.height + p.titleBar)
    }

    func scene(containing id: String) -> IBDocument.Object? {
        var o = document.byID[id]
        while let c = o, c.parent != nil { o = c.parent }
        return o
    }

    override func draw(_ dirtyRect: NSRect) {
        sceneBars = []
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        for p in placements {
            let box = CGRect(origin: p.origin, size: p.view.frame!.size)
            let full = box.insetBy(dx: 0, dy: 0).union(CGRect(x: box.minX, y: box.minY - p.titleBar, width: box.width, height: p.titleBar))
            drawSceneBar(p.title, above: full)
            if document.isFlippedRuntime { drawDeviceFrame(around: box) }
            if p.titleBar > 0 {
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: full, xRadius: 8, yRadius: 8).fill()
                for (i, c) in [NSColor.systemGray, .systemGray, .systemGray].enumerated() {
                    c.withAlphaComponent(0.6).setFill()
                    NSBezierPath(ovalIn: CGRect(x: full.minX + 10 + CGFloat(i) * 18, y: full.minY + 8, width: 12, height: 12)).fill()
                }
            }
            NSColor.textBackgroundColor.setFill()
            box.fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: full).stroke()
            p.view.walk { v in
                guard v !== p.view, v.isView, let r = rect(of: v) else { return }
                NSColor.systemBlue.withAlphaComponent(document.isHidden(v.id) ? 0.02 : 0.06).setFill()
                r.fill()
                NSColor.systemBlue.withAlphaComponent(0.5).setStroke()
                NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
                let label = NSAttributedString(string: v.displayName, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.labelColor])
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: r).addClip()
                label.draw(at: NSPoint(x: r.minX + 3, y: r.minY + 2))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        drawSegues()
        drawEntryPoint()
        drawConstraintGuides()
        if let p = dragPreview {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            p.fill()
            let path = NSBezierPath(rect: p)
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        if let id = selectedID, let o = document.byID[id], let r = rect(of: o) {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()
            if o.parent?.isView == true {
                for h in handles(r) {
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: h.rect).fill()
                    NSColor.controlAccentColor.setStroke()
                    NSBezierPath(ovalIn: h.rect).stroke()
                }
            }
        }
    }

    /// Segue arrows: from the source scene's right edge to the destination
    /// scene's left edge.
    var segueLines: [(from: CGPoint, to: CGPoint, kind: String)] {
        var out: [(CGPoint, CGPoint, String)] = []
        for r in document.roots {
            r.walk { o in
                for c in o.connections where c.kind == .segue {
                    guard let s = scene(containing: o.id), let d = scene(containing: c.other), s !== d,
                          let a = sceneBox(s), let b = sceneBox(d) else { continue }
                    out.append((CGPoint(x: a.maxX, y: a.midY), CGPoint(x: b.minX, y: b.midY), c.name))
                }
            }
        }
        return out
    }

    func drawSegues() {
        for s in segueLines {
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath()
            path.move(to: s.from)
            let mid = (s.from.x + s.to.x) / 2
            path.curve(to: s.to, controlPoint1: CGPoint(x: mid, y: s.from.y), controlPoint2: CGPoint(x: mid, y: s.to.y))
            path.lineWidth = 1.5
            path.stroke()
            arrowHead(at: s.to, pointingRight: s.to.x >= s.from.x)
            let c = CGPoint(x: mid, y: (s.from.y + s.to.y) / 2)
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)).fill()
            NSColor.secondaryLabelColor.setStroke()
            NSBezierPath(ovalIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)).stroke()
        }
    }

    /// The entry-point arrow into the initial controller's scene.
    var entryPoint: (from: CGPoint, to: CGPoint)? {
        guard let id = document.initialViewController, let s = scene(containing: id), let b = sceneBox(s) else { return nil }
        return (CGPoint(x: b.minX - 70, y: b.midY), CGPoint(x: b.minX - 4, y: b.midY))
    }

    /// A scene's title bar: a rounded strip with the controller's icon
    /// and title, above its frame.
    func drawSceneBar(_ title: String, above full: CGRect) {
        let bar = CGRect(x: full.minX, y: full.minY - Self.sceneBarHeight - (document.isFlippedRuntime ? 16 : 6), width: full.width, height: Self.sceneBarHeight)
        sceneBars.append((title, bar))
        NSColor.controlBackgroundColor.setFill()
        let path = NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        NSColor.systemYellow.setFill()
        NSBezierPath(roundedRect: CGRect(x: bar.minX + 6, y: bar.minY + 6, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
        let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
        t.draw(at: NSPoint(x: bar.minX + 24, y: bar.minY + 5))
    }

    /// Scene bars as last drawn (tests).
    private(set) var sceneBars: [(title: String, rect: CGRect)] = []

    /// A device-shaped bezel (Ycode's own rounded rectangle) around a
    /// scene's root view in iOS documents.
    func drawDeviceFrame(around box: CGRect) {
        let outer = box.insetBy(dx: -12, dy: -12)
        let path = NSBezierPath(roundedRect: outer, xRadius: 36, yRadius: 36)
        path.append(NSBezierPath(roundedRect: box, xRadius: 26, yRadius: 26).reversed)
        NSColor(white: 0.15, alpha: 1).setFill()
        path.fill()
    }

    /// Dashed guides for the selected view's constraints (or the selected
    /// constraint): from the view's edge to the other item's edge.
    func drawConstraintGuides() {
        guard let id = selectedID, let o = document.byID[id] else { return }
        for c in constraintGuides(for: o) {
            let path = NSBezierPath()
            path.move(to: c.from)
            path.line(to: c.to)
            path.setLineDash([3, 2], count: 2, phase: 0)
            (c.id == selectedConstraint ? NSColor.controlAccentColor : NSColor.systemOrange).setStroke()
            path.stroke()
        }
    }

    func constraintGuides(for o: IBDocument.Object) -> [(id: String, from: CGPoint, to: CGPoint)] {
        func point(_ r: CGRect, _ a: String) -> CGPoint {
            switch a {
            case "leading", "left", "leadingMargin": return CGPoint(x: r.minX, y: r.midY)
            case "trailing", "right", "trailingMargin": return CGPoint(x: r.maxX, y: r.midY)
            case "top", "topMargin": return CGPoint(x: r.midX, y: r.minY)
            case "bottom", "bottomMargin", "baseline", "lastBaseline": return CGPoint(x: r.midX, y: r.maxY)
            default: return CGPoint(x: r.midX, y: r.midY)
            }
        }
        var out: [(String, CGPoint, CGPoint)] = []
        for c in document.constraints(involving: o.id) {
            guard let a = c.firstItem.flatMap({ document.byID[$0] }).flatMap({ rect(of: $0) }) else { continue }
            let p1 = point(a, c.firstAttribute)
            if let second = c.secondItem.flatMap({ document.byID[$0] }), let b = rect(of: second) {
                out.append((c.id, p1, point(b, c.secondAttribute ?? c.firstAttribute)))
            } else {
                let w = c.firstAttribute == "width"
                out.append((c.id, w ? CGPoint(x: a.minX, y: a.maxY + 6) : CGPoint(x: a.maxX + 6, y: a.minY),
                            w ? CGPoint(x: a.maxX, y: a.maxY + 6) : CGPoint(x: a.maxX + 6, y: a.maxY)))
            }
        }
        return out
    }

    func drawEntryPoint() {
        guard let e = entryPoint else { return }
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.move(to: e.from)
        path.line(to: e.to)
        path.lineWidth = 3
        path.stroke()
        arrowHead(at: e.to, pointingRight: true)
    }

    func arrowHead(at p: CGPoint, pointingRight: Bool) {
        let d: CGFloat = pointingRight ? -1 : 1
        let head = NSBezierPath()
        head.move(to: p)
        head.line(to: CGPoint(x: p.x + 10 * d, y: p.y - 6))
        head.line(to: CGPoint(x: p.x + 10 * d, y: p.y + 6))
        head.close()
        NSColor.secondaryLabelColor.setFill()
        head.fill()
    }

    // MARK: Handles and dragging

    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    func handles(_ r: CGRect) -> [(handle: Handle, rect: CGRect)] {
        let pts: [(Handle, CGPoint)] = [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
                                        (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
                                        (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
                                        (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
        return pts.map { ($0.0, CGRect(x: $0.1.x - 4, y: $0.1.y - 4, width: 8, height: 8)) }
    }

    /// The deepest view under a canvas point.
    func view(at p: CGPoint) -> IBDocument.Object? {
        var hit: IBDocument.Object?
        for pl in placements { pl.view.walk { v in if v.isView, let r = rect(of: v), r.contains(p) { hit = v } } }
        return hit
    }

    /// A resized or moved rectangle (whole points).
    static func dragged(_ r: CGRect, handle: Handle?, by d: CGSize) -> CGRect {
        var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        switch handle {
        case nil: x0 += d.width; x1 += d.width; y0 += d.height; y1 += d.height
        case .topLeft?: x0 += d.width; y0 += d.height
        case .top?: y0 += d.height
        case .topRight?: x1 += d.width; y0 += d.height
        case .right?: x1 += d.width
        case .bottomRight?: x1 += d.width; y1 += d.height
        case .bottom?: y1 += d.height
        case .bottomLeft?: x0 += d.width; y1 += d.height
        case .left?: x0 += d.width
        }
        return CGRect(x: min(x0, x1).rounded(), y: min(y0, y1).rounded(), width: abs(x1 - x0).rounded(), height: abs(y1 - y0).rounded())
    }

    private var drag: (id: String, handle: Handle?, start: CGPoint, original: CGRect, root: CGRect)?
    private(set) var dragPreview: CGRect?

    /// Starts a drag at a canvas point: a handle of the selected view
    /// resizes it, the body of a view selects and moves it.
    func beginDrag(at p: CGPoint) {
        if let id = selectedID, let o = document.byID[id], o.parent?.isView == true, let r = rect(of: o),
           let h = handles(r).first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) {
            drag = (id, h.handle, p, r, document.frameInRoot(o)!)
            return
        }
        guard let v = view(at: p) else { return }
        controller?.select(v)
        if v.parent?.isView == true, let r = rect(of: v) { drag = (v.id, nil, p, r, document.frameInRoot(v)!) }
    }

    func continueDrag(to p: CGPoint) {
        guard let d = drag else { return }
        dragPreview = Self.dragged(d.original, handle: d.handle, by: CGSize(width: p.x - d.start.x, height: p.y - d.start.y))
        needsDisplay = true
    }

    func endDrag(at p: CGPoint) {
        defer { drag = nil; dragPreview = nil; needsDisplay = true }
        guard let d = drag else { return }
        let delta = CGSize(width: p.x - d.start.x, height: p.y - d.start.y)
        guard delta.width != 0 || delta.height != 0 else { return }
        controller?.setRootFrame(Self.dragged(d.root, handle: d.handle, by: delta), of: d.id)
    }

    override func mouseDown(with e: NSEvent) { beginDrag(at: convert(e.locationInWindow, from: nil)) }
    override func mouseDragged(with e: NSEvent) { continueDrag(to: convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { endDrag(at: convert(e.locationInWindow, from: nil)) }

    override var acceptsFirstResponder: Bool { true }

    /// ⌘+ / ⌘− / ⌘0 zoom; ⌘Z / ⇧⌘Z undo and redo document edits.
    override func keyDown(with e: NSEvent) {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (flags, e.charactersIgnoringModifiers ?? "") {
        case (.command, "="), (.command, "+"), ([.command, .shift], "="), ([.command, .shift], "+"): controller?.zoomIn()
        case (.command, "-"): controller?.zoomOut()
        case (.command, "0"): controller?.zoomToFit()
        case ([], "\u{7F}"), ([], "\u{F728}"): controller?.deleteSelection()
        case (.command, "z"): controller?.undo()
        case ([.command, .shift], "z"), ([.command, .shift], "Z"): controller?.redo()
        default: super.keyDown(with: e)
        }
    }

    override func magnify(with e: NSEvent) {
        controller?.setZoom((controller?.zoom ?? 1) * (1 + e.magnification))
    }

    @objc func undo(_ sender: Any?) { controller?.undo() }
    @objc func redo(_ sender: Any?) { controller?.redo() }

    // MARK: Dropping Library objects

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: Self.objectType) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let raw = sender.draggingPasteboard.string(forType: Self.objectType), let kind = IBDocument.NewObject(rawValue: raw) else { return false }
        return controller?.insert(kind, atCanvasPoint: convert(sender.draggingLocation, from: nil)) != nil
    }
}

/// The Document Outline: ⌫ deletes the selection.
final class IBOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 51 || e.keyCode == 117 { onDelete?() } else { super.keyDown(with: e) }
    }
}

/// Add New Constraints: spacing to the nearest neighbor on each side,
/// width, height, and centering in the container. See
/// `specs/ide/interface-builder.md` §Constraints.
@MainActor
public final class AddConstraintsController: NSViewController {
    public let viewID: String
    public private(set) var edgeChecks: [IBDocument.Edge: NSButton] = [:]
    public private(set) var edgeFields: [IBDocument.Edge: NSTextField] = [:]
    public let widthCheck = NSButton(checkboxWithTitle: "Width", target: nil, action: nil)
    public let heightCheck = NSButton(checkboxWithTitle: "Height", target: nil, action: nil)
    public let widthField = NSTextField(string: "")
    public let heightField = NSTextField(string: "")
    public let centerXCheck = NSButton(checkboxWithTitle: "Horizontally in Container", target: nil, action: nil)
    public let centerYCheck = NSButton(checkboxWithTitle: "Vertically in Container", target: nil, action: nil)
    public var onAdd: ((IBDocument.NewConstraints) -> Void)?
    let document: IBDocument

    init(document: IBDocument, viewID: String) {
        self.document = document
        self.viewID = viewID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let title = NSTextField(labelWithString: "Add New Constraints")
        title.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(title)
        let f = document.byID[viewID]?.frame ?? .zero
        for edge in IBDocument.Edge.allCases {
            let n = document.nearestNeighbor(of: viewID, edge: edge)
            let check = NSButton(checkboxWithTitle: "Spacing to nearest neighbor: \(edge.rawValue) (\(document.name(n?.id)))", target: nil, action: nil)
            check.font = .systemFont(ofSize: 11)
            let field = NSTextField(string: IBDocument.number(n?.spacing ?? 0))
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
            edgeChecks[edge] = check
            edgeFields[edge] = field
            stack.addArrangedSubview(NSStackView(views: [check, field]))
        }
        widthField.stringValue = IBDocument.number(f.width)
        heightField.stringValue = IBDocument.number(f.height)
        for fl in [widthField, heightField] { fl.widthAnchor.constraint(equalToConstant: 56).isActive = true }
        stack.addArrangedSubview(NSStackView(views: [widthCheck, widthField]))
        stack.addArrangedSubview(NSStackView(views: [heightCheck, heightField]))
        stack.addArrangedSubview(centerXCheck)
        stack.addArrangedSubview(centerYCheck)
        let add = NSButton(title: "Add Constraints", target: self, action: #selector(addClicked))
        add.keyEquivalent = "\r"
        stack.addArrangedSubview(add)
        view = stack
    }

    /// What the checked boxes and fields describe.
    public var spec: IBDocument.NewConstraints {
        _ = view
        var s = IBDocument.NewConstraints()
        for (edge, check) in edgeChecks where check.state == .on {
            s.spacing[edge] = CGFloat(Double(edgeFields[edge]?.stringValue ?? "") ?? 0)
        }
        if widthCheck.state == .on { s.width = CGFloat(Double(widthField.stringValue) ?? 0) }
        if heightCheck.state == .on { s.height = CGFloat(Double(heightField.stringValue) ?? 0) }
        s.centerX = centerXCheck.state == .on
        s.centerY = centerYCheck.state == .on
        return s
    }

    @objc public func addClicked() {
        onAdd?(spec)
        if presentingViewController != nil { dismiss(nil) }
    }
}
