import USDCore

/// A composed prim on a stage.
public struct Prim {
    public let stage: Stage
    public let path: Path

    public var name: String { path.name }

    /// The strongest authored type name ("" for typeless prims).
    public var typeName: String {
        for o in stage.opinions(path) {
            if let t = o.spec.fields[FieldKey.typeName]?.stringValue, !t.isEmpty { return t }
        }
        return ""
    }

    /// The strongest defining specifier (`def` or `class`), else `over`.
    public var specifier: Specifier {
        for o in stage.opinions(path) {
            if case .specifier(let s)? = o.spec.fields[FieldKey.specifier], s != .over { return s }
        }
        return .over
    }

    /// True when the prim and all its ancestors have a defining specifier.
    public var isDefined: Bool {
        guard !path.isRoot else { return true }
        return specifier != .over && Prim(stage: stage, path: path.parent).isDefined
    }

    public var isActive: Bool { metadata(FieldKey.active)?.boolValue ?? true }
    public var kind: String? { metadata(FieldKey.kind)?.stringValue }

    public func metadata(_ key: String) -> Value? { stage.resolvedField(key, at: path) }

    /// Applied API schemas (the composed `apiSchemas` list op).
    public var appliedSchemas: [String] {
        var items: [String] = []
        for o in stage.opinions(path).reversed() {
            if case .tokenListOp(let op)? = o.spec.fields[FieldKey.apiSchemas] { items = op.applied(to: items) }
        }
        return items
    }

    public var children: [Prim] { stage.childNames(of: path).map { Prim(stage: stage, path: path.appendingChild($0)) } }
    public var parent: Prim? { path.isRoot ? nil : Prim(stage: stage, path: path.parent) }
    public var propertyNames: [String] { stage.propertyNames(of: path) }

    public func attribute(_ name: String) -> Attribute? {
        let a = Attribute(stage: stage, path: path.appendingProperty(name))
        return a.exists && !a.isRelationship ? a : nil
    }

    public func relationship(_ name: String) -> Attribute? {
        let a = Attribute(stage: stage, path: path.appendingProperty(name))
        return a.exists && a.isRelationship ? a : nil
    }

    public var attributes: [Attribute] { propertyNames.compactMap(attribute) }

    /// Variant sets with their variants and the current selection.
    public var variantSets: [(name: String, variants: [String], selection: String?)] {
        guard let index = stage.primIndex(path) else { return [] }
        var names: [String] = []
        for o in stage.opinions(path).reversed() {
            if case .stringListOp(let op)? = o.spec.fields[FieldKey.variantSetNames] { names = op.applied(to: names) }
        }
        return names.map { set in
            var variants: [String] = []
            for node in index.strengthOrdered {
                for entry in node.stack.layers {
                    for v in entry.layer.variantNames(of: node.path, set: set) where !variants.contains(v) { variants.append(v) }
                }
            }
            let chosen = index.strengthOrdered.first { node in
                if node.arc == .variant, case .variantSelection(let s, _)? = node.path.last { return s == set }
                return false
            }
            if case .variantSelection(_, let v)? = chosen?.path.last { return (set, variants, v) }
            return (set, variants, nil)
        }
    }

    /// The sites that contribute opinions to this prim (the root site
    /// always), strongest first (for tools).
    public var arcs: [(arc: ArcType, layer: String, path: Path)] {
        stage.primIndex(path)?.strengthOrdered.filter { $0.arc == .root || $0.stack.hasSpec(at: $0.path) }
            .map { ($0.arc, $0.stack.identifier, $0.path) } ?? []
    }
}

/// A composed attribute or relationship.
public struct Attribute {
    public let stage: Stage
    public let path: Path

    public var name: String { path.name }
    var opinions: [(node: IndexNode, layer: Layer, spec: Spec, offset: LayerOffset)] { stage.opinions(path) }
    public var exists: Bool { !opinions.isEmpty }
    public var isRelationship: Bool { opinions.first?.spec.type == .relationship }

    public var typeName: TypeName? {
        for o in opinions {
            if let t = o.spec.fields[FieldKey.typeName]?.stringValue { return TypeName(t) }
        }
        return nil
    }

    public var variability: Variability {
        for o in opinions {
            if case .variability(let v)? = o.spec.fields[FieldKey.variability] { return v }
        }
        return isRelationship ? .uniform : .varying
    }

    public func metadata(_ key: String) -> Value? { stage.resolvedField(key, at: path) }

    /// The value at the default time (time samples ignored), or at `time`
    /// (stage time codes) where the strongest opinion with samples or a
    /// default wins. Blocked values return nil.
    public func value(at time: Double? = nil) -> Value? {
        for o in opinions {
            if let time, case .timeSamples(let samples)? = o.spec.fields[FieldKey.timeSamples], !samples.isEmpty {
                let local = o.offset.scale != 0 ? (time - o.offset.offset) / o.offset.scale : time
                return Attribute.sample(samples, at: local)
            }
            if let v = o.spec.fields[FieldKey.defaultValue] {
                return v == .valueBlock ? nil : v
            }
        }
        return nil
    }

    /// Authored time samples of the strongest opinion that has any, mapped
    /// to stage times.
    public var timeSamples: [TimeSample] {
        for o in opinions {
            if case .timeSamples(let samples)? = o.spec.fields[FieldKey.timeSamples] {
                return samples.map { TimeSample(time: o.offset.apply($0.time), value: $0.value) }
            }
        }
        return []
    }

