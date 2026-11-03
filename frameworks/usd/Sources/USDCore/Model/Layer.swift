/// Errors from layer editing and file I/O.
public struct USDError: Error, CustomStringConvertible, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A layer: a map from paths to specs, the unit USD reads and writes.
///
/// Layers are values. The pseudo-root spec at `/` holds the layer metadata;
/// prim specs keep their children in `primChildren` and `properties`
/// (token vectors), variant sets in `variantSetChildren`, and variants in
/// `variantChildren`, as in OpenUSD's Sdf data model.
public struct Layer: Hashable, Sendable {
    /// Where the layer came from (a file path or an anonymous tag).
    public var identifier: String
    public private(set) var specs: [Path: Spec]

    public init(identifier: String = "anonymous.usda") {
        self.identifier = identifier
        specs = [.root: Spec(type: .pseudoRoot)]
    }

    // MARK: Specs and fields

    public func spec(at path: Path) -> Spec? { specs[path] }
    public func hasSpec(at path: Path) -> Bool { specs[path] != nil }

    public func field(_ name: String, at path: Path) -> Value? { specs[path]?.fields[name] }

    public mutating func setField(_ name: String, _ value: Value?, at path: Path) {
        guard specs[path] != nil else { return }
        specs[path]!.fields[name] = value
    }

    /// Inserts or replaces a spec without touching children lists (used by
    /// the file readers, which store children lists as fields).
    public mutating func setSpec(_ spec: Spec?, at path: Path) {
        specs[path] = spec
    }

    /// Paths of every spec, sorted.
    public var allPaths: [Path] { specs.keys.sorted() }

    // MARK: Layer metadata

    public var pseudoRoot: Spec { specs[.root] ?? Spec(type: .pseudoRoot) }

    public subscript(metadata name: String) -> Value? {
        get { specs[.root]?.fields[name] }
        set { specs[.root, default: Spec(type: .pseudoRoot)].fields[name] = newValue }
    }

    public var defaultPrim: String? {
        get { self[metadata: FieldKey.defaultPrim]?.stringValue }
        set { self[metadata: FieldKey.defaultPrim] = newValue.map { .token($0) } }
    }

    public var upAxis: String? {
        get { self[metadata: FieldKey.upAxis]?.stringValue }
        set { self[metadata: FieldKey.upAxis] = newValue.map { .token($0) } }
    }

    public var metersPerUnit: Double? {
        get { self[metadata: FieldKey.metersPerUnit]?.doubleValue }
        set { self[metadata: FieldKey.metersPerUnit] = newValue.map { .double($0) } }
    }

    public var documentation: String? {
        get { self[metadata: FieldKey.documentation]?.stringValue }
        set { self[metadata: FieldKey.documentation] = newValue.map { .string($0) } }
    }

    public var subLayers: [String] {
        get { self[metadata: FieldKey.subLayers]?.stringArray ?? [] }
        set { self[metadata: FieldKey.subLayers] = newValue.isEmpty ? nil : .stringVector(newValue) }
    }

    public var subLayerOffsets: [LayerOffset] {
        get {
            if case .layerOffsetVector(let v)? = self[metadata: FieldKey.subLayerOffsets] { return v }
            return []
        }
        set { self[metadata: FieldKey.subLayerOffsets] = newValue.allSatisfy(\.isIdentity) ? nil : .layerOffsetVector(newValue) }
    }

    public var timeCodesPerSecond: Double? { self[metadata: FieldKey.timeCodesPerSecond]?.doubleValue }
    public var startTimeCode: Double? { self[metadata: FieldKey.startTimeCode]?.doubleValue }
    public var endTimeCode: Double? { self[metadata: FieldKey.endTimeCode]?.doubleValue }

    // MARK: Children

    /// Child prim names of a prim, variant or the root, in authored order.
    public func primChildren(of path: Path) -> [String] {
        specs[path]?.fields[FieldKey.primChildren]?.stringArray ?? []
    }

    /// Property names of a prim or variant, in authored order.
    public func propertyNames(of path: Path) -> [String] {
        specs[path]?.fields[FieldKey.properties]?.stringArray ?? []
    }

    /// Variant set names authored as specs under a prim.
    public func variantSetNames(of path: Path) -> [String] {
        specs[path]?.fields[FieldKey.variantSetChildren]?.stringArray ?? []
    }

    /// Variant names of a variant set (`path` is the prim path).
    public func variantNames(of path: Path, set: String) -> [String] {
        specs[path.appendingVariantSelection(set: set, variant: "")]?.fields[FieldKey.variantChildren]?.stringArray ?? []
    }

    private mutating func appendChild(_ name: String, list: String, at parent: Path) {
        var names = specs[parent]?.fields[list]?.stringArray ?? []
        guard !names.contains(name) else { return }
        names.append(name)
        specs[parent]?.fields[list] = .tokenVector(names)
    }

