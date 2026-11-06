import Foundation

/// Edits behind the Attributes inspector beyond plain attributes
/// (`interface-builder.md` §Reference Attributes inspector): attributes of
/// keyed child elements, colours, fonts, and edits Ycode works out (segment
/// and cell counts, section header and footer, child elements turned on or
/// off). Each splices only what changes.
///
/// A path names a child element below an object: `id>comp>comp…`, each
/// component `element`, `element@key` or `element#index` (both may be
/// given), matched among the XML children of the element above.
extension IBDocument {
    struct PathComponent {
        var element: String
        var key: String?
        var index: Int

        init(_ s: Substring) {
            var rest = String(s)
            index = 0
            if let h = rest.firstIndex(of: "#") { index = Int(rest[rest.index(after: h)...]) ?? 0; rest = String(rest[..<h]) }
            if let a = rest.firstIndex(of: "@") { key = String(rest[rest.index(after: a)...]); element = String(rest[..<a]) } else { element = rest }
        }

        func matches(_ n: XMLSourceNode) -> Bool { n.name == element && (key == nil || n["key"] == key) }
    }

    /// The deepest node a path reaches, and the components still missing.
    func resolve(path: String) -> (node: XMLSourceNode, missing: [PathComponent])? {
        let parts = path.split(separator: ">")
        guard let first = parts.first, var node = byID[String(first)]?.node else { return nil }
        let comps = parts.dropFirst().map(PathComponent.init)
        for (i, c) in comps.enumerated() {
            let hits = node.children.filter(c.matches)
            guard c.index < hits.count else { return (node, Array(comps[i...])) }
            node = hits[c.index]
        }
        return (node, [])
    }

    /// The node a target names (an object or a path), if it exists.
    public func node(at target: String) -> XMLSourceNode? {
        guard let (n, missing) = resolve(path: target), missing.isEmpty else { return nil }
        return n
    }

    /// An attribute of the node a target names.
    public func value(_ attribute: String, at target: String) -> String? { node(at: target)?[attribute] }

    /// Attributes a child element gets when it is made for an edit, so the
    /// others keep their defaults (a stretch rectangle, offsets).
    static let childDefaults: [String: [(String, String)]] = [
        "rect@contentStretch": [("x", "0.0"), ("y", "0.0"), ("width", "1"), ("height", "1")],
        "size@shadowOffset": [("width", "0.0"), ("height", "-1")],
        "size@titleShadowOffset": [("width", "0.0"), ("height", "0.0")],
        "size@preferredContentSize": [("width", "0.0"), ("height", "0.0")],
        "size@contentOffset": [("width", "0.0"), ("height", "0.0")],
    ]

    /// Sets (nil removes) an attribute of a path's element, making the
    /// missing elements on the way (among the kind children).
    func settingPathAttribute(_ name: String, _ value: String?, path: String) throws -> IBDocument {
        guard let (node, missing) = resolve(path: path) else { return self }
        if missing.isEmpty { return try edited([XMLEdit.setAttribute(name, value, on: node, in: source)]) }
        guard let value, missing.allSatisfy({ $0.index == 0 }) else { return self }
        var lines: [(Int, String)] = []
        for (i, c) in missing.enumerated() {
            let id = c.key.map { "\(c.element)@\($0)" } ?? c.element
            var attrs = c.key.map { [("key", $0)] } ?? []
            attrs += Self.childDefaults[id] ?? []
            if i == missing.count - 1 {
                if let j = attrs.firstIndex(where: { $0.0 == name }) { attrs[j].1 = value } else { attrs.append((name, value)) }
            }
            let text = "<\(c.element)" + attrs.map { " \($0.0)=\"\(XMLSource.encode($0.1))\"" }.joined()
            lines.append((i, i == missing.count - 1 ? text + "/>" : text + ">"))
        }
        for i in stride(from: missing.count - 2, through: 0, by: -1) { lines.append((i, "</\(missing[i].element)>")) }
        return try edited([childInsertion(lines, into: node, before: Self.comesAfterKindChildren)])
    }

    // MARK: Colours

