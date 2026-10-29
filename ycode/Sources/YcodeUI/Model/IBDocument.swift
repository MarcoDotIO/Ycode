import Foundation

/// A storyboard or xib, read as an XML file format (read-only). See
/// `specs/ide/interface-builder.md`.
public final class IBDocument {
    /// One object of the document (an element with an `id`).
    public final class Object {
        /// The XML element name (`view`, `button`, `scene`, …).
        public let element: String
        /// The `id` attribute (`sceneID` for scenes), unique in the document.
        public let id: String
        /// The element's `key` (its role in the parent: `view`, `cell`, …).
        public let key: String?
        /// The element's attributes in file order.
        public internal(set) var attributes: [(String, String)]
        /// Frame in the parent's coordinates, as written.
        public internal(set) var frame: CGRect?
        /// Child objects in file order, found through container elements.
        public internal(set) var children: [Object] = []
        /// Constraints written inside this object.
        public internal(set) var constraints: [Constraint] = []
        /// Outlets, actions and segues written inside this object (this object
        /// is the source).
        public internal(set) var connections: [Connection] = []
        /// Value-only child elements (`color`, `fontDescription`, `autoresizingMask`, …).
        public internal(set) var properties: [(String, [(String, String)])] = []
        /// The enclosing object; nil for a root.
        public internal(set) weak var parent: Object?
        /// For scenes: the canvas location, when written.
        public internal(set) var canvasLocation: CGPoint?
        /// For windows: `<rect key="contentRect">`.
        public internal(set) var contentRect: CGRect?
        /// The object's element in the source, and its frame element.
        public internal(set) var node: XMLSourceNode!
        /// The `<rect key="frame">` element, when the object has one.
        public internal(set) var frameNode: XMLSourceNode?

        init(element: String, id: String, key: String?, attributes: [(String, String)]) {
            self.element = element
            self.id = id
            self.key = key
            self.attributes = attributes
        }

        /// The value of attribute `name`, or nil when absent.
        public func attribute(_ name: String) -> String? { attributes.first { $0.0 == name }?.1 }

        /// What the outline shows: the user label, else a title, else the
        /// custom class or the element name in words.
        public var displayName: String {
            if let l = attribute("userLabel") { return l }
            if element == "scene" { return children.first.map { $0.displayName + " Scene" } ?? "Scene" }
            let kind = attribute("customClass") ?? IBDocument.words(element)
            if let t = attribute("title") ?? attribute("text"), !t.isEmpty { return "\(kind) - \(t)" }
            if let cellTitle = children.first(where: { $0.key == "cell" })?.attribute("title"), !cellTitle.isEmpty { return "\(kind) - \(cellTitle)" }
            return kind
        }

        /// Whether the object is a view (has a frame or a view role).
        public var isView: Bool { frame != nil }

        /// Calls `f` on this object, then on every descendant (pre-order).
        public func walk(_ f: (Object) -> Void) { f(self); children.forEach { $0.walk(f) } }
    }

    public struct Constraint: Equatable, Sendable {
        public var id: String
        public var firstItem: String?
        public var firstAttribute: String
        public var relation: String
        public var secondItem: String?
        public var secondAttribute: String?
        public var constant: String
        public var multiplier: String?
        public var priority: String?

        /// `View.centerX = Superview.centerX + 10` with item names.
        public func text(_ name: (String?) -> String) -> String {
            let rel = relation == "greaterThanOrEqual" ? "≥" : relation == "lessThanOrEqual" ? "≤" : "="
            var rhs = secondAttribute.map { "\(name(secondItem)).\($0)" } ?? ""
            if let m = multiplier, !rhs.isEmpty { rhs += " × \(m)" }
            let c = constant
            if rhs.isEmpty { rhs = c } else if c != "0" && !c.isEmpty { rhs += c.hasPrefix("-") ? " - \(c.dropFirst())" : " + \(c)" }
            var s = "\(name(firstItem)).\(firstAttribute) \(rel) \(rhs)"
            if let p = priority { s += " @\(p)" }
            return s
        }
    }

    public struct Connection: Equatable, Sendable {
        public enum Kind: String, Sendable { case outlet, action, segue, outletCollection }
        public var kind: Kind
        /// Outlet `property`, action `selector`, segue `kind`.
        public var name: String
        /// The other end: outlet `destination`, action `target`, segue `destination`.
        public var other: String
        public var id: String
    }

    /// True for a storyboard, false for a xib (from the root `type`).
    public let isStoryboard: Bool
    /// `targetRuntime` (e.g. `MacOSX.Cocoa`, `iOS.CocoaTouch`).
    public let targetRuntime: String
    /// The root `toolsVersion` attribute, when written.
    public let toolsVersion: String?
    /// The ID of the storyboard's initial view controller, when set.
    public let initialViewController: String?
    /// Top-level objects: scenes (storyboards) or the `objects` list (xibs).
    public private(set) var roots: [Object] = []
    /// Every object by its ID.
    public private(set) var byID: [String: Object] = [:]

    /// True for runtimes with a top-left origin (everything except macOS
    /// Cocoa); frames of other runtimes have a bottom-left origin.
    public var isFlippedRuntime: Bool { !targetRuntime.hasPrefix("MacOSX") }

    /// The file's bytes; edits splice these (see IBEditing.swift).
    public let source: [UInt8]
    /// The root `<document>` element of the parsed source.
    public let documentNode: XMLSourceNode