    private mutating func removeChild(_ name: String, list: String, at parent: Path) {
        guard var names = specs[parent]?.fields[list]?.stringArray else { return }
        names.removeAll { $0 == name }
        specs[parent]?.fields[list] = names.isEmpty ? nil : .tokenVector(names)
    }

    private func childList(for path: Path) -> (parent: Path, list: String, name: String)? {
        switch path.last {
        case .prim(let n): return (path.parent, FieldKey.primChildren, n)
        case .property(let n): return (path.parent, FieldKey.properties, n)
        case .variantSelection(let set, let variant):
            if variant.isEmpty { return (path.parent, FieldKey.variantSetChildren, set) }
            return (path.parent.appendingVariantSelection(set: set, variant: ""), FieldKey.variantChildren, variant)
        default: return nil
        }
    }

    /// Adds a spec and registers it in its parent's children list. The
    /// parent must exist.
    @discardableResult
    public mutating func insertSpec(_ spec: Spec, at path: Path, index: Int? = nil) -> Bool {
        guard let (parent, list, name) = childList(for: path), specs[parent] != nil else { return false }
        specs[path] = spec
        appendChild(name, list: list, at: parent)
        if let index {
            var names = specs[parent]?.fields[list]?.stringArray ?? []
            names.removeAll { $0 == name }
            names.insert(name, at: min(max(index, 0), names.count))
            specs[parent]?.fields[list] = .tokenVector(names)
        }
        return true
    }

    // MARK: Creating specs

    /// Creates (or returns) a prim spec; missing ancestors are created as
    /// `over`s. Variant selections in the path must already exist.
    @discardableResult
    public mutating func createPrim(at path: Path, specifier: Specifier = .def, typeName: String? = nil) throws -> Path {
        guard path.isAbsolute, path.isPrimPath else { throw USDError("not an absolute prim path: \(path)") }
        if specs[path] == nil {
            let parent = path.parent
            if specs[parent] == nil {
                guard parent.isPrimPath else { throw USDError("missing parent spec for \(path)") }
                try createPrim(at: parent, specifier: .over)
            }
            var spec = Spec(type: .prim)
            spec[FieldKey.specifier] = .specifier(specifier)
            if let typeName, !typeName.isEmpty { spec[FieldKey.typeName] = .token(typeName) }
            insertSpec(spec, at: path)
        } else {
            specs[path]?.fields[FieldKey.specifier] = .specifier(specifier)
            if let typeName { specs[path]?.fields[FieldKey.typeName] = typeName.isEmpty ? nil : .token(typeName) }
        }
        return path
    }

    /// Creates or updates an attribute spec.
    @discardableResult
    public mutating func createAttribute(at path: Path, typeName: TypeName, value: Value? = nil, variability: Variability = .varying,
                                         custom: Bool = false) throws -> Path {
        guard path.isPropertyPath, specs[path.parent] != nil else { throw USDError("no owner for attribute \(path)") }
        var spec = specs[path] ?? Spec(type: .attribute)
        spec.type = .attribute
        spec[FieldKey.typeName] = .token(typeName.description)
        spec[FieldKey.variability] = .variability(variability)
        spec[FieldKey.custom] = .bool(custom)
        if let value { spec[FieldKey.defaultValue] = value }
        if specs[path] == nil { insertSpec(spec, at: path) } else { specs[path] = spec }
        return path
    }

    /// Creates or updates a relationship spec with explicit targets.
    @discardableResult
    public mutating func createRelationship(at path: Path, targets: [Path], custom: Bool = false) throws -> Path {
        guard path.isPropertyPath, specs[path.parent] != nil else { throw USDError("no owner for relationship \(path)") }
        var spec = specs[path] ?? Spec(type: .relationship)
        spec.type = .relationship
        spec[FieldKey.targetPaths] = .pathListOp(.explicit(targets))
        spec[FieldKey.custom] = .bool(custom)
        if spec[FieldKey.variability] == nil { spec[FieldKey.variability] = .variability(.uniform) }
        if specs[path] == nil { insertSpec(spec, at: path) } else { specs[path] = spec }
        return path
    }

    /// Creates a variant set spec under a prim and adds it to the prim's
    /// `variantSets` list op.
    public mutating func createVariantSet(_ name: String, on prim: Path) throws {
        guard specs[prim]?.type == .prim || specs[prim]?.type == .variant else { throw USDError("no prim at \(prim)") }
        let setPath = prim.appendingVariantSelection(set: name, variant: "")
        if specs[setPath] == nil { insertSpec(Spec(type: .variantSet), at: setPath) }
        var listOp: ListOp<String> = {
            if case .stringListOp(let op)? = specs[prim]?.fields[FieldKey.variantSetNames] { return op }
            return ListOp()
        }()
        if !listOp.allItems.contains(name) {
            listOp.prependedItems.append(name)
            specs[prim]?.fields[FieldKey.variantSetNames] = .stringListOp(listOp)
        }
    }