    /// The colour pop-up's choices: Default, then the colours Ycode writes.
    public static let colorChoices: [(title: String, attributes: String)] = [
        ("Default", ""),
        ("System Background Color", "systemColor=\"systemBackgroundColor\""),
        ("System Grouped Background Color", "systemColor=\"systemGroupedBackgroundColor\""),
        ("Label Color", "systemColor=\"labelColor\""),
        ("Secondary Label Color", "systemColor=\"secondaryLabelColor\""),
        ("System Blue Color", "systemColor=\"systemBlueColor\""),
        ("System Red Color", "systemColor=\"systemRedColor\""),
        ("System Green Color", "systemColor=\"systemGreenColor\""),
        ("System Orange Color", "systemColor=\"systemOrangeColor\""),
        ("System Yellow Color", "systemColor=\"systemYellowColor\""),
        ("System Gray Color", "systemColor=\"systemGrayColor\""),
        ("White Color", "white=\"1\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"genericGamma22GrayColorSpace\""),
        ("Black Color", "white=\"0.0\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"genericGamma22GrayColorSpace\""),
        ("Clear Color", "white=\"0.0\" alpha=\"0.0\" colorSpace=\"custom\" customColorSpace=\"genericGamma22GrayColorSpace\""),
    ]

    /// The `<color key=…>` (or `<nil key=…>`) child of a target's element.
    func colorNode(_ key: String, at target: String) -> XMLSourceNode? {
        node(at: target)?.children.first { ($0.name == "color" || $0.name == "nil") && $0["key"] == key }
    }

    /// The colour pop-up's title for a colour child, else `default`.
    public func colorTitle(_ key: String, at target: String, default d: String = "Default") -> String {
        guard let n = colorNode(key, at: target), n.name == "color" else { return d }
        if let s = n["systemColor"] ?? n["name"] {
            return Self.colorChoices.first { $0.attributes == "systemColor=\"\(s)\"" }?.title ?? Self.words(s)
        }
        if let w = n["white"] {
            if n["alpha"].flatMap(Double.init) == 0 { return "Clear Color" }
            return Double(w) == 1 ? "White Color" : Double(w) == 0 ? "Black Color" : "Custom"
        }
        return "Custom"
    }

    /// Sets a colour by its pop-up title ("Default" or nil removes it).
    /// System colours get their `<systemColor>` resource.
    public func settingColor(_ title: String?, key: String, of target: String) throws -> IBDocument {
        guard let owner = node(at: target) else { return self }
        let choice = Self.colorChoices.first { $0.title == title }
        let existing = colorNode(key, at: target)
        guard let choice, !choice.attributes.isEmpty else {
            guard let n = existing else { return self }
            return try edited([XMLEdit(lineRange(of: n), "")])
        }
        let line = "<color key=\"\(key)\" \(choice.attributes)/>"
        let next: IBDocument
        if let n = existing {
            next = try edited([XMLEdit(n.range, line)])
        } else if key == "backgroundColor" {
            next = try edited([childInsertion([(0, line)], into: owner, before: {
                ["constraints", "connections", "userDefinedRuntimeAttributes", "variation", "accessibility", "keyCommands"].contains($0.name)
            })])
        } else {
            next = try edited([childInsertion([(0, line)], into: owner, before: Self.comesAfterValues)])
        }
        return try next.addingSystemColorResources(since: self)
    }

    // MARK: Fonts

    /// The Font pop-up's choices, with the `fontDescription` attributes each writes.
    public static let fontChoices: [(title: String, attributes: String)] = {
        var out: [(String, String)] = [12, 14, 15, 17, 20, 24, 28, 34].map { ("System \($0).0", "type=\"system\" pointSize=\"\($0)\"") }
        out += [14, 17, 20].map { ("System Bold \($0).0", "type=\"boldSystem\" pointSize=\"\($0)\"") }
        out += [("Large Title", "Title0"), ("Title 1", "Title1"), ("Title 2", "Title2"), ("Title 3", "Title3"), ("Headline", "Headline"),
                ("Body", "Body"), ("Callout", "Callout"), ("Subheadline", "Subhead"), ("Footnote", "Footnote"), ("Caption 1", "Caption1"),
                ("Caption 2", "Caption2")].map { ($0.0, "style=\"UICTFontTextStyle\($0.1)\"") }
        return out
    }()

