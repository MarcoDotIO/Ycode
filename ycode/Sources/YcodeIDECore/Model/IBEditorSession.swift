#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The four inspectors an Interface Builder document adds after File,
/// History and Quick Help (`interface-builder.md` §Layout).
public enum IBInspectorTab: Int, CaseIterable, Sendable {
    case identity, attributes, size, connections
    public var title: String { ["Identity", "Attributes", "Size", "Connections"][rawValue] }
    /// The tab's symbol name (drawn by the platform's symbol set; Ycode's
    /// own drawings on Linux).
    public var symbol: String { ["person.crop.rectangle", "slider.horizontal.3", "ruler", "arrow.right.circle"][rawValue] }
}

/// One Document Outline row (`interface-builder.md` §Outline): an object, a
/// "Constraints" group, one constraint, or the storyboard entry point.
public struct IBOutlineRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case scene, view, object, constraints, constraint, entryPoint }
    /// Unique in the outline: the object ID, `constraints:<owner>`,
    /// `constraint:<id>` or `entry:<scene>`.
    public var id: String
    public var kind: Kind
    /// The object the row stands for (nil for groups and the entry point).
    public var objectID: String?
    /// The constraint the row stands for.
    public var constraintID: String?
    public var title: String
    /// Kind badge after a subview named by its content ("Label").
    public var badge: String?
    public var children: [IBOutlineRow]

    /// The row and its descendants matching `query` (case-insensitive), or
    /// nil when none does.
    public func filtered(_ query: String) -> IBOutlineRow? {
        let kids = children.compactMap { $0.filtered(query) }
        guard title.localizedCaseInsensitiveContains(query) || !kids.isEmpty else { return nil }
        var r = self
        r.children = kids
        return r
    }
}

/// The Interface Builder editor's state without any toolkit: the document,
/// the selection, undo and redo, the outline rows, the canvas layout and
/// every edit the editor offers. The macOS editor (`InterfaceBuilderController`)
/// and the Linux IDE's both drive one, so both write the same bytes. Each
/// edit splices only what changes, is written to the file at once (when
/// `writesFile`), and keeps the selection; opening never writes. See
/// `specs/ide/interface-builder.md`.
public final class IBEditorSession {
    public let url: URL
    /// Whether edits are written to `url` (off for documents not from a file).
    public var writesFile: Bool
    public private(set) var document: IBDocument
    /// The selected object's ID.
    public private(set) var selectedID: String?
    /// The selected constraint (an outline row), if any.
    public private(set) var selectedConstraint: String?
    /// The outline's Filter (bottom of the column).
    public var outlineFilter = ""
    /// The canvas layout of the current document.
    public private(set) var layout: IBCanvasLayout
    /// Why the last write failed, if it did.
    public private(set) var problem: String?
    /// Bumped on every change of document or selection (views wait on it).
    public private(set) var revision = 0
    /// Number of writes to the file (drivers and tests wait on it).
    public private(set) var saveCount = 0
    private var undoStack: [[UInt8]] = []
    private var redoStack: [[UInt8]] = []

    public init(document: IBDocument, url: URL = URL(fileURLWithPath: "/"), writesFile: Bool = false) {
        self.url = url
        self.document = document
        self.writesFile = writesFile
        layout = IBCanvasLayout(document: document)
        selectedID = Self.firstView(in: document)?.id ?? document.roots.first?.id
    }

    /// Opens the file at `url` (read only until the first edit).
    public convenience init(url: URL) throws {
        self.init(document: try IBDocument(url: url), url: url, writesFile: true)
    }

    // MARK: Selection

    public var selected: IBDocument.Object? { selectedID.flatMap { document.byID[$0] } }

    /// The first view of the document (what opening selects).
    public static func firstView(in d: IBDocument) -> IBDocument.Object? {
        func first(_ o: IBDocument.Object) -> IBDocument.Object? {
            if o.isView { return o }
            for c in o.children { if let v = first(c) { return v } }
            return nil
        }
        for r in d.roots { if let v = first(r) { return v } }
        return nil
    }

