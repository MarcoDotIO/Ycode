import Foundation
import USDCore
import USDStage

/// Copied prims: a layer whose root prims are the copied subtrees. Its
/// USDA text is what goes to a system pasteboard.
public struct Clipboard: Equatable, Sendable {
    public var layer: Layer

    public init(layer: Layer) { self.layer = layer }

    public init(text: String) throws { layer = try USDAReader.read(text, identifier: "clipboard.usda") }

    public var text: String { USDAWriter.write(layer) }
    public var rootNames: [String] { layer.primChildren(of: .root) }
}

/// The editing operations of the composer. Each is one undo step.
extension SceneDocument {
    // MARK: Prims

    /// Creates `def <type> "<name>"` under `parent` (name made unique).
    @discardableResult
    public func createPrim(named name: String, type: String? = nil, under parent: Path) throws -> Path {
        let unique = uniqueName(name, under: parent)
        let path = parent.appendingChild(unique)
        try perform("Create \(unique)") { layer in
            try layer.createPrim(at: path, typeName: type)
            if layer.field(FieldKey.specifier, at: parent) == nil, !parent.isRoot {
                layer.setField(FieldKey.specifier, .specifier(.over), at: parent)
            }
        }
        return path
    }

    /// Deletes prims authored in this layer; prims that only come from other
    /// layers are deactivated instead (`active = false`).
    public func delete(_ paths: [Path]) throws {
        let roots = Selection(paths).roots
        try perform(roots.count == 1 ? "Delete \(roots[0].name)" : "Delete \(roots.count) Prims") { layer in
            for p in roots {
                if layer.hasSpec(at: p) && !self.isIntroducedByArcs(p) {
                    layer.removeSpec(at: p)
                } else {
                    try layer.createPrim(at: p, specifier: .over)
                    layer.setField(FieldKey.specifier, .specifier(.over), at: p)
                    layer.setField(FieldKey.active, .bool(false), at: p)
                }
            }
        }
    }

    /// True when a weaker site (reference, payload, inherit, variant or
    /// sublayer) also defines the prim, so deleting the local spec would not
    /// remove it.
    func isIntroducedByArcs(_ path: Path) -> Bool {
        stage.opinions(path).contains { $0.layer.identifier != layer.identifier || $0.node.arc != .root }
    }

    /// Renames a prim and retargets paths in this layer that pointed into it.
    public func rename(_ path: Path, to newName: String) throws {
        guard let parsed = Path(parsing: "/" + newName), parsed.elements.count == 1, parsed.isPrimPath else {
            throw USDError("'\(newName)' is not a valid prim name")
        }
        let destination = path.parent.appendingChild(newName)
        guard destination != path else { return }
        guard stage.prim(at: destination) == nil, !layer.hasSpec(at: destination) else { throw USDError("\(destination) already exists") }
        try move(path, to: destination, name: "Rename \(path.name) to \(newName)")
    }

    /// Moves a prim under another parent (at `index` among its children).
    public func reparent(_ path: Path, to parent: Path, index: Int? = nil) throws {
        guard !parent.hasPrefix(path) else { throw USDError("cannot move \(path) under itself") }
        let name = parent == path.parent ? path.name : uniqueName(path.name, under: parent)
        try move(path, to: parent.appendingChild(name), index: index, name: "Move \(path.name)")
    }

    private func move(_ path: Path, to destination: Path, index: Int? = nil, name: String) throws {
        guard layer.hasSpec(at: path) else { throw USDError("\(path) is not authored in this layer") }
        let previousSelection = selection
        selection.update(renaming: path, to: destination)
        do {
            try perform(name) { layer in
                if !layer.hasSpec(at: destination.parent) { try layer.createPrim(at: destination.parent, specifier: .over) }
                if destination != path { try layer.moveSpec(at: path, to: destination, index: index) }
                Self.retarget(&layer, from: path, to: destination)
            }
        } catch {
            selection = previousSelection
            throw error
        }
    }

    /// Rewrites relationship targets and connections that point into `from`.
    static func retarget(_ layer: inout Layer, from: Path, to: Path) {
        for p in layer.allPaths {
            guard let spec = layer.spec(at: p) else { continue }
            for key in [FieldKey.targetPaths, FieldKey.connectionPaths, FieldKey.inheritPaths, FieldKey.specializes] {
                guard case .pathListOp(let op)? = spec.fields[key] else { continue }
                let mapped = ListOp(isExplicit: op.isExplicit, explicitItems: op.explicitItems.map { m($0) },
                                    addedItems: op.addedItems.map { m($0) }, prependedItems: op.prependedItems.map { m($0) },
                                    appendedItems: op.appendedItems.map { m($0) }, deletedItems: op.deletedItems.map { m($0) },
                                    orderedItems: op.orderedItems.map { m($0) })
                if mapped != op { layer.setField(key, .pathListOp(mapped), at: p) }
            }
        }
        func m(_ x: Path) -> Path { x.hasPrefix(from) ? x.replacingPrefix(from, with: to) : x }
    }