    /// Creates a variant (`/Prim{set=variant}`) and returns its path.
    @discardableResult
    public mutating func createVariant(_ variant: String, inSet set: String, on prim: Path) throws -> Path {
        try createVariantSet(set, on: prim)
        let path = prim.appendingVariantSelection(set: set, variant: variant)
        if specs[path] == nil { insertSpec(Spec(type: .variant), at: path) }
        return path
    }

    // MARK: Removing and moving

    /// Every spec path at or below `path`.
    public func subtreePaths(_ path: Path) -> [Path] {
        specs.keys.filter { $0.hasPrefix(path) }
    }

    /// Removes a spec and everything below it. Returns the removed specs.
    @discardableResult
    public mutating func removeSpec(at path: Path) -> [Path: Spec] {
        guard !path.isRoot else { return [:] }
        var removed: [Path: Spec] = [:]
        for p in subtreePaths(path) {
            removed[p] = specs.removeValue(forKey: p)
        }
        if let (parent, list, name) = childList(for: path) {
            removeChild(name, list: list, at: parent)
        }
        return removed
    }

    /// Copies a spec subtree from another layer (or this one) to `destination`,
    /// remapping internal paths in relationship targets and connections that
    /// point inside the copied subtree. The destination's parent must exist.
    public mutating func copySpec(from source: Layer, at sourcePath: Path, to destination: Path) throws {
        guard source.specs[sourcePath] != nil else { throw USDError("no spec at \(sourcePath)") }
        guard let (parent, _, _) = childList(for: destination), specs[parent] != nil else {
            throw USDError("no parent for \(destination)")
        }
        let paths = source.subtreePaths(sourcePath)
        if specs[destination] != nil { removeSpec(at: destination) }
        for p in paths.sorted(by: { $0.elements.count < $1.elements.count }) {
            var spec = source.specs[p]!
            for (key, value) in spec.fields {
                spec.fields[key] = Layer.remap(value, from: sourcePath, to: destination)
            }
            let target = p.replacingPrefix(sourcePath, with: destination)
            if p == sourcePath { insertSpec(spec, at: target) } else { specs[target] = spec }
        }
    }

    /// Moves (renames or reparents) a spec subtree.
    public mutating func moveSpec(at path: Path, to destination: Path, index: Int? = nil) throws {
        guard specs[path] != nil else { throw USDError("no spec at \(path)") }
        guard specs[destination] == nil else { throw USDError("\(destination) already exists") }
        guard !destination.hasPrefix(path) else { throw USDError("cannot move \(path) below itself") }
        var index = index
        if index == nil, destination.parent == path.parent, let (parent, list, name) = childList(for: path) {
            index = specs[parent]?.fields[list]?.stringArray?.firstIndex(of: name)
        }
        let copy = self
        try copySpec(from: copy, at: path, to: destination)
        removeSpec(at: path)
        if let index, let (parent, list, name) = childList(for: destination) {
            var names = specs[parent]?.fields[list]?.stringArray ?? []
            names.removeAll { $0 == name }
            names.insert(name, at: min(max(index, 0), names.count))
            specs[parent]?.fields[list] = .tokenVector(names)
        }
    }

    static func remap(_ value: Value, from: Path, to: Path) -> Value {
        func map(_ p: Path) -> Path { p.hasPrefix(from) ? p.replacingPrefix(from, with: to) : p }
        func mapOp(_ op: ListOp<Path>) -> ListOp<Path> {
            ListOp(isExplicit: op.isExplicit, explicitItems: op.explicitItems.map(map), addedItems: op.addedItems.map(map),
                   prependedItems: op.prependedItems.map(map), appendedItems: op.appendedItems.map(map),
                   deletedItems: op.deletedItems.map(map), orderedItems: op.orderedItems.map(map))
        }
        switch value {
        case .pathListOp(let op): return .pathListOp(mapOp(op))
        case .pathVector(let v): return .pathVector(v.map(map))
        case .path(let p): return .path(map(p))
        default: return value
        }
    }

    // MARK: Traversal

    /// Prim spec paths in depth-first authored order, including prims inside
    /// variants (after the prim's own children).
    public func primPaths(under root: Path = .root) -> [Path] {
        var out: [Path] = []
        func visit(_ path: Path) {
            for child in primChildren(of: path) {
                let p = path.appendingChild(child)
                guard specs[p] != nil else { continue }
                out.append(p)
                visit(p)
            }
            for set in variantSetNames(of: path) {
                for variant in variantNames(of: path, set: set) {
                    let v = path.appendingVariantSelection(set: set, variant: variant)
                    if specs[v] != nil { visit(v) }
                }
            }
        }
        visit(root)
        return out
    }
}