    /// Composed connections or relationship targets, in stage namespace.
    public var targets: [Path] {
        let field = isRelationship ? FieldKey.targetPaths : FieldKey.connectionPaths
        var items: [Path] = []
        for o in opinions.reversed() {
            if case .pathListOp(let op)? = o.spec.fields[field] {
                let mapped = ListOp(isExplicit: op.isExplicit, explicitItems: op.explicitItems.map(o.node.mapToStage),
                                    addedItems: op.addedItems.map(o.node.mapToStage), prependedItems: op.prependedItems.map(o.node.mapToStage),
                                    appendedItems: op.appendedItems.map(o.node.mapToStage), deletedItems: op.deletedItems.map(o.node.mapToStage),
                                    orderedItems: op.orderedItems.map(o.node.mapToStage))
                items = mapped.applied(to: items)
            }
        }
        return items
    }

    /// Linear interpolation for floating-point values, held otherwise.
    static func sample(_ samples: [TimeSample], at t: Double) -> Value? {
        guard let first = samples.first else { return nil }
        if t <= first.time { return first.value == .valueBlock ? nil : first.value }
        guard let last = samples.last, t < last.time else { return samples.last?.value == .valueBlock ? nil : samples.last?.value }
        var i = 0
        while i + 1 < samples.count, samples[i + 1].time <= t { i += 1 }
        let a = samples[i]
        let b = samples[i + 1]
        if a.time == t || a.value == .valueBlock || b.value == .valueBlock { return a.value == .valueBlock ? nil : a.value }
        let u = (t - a.time) / (b.time - a.time)
        switch (a.value, b.value) {
        case (.scalar(let ta, .floats(let x)), .scalar(let tb, .floats(let y))) where ta == tb && x.count == y.count:
            return .scalar(ta, .floats(zip(x, y).map { $0 + Float(u) * ($1 - $0) }))
        case (.scalar(let ta, .doubles(let x)), .scalar(let tb, .doubles(let y))) where ta == tb && x.count == y.count:
            return .scalar(ta, .doubles(zip(x, y).map { $0 + u * ($1 - $0) }))
        case (.array(let ta, .floats(let x)), .array(let tb, .floats(let y))) where ta == tb && x.count == y.count:
            return .array(ta, .floats(zip(x, y).map { $0 + Float(u) * ($1 - $0) }))
        case (.array(let ta, .doubles(let x)), .array(let tb, .doubles(let y))) where ta == tb && x.count == y.count:
            return .array(ta, .doubles(zip(x, y).map { $0 + u * ($1 - $0) }))
        default:
            return a.value
        }
    }
}

extension Stage {
    static let arcFields: Set<String> = Set([
        FieldKey.references, FieldKey.payload, FieldKey.inheritPaths, FieldKey.specializes, FieldKey.variantSetNames,
        FieldKey.variantSelection, FieldKey.apiSchemas, FieldKey.primOrder, FieldKey.propertyOrder, FieldKey.specifier,
        FieldKey.typeName,
    ]).union(FieldKey.childrenFields)

    /// One layer holding the composed result: every prim with its resolved
    /// specifier, type, metadata, attribute values, time samples (in stage
    /// time) and targets. Composition arcs are baked in and dropped.
    public func flatten() -> Layer {
        var out = Layer(identifier: rootLayer.identifier)
        for (key, value) in rootLayer.pseudoRoot.fields where ![FieldKey.subLayers, FieldKey.subLayerOffsets, FieldKey.primChildren].contains(key) {
            out[metadata: key] = value
        }
        for prim in traverse(.all) {
            let p = prim.path
            _ = try? out.createPrim(at: p, specifier: prim.specifier, typeName: prim.typeName)
            var keys: Set<String> = []
            for o in opinions(p) { keys.formUnion(o.spec.fields.keys) }
            for key in keys.subtracting(Stage.arcFields).sorted() {
                if let v = resolvedField(key, at: p) { out.setField(key, v, at: p) }
            }
            let schemas = prim.appliedSchemas
            if !schemas.isEmpty { out.setField(FieldKey.apiSchemas, .tokenListOp(.prepended(schemas)), at: p) }
            for name in prim.propertyNames {
                let a = Attribute(stage: self, path: p.appendingProperty(name))
                guard a.exists else { continue }
                let propPath = p.appendingProperty(name)
                if a.isRelationship {
                    _ = try? out.createRelationship(at: propPath, targets: a.targets)
                    out.setField(FieldKey.variability, .variability(a.variability), at: propPath)
                } else {
                    guard let type = a.typeName else { continue }
                    var raw: Value?
                    for o in a.opinions {
                        if let v = o.spec.fields[FieldKey.defaultValue] {
                            raw = v
                            break
                        }
                    }
                    _ = try? out.createAttribute(at: propPath, typeName: type, value: raw, variability: a.variability,
                                             custom: a.metadata(FieldKey.custom)?.boolValue ?? false)
                    let samples = a.timeSamples
                    if !samples.isEmpty { out.setField(FieldKey.timeSamples, .timeSamples(samples), at: propPath) }
                    let targets = a.targets
                    if !targets.isEmpty { out.setField(FieldKey.connectionPaths, .pathListOp(.explicit(targets)), at: propPath) }
                }
                var metaKeys: Set<String> = []
                for o in a.opinions { metaKeys.formUnion(o.spec.fields.keys) }
                let skip: Set<String> = [FieldKey.typeName, FieldKey.defaultValue, FieldKey.timeSamples, FieldKey.connectionPaths,
                                         FieldKey.targetPaths, FieldKey.variability, FieldKey.custom]
                for key in metaKeys.subtracting(skip).sorted() {
                    if let v = a.metadata(key) { out.setField(key, v, at: propPath) }
                }
            }
        }
        return out
    }
}