    /// Duplicates prims next to themselves; returns the new paths.
    @discardableResult
    public func duplicate(_ paths: [Path]) throws -> [Path] {
        var created: [Path] = []
        try group("Duplicate") {
            for p in Selection(paths).roots {
                created += try paste(copy([p]), under: p.parent)
            }
        }
        return created
    }

    // MARK: Clipboard

    /// Copies prims. Specs authored in this layer are copied as they are
    /// (arcs included); prims that exist only through composition are
    /// copied in flattened form.
    public func copy(_ paths: [Path]) throws -> Clipboard {
        var clip = Layer(identifier: "clipboard.usda")
        var flat: Layer?
        for p in Selection(paths).roots {
            let name = Clipboard(layer: clip).rootNames.contains(p.name) ? "\(p.name)_\(clip.primChildren(of: .root).count)" : p.name
            let target = Path.root.appendingChild(name)
            if layer.hasSpec(at: p) {
                try clip.copySpec(from: layer, at: p, to: target)
            } else {
                if flat == nil { flat = stage.flatten() }
                try clip.copySpec(from: flat!, at: p, to: target)
            }
            clip.setField(FieldKey.specifier, layer.field(FieldKey.specifier, at: p) == .specifier(.over) ? .specifier(.def) : clip.field(FieldKey.specifier, at: target), at: target)
        }
        return Clipboard(layer: clip)
    }

    /// Pastes clipboard prims under `parent` with unique names; paths inside
    /// the pasted subtrees are remapped. Returns the new paths.
    @discardableResult
    public func paste(_ clipboard: Clipboard, under parent: Path) throws -> [Path] {
        var created: [Path] = []
        try perform("Paste") { layer in
            if !parent.isRoot, !layer.hasSpec(at: parent) { try layer.createPrim(at: parent, specifier: .over) }
            var taken = Set(self.stage.childNames(of: parent) + layer.primChildren(of: parent))
            for name in clipboard.rootNames {
                var unique = name
                var i = 1
                while taken.contains(unique) {
                    unique = "\(name)_\(i)"
                    i += 1
                }
                taken.insert(unique)
                let destination = parent.appendingChild(unique)
                try layer.copySpec(from: clipboard.layer, at: Path.root.appendingChild(name), to: destination)
                created.append(destination)
            }
        }
        return created
    }

    // MARK: Properties and metadata

    /// Sets an attribute value (creating the attribute when `type` is given),
    /// or a time sample when `time` is given.
    public func setAttribute(_ path: Path, _ value: Value, type: TypeName? = nil, time: Double? = nil) throws {
        guard path.isPropertyPath else { throw USDError("\(path) is not a property path") }
        let resolvedType = type ?? stage.prim(at: path.primPath)?.attribute(path.name)?.typeName
        guard let resolvedType else { throw USDError("\(path) does not exist; give its type") }
        if let vt = value.valueType, vt != resolvedType.valueType || value.isArray != resolvedType.isArray {
            throw USDError("value of type \(vt.baseName)\(value.isArray ? "[]" : "") does not match \(resolvedType)")
        }
        try perform("Set \(path.name)") { layer in
            if !layer.hasSpec(at: path.primPath) { try layer.createPrim(at: path.primPath, specifier: .over) }
            if !layer.hasSpec(at: path) { try layer.createAttribute(at: path, typeName: resolvedType) }
            if let time {
                var samples: [TimeSample] = {
                    if case .timeSamples(let s)? = layer.field(FieldKey.timeSamples, at: path) { return s }
                    return []
                }()
                samples.removeAll { $0.time == time }
                samples.append(TimeSample(time: time, value: value))
                samples.sort { $0.time < $1.time }
                layer.setField(FieldKey.timeSamples, .timeSamples(samples), at: path)
            } else {
                layer.setField(FieldKey.defaultValue, value, at: path)
            }
        }
    }

    /// Removes this layer's opinion of an attribute (the composed value
    /// falls back to weaker layers).
    public func clearAttribute(_ path: Path) throws {
        try perform("Clear \(path.name)") { layer in layer.removeSpec(at: path) }
    }

