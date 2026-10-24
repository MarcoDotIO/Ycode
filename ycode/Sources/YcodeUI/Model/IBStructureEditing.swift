import Foundation

/// Deleting, moving and constraining objects, byte-minimally. See
/// `specs/ide/interface-builder.md` §Structure edits and §Constraints.
extension IBDocument {
    /// The `constraint` element with an ID.
    public func constraintNode(_ id: String) -> XMLSourceNode? {
        var hit: XMLSourceNode?
        documentNode.walk { if hit == nil, $0.name == "constraint", $0["id"] == id { hit = $0 } }
        return hit
    }

    /// The byte range of whole lines covering a node (from its line's
    /// indentation through the newline after it).
    func lineRange(of n: XMLSourceNode) -> Range<Int> {
        var start = n.range.lowerBound
        while start > 0, source[start - 1] == 0x20 || source[start - 1] == 0x09 { start -= 1 }
        var end = n.range.upperBound
        if end < source.count, source[end] == 0x0A { end += 1 }
        return start..<end
    }

    /// Removals for a set of nodes; a container (`subviews`, `constraints`,
    /// `connections`) left empty is removed whole.
    func removals(_ nodes: [XMLSourceNode]) -> [XMLEdit] {
        var doomed = nodes
        var changed = true
        while changed {
            changed = false
            for n in doomed {
                guard let p = n.parent, ["subviews", "constraints", "connections"].contains(p.name), !doomed.contains(where: { $0 === p }) else { continue }
                if p.children.allSatisfy({ c in doomed.contains { $0 === c } }) {
                    doomed.removeAll { $0.parent === p }
                    doomed.append(p)
                    changed = true
                    break
                }
            }
        }
        // Drop nodes inside other doomed nodes.
        let top = doomed.filter { n in
            var p = n.parent
            while let q = p { if doomed.contains(where: { $0 === q }) { return false }; p = q.parent }
            return true
        }
        return top.map { XMLEdit(lineRange(of: $0), "") }
    }

    /// Deletes objects, their constraints (anywhere) and connections that
    /// point at them.
    public func deleting(_ ids: [String]) throws -> IBDocument {
        var gone = Set<String>()
        for id in ids { byID[id]?.walk { gone.insert($0.id) } }
        var nodes = ids.compactMap { byID[$0]?.node }
        documentNode.walk { n in
            switch n.name {
            case "constraint":
                if [n["firstItem"], n["secondItem"]].contains(where: { $0.map(gone.contains) ?? false }) { nodes.append(n) }
            case "outlet", "outletCollection", "segue":
                if let d = n["destination"], gone.contains(d) { nodes.append(n) }
            case "action":
                if let t = n["target"], gone.contains(t) { nodes.append(n) }
            default: break
            }
        }
        return try edited(removals(nodes))
    }

    /// Deletes constraints by ID.
    public func deletingConstraints(_ ids: [String]) throws -> IBDocument {
        try edited(removals(ids.compactMap(constraintNode)))
    }

    /// Sets a constraint's `constant` (0 removes the attribute).
    public func settingConstant(_ value: CGFloat, ofConstraint id: String) throws -> IBDocument {
        guard let n = constraintNode(id) else { return self }
        let text = value == 0 ? nil : (value == value.rounded() ? String(Int(value)) : Self.number(value))
        return try edited([XMLEdit.setAttribute("constant", text, on: n, in: source)])
    }

