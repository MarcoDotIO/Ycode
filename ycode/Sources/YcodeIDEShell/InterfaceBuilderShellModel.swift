#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Observation
import YcodeIDECore

/// The Interface Builder editor of the Linux IDE (`specs/ide/interface-builder.md`):
/// the Document Outline, the canvas, the Library's Objects tab and the
/// Identity, Attributes, Size and Connections inspectors, over the same
/// `IBEditorSession` the macOS editor drives, so both write the same bytes.
/// Every edit is written at once; a document that is only looked at is
/// never written. No toolkit types: tested headless on macOS and Linux.
@MainActor
@Observable
public final class InterfaceBuilderShellModel {
    public let path: String
    /// The shared editor state. Views read it through the properties below,
    /// which follow `revision`.
    @ObservationIgnored public let session: IBEditorSession
    /// Bumped on every change of the session (document or selection).
    public private(set) var revision = 0

    /// Canvas zoom, 10%–400%.
    public var zoom: CGFloat {
        get { zoomValue }
        set { zoomValue = IBCanvasLayout.clampZoom(newValue) }
    }
    private var zoomValue: CGFloat = 1
    /// The canvas bar's outline toggle.
    public var isOutlineShown = true
    /// The inspector shown while this editor is open: one of the four, or
    /// nil for File / History / Quick Help. Opening selects Attributes.
    public var inspectorTab: IBInspectorTab? = .attributes
    /// The canvas bar's appearance toggle: the scenes drawn dark.
    public var canvasIsDark = false
    /// Orientation and device: stored state only (§Layout).
    public var isLandscape = false
    public var device: String
    /// The Library (⇧⌘L) is shown over the editor.
    public var isLibraryShown = false
    /// The Library's search text; a change selects the first match
    /// (`library.md` §Panel, Selection).
    public var libraryFilter = "" {
        didSet { if libraryFilter != oldValue { librarySelection = libraryObjects.first } }
    }
    /// The Library's tab: Objects, Image, Color, Symbols.
    public var libraryTab: IBLibraryTab = .objects
    /// The list shows icons only, four to a row (the header's first toggle).
    public var libraryIsIconView = false
    /// The detail area is shown (the header's second toggle).
    public var libraryShowsDetails = true
    /// The Library row the keyboard and the detail area follow.
    public var librarySelection: IBDocument.NewObject? = .label
    /// Editor ▸ Add New Constraints… is shown.
    public var isAddConstraintsShown = false
    /// Outline rows the user closed (all are open at first).
    public private(set) var collapsed: Set<String> = []
    /// A drag on the canvas, and the outline it shows.
    @ObservationIgnored private var drag: IBCanvasDrag?
    public private(set) var dragPreview: CGRect?

    /// Opens `path` (throws when it is not an Interface Builder document).
    public init(path: String) throws {
        self.path = path
        session = try IBEditorSession(url: URL(fileURLWithPath: path))
        device = session.document.isFlippedRuntime ? Self.iOSDevices[0] : "Mac"
    }

    /// Device pop-up choices: iOS documents list phones and tablets.
    public static let iOSDevices = ["iPhone 16", "iPhone 16 Pro", "iPhone 16 Pro Max", "iPhone SE (3rd generation)", "iPad (A16)", "iPad Pro 11-inch", "iPad Pro 13-inch"]
    public var deviceChoices: [String] { document.isFlippedRuntime ? Self.iOSDevices : ["Mac"] }

    private func changed() { revision = session.revision }

    // MARK: Reading (each follows `revision`)

    public var document: IBDocument { _ = revision; return session.document }
    public var layout: IBCanvasLayout { _ = revision; return session.layout }
    public var selectedID: String? { _ = revision; return session.selectedID }
    public var selected: IBDocument.Object? { _ = revision; return session.selected }
    public var selectedConstraint: String? { _ = revision; return session.selectedConstraint }
    public var jumpBarPath: [String] { _ = revision; return session.jumpBarPath }
    public var canUndo: Bool { _ = revision; return session.canUndo }
    public var canRedo: Bool { _ = revision; return session.canRedo }
    public var saveCount: Int { _ = revision; return session.saveCount }
    public var problem: String? { _ = revision; return session.problem }
    public var controlState: IBControlState? { _ = revision; return session.controlState }
    public var zoomText: String { "\(Int((zoom * 100).rounded()))%" }

    public func inspectorSections(_ t: IBInspectorTab) -> [IBInspectorSection] { _ = revision; return session.inspectorSections(t) }