    public func setMetadata(_ path: Path, _ key: String, _ value: Value?) throws {
        try perform("Set \(key)") { layer in
            if !layer.hasSpec(at: path) { try layer.createPrim(at: path, specifier: .over) }
            layer.setField(key, value, at: path)
        }
    }

    public func setActive(_ path: Path, _ active: Bool) throws {
        try setMetadata(path, FieldKey.active, .bool(active))
    }

    /// Writes a local transform as T·orient·S ops.
    public func setTransform(_ path: Path, _ trs: TRS, time: Double? = nil) throws {
        try perform("Transform \(path.name)") { layer in try Xform.setTRS(trs, at: path, in: &layer, time: time) }
    }

    /// Places a prim at a world-space transform.
    public func setWorldTransform(_ path: Path, _ world: Matrix4, time: Double? = nil) throws {
        guard let p = prim(path) else { throw USDError("no prim at \(path)") }
        try setTransform(path, TRS(matrix: Xform.local(forWorld: world, of: p, time: time)), time: time)
    }

    // MARK: Composition

    /// Adds a prim that references another file (`scene-usd.md` §2: a
    /// typeless prim with a prepended reference).
    @discardableResult
    public func addReference(named name: String, asset: String, primPath: Path = .empty, under parent: Path) throws -> Path {
        let unique = uniqueName(name, under: parent)
        let path = parent.appendingChild(unique)
        try perform("Add \(unique)") { layer in
            try layer.createPrim(at: path)
            layer.setField(FieldKey.active, .bool(true), at: path)
            layer.setField(FieldKey.references, .referenceListOp(.prepended([Reference(assetPath: asset, primPath: primPath)])), at: path)
        }
        return path
    }

    public func setVariantSelection(_ prim: Path, set: String, variant: String?) throws {
        try perform("Select \(variant ?? "no") \(set)") { layer in
            if !layer.hasSpec(at: prim) { try layer.createPrim(at: prim, specifier: .over) }
            var map: [String: String] = {
                if case .variantSelectionMap(let m)? = layer.field(FieldKey.variantSelection, at: prim) { return m }
                return [:]
            }()
            map[set] = variant
            layer.setField(FieldKey.variantSelection, map.isEmpty ? nil : .variantSelectionMap(map), at: prim)
        }
    }

    /// Binds a material: `MaterialBindingAPI` plus `rel material:binding`
    /// with `bindMaterialAs = "weakerThanDescendants"` (`scene-usd.md` §1).
    public func bindMaterial(_ prim: Path, to material: Path?) throws {
        try perform("Bind Material") { layer in
            if !layer.hasSpec(at: prim) { try layer.createPrim(at: prim, specifier: .over) }
            var schemas: ListOp<String> = {
                if case .tokenListOp(let op)? = layer.field(FieldKey.apiSchemas, at: prim) { return op }
                return ListOp()
            }()
            if !schemas.applied(to: []).contains("MaterialBindingAPI") {
                schemas.prependedItems.append("MaterialBindingAPI")
                layer.setField(FieldKey.apiSchemas, .tokenListOp(schemas), at: prim)
            }
            let rel = prim.appendingProperty("material:binding")
            try layer.createRelationship(at: rel, targets: material.map { [$0] } ?? [])
            layer.setField("bindMaterialAs", .token("weakerThanDescendants"), at: rel)
        }
    }

    // MARK: Components

    public func componentsOf(_ prim: Path) -> [Component] { components.components(of: prim, in: layer) }

    /// Adds a catalogue component with the reference's always-written fields.
    @discardableResult
    public func addComponent(_ id: String, to prim: Path, catalogue: ComponentCatalogue = .realityKit) throws -> Component {
        var c = try catalogue.makeComponent(id)
        c.primName = uniqueName(c.primName, under: prim)
        try setComponent(c, on: prim)
        return c
    }

    /// Writes a component (replacing a prim of the same name).
    public func setComponent(_ component: Component, on prim: Path) throws {
        let storage = components
        try perform("Set \(component.primName)") { layer in
            if !layer.hasSpec(at: prim) { try layer.createPrim(at: prim, specifier: .over) }
            storage.remove(component.primName, from: prim, in: &layer)
            try storage.write(component, to: prim, in: &layer)
        }
    }

    public func removeComponent(_ primName: String, from prim: Path) throws {
        let storage = components
        try perform("Remove \(primName)") { layer in storage.remove(primName, from: prim, in: &layer) }
    }
}