    public func select(id: String?) {
        selectedConstraint = nil
        selectedID = id.flatMap { document.byID[$0] != nil ? $0 : nil }
        revision += 1
    }

    public func selectConstraint(_ id: String) {
        selectedConstraint = id
        revision += 1
    }

    /// Selects what an outline row stands for.
    public func select(row: IBOutlineRow) {
        if let c = row.constraintID { selectConstraint(c) } else if let o = row.objectID { select(id: o) }
    }

    // MARK: Outline

    /// The Document Outline, filtered by `outlineFilter`.
    public var outlineRows: [IBOutlineRow] {
        let all = document.roots.map(row)
        let q = outlineFilter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.compactMap { $0.filtered(q) }
    }

    func row(_ o: IBDocument.Object) -> IBOutlineRow {
        var kids = document.outlineChildren(o).map(row)
        if !o.constraints.isEmpty {
            kids.append(IBOutlineRow(id: "constraints:\(o.id)", kind: .constraints, title: "Constraints", children: o.constraints.map {
                IBOutlineRow(id: "constraint:\($0.id)", kind: .constraint, constraintID: $0.id, title: $0.text(document.name), children: [])
            }))
        }
        if o.element == "scene", document.isInitialScene(o) {
            kids.append(IBOutlineRow(id: "entry:\(o.id)", kind: .entryPoint, title: IBDocument.entryPointTitle, children: []))
        }
        let kind: IBOutlineRow.Kind = o.element == "scene" ? .scene : o.isView ? .view : .object
        return IBOutlineRow(id: o.id, kind: kind, objectID: o.id, title: document.outlineTitle(o), badge: document.outlineBadge(o), children: kids)
    }

    /// Outline titles, depth-first with two spaces per level (tests);
    /// with `badges`, "title [badge]".
    public func outlineTitles(badges: Bool = false) -> [String] {
        var out: [String] = []
        func walk(_ r: IBOutlineRow, _ d: Int) {
            out.append(String(repeating: "  ", count: d) + r.title + (badges ? r.badge.map { " [\($0)]" } ?? "" : ""))
            r.children.forEach { walk($0, d + 1) }
        }
        outlineRows.forEach { walk($0, 0) }
        return out
    }

    /// The jump bar's path down to the selection (file name first).
    public var jumpBarPath: [String] {
        guard let o = selected else { return [url.lastPathComponent] }
        var path = [url.lastPathComponent] + document.outlinePath(to: o)
        if let c = selectedConstraint, let con = document.constraints(involving: o.id).first(where: { $0.id == c }) {
            path += ["Constraints", con.text(document.name)]
        }
        return path
    }

    // MARK: Editing

    /// Replaces the document with an edited one: records undo, writes the
    /// file, re-lays the canvas and keeps the selection. False when nothing
    /// changed.
    @discardableResult
    public func commit(_ next: IBDocument) -> Bool {
        guard next.source != document.source else { return false }
        undoStack.append(document.source)
        redoStack = []
        replace(with: next)
        return true
    }

    /// Applies an edit; false when it changed nothing or failed.
    @discardableResult
    public func apply(_ f: (IBDocument) throws -> IBDocument) -> Bool {
        guard let d = try? f(document) else { return false }
        return commit(d)
    }

    private func replace(with next: IBDocument) {
        let keep = selectedID
        document = next
        layout = IBCanvasLayout(document: next)
        write()
        selectedID = keep.flatMap { next.byID[$0] != nil ? $0 : nil } ?? Self.firstView(in: next)?.id
        selectedConstraint = nil
        revision += 1
    }