    /// Moves a view into another view (last subview), keeping its place on
    /// the canvas; constraints that mention it are removed.
    public func moving(_ id: String, into newParent: String) throws -> IBDocument {
        guard let o = byID[id], let target = byID[newParent], target.isView, o.parent?.id != newParent,
              let rootFrame = frameInRoot(o), let targetRoot = frameInRoot(target), rootView(of: o) === rootView(of: target) else { return self }
        // Not into itself or a descendant.
        var p: Object? = target
        while let q = p { if q.id == id { return self }; p = q.parent }
        let range = lineRange(of: o.node)
        let oldIndent = XMLEdit.indentation(of: o.node, in: source)
        let lines = String(decoding: source[range], as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        // Remove constraints first (they name the view), then the element.
        var constraintNodes: [XMLSourceNode] = []
        documentNode.walk { n in if n.name == "constraint", n["firstItem"] == id || n["secondItem"] == id { constraintNodes.append(n) } }
        let removed = try edited(removals([o.node] + constraintNodes))
        guard let t2 = removed.byID[newParent], let f2 = t2.frameNode else { return self }
        let indent: String
        let insertAt: Int
        var prefix = "", suffix = ""
        if let subviews = t2.node.child("subviews"), let end = subviews.endTag {
            indent = XMLEdit.indentation(of: subviews, in: removed.source) + "    "
            var lineStart = end.lowerBound
            while lineStart > 0, removed.source[lineStart - 1] != 0x0A { lineStart -= 1 }
            insertAt = lineStart
        } else {
            let base = XMLEdit.indentation(of: f2, in: removed.source)
            indent = base + "    "
            insertAt = f2.range.upperBound
            prefix = "\n" + base + "<subviews>\n"
            suffix = base + "</subviews>"
        }
        let body = lines.map { line -> String in
            let l = String(line)
            return indent + (l.hasPrefix(oldIndent) ? String(l.dropFirst(oldIndent.count)) : l.trimmingCharacters(in: .whitespaces)) + "\n"
        }.joined()
        let text = prefix + body + suffix
        let inserted = try removed.edited([XMLEdit(insertAt..<insertAt, text)])
        // Same place on the canvas, in the new parent's coordinates.
        var local = CGRect(x: rootFrame.minX - targetRoot.minX, y: rootFrame.minY - targetRoot.minY, width: rootFrame.width, height: rootFrame.height)
        if !isFlippedRuntime, let tf = target.frame { local.origin.y = tf.height - local.maxY }
        return try inserted.settingFrame(local, of: id)
    }

    // MARK: Constraints

    public enum Edge: String, CaseIterable, Sendable { case top, leading, bottom, trailing }

    /// The nearest object on one side of a view: a sibling whose span
    /// overlaps and that lies wholly on that side (closest first), else the
    /// superview. Returns its ID and the spacing (root coordinates).
    public func nearestNeighbor(of id: String, edge: Edge) -> (id: String, spacing: CGFloat)? {
        guard let o = byID[id], let parent = o.parent, parent.isView, let r = frameInRoot(o), let pr = frameInRoot(parent) else { return nil }
        var best: (String, CGFloat)?
        for s in parent.children where s.isView && s.id != id {
            guard let sr = frameInRoot(s) else { continue }
            let gap: CGFloat?
            switch edge {
            case .top: gap = sr.maxY <= r.minY && sr.maxX > r.minX && sr.minX < r.maxX ? r.minY - sr.maxY : nil
            case .bottom: gap = sr.minY >= r.maxY && sr.maxX > r.minX && sr.minX < r.maxX ? sr.minY - r.maxY : nil
            case .leading: gap = sr.maxX <= r.minX && sr.maxY > r.minY && sr.minY < r.maxY ? r.minX - sr.maxX : nil
            case .trailing: gap = sr.minX >= r.maxX && sr.maxY > r.minY && sr.minY < r.maxY ? sr.minX - r.maxX : nil
            }
            if let g = gap, best == nil || g < best!.1 { best = (s.id, g) }
        }
        if let best { return best }
        switch edge {
        case .top: return (parent.id, r.minY - pr.minY)
        case .bottom: return (parent.id, pr.maxY - r.maxY)
        case .leading: return (parent.id, r.minX - pr.minX)
        case .trailing: return (parent.id, pr.maxX - r.maxX)
        }
    }

    /// What the Add New Constraints popover asks for.
    public struct NewConstraints: Equatable, Sendable {
        public var spacing: [Edge: CGFloat] = [:]
        public var width: CGFloat?
        public var height: CGFloat?
        public var centerX = false
        public var centerY = false
        public init(spacing: [Edge: CGFloat] = [:], width: CGFloat? = nil, height: CGFloat? = nil, centerX: Bool = false, centerY: Bool = false) {
            self.spacing = spacing
            self.width = width
            self.height = height
            self.centerX = centerX
            self.centerY = centerY
        }
    }

    /// Adds constraints for a view. Spacing and centering constraints go in
    /// the superview's `constraints`, width/height in the view's own; the
    /// view gets `translatesAutoresizingMaskIntoConstraints="NO"`. Returns
    /// the new document and the new constraint IDs.
    public func addingConstraints(_ spec: NewConstraints, to id: String) throws -> (IBDocument, [String]) {
        guard let o = byID[id], let parent = o.parent, parent.isView else { return (self, []) }
        var g = SystemRandomNumberGenerator()
        var ids: [String] = []
        func fresh() -> String {
            while true { let n = makeObjectID(using: &g); if !ids.contains(n) { ids.append(n); return n } }
        }
        func num(_ v: CGFloat) -> String { v == v.rounded() ? String(Int(v)) : Self.number(v) }
        var inParent: [String] = [], inSelf: [String] = []
        for edge in Edge.allCases {
            guard let value = spec.spacing[edge], let n = nearestNeighbor(of: id, edge: edge) else { continue }
            let c = value == 0 ? "" : " constant=\"\(num(value))\""
            let toSuper = n.id == parent.id
            switch edge {
            case .top, .leading:
                let other = toSuper ? edge.rawValue : (edge == .top ? "bottom" : "trailing")
                inParent.append("<constraint firstItem=\"\(id)\" firstAttribute=\"\(edge.rawValue)\" secondItem=\"\(n.id)\" secondAttribute=\"\(other)\"\(c) id=\"\(fresh())\"/>")
            case .bottom, .trailing:
                if toSuper {
                    inParent.append("<constraint firstAttribute=\"\(edge.rawValue)\" secondItem=\"\(id)\" secondAttribute=\"\(edge.rawValue)\"\(c) id=\"\(fresh())\"/>")
                } else {
                    let other = edge == .bottom ? "top" : "leading"
                    inParent.append("<constraint firstItem=\"\(n.id)\" firstAttribute=\"\(other)\" secondItem=\"\(id)\" secondAttribute=\"\(edge.rawValue)\"\(c) id=\"\(fresh())\"/>")
                }
            }
        }
        if spec.centerX { inParent.append("<constraint firstItem=\"\(id)\" firstAttribute=\"centerX\" secondItem=\"\(parent.id)\" secondAttribute=\"centerX\" id=\"\(fresh())\"/>") }
        if spec.centerY { inParent.append("<constraint firstItem=\"\(id)\" firstAttribute=\"centerY\" secondItem=\"\(parent.id)\" secondAttribute=\"centerY\" id=\"\(fresh())\"/>") }
        if let w = spec.width { inSelf.append("<constraint firstAttribute=\"width\" constant=\"\(num(w))\" id=\"\(fresh())\"/>") }
        if let h = spec.height { inSelf.append("<constraint firstAttribute=\"height\" constant=\"\(num(h))\" id=\"\(fresh())\"/>") }
        var edits: [XMLEdit?] = [XMLEdit.setAttribute("translatesAutoresizingMaskIntoConstraints", "NO", on: o.node, in: source)]
        edits.append(constraintInsertion(inParent, into: parent))
        edits.append(constraintInsertion(inSelf, into: o))
        return (try edited(edits), ids)
    }

    /// Appends constraint lines to an object's `constraints` element, or
    /// adds one after its `subviews` (else after its frame).
    func constraintInsertion(_ lines: [String], into o: Object) -> XMLEdit? {
        guard !lines.isEmpty else { return nil }
        if let cs = o.node.child("constraints"), let end = cs.endTag {
            let indent = XMLEdit.indentation(of: cs, in: source) + "    "
            var lineStart = end.lowerBound
            while lineStart > 0, source[lineStart - 1] != 0x0A { lineStart -= 1 }
            return XMLEdit(lineStart..<lineStart, lines.map { indent + $0 + "\n" }.joined())
        }
        guard let anchor = o.node.child("subviews") ?? o.frameNode else { return nil }
        let base = XMLEdit.indentation(of: anchor, in: source)
        let at = anchor.range.upperBound
        return XMLEdit(at..<at, "\n" + base + "<constraints>\n" + lines.map { base + "    " + $0 + "\n" }.joined() + base + "</constraints>")
    }
}
