import Foundation
import USDCore
import USDStage

/// The specs a change touched, before and after. Undo writes `before`
/// back, redo `after`.
public struct LayerDelta: Sendable, Equatable {
    public var changes: [Path: Change]

    public struct Change: Sendable, Equatable {
        public var before: Spec?
        public var after: Spec?
    }

    public init(changes: [Path: Change] = [:]) { self.changes = changes }

    public var isEmpty: Bool { changes.isEmpty }

    /// The specs that differ between two versions of a layer.
    public static func between(_ a: Layer, _ b: Layer) -> LayerDelta {
        var out: [Path: Change] = [:]
        for (path, spec) in a.specs where b.specs[path] != spec {
            out[path] = Change(before: spec, after: b.specs[path])
        }
        for (path, spec) in b.specs where a.specs[path] == nil {
            out[path] = Change(before: nil, after: spec)
        }
        return LayerDelta(changes: out)
    }

    /// `self` followed by `next`.
    public func merged(with next: LayerDelta) -> LayerDelta {
        var out = changes
        for (path, change) in next.changes {
            if let existing = out[path] {
                out[path] = Change(before: existing.before, after: change.after)
            } else {
                out[path] = change
            }
        }
        return LayerDelta(changes: out.filter { $0.value.before != $0.value.after })
    }

    func apply(to layer: inout Layer, forward: Bool) {
        for (path, change) in changes { layer.setSpec(forward ? change.after : change.before, at: path) }
    }
}

/// An undoable edit of the document's layer.
public protocol EditCommand {
    /// Shown in Undo/Redo menu items.
    var name: String { get }
    func apply(to layer: inout Layer) throws
}

/// A command made from a closure (for tools and scripting).
public struct BlockCommand: EditCommand {
    public let name: String
    let body: (inout Layer) throws -> Void

    public init(_ name: String, _ body: @escaping (inout Layer) throws -> Void) {
        self.name = name
        self.body = body
    }

    public func apply(to layer: inout Layer) throws { try body(&layer) }
}

/// Undo and redo of layer deltas, with grouping.
public struct UndoStack: Sendable {
    public struct Entry: Sendable {
        public var name: String
        public var delta: LayerDelta
    }

    public private(set) var undoEntries: [Entry] = []
    public private(set) var redoEntries: [Entry] = []
    public var limit = 500

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoName: String? { undoEntries.last?.name }
    public var redoName: String? { redoEntries.last?.name }

    mutating func push(_ entry: Entry) {
        undoEntries.append(entry)
        if undoEntries.count > limit { undoEntries.removeFirst(undoEntries.count - limit) }
        redoEntries.removeAll()
    }

    mutating func popUndo() -> Entry? {
        guard let e = undoEntries.popLast() else { return nil }
        redoEntries.append(e)
        return e
    }

    mutating func popRedo() -> Entry? {
        guard let e = redoEntries.popLast() else { return nil }
        undoEntries.append(e)
        return e
    }

    mutating func clear() {
        undoEntries.removeAll()
        redoEntries.removeAll()
    }
}

/// An ordered set of selected prim paths; the last one is the primary
/// (the one the inspector shows).
public struct Selection: Equatable, Sendable {
    public private(set) var paths: [Path] = []

    public init(_ paths: [Path] = []) { self.paths = [] ; paths.forEach { add($0) } }

    public var primary: Path? { paths.last }
    public var isEmpty: Bool { paths.isEmpty }
    public func contains(_ p: Path) -> Bool { paths.contains(p) }

    public mutating func select(_ p: Path) { paths = [p] }
    public mutating func add(_ p: Path) {
        paths.removeAll { $0 == p }
        paths.append(p)
    }
    public mutating func toggle(_ p: Path) {
        if contains(p) { paths.removeAll { $0 == p } } else { paths.append(p) }
    }
    public mutating func clear() { paths.removeAll() }

    /// Selected paths without descendants of other selected paths (what
    /// delete, copy and move act on).
    public var roots: [Path] {
        paths.filter { p in !paths.contains { $0 != p && p.hasPrefix($0) } }
    }

    /// Follows renames and moves; drops paths that no longer exist.
    mutating func update(renaming from: Path, to: Path) {
        paths = paths.map { $0.hasPrefix(from) ? $0.replacingPrefix(from, with: to) : $0 }
    }
}

/// A scene being edited: one USD layer (the edit target), its composed
/// stage, the selection and the undo history. Every change goes through
/// `perform`, so every edit is undoable.
public final class SceneDocument {
    public private(set) var layer: Layer
    public let stage: Stage
    public var selection = Selection()
    public private(set) var history = UndoStack()
    /// Where the document is saved (nil for a new document).
    public var filePath: String?
    public private(set) var isDirty = false
    public let components: ComponentStorage
    /// Called after every change (edit, undo, redo) with the paths touched.
    public var onChange: [([Path]) -> Void] = []
    private var groupDepth = 0
    private var groupEntry: UndoStack.Entry?

    public init(layer: Layer, resolver: LayerResolver? = nil, components: ComponentStorage = RealityKitComponentStorage()) {
        self.layer = layer
        stage = Stage(rootLayer: layer, resolver: resolver)
        self.components = components
    }