    private func write() {
        guard writesFile else { return }
        do {
            try Data(document.source).write(to: url, options: .atomic)
            problem = nil
            saveCount += 1
        } catch {
            problem = "The document could not be saved: \(error.localizedDescription)"
        }
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Restores the bytes before the last edit.
    public func undo() {
        guard let prev = undoStack.popLast(), let d = try? IBDocument(data: Data(prev)) else { return }
        redoStack.append(document.source)
        replace(with: d)
    }

    public func redo() {
        guard let next = redoStack.popLast(), let d = try? IBDocument(data: Data(next)) else { return }
        undoStack.append(document.source)
        replace(with: d)
    }

    /// Sets the selected (or given) object's stored frame.
    public func setFrame(_ f: CGRect, of id: String? = nil) {
        guard let id = id ?? selectedID else { return }
        apply { try $0.settingFrame(f, of: id) }
    }

    /// Sets a frame given in canvas root coordinates (move or resize).
    public func setRootFrame(_ r: CGRect, of id: String) {
        guard let f = document.storedFrame(forRootFrame: r, of: id) else { return }
        setFrame(f, of: id)
    }

    public func setFrameComponent(_ component: String, _ value: CGFloat, of id: String) {
        apply { try $0.settingFrameComponent(component, value, of: id) }
    }

    public func setExtendedEdge(_ edge: String, _ on: Bool, of id: String) {
        apply { try $0.settingExtendedEdge(edge, on, of: id) }
    }

    /// ⌫: deletes the selected constraint, else the selected object (not a
    /// scene's root view or a top-level object). False when nothing was.
    @discardableResult
    public func deleteSelection() -> Bool {
        if let c = selectedConstraint {
            selectedConstraint = nil
            return apply { try $0.deletingConstraints([c]) }
        }
        guard let o = selected, o.parent?.isView == true else { return false }
        let parent = o.parent?.id
        let done = apply { try $0.deleting([o.id]) }
        if done { select(id: parent) }
        return done
    }

    /// Moves a view into another view (Document Outline drag).
    @discardableResult
    public func move(_ id: String, into parent: String) -> Bool {
        guard let next = try? document.moving(id, into: parent), commit(next) else { return false }
        select(id: id)
        return true
    }

    public func setConstant(_ v: CGFloat, ofConstraint id: String) { apply { try $0.settingConstant(v, ofConstraint: id) } }

    /// Adds constraints to the selected view. Returns the new IDs.
    @discardableResult
    public func addConstraints(_ spec: IBDocument.NewConstraints) -> [String] {
        guard let o = selected, let (next, ids) = try? document.addingConstraints(spec, to: o.id), commit(next) else { return [] }
        return ids
    }

    /// The Add New Constraints values prefilled for the selected view: the
    /// spacing to the nearest neighbor on each side, and its size.
    public var suggestedConstraints: (spacing: [IBDocument.Edge: (neighbor: String, value: CGFloat)], size: CGSize)? {
        guard let o = selected, o.parent?.isView == true, let f = o.frame else { return nil }
        var spacing: [IBDocument.Edge: (String, CGFloat)] = [:]
        for e in IBDocument.Edge.allCases {
            if let n = document.nearestNeighbor(of: o.id, edge: e) { spacing[e] = (document.name(n.id), n.spacing) }
        }
        return (spacing, f.size)
    }

    public func setTitle(_ s: String) { if let id = selectedID { apply { try $0.settingTitle(s, of: id) } } }
    public func setPlaceholder(_ s: String) { if let id = selectedID { apply { try $0.settingPlaceholder(s, of: id) } } }
    public func setHidden(_ b: Bool) { if let id = selectedID { apply { try $0.settingHidden(b, of: id) } } }
    public func setEnabled(_ b: Bool) { if let id = selectedID { apply { try $0.settingEnabled(b, of: id) } } }
    public func setAlignment(_ s: String) { if let id = selectedID { apply { try $0.settingAlignment(s, of: id) } } }

    /// Writes an attribute (nil or empty removes); `initialViewController`
    /// goes on the document element.
    public func setAttribute(_ name: String, _ value: String?, of id: String) {
        if name == "initialViewController" { apply { try $0.settingInitial(value) }; return }
        apply { try $0.settingAttribute(name, value.flatMap { $0.isEmpty ? nil : $0 }, of: id) }
    }

    /// A toggle row of an inspector section, switched on or off.
    public func setToggle(_ row: IBInspectorRow, on: Bool) {
        switch row {
        case .toggle(_, let target, let attr, _, let onValue, let offValue): setAttribute(attr, on ? onValue : offValue, of: target)
        case .edgeToggle(_, let target, let edge, _): setExtendedEdge(edge, on, of: target)
        default: break
        }
    }

    /// A choice row set to `value`; the first option is the default and is
    /// written as removal.
    public func setChoice(_ row: IBInspectorRow, _ value: String) {
        guard case .choice(_, let target, let attr, let options, _) = row else { return }
        setAttribute(attr, value == options.first ? nil : value, of: target)
    }

    public func addRuntimeAttribute(keyPath: String, type: String = "string", value: String = "") {
        guard let id = selectedID else { return }
        apply { try $0.addingRuntimeAttribute(.init(keyPath: keyPath, type: type, value: value), to: id) }
    }

    /// The next free default key path for the + of User Defined Runtime Attributes.
    public var nextRuntimeKeyPath: String {
        let n = document.runtimeAttributes(of: selectedID ?? "").count
        return n == 0 ? "keyPath" : "keyPath\(n + 1)"
    }

    public func removeRuntimeAttribute(_ keyPath: String) {
        guard let id = selectedID else { return }
        apply { try $0.removingRuntimeAttribute(keyPath, of: id) }
    }

    /// The × on a connected outlet's capsule.
    public func disconnect(_ connectionID: String) { apply { try $0.removingConnection(connectionID) } }

    /// Inserts a Library object into the view under a canvas point (or the
    /// selected view, else the first root view), centered on the point, at
    /// its default size. Selects and returns the new ID.
    @discardableResult
    public func insert(_ kind: IBDocument.NewObject, atCanvasPoint p: CGPoint? = nil) -> String? {
        let target = p.flatMap { layout.view(at: $0) } ?? (selected?.isView == true ? selected : Self.firstView(in: document))
        guard let parent = target, let parentRoot = layout.rect(of: parent), let pf = parent.frame else { return nil }
        let size = kind.defaultSize
        let center = p ?? CGPoint(x: parentRoot.midX, y: parentRoot.midY)
        var local = CGRect(x: (center.x - parentRoot.minX - size.width / 2).rounded(), y: (center.y - parentRoot.minY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        if !document.isFlippedRuntime { local.origin.y = pf.height - local.maxY }
        guard let (next, id) = try? document.inserting(kind, into: parent.id, frame: local), !id.isEmpty, commit(next) else { return nil }
        select(id: id)
        return id
    }

    /// The selected object's inspector sections (`IBInspectorModel.swift`).
    public func inspectorSections(_ t: IBInspectorTab) -> [IBInspectorSection] {
        guard let o = selected else { return [] }
        switch t {
        case .identity: return document.identitySections(o.id)
        case .attributes: return document.attributesSections(o.id)
        case .size: return document.sizeSections(o.id)
        case .connections: return document.connectionsSections(o.id)
        }
    }

    /// The Attributes inspector's Control rows for a view (§Layout): Title
    /// (when the object has one), Placeholder (text fields), Alignment,
    /// Enabled and Hidden.
    public var controlState: IBControlState? {
        guard let o = selected, o.isView, o.parent != nil else { return nil }
        let alignment = document.alignment(of: o.id) ?? (["textField", "label"].contains(o.element) ? "natural" : nil)
        return IBControlState(title: document.title(of: o.id),
                              placeholder: ["textField", "searchField"].contains(o.element) ? document.placeholder(of: o.id) ?? "" : nil,
                              alignment: alignment, isEnabled: document.isEnabled(o.id), isHidden: document.isHidden(o.id))
    }
}

/// What the Attributes inspector's Control block shows for a view.
public struct IBControlState: Equatable, Sendable {
    /// Alignment pop-up choices, in menu order (`interface-builder.md` §Layout).
    public static let alignments = ["left", "center", "right", "justified", "natural"]
    public var title: String?
    public var placeholder: String?
    public var alignment: String?
    public var isEnabled: Bool
    public var isHidden: Bool
}
