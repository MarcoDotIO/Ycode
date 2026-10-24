import AppKit
import YcodePlist

/// One outline row: its index path in the property list.
final class PlistNode: NSObject {
    let path: [Int]
    init(_ path: [Int]) { self.path = path }
}

/// The property-list editor: Key | Type | Value outline, + and −. Every
/// edit is written to the file at once, in the file's own format (XML or
/// binary). See `specs/ide/plist-editor.md`.
@MainActor
public final class PlistEditorController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    public let url: URL
    public private(set) var document: PropertyListDocument
    public private(set) var tree: PlistTree
    let outline = NSOutlineView()
    private var nodes: [[Int]: PlistNode] = [:]

    public init(url: URL) throws {
        self.url = url
        document = try PropertyListDocument(data: try Data(contentsOf: url))
        tree = PlistTree(root: document.root)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func node(_ path: [Int]) -> PlistNode {
        if let n = nodes[path] { return n }
        let n = PlistNode(path)
        nodes[path] = n
        return n
    }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        for (id, title, w) in [("key", "Key", 320.0), ("type", "Type", 110.0), ("value", "Value", 300.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            outline.addTableColumn(c)
            if id == "key" { outline.outlineTableColumn = c }
        }
        outline.dataSource = self
        outline.delegate = self
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowSizeStyle = .small
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add item")!, target: self, action: #selector(addClicked))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove item")!, target: self, action: #selector(removeClicked))
        for b in [add, remove] { b.bezelStyle = .smallSquare }
        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 0
        for v in [scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -4),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
        view = root
        reload()
    }

    func reload() {
        nodes = [:]
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    /// Writes the file in its original format.
    func commit() {
        document.root = tree.root
        do { try document.data().write(to: url, options: .atomic) } catch { presentError(error) }
        reload()
    }

    // MARK: Edits (also used by tests)

    public func setKey(_ key: String, at path: [Int]) { tree.setKey(key, at: path); commit() }
    public func setType(_ type: String, at path: [Int]) { tree.setType(type, at: path); commit() }

    /// Sets a value from Value-column text; returns false if it does not
    /// parse for the item's type.
    @discardableResult
    public func setValueText(_ text: String, at path: [Int]) -> Bool {
        guard let type = tree.item(at: path)?.typeName, let v = PlistTree.parse(text, as: type) else { NSSound.beep(); return false }
        tree.setValue(v, at: path)
        commit()
        return true
    }

    @discardableResult
    public func insert(after path: [Int], asChild: Bool = false) -> [Int] {
        let p = tree.insert(after: path, asChild: asChild)
        commit()
        return p
    }

    public func remove(at path: [Int]) { tree.remove(at: path); commit() }

    var selectedPath: [Int]? { (outline.item(atRow: outline.selectedRow) as? PlistNode)?.path }
    /// The selected row's index path (nil = none).
    public var selectedItemPath: [Int]? { selectedPath }

    /// Selects the row of an index path ([] = Root).
    public func selectItem(at path: [Int]) {
        _ = view
        let row = outline.row(forItem: node(path))
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
    }

    @objc private func addClicked() { addItem() }

    /// "+" and Editor ▸ Add Item: a new item after the selected row, or as
    /// the first child of a selected container (the root with no selection).
    @discardableResult
    public func addItem() -> [Int] {
        let p: [Int]
        if let sel = selectedPath, let v = tree.item(at: sel), PlistTree.isContainer(v) { p = insert(after: sel, asChild: true) }
        else { p = insert(after: selectedPath ?? [Int](), asChild: selectedPath == nil) }
        selectItem(at: p)
        return p
    }

    /// Editor ▸ Value Type ▸ <type>: the selected row's type.
    @discardableResult
    public func setTypeOfSelection(_ type: String) -> Bool {
        guard let p = selectedPath else { return false }
        setType(type, at: p)
        selectItem(at: p)
        return true
    }

    /// The selected row's type name ("String", …).
    public var selectedTypeName: String? { selectedPath.flatMap { tree.item(at: $0)?.typeName } }

    /// Editor ▸ Raw Keys and Values: raw key names instead of readable
    /// ones (`reference-ui-5.md` §2.8; readable names as in the target's
    /// Info tab).
    public var showsRawKeys = false {
        didSet {
            guard oldValue != showsRawKeys else { return }
            let sel = selectedPath
            reload()
            if let sel { selectItem(at: sel) }
        }
    }

    /// The Key column's text for a key.
    public func displayedKey(_ key: String) -> String { showsRawKeys ? key : ProjectEditorModel.readableKey(key) }

    /// The key a Key-column text stands for (a readable name maps back).
    func rawKey(forDisplayed text: String, current: String) -> String {
        if text == displayedKey(current) { return current }
        return ProjectEditorModel.readableInfoKeys.first { $0.value == text }?.key ?? text
    }

    @objc private func removeClicked() { if let p = selectedPath { remove(at: p) } }

    // MARK: Outline

    public func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let path = (item as? PlistNode)?.path
        if path == nil { return 1 } // the Root row
        return tree.item(at: path!).map { PlistTree.children(of: $0).count } ?? 0
    }

    public func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let p = (item as? PlistNode)?.path else { return node([]) }
        return node(p + [index])
    }

    public func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let p = (item as? PlistNode)?.path, let v = tree.item(at: p) else { return false }
        return PlistTree.isContainer(v)
    }

    public func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        guard let p = (item as? PlistNode)?.path, let v = tree.item(at: p) else { return nil }
        let parent = p.isEmpty ? nil : tree.item(at: Array(p.dropLast()))
        let rawKey = p.isEmpty ? "Root" : PlistTree.children(of: parent!)[p.last!].key
        let key = p.isEmpty || !inDictionaryParent(parent) ? rawKey : displayedKey(rawKey)
        let inDictionary: Bool = { if case .dictionary? = parent { return true } else { return false } }()
        switch c?.identifier.rawValue {
        case "type":
            let pop = NSPopUpButton(frame: .zero, pullsDown: false)
            pop.addItems(withTitles: PlistTree.types)
            pop.selectItem(withTitle: v.typeName)
            pop.controlSize = .small
            pop.isBordered = false
            pop.identifier = .init(p.map(String.init).joined(separator: "."))
            pop.target = self
            pop.action = #selector(typeChosen(_:))
            return pop
        case "value":
            let editable = !PlistTree.isContainer(v)
            let f = editable ? NSTextField(string: PlistTree.editText(v)) : NSTextField(labelWithString: v.summary)
            f.textColor = editable ? .labelColor : .secondaryLabelColor
            f.font = .systemFont(ofSize: 11)
            if editable { f.isBordered = false; f.drawsBackground = false; f.identifier = .init("v" + p.map(String.init).joined(separator: ".")); f.delegate = self }
            return f
        default:
            let f = inDictionary ? NSTextField(string: key) : NSTextField(labelWithString: key)
            f.font = p.isEmpty ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
            if inDictionary { f.isBordered = false; f.drawsBackground = false; f.identifier = .init("k" + p.map(String.init).joined(separator: ".")); f.delegate = self }
            return f
        }
    }

    func inDictionaryParent(_ parent: PropertyListItem?) -> Bool { if case .dictionary? = parent { true } else { false } }

    static func path(_ s: String) -> [Int] { s.isEmpty ? [] : s.split(separator: ".").compactMap { Int($0) } }

    @objc private func typeChosen(_ p: NSPopUpButton) {
        guard let t = p.titleOfSelectedItem else { return }
        setType(t, at: Self.path(p.identifier?.rawValue ?? ""))
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let id = f.identifier?.rawValue, let kind = id.first else { return }
        let path = Self.path(String(id.dropFirst()))
        if kind == "k" {
            let current = path.isEmpty ? "" : PlistTree.children(of: tree.item(at: Array(path.dropLast())) ?? tree.root)[path.last!].key
            let key = rawKey(forDisplayed: f.stringValue, current: current)
            if key != current { setKey(key, at: path) }
        } else if kind == "v" { setValueText(f.stringValue, at: path) }
    }
}