    /// The outline's Filter.
    public var outlineFilter: String {
        get { _ = revision; return session.outlineFilter }
        set { session.outlineFilter = newValue; revision &+= 1 }
    }

    /// One visible outline row with its depth.
    public struct VisibleRow: Identifiable, Equatable {
        public var row: IBOutlineRow
        public var depth: Int
        public var isExpanded: Bool
        public var id: String { row.id }
    }

    /// The outline flattened for drawing: closed rows hide their children
    /// (a filter shows everything that matches).
    public var visibleRows: [VisibleRow] {
        _ = revision
        var out: [VisibleRow] = []
        let filtering = !session.outlineFilter.isEmpty
        func walk(_ r: IBOutlineRow, _ d: Int) {
            let open = filtering || !collapsed.contains(r.id)
            out.append(VisibleRow(row: r, depth: d, isExpanded: open && !r.children.isEmpty))
            if open { r.children.forEach { walk($0, d + 1) } }
        }
        session.outlineRows.forEach { walk($0, 0) }
        return out
    }

    public func setExpanded(_ id: String, _ open: Bool) {
        if open { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// Whether an outline row is the selection.
    public func isSelected(_ r: IBOutlineRow) -> Bool {
        _ = revision
        if let c = r.constraintID { return c == session.selectedConstraint }
        return session.selectedConstraint == nil && r.objectID != nil && r.objectID == session.selectedID
    }

    // MARK: Selection

    public func select(id: String?) { session.select(id: id); changed() }
    public func select(row: IBOutlineRow) { session.select(row: row); changed() }

    /// Moves the outline selection up or down among the visible rows.
    public func moveSelection(_ d: Int) {
        let rows = visibleRows.filter { $0.row.objectID != nil || $0.row.constraintID != nil }
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { isSelected($0.row) } ?? (d > 0 ? -1 : rows.count)
        select(row: rows[min(max(i + d, 0), rows.count - 1)].row)
    }

    // MARK: Canvas pointer

    /// A press on the canvas (canvas points): selects the deepest view
    /// there, and starts moving it or resizing the selection by a handle.
    public func pointerDown(at p: CGPoint) {
        let (hit, d) = IBCanvasDrag.begin(at: p, selected: session.selectedID, in: session.layout)
        if let hit, hit.id != session.selectedID || d?.handle == nil { select(id: hit.id) }
        drag = d
        dragPreview = nil
    }

    public func pointerDragged(to p: CGPoint) {
        guard let d = drag else { return }
        dragPreview = d.preview(at: p)
    }

    public func pointerUp(at p: CGPoint) {
        defer { drag = nil; dragPreview = nil }
        guard let d = drag, let r = d.result(at: p) else { return }
        session.setRootFrame(r, of: d.id)
        changed()
    }

    // MARK: Zoom (⌘+ / ⌘− ×1.25, Zoom to Fit never above 100%)

    public func zoomIn() { zoom *= 1.25 }
    public func zoomOut() { zoom /= 1.25 }
    public func zoomToFit(_ viewport: CGSize) { zoom = layout.zoomToFit(viewport) }

    // MARK: Edits

    private func edit(_ f: () -> Void) { f(); changed() }

    public func undo() { edit { session.undo() } }
    public func redo() { edit { session.redo() } }
    public func deleteSelection() { edit { session.deleteSelection() } }
    @discardableResult
    public func move(_ id: String, into parent: String) -> Bool { defer { changed() }; return session.move(id, into: parent) }
    public func setTitle(_ s: String) { edit { session.setTitle(s) } }
    public func setPlaceholder(_ s: String) { edit { session.setPlaceholder(s) } }
    public func setHidden(_ b: Bool) { edit { session.setHidden(b) } }
    public func setEnabled(_ b: Bool) { edit { session.setEnabled(b) } }
    public func setAlignment(_ s: String) { edit { session.setAlignment(s) } }
    public func setAttribute(_ name: String, _ value: String?, of id: String) { edit { session.setAttribute(name, value, of: id) } }
    public func setToggle(_ row: IBInspectorRow, on: Bool) { edit { session.setToggle(row, on: on) } }
    public func setChoice(_ row: IBInspectorRow, _ value: String) { edit { session.setChoice(row, value) } }
    public func setColor(_ row: IBInspectorRow, _ title: String) { edit { session.setColor(row, title) } }
    public func setFrameComponent(_ c: String, _ v: CGFloat, of id: String) { edit { session.setFrameComponent(c, v, of: id) } }
    public func setConstant(_ v: CGFloat, ofConstraint id: String) { edit { session.setConstant(v, ofConstraint: id) } }
    public func addRuntimeAttribute() { edit { session.addRuntimeAttribute(keyPath: session.nextRuntimeKeyPath) } }
    public func removeRuntimeAttribute(_ keyPath: String) { edit { session.removeRuntimeAttribute(keyPath) } }
    public func disconnect(_ id: String) { edit { session.disconnect(id) } }

    /// Inserts a Library object into the selected view (else the first
    /// view), centered; selects it. Returns its ID.
    @discardableResult
    public func insert(_ kind: IBDocument.NewObject) -> String? {
        defer { changed() }
        return session.insert(kind)
    }

    /// Adds constraints to the selected view; closes the popover. Returns the IDs.
    @discardableResult
    public func addConstraints(_ spec: IBDocument.NewConstraints) -> [String] {
        defer { changed(); isAddConstraintsShown = false }
        return session.addConstraints(spec)
    }

    // MARK: Library (Objects tab)

    /// The Objects the Library lists for this document under its search
    /// (`library.md` §Search: every word in the name or the class name).
    public var libraryObjects: [IBDocument.NewObject] {
        let d = document
        return IBDocument.NewObject.matching(libraryFilter, in: IBDocument.NewObject.list(for: d), iOS: d.isFlippedRuntime)
    }

    /// The detail area for the Library selection: name, `Class: summary`,
    /// and the description.
    public var libraryDetailParts: (name: String, subtitle: String, description: String)? {
        guard let o = librarySelection, libraryObjects.contains(o) else { return nil }
        return (o.rawValue, o.subtitle(iOS: document.isFlippedRuntime), o.details)
    }

    /// The detail area's text (tests and the walk).
    public var libraryDetail: String {
        guard let p = libraryDetailParts else { return "" }
        return "\(p.name)\n\(p.subtitle)\n\(p.description)"
    }

    /// Double-click or Return: inserts the object into the selected view.
    @discardableResult
    public func insertFromLibrary(_ o: IBDocument.NewObject? = nil) -> String? {
        guard let kind = o ?? librarySelection else { return nil }
        librarySelection = kind
        return insert(kind)
    }

    /// Up and Down in the Library list (in the icon view, Up and Down move
    /// a row of four, Left and Right one item).
    public func moveLibrarySelection(_ d: Int) {
        let list = libraryObjects
        guard !list.isEmpty else { return }
        let i = librarySelection.flatMap { list.firstIndex(of: $0) } ?? (d > 0 ? -1 : list.count)
        librarySelection = list[min(max(i + d, 0), list.count - 1)]
    }

    // MARK: Editor menu (StructuredEditors.swift routes these)

    /// Whether an Editor or View menu action applies, and its check mark.
    public func actionState(_ action: String, tag: Int) -> (enabled: Bool, checked: Bool)? {
        switch action {
        case "showAddConstraints:": (selected?.parent?.isView == true, false)
        case "zoomCanvasIn:", "zoomCanvasOut:", "zoomCanvasToFit:", "updateCanvasFrames:", "showLibrary:": (true, false)
        case "zoomCanvasToPercent:": (true, Int((zoom * 10000).rounded()) == tag)
        case "toggleDocumentOutline:": (true, isOutlineShown)
        default: nil
        }
    }

    /// Performs an Editor or View menu action; false when it is not one of
    /// this editor's. Zoom to Fit uses `viewport` (the canvas's size).
    @discardableResult
    public func perform(_ action: String, tag: Int, viewport: CGSize = CGSize(width: 900, height: 600)) -> Bool {
        switch action {
        case "showAddConstraints:":
            guard selected?.parent?.isView == true else { return false }
            isAddConstraintsShown = true
        case "zoomCanvasIn:": zoomIn()
        case "zoomCanvasOut:": zoomOut()
        case "zoomCanvasToFit:": zoomToFit(viewport)
        case "zoomCanvasToPercent:": zoom = CGFloat(tag) / 10000
        case "toggleDocumentOutline:": isOutlineShown.toggle()
        case "updateCanvasFrames:": changed()
        case "showLibrary:": isLibraryShown.toggle()
        default: return false
        }
        return true
    }
}

/// The Library's tabs while an Interface Builder document is focused
/// (`library.md` §Panel, Tabs).
public enum IBLibraryTab: Int, CaseIterable, Sendable {
    case objects, image, color, symbols
    public var title: String { ["Objects", "Image", "Color", "Symbols"][rawValue] }
    /// The tab's symbol (the platform's symbol set; Ycode's drawings on Linux).
    public var symbol: String { ["square.on.circle", "photo", "paintpalette", "star.square"][rawValue] }
}