    /// The Font pop-up's title for an object (its `fontDescription`).
    public func fontTitle(_ o: Object, default d: String) -> String {
        guard let f = o.node.child("fontDescription", key: "fontDescription") else { return d }
        if let style = f["style"] { return Self.fontChoices.first { $0.attributes == "style=\"\(style)\"" }?.title ?? style }
        let size = f["pointSize"].flatMap(Double.init).map { String(format: "%.1f", $0) } ?? ""
        let type = f["type"] == "boldSystem" ? "System Bold" : f["type"] == "italicSystem" ? "System Italic" : f["name"] ?? "System"
        return [type, size].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func settingFont(_ title: String?, of o: Object) throws -> IBDocument {
        guard let attrs = Self.fontChoices.first(where: { $0.title == title })?.attributes else { return self }
        let line = "<fontDescription key=\"fontDescription\" \(attrs)/>"
        if let n = o.node.child("fontDescription", key: "fontDescription") { return try edited([XMLEdit(n.range, line)]) }
        return try edited([childInsertion([(0, line)], into: o.node, before: { !["rect", "autoresizingMask"].contains($0.name) })])
    }

    // MARK: Edits Ycode works out

    /// Attributes starting with "@" (see the type's comment).
    func settingVirtual(_ name: String, _ value: String?, of id: String) throws -> IBDocument {
        guard let o = byID[id] else { return self }
        let on = value.map { $0 != "NO" && !$0.isEmpty } ?? false
        switch name {
        case "@font": return try settingFont(value, of: o)
        case "@title": return try settingTitle(value ?? "", of: id)
        case "@segments":
            guard let n = value.flatMap(Int.init), n >= 1, let segs = o.node.child("segments") else { return self }
            let have = segs.children.filter { $0.name == "segment" }
            if n > have.count {
                return try edited([childInsertion((have.count..<n).map { (0, "<segment title=\"Segment \($0)\"/>") }, into: segs)])
            }
            return try edited(have.suffix(have.count - n).map { XMLEdit(lineRange(of: $0), "") })
        case "@prototypes", "@items":
            let kind: NewObject = name == "@prototypes" ? .tableViewCell : .collectionViewCell
            guard var n = value.flatMap(Int.init), n >= 0 else { return self }
            n = min(n, 50)
            var d = self
            var cells = o.children.filter { $0.element == kind.element }
            if n < cells.count { return try deleting(cells.suffix(cells.count - n).map(\.id)) }
            while cells.count < n {
                let (next, nid) = try d.inserting(kind, near: id)
                guard !nid.isEmpty else { break }
                d = next
                cells = d.byID[id]?.children.filter { $0.element == kind.element } ?? []
            }
            return d
        case "@selection":
            return try edited([XMLEdit.setAttribute("allowsSelection", value == "none" ? "NO" : nil, on: o.node, in: source),
                               XMLEdit.setAttribute("allowsMultipleSelection", value == "multiple" ? "YES" : nil, on: o.node, in: source)])
        case "@editingSelection":
            return try edited([XMLEdit.setAttribute("allowsSelectionDuringEditing", value == "single" ? "YES" : nil, on: o.node, in: source),
                               XMLEdit.setAttribute("allowsMultipleSelectionDuringEditing", value == "multiple" ? "YES" : nil, on: o.node, in: source)])
        case "@sectionHeader", "@sectionFooter":
            let key = name == "@sectionHeader" ? "sectionHeaderView" : "sectionFooterView"
            let existing = o.children.first { $0.key == key }
            if !on { return try existing.map { try deleting([$0.id]) } ?? self }
            guard existing == nil, let cf = o.frame else { return self }
            var maker = IDMaker(document: self)
            var ids: [String: String] = [:]
            let f = CGRect(x: 0, y: key == "sectionHeaderView" ? 0 : max(0, cf.height - 50), width: cf.width, height: 50)
            let lines = Self.keyed(Self.expand(Self.iosTemplate(.collectionReusableView), id: maker.make(), frame: f, storyboard: isStoryboard,
                                               ids: &ids, fresh: { maker.make() }), key)
            return try edited([childInsertion(lines, into: o.node, before: Self.comesAfterKindChildren)])
        default:
            if name.hasPrefix("@child:") {
                let c = PathComponent(name.dropFirst("@child:".count))
                let existing = o.node.children.first(where: c.matches)
                if !on { return try existing.map { try edited([XMLEdit(lineRange(of: $0), "")]) } ?? self }
                guard existing == nil else { return self }
                let line = "<\(c.element)" + (c.key.map { " key=\"\($0)\"" } ?? "") + "/>"
                return try edited([childInsertion([(0, line)], into: o.node, before: Self.comesAfterKindChildren)])
            }
            // Rows Ycode shows but does not store yet.
            return self
        }
    }
}