    /// A new scene with the conventions of `scene-usd.md` §1: an `Xform`
    /// default prim named `Root`, metres, +Y up, and a creator tag.
    public static func newScene(identifier: String = "Untitled.usda", creator: String = "Ycode Scene Composer") -> SceneDocument {
        var layer = Layer(identifier: identifier)
        layer.defaultPrim = "Root"
        layer.metersPerUnit = 1
        layer.upAxis = "Y"
        layer[metadata: FieldKey.customLayerData] = .dictionary(["creator": .string(creator)])
        _ = try? layer.createPrim(at: "/Root", typeName: "Xform")
        return SceneDocument(layer: layer)
    }

    public static func open(_ path: String) throws -> SceneDocument {
        let resolver = FileLayerResolver()
        let doc = SceneDocument(layer: try resolver.layer(for: path), resolver: resolver)
        doc.filePath = path
        return doc
    }

    /// Saves the layer. The format follows the extension (`.usda` by default).
    public func save(to path: String? = nil, format: LayerFormat? = nil) throws {
        guard let target = path ?? filePath else { throw USDError("the document has no file path") }
        try LayerIO.write(layer, to: target, format: format ?? LayerFormat(path: target) ?? .usda)
        filePath = target
        isDirty = false
    }

    // MARK: Editing

    /// Applies a command as one undoable step. A failing command leaves the
    /// document unchanged.
    @discardableResult
    public func perform(_ command: EditCommand) throws -> LayerDelta {
        var edited = layer
        try command.apply(to: &edited)
        let delta = LayerDelta.between(layer, edited)
        guard !delta.isEmpty else { return delta }
        commit(edited, delta: delta, name: command.name)
        return delta
    }

    public func perform(_ name: String, _ body: @escaping (inout Layer) throws -> Void) throws {
        try perform(BlockCommand(name, body))
    }

    /// Groups several commands into one undo step (nesting allowed).
    public func group(_ name: String, _ body: () throws -> Void) rethrows {
        if groupDepth == 0 { groupEntry = UndoStack.Entry(name: name, delta: LayerDelta()) }
        groupDepth += 1
        defer {
            groupDepth -= 1
            if groupDepth == 0, let entry = groupEntry {
                if !entry.delta.isEmpty { history.push(entry) }
                groupEntry = nil
            }
        }
        try body()
    }

    private func commit(_ edited: Layer, delta: LayerDelta, name: String) {
        layer = edited
        if groupDepth > 0, var entry = groupEntry {
            entry.delta = entry.delta.merged(with: delta)
            groupEntry = entry
        } else {
            history.push(UndoStack.Entry(name: name, delta: delta))
        }
        changed(delta)
    }

    private func changed(_ delta: LayerDelta) {
        isDirty = true
        stage.setRootLayer(layer)
        selection = Selection(selection.paths.filter { $0.isRoot || layer.hasSpec(at: $0) || stage.prim(at: $0) != nil })
        let paths = Array(delta.changes.keys)
        for observer in onChange { observer(paths) }
    }

    public func undo() {
        guard let entry = history.popUndo() else { return }
        entry.delta.apply(to: &layer, forward: false)
        changed(entry.delta)
    }

    public func redo() {
        guard let entry = history.popRedo() else { return }
        entry.delta.apply(to: &layer, forward: true)
        changed(entry.delta)
    }

    // MARK: Queries

    public func prim(_ path: Path) -> Prim? { stage.prim(at: path) }

    public func localTransform(_ path: Path, time: Double? = nil) -> Matrix4 {
        guard let p = prim(path) else { return .identity }
        return Xform.localTransform(p, time: time).matrix
    }

    public func worldTransform(_ path: Path, time: Double? = nil) -> Matrix4 {
        guard let p = prim(path) else { return .identity }
        return Xform.worldTransform(p, time: time)
    }

    /// The composed hierarchy for an outline view.
    public func tree(_ options: Stage.TraversalOptions = .all) -> [SceneNode] {
        func build(_ prim: Prim) -> SceneNode {
            let children = prim.children.filter { child in
                (options.includeInactive || child.isActive) && (options.includeAbstract || child.specifier != .class)
                    && (options.includeUndefined || child.isDefined)
            }
            return SceneNode(path: prim.path, typeName: prim.typeName, specifier: prim.specifier, isActive: prim.isActive,
                             hasArcs: prim.arcs.count > 1, isComponent: SceneNode.componentTypes.contains(prim.typeName),
                             children: children.map(build))
        }
        return stage.pseudoRoot.children.filter { options.includeAbstract || $0.specifier != .class }.map(build)
    }

    /// A child name not used under `parent`: `name`, `name_1`, `name_2`…
    public func uniqueName(_ name: String, under parent: Path) -> String {
        let taken = Set(stage.childNames(of: parent) + layer.primChildren(of: parent))
        guard taken.contains(name) else { return name }
        var base = name
        if let underscore = name.lastIndex(of: "_"), Int(name[name.index(after: underscore)...]) != nil { base = String(name[..<underscore]) }
        var i = 1
        while taken.contains("\(base)_\(i)") { i += 1 }
        return "\(base)_\(i)"
    }
}

/// One row of the hierarchy.
public struct SceneNode: Equatable, Sendable {
    public var path: Path
    public var typeName: String
    public var specifier: Specifier
    public var isActive: Bool
    /// Brought in or changed by references, payloads, inherits or variants.
    public var hasArcs: Bool
    /// A component, struct, timeline or other RealityKit data prim (hidden
    /// from the entity hierarchy by editors).
    public var isComponent: Bool
    public var children: [SceneNode]

    static let componentTypes: Set<String> = [
        RealityKitComponentStorage.componentType, RealityKitComponentStorage.customComponentType, RealityKitComponentStorage.structType,
    ]

    public var name: String { path.name }
}