    /// Parses a storyboard or xib. Throws `CocoaError(.fileReadCorruptFile)`
    /// when the XML is malformed or the root is not `<document>`.
    public init(data: Data) throws {
        source = Array(data)
        let root: XMLSourceNode
        do { root = try XMLSource.parse(source) } catch {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
        }
        guard root.name == "document" else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Not an Interface Builder document"])
        }
        documentNode = root
        isStoryboard = (root["type"] ?? "").contains("Storyboard")
        targetRuntime = root["targetRuntime"] ?? ""
        toolsVersion = root["toolsVersion"]
        initialViewController = root["initialViewController"]
        roots = Self.build(root.children, owner: nil)
        for r in roots { r.walk { byID[$0.id] = $0 } }
    }

    /// Reads and parses the file at `url`; throws as `init(data:)` does, or
    /// the read error.
    public convenience init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    /// `viewController` → `View Controller`.
    static func words(_ element: String) -> String {
        var out = ""
        for (i, c) in element.enumerated() {
            if i == 0 { out.append(contentsOf: c.uppercased()) } else if c.isUppercase { out += " " + String(c) } else { out.append(c) }
        }
        return out
    }

    /// The name of an object by ID (for constraints and connections).
    public func name(_ id: String?) -> String {
        guard let id else { return "" }
        return byID[id]?.displayName ?? id
    }

    /// Connections that point at an object (from other objects).
    public func incomingConnections(to id: String) -> [(from: Object, connection: Connection)] {
        var out: [(Object, Connection)] = []
        for r in roots { r.walk { o in for c in o.connections where c.other == id { out.append((o, c)) } } }
        return out
    }

    /// Constraints that mention an object, wherever they are stored.
    public func constraints(involving id: String) -> [Constraint] {
        var out: [Constraint] = []
        for r in roots {
            r.walk { o in
                for c in o.constraints where c.firstItem == id || c.secondItem == id { out.append(c) }
            }
        }
        return out
    }

    /// A view's frame in its root view's coordinates, top-left origin
    /// (frames in bottom-left runtimes are flipped level by level).
    public func frameInRoot(_ o: Object) -> CGRect? {
        guard let own = o.frame else { return nil }
        var x: CGFloat = 0, top: CGFloat = 0
        var v = o
        while let p = v.parent, let pf = p.frame, let vf = v.frame {
            x += vf.minX
            top += isFlippedRuntime ? vf.minY : pf.height - vf.maxY
            v = p
        }
        return CGRect(x: x, y: top, width: own.width, height: own.height)
    }

    /// The topmost view above (or at) an object.
    public func rootView(of o: Object) -> Object? {
        var v: Object? = o.isView ? o : nil
        var cur = o.parent
        while let c = cur { if c.isView { v = c }; cur = c.parent }
        return v
    }

    // MARK: Building

    static let nonObjects: Set<String> = ["constraint", "action", "outlet", "segue", "outletCollection", "document", "dependencies",
                                          "plugIn", "capability", "deployment", "resources", "image", "namedColor", "systemColor",
                                          "development", "point", "rect", "size", "color", "font", "fontDescription"]

    /// Objects among `nodes` (recursing through container elements such as
    /// `scenes`, `objects`, `subviews`), attached to `owner`.
    static func build(_ nodes: [XMLSourceNode], owner: Object?) -> [Object] {
        var out: [Object] = []
        for n in nodes {
            let a = n.attributes
            switch n.name {
            case "rect" where n["key"] == "frame":
                owner?.frame = rect(n)
                owner?.frameNode = n
                continue
            case "rect" where n["key"] == "contentRect":
                owner?.contentRect = rect(n)
                continue
            case "point" where n["key"] == "canvasLocation":
                owner?.canvasLocation = CGPoint(x: Double(n["x"] ?? "0") ?? 0, y: Double(n["y"] ?? "0") ?? 0)
                continue
            case "constraint":
                owner?.constraints.append(Constraint(id: n["id"] ?? "", firstItem: n["firstItem"] ?? owner?.id, firstAttribute: n["firstAttribute"] ?? "",
                                                     relation: n["relation"] ?? "equal", secondItem: n["secondItem"],
                                                     secondAttribute: n["secondAttribute"], constant: n["constant"] ?? "0",
                                                     multiplier: n["multiplier"], priority: n["priority"]))
                continue
            case "outlet", "outletCollection":
                owner?.connections.append(Connection(kind: n.name == "outlet" ? .outlet : .outletCollection, name: n["property"] ?? "",
                                                     other: n["destination"] ?? "", id: n["id"] ?? ""))
                continue
            case "action":
                owner?.connections.append(Connection(kind: .action, name: n["selector"] ?? "", other: n["target"] ?? "", id: n["id"] ?? ""))
                continue
            case "segue":
                owner?.connections.append(Connection(kind: .segue, name: n["kind"] ?? "", other: n["destination"] ?? "", id: n["id"] ?? ""))
                continue
            default: break
            }
            let id = n["id"] ?? n["sceneID"]
            if let id, !nonObjects.contains(n.name) {
                let o = Object(element: n.name, id: id, key: n["key"], attributes: a.map { ($0.name, $0.value) })
                o.node = n
                o.parent = owner
                o.children = build(n.children, owner: o)
                out.append(o)
            } else {
                if id == nil, n["key"] != nil || ["autoresizingMask", "color", "fontDescription", "font", "size"].contains(n.name), let owner {
                    owner.properties.append((n["key"].map { "\(n.name) (\($0))" } ?? n.name, a.filter { $0.name != "key" }.map { ($0.name, $0.value) }))
                }
                out += build(n.children, owner: owner)
            }
        }
        // Children found through containers belong to the owner, in order.
        return out
    }

    static func rect(_ n: XMLSourceNode) -> CGRect {
        CGRect(x: Double(n["x"] ?? "0") ?? 0, y: Double(n["y"] ?? "0") ?? 0,
               width: Double(n["width"] ?? "0") ?? 0, height: Double(n["height"] ?? "0") ?? 0)
    }
}
