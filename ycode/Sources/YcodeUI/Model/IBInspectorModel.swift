import Foundation

/// The Interface Builder inspectors as data (reference-ui-4.md §13): the
/// sections and rows for Identity, Attributes, Size and Connections, each
/// editable row naming the XML attribute it reads and writes. Attribute
/// names are storyboard file-format facts and public UIKit property names
/// (§18 item 1).
public struct IBInspectorSection: Equatable {
    public var title: String
    public var rows: [IBInspectorRow]
    public init(_ title: String, _ rows: [IBInspectorRow]) { self.title = title; self.rows = rows }
}

public enum IBInspectorRow: Equatable {
    /// A text field writing `attribute` on object `target` (nil value removes).
    case text(label: String, target: String, attribute: String, value: String, placeholder: String)
    /// A checkbox; `onValue`/`offValue` are what is written (nil = removed).
    case toggle(label: String, target: String, attribute: String, isOn: Bool, onValue: String?, offValue: String?)
    /// A pop-up of values; the first option is the default (written as removal).
    case choice(label: String, target: String, attribute: String, options: [String], value: String)
    /// Read-only.
    case info(label: String, value: String)
    /// A runtime attribute row (key path, type, value).
    case runtimeAttribute(keyPath: String, type: String, value: String)
    /// A constraint: "<kind> to: <item>" with its ID (Edit button).
    case constraint(text: String, id: String)
    /// A connection row: name, the other end (empty = unconnected), the
    /// connection ID (× disconnects), ending in a connection circle.
    case connection(name: String, other: String, id: String?)
    /// A frame component (X, Y, Width, Height) with a stepper; edits the
    /// object's `<rect key="frame">`.
    case frameValue(label: String, target: String, component: String, value: String)
    /// Extend Edges ▸ Under Top / Bottom Bars: one edge of the controller's
    /// `edgesForExtendedLayout`.
    case edgeToggle(label: String, target: String, edge: String, isOn: Bool)

    public var label: String {
        switch self {
        case .text(let l, _, _, _, _), .toggle(let l, _, _, _, _, _), .choice(let l, _, _, _, _), .info(let l, _): return l
        case .runtimeAttribute(let k, _, _): return k
        case .constraint(let t, _): return t
        case .connection(let n, _, _): return n
        case .frameValue(let l, _, _, _), .edgeToggle(let l, _, _, _): return l
        }
    }
}

extension IBDocument {
    public struct RuntimeAttribute: Equatable, Sendable {
        public var keyPath: String
        public var type: String
        public var value: String
    }

    // MARK: Generic attribute edits

    /// Sets (nil removes) one attribute of an object.
    public func settingAttribute(_ name: String, _ value: String?, of id: String) throws -> IBDocument {
        guard let o = byID[id] else { return self }
        return try edited([XMLEdit.setAttribute(name, value, on: o.node, in: source)])
    }

    /// Is Initial View Controller: the document's `initialViewController`.
    public func settingInitial(_ id: String?) throws -> IBDocument {
        try edited([XMLEdit.setAttribute("initialViewController", id, on: documentNode, in: source)])
    }

    // MARK: User Defined Runtime Attributes

    /// The object's User Defined Runtime Attributes, in file order; empty
    /// for an unknown ID.
    public func runtimeAttributes(of id: String) -> [RuntimeAttribute] {
        guard let n = byID[id]?.node.child("userDefinedRuntimeAttributes") else { return [] }
        return n.children.filter { $0.name == "userDefinedRuntimeAttribute" }.map {
            let v = $0["value"] ?? $0.children.first.flatMap { c in c["value"] ?? c.attributes.first { $0.name != "key" }?.value } ?? ""
            return RuntimeAttribute(keyPath: $0["keyPath"] ?? "", type: $0["type"] ?? "", value: v)
        }
    }

    /// Adds `<userDefinedRuntimeAttribute type keyPath value/>` (creating
    /// the container as the object's first child element when absent).
    public func addingRuntimeAttribute(_ a: RuntimeAttribute, to id: String) throws -> IBDocument {
        guard let o = byID[id] else { return self }
        var line = "<userDefinedRuntimeAttribute type=\"\(XMLSource.encode(a.type))\" keyPath=\"\(XMLSource.encode(a.keyPath))\""
        line += a.value.isEmpty ? "/>" : " value=\"\(XMLSource.encode(a.value))\"/>"
        if let c = o.node.child("userDefinedRuntimeAttributes"), let end = c.endTag {
            let indent = XMLEdit.indentation(of: c, in: source) + "    "
            var ls = end.lowerBound
            while ls > 0, source[ls - 1] != 0x0A { ls -= 1 }
            return try edited([XMLEdit(ls..<ls, indent + line + "\n")])
        }
        let base = XMLEdit.indentation(of: o.node, in: source) + "    "
        if o.node.selfClosing {
            // `<x …/>` → `<x …>` + container + `</x>`.
            let close = o.node.startTag.upperBound
            let tagEnd = XMLEdit(close - 2..<close, ">\n" + base + "<userDefinedRuntimeAttributes>\n" + base + "    " + line + "\n" + base
                                 + "</userDefinedRuntimeAttributes>\n" + XMLEdit.indentation(of: o.node, in: source) + "</\(o.element)>")
            return try edited([tagEnd])
        }
        let at = o.node.startTag.upperBound
        return try edited([XMLEdit(at..<at, "\n" + base + "<userDefinedRuntimeAttributes>\n" + base + "    " + line + "\n" + base + "</userDefinedRuntimeAttributes>")])
    }

    /// Removes the runtime attribute `keyPath`, and the container element when
    /// it was the last one. Returns `self` when there is nothing to remove.
    public func removingRuntimeAttribute(_ keyPath: String, of id: String) throws -> IBDocument {
        guard let c = byID[id]?.node.child("userDefinedRuntimeAttributes"),
              let n = c.children.first(where: { $0["keyPath"] == keyPath }) else { return self }
        let doomed = c.children.count == 1 ? c : n
        return try edited([XMLEdit(lineRange(of: doomed), "")])
    }

    // MARK: Connections

    /// Removes a connection element (outlet, action, segue) by ID; an
    /// emptied `connections` element goes too.
    public func removingConnection(_ id: String) throws -> IBDocument {
        var hit: XMLSourceNode?
        documentNode.walk { n in
            if hit == nil, ["outlet", "action", "segue", "outletCollection"].contains(n.name), n["id"] == id { hit = n }
        }
        guard let n = hit else { return self }
        return try edited(removals([n]))
    }

    // MARK: Sections

    /// The segue kinds the Attributes inspector offers, in menu order.
    public static let segueKinds = ["Relationship", "Show", "Show Detail", "Present Modally", "Present As Popover", "Embed",
                                    "Push (deprecated)", "Modal (deprecated)", "Custom"]

    func isController(_ o: Object) -> Bool { o.element.hasSuffix("Controller") || o.attribute("sceneMemberID") == "viewController" }

    /// The base class an object's Class field shows as its placeholder.
    public static func baseClass(_ element: String) -> String {
        let ios = ["viewController": "UIViewController", "view": "UIView", "label": "UILabel", "button": "UIButton",
                   "imageView": "UIImageView", "textField": "UITextField", "navigationController": "UINavigationController",
                   "tableViewController": "UITableViewController", "tableView": "UITableView", "stackView": "UIStackView"]
        return ios[element] ?? "UI" + words(element).replacingOccurrences(of: " ", with: "")
    }

    /// The Identity inspector's sections for object `id`; empty when unknown.
    public func identitySections(_ id: String) -> [IBInspectorSection] {
        guard let o = byID[id] else { return [] }
        var out = [IBInspectorSection("Custom Class", [
            .text(label: "Class", target: id, attribute: "customClass", value: o.attribute("customClass") ?? "", placeholder: Self.baseClass(o.element)),
            .text(label: "Module", target: id, attribute: "customModule", value: o.attribute("customModule") ?? "", placeholder: "None"),
            .toggle(label: "Inherit Module From Target", target: id, attribute: "customModuleProvider",
                    isOn: o.attribute("customModuleProvider") == "target", onValue: "target", offValue: nil),
        ])]
        do {
            out.append(IBInspectorSection("Identity", [
                .text(label: "Storyboard ID", target: id, attribute: "storyboardIdentifier", value: o.attribute("storyboardIdentifier") ?? "", placeholder: ""),
                .text(label: "Restoration ID", target: id, attribute: "restorationIdentifier", value: o.attribute("restorationIdentifier") ?? "", placeholder: ""),
                .toggle(label: "Use Storyboard ID", target: id, attribute: "useStoryboardIdentifierAsRestorationIdentifier",
                        isOn: o.attribute("useStoryboardIdentifierAsRestorationIdentifier") == "YES", onValue: "YES", offValue: nil),
            ]))
        }
        out.append(IBInspectorSection("User Defined Runtime Attributes",
                                      runtimeAttributes(of: id).map { .runtimeAttribute(keyPath: $0.keyPath, type: $0.type, value: $0.value) }))
        out.append(IBInspectorSection("Document", [
            .text(label: "Label", target: id, attribute: "userLabel", value: o.attribute("userLabel") ?? "", placeholder: "Xcode Specific Label"),
            .info(label: "Object ID", value: o.id),
            .info(label: "Lock", value: "Inherited - (Nothing)"),
            .text(label: "Localizer Hint", target: id, attribute: "comment", value: o.attribute("comment") ?? "", placeholder: "Comment For Localizer"),
        ]))
        return out
    }

    /// The Attributes inspector's sections for object `id`; empty when unknown.
    public func attributesSections(_ id: String) -> [IBInspectorSection] {
        guard let o = byID[id] else { return [] }
        func t(_ l: String, _ a: String, _ ph: String = "") -> IBInspectorRow { .text(label: l, target: id, attribute: a, value: o.attribute(a) ?? "", placeholder: ph) }
        func b(_ l: String, _ a: String, default on: Bool = false) -> IBInspectorRow {
            let v = o.attribute(a)
            return .toggle(label: l, target: id, attribute: a, isOn: v.map { $0 == "YES" } ?? on, onValue: on ? nil : "YES", offValue: on ? "NO" : nil)
        }
        func c(_ l: String, _ a: String, _ opts: [String]) -> IBInspectorRow { .choice(label: l, target: id, attribute: a, options: opts, value: o.attribute(a) ?? opts[0]) }
        if isController(o) {
            let metric = ["Inferred"]
            return [
                IBInspectorSection("Simulated Metrics", ["Size", "Top Bar", "Bottom Bar", "Keyboard"].map { .info(label: $0, value: metric[0]) }),
                IBInspectorSection("View Controller", [
                    t("Title", "title"),
                    .toggle(label: "Is Initial View Controller", target: id, attribute: "initialViewController", isOn: initialViewController == id, onValue: id, offValue: nil),
                    t("Activity Name", "userActivityType"),
                ]),
                IBInspectorSection("Layout", [b("Adjust Scroll View Insets", "automaticallyAdjustsScrollViewInsets", default: true),
                                              b("Hide Bottom Bar on Push", "hidesBottomBarWhenPushed"),
                                              b("Resize View From NIB", "autoresizesArchivedViewToFullSize", default: true),
                                              b("Use Full Screen (Deprecated)", "wantsFullScreenLayout")]),
                IBInspectorSection("Extend Edges", [.edgeToggle(label: "Under Top Bars", target: id, edge: "top", isOn: extendedEdge(o, "top")),
                                                    .edgeToggle(label: "Under Bottom Bars", target: id, edge: "bottom", isOn: extendedEdge(o, "bottom")),
                                                    b("Under Opaque Bars", "extendedLayoutIncludesOpaqueBars")]),
                IBInspectorSection("Presentation", [c("Transition Style", "modalTransitionStyle", ["coverVertical", "flipHorizontal", "crossDissolve", "partialCurl"]),
                                                    c("Presentation", "modalPresentationStyle", ["automatic", "fullScreen", "pageSheet", "formSheet", "currentContext", "overFullScreen", "overCurrentContext", "popover"]),
                                                    b("Defines Context", "definesPresentationContext"),
                                                    b("Provides Context", "providesPresentationContextTransitionStyle")]),
                IBInspectorSection("Content Size", [b("Use Preferred Explicit Size", "usesPreferredContentSize"),
                                                    .info(label: "Width", value: property(o, "size", key: "preferredContentSize")?["width"] ?? "0"),
                                                    .info(label: "Height", value: property(o, "size", key: "preferredContentSize")?["height"] ?? "0")]),
                IBInspectorSection("Key Commands", keyCommands(o).flatMap { [.info(label: "Key", value: $0.input), .info(label: "Selector", value: $0.action)] }),
            ]
        }
        var out: [IBInspectorSection] = []
        if o.element == "label" {
            let offset = property(o, "size", key: "shadowOffset")
            out.append(IBInspectorSection("Label", [
                .info(label: "Text", value: o.node.child("attributedString") != nil ? "Attributed" : "Plain"), t("", "text"),
                .info(label: "Color", value: colorDescription(o, key: "textColor", default: "Default (Label Color)")),
                .info(label: "Font", value: fontDescription(o)),
                b("Dynamic Type", "adjustsFontForContentSizeCategory"),
                c("Alignment", "textAlignment", ["natural", "left", "center", "right", "justified"]),
                t("Lines", "numberOfLines", "1"),
                b("Enabled", "enabled", default: true), b("Highlighted", "highlighted"),
                t("Tooltip", "toolTip"),
                c("Baseline", "baselineAdjustment", ["alignBaselines", "alignCenters", "none"]),
                c("Line Break", "lineBreakMode", ["tailTruncation", "headTruncation", "middleTruncation", "wordWrap", "characterWrap", "clip"]),
                c("Strategy", "lineBreakStrategy", ["standard", "pushOut", "hangulWordPriority", "none"]),
                b("Autoshrink", "adjustsFontSizeToFit"),
                b("Tighten Letter Spacing", "allowsDefaultTighteningForTruncation"),
                c("Sizing Rule", "sizingRule", ["typographic", "oversize"]),
                .info(label: "Highlighted Color", value: colorDescription(o, key: "highlightedColor", default: "Default")),
                .info(label: "Shadow", value: colorDescription(o, key: "shadowColor", default: "Default")),
                .info(label: "Shadow Offset", value: "\(offset?["width"] ?? "0"), \(offset?["height"] ?? "-1")"),
            ]))
        }
        if o.isView {
            out.append(IBInspectorSection("View", [
                c("Content Mode", "contentMode", ["scaleToFill", "scaleAspectFit", "scaleAspectFill", "redraw", "center", "top", "bottom", "left", "right"]),
                c("Semantic", "semanticContentAttribute", ["unspecified", "playback", "spatial", "forceLeftToRight", "forceRightToLeft"]),
                t("Tag", "tag", "0"),
                b("User Interaction Enabled", "userInteractionEnabled", default: true), b("Multiple Touch", "multipleTouchEnabled"),
                t("Alpha", "alpha", "1"),
                b("Opaque", "opaque", default: true), b("Hidden", "hidden"), b("Clears Graphics Context", "clearsContextBeforeDrawing", default: true),
                b("Clips to Bounds", "clipsSubviews"),
                .info(label: "Background", value: colorDescription(o, key: "backgroundColor", default: "Default")),
                .info(label: "Tint", value: colorDescription(o, key: "tintColor", default: "Default")),
                .info(label: "Stretching", value: ["x", "y", "width", "height"].map { property(o, "rect", key: "contentStretch")?[$0] ?? ($0 == "width" || $0 == "height" ? "1" : "0") }
                    .joined(separator: ", ")),
            ]))
        }
        return out
    }

    /// `<extendedEdge key="edgesForExtendedLayout" top=… bottom=…/>`; absent = all edges.
    func extendedEdge(_ o: Object, _ edge: String) -> Bool {
        guard let n = o.node.children.first(where: { $0["key"] == "edgesForExtendedLayout" }) else { return true }
        return n[edge] == "YES"
    }

    /// "<kind> to: <item>" for a constraint seen from `id`.
    public func constraintSummary(_ c: Constraint, from id: String) -> String {
        let mine = c.firstItem == id
        let attr = mine ? c.firstAttribute : (c.secondAttribute ?? c.firstAttribute)
        let other = mine ? c.secondItem : c.firstItem
        let kind: String
        switch attr {
        case "leading", "trailing", "top", "bottom", "left", "right": kind = attr.prefix(1).uppercased() + attr.dropFirst() + " Space"
        case "centerX": kind = "Align Center X"
        case "centerY": kind = "Align Center Y"
        case "width": kind = "Width Equals"
        case "height": kind = "Height Equals"
        default: kind = Self.words(attr)
        }
        if other == nil { return "\(kind): \(c.constant)" }
        return "\(kind) to: \(name(other))"
    }

    /// The Size inspector's sections for object `id`; empty when unknown.
    public func sizeSections(_ id: String) -> [IBInspectorSection] {
        guard let o = byID[id] else { return [] }
        if isController(o) { return [IBInspectorSection("Simulated Size", [.info(label: "Simulated Size", value: "Fixed")])] }
        var out: [IBInspectorSection] = []
        if let f = o.frame {
            out.append(IBInspectorSection("View", [
                .info(label: "Show", value: "Frame Rectangle"),
                .frameValue(label: "X", target: id, component: "x", value: Self.number(f.minX)),
                .frameValue(label: "Y", target: id, component: "y", value: Self.number(f.minY)),
                .frameValue(label: "Width", target: id, component: "width", value: Self.number(f.width)),
                .frameValue(label: "Height", target: id, component: "height", value: Self.number(f.height)),
                .info(label: "Arrange", value: "Align and Fill"),
                .info(label: "Layout", value: "Inferred (Constraints)"),
                .info(label: "Layout Margins", value: layoutMargins(o)),
                .toggle(label: "Preserve Superview Margins", target: id, attribute: "preservesSuperviewLayoutMargins",
                        isOn: o.attribute("preservesSuperviewLayoutMargins") == "YES", onValue: "YES", offValue: nil),
                .toggle(label: "Follow Readable Width", target: id, attribute: "readableContentGuide",
                        isOn: o.attribute("readableContentGuide") == "YES", onValue: "YES", offValue: nil),
                .toggle(label: "Safe Area Relative Margins", target: id, attribute: "insetsLayoutMarginsFromSafeArea",
                        isOn: o.attribute("insetsLayoutMarginsFromSafeArea") != "NO", onValue: nil, offValue: "NO"),
            ]))
        }
        let cs = constraints(involving: id)
        let horizontal: Set<String> = ["leading", "trailing", "left", "right", "centerX", "width", "leadingMargin", "trailingMargin", "centerXWithinMargins"]
        func isH(_ c: Constraint) -> Bool { horizontal.contains(c.firstItem == id ? c.firstAttribute : (c.secondAttribute ?? c.firstAttribute)) }
        var rows: [IBInspectorRow] = [.info(label: "Scope", value: "All | This Size Class")]
        for (title, part) in [("Horizontal", cs.filter(isH)), ("Vertical", cs.filter { !isH($0) })] where !part.isEmpty {
            rows.append(.info(label: title, value: ""))
            rows += part.map { .constraint(text: constraintSummary($0, from: id), id: $0.id) }
        }
        rows.append(.info(label: "Showing \(cs.count) of \(cs.count)", value: ""))
        out.append(IBInspectorSection("Constraints", rows))
        if o.isView {
            func p(_ l: String, _ a: String, _ d: String) -> IBInspectorRow { .text(label: l, target: id, attribute: a, value: o.attribute(a) ?? d, placeholder: d) }
            out.append(IBInspectorSection("Content Hugging Priority", [p("Horizontal", "horizontalHuggingPriority", "250"), p("Vertical", "verticalHuggingPriority", "250")]))
            out.append(IBInspectorSection("Content Compression Resistance Priority",
                                          [p("Horizontal", "horizontalCompressionResistancePriority", "750"), p("Vertical", "verticalCompressionResistancePriority", "750")]))
            out.append(IBInspectorSection("", [.info(label: "Intrinsic Size", value: "Default (System Defined)"), .info(label: "Ambiguity", value: "Always Verify")]))
        }
        return out
    }

    /// The Connections inspector's sections for object `id`; empty when unknown.
    public func connectionsSections(_ id: String) -> [IBInspectorSection] {
        guard let o = byID[id] else { return [] }
        func rows(_ k: Connection.Kind) -> [IBInspectorRow] { o.connections.filter { $0.kind == k }.map { .connection(name: $0.name, other: name($0.other), id: $0.id) } }
        var out = [IBInspectorSection("Triggered Segues", rows(.segue)), IBInspectorSection("Outlets", rows(.outlet))]
        if o.connections.contains(where: { $0.kind == .action }) { out.append(IBInspectorSection("Sent Actions", rows(.action))) }
        if isController(o) {
            let segues = incomingConnections(to: id).filter { $0.connection.kind == .segue }
            out.append(IBInspectorSection("Presenting Segues", Self.segueKinds.map { k in
                let hit = segues.first { Self.segueTitle($0.connection.name) == k }
                return .connection(name: k, other: hit.map { $0.from.displayName } ?? "", id: hit?.connection.id)
            }))
        }
        let incoming = incomingConnections(to: id)
        out.append(IBInspectorSection("Referencing Outlets", incoming.filter { $0.connection.kind == .outlet }.map {
            .connection(name: $0.connection.name, other: $0.from.displayName, id: $0.connection.id)
        } + [.connection(name: "New Referencing Outlet", other: "", id: nil)]))
        out.append(IBInspectorSection("Referencing Outlet Collections", incoming.filter { $0.connection.kind == .outletCollection }.map {
            .connection(name: $0.connection.name, other: $0.from.displayName, id: $0.connection.id)
        } + [.connection(name: "New Referencing Outlet Collection", other: "", id: nil)]))
        return out
    }

    /// Segue `kind` attribute → the menu title.
    public static func segueTitle(_ kind: String) -> String {
        ["relationship": "Relationship", "show": "Show", "showDetail": "Show Detail", "presentation": "Present Modally",
         "popoverPresentation": "Present As Popover", "embed": "Embed", "push": "Push (deprecated)", "modal": "Modal (deprecated)",
         "custom": "Custom"][kind] ?? kind
    }
}

// MARK: Value-only child elements (reference-ui-4.md §13 leftovers, P14)

extension IBDocument {
    /// A value-only child element's attributes (`<color key="textColor" …/>`).
    func property(_ o: Object, _ element: String, key: String) -> [String: String]? {
        // Properties are recorded as "<element> (<key>)" without the key.
        guard let p = o.properties.first(where: { $0.0 == "\(element) (\(key))" }) else { return nil }
        return Dictionary(p.1.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
    }

    /// "Label Color" for a named system color, "Custom" for components.
    func colorDescription(_ o: Object, key: String, default d: String) -> String {
        guard let c = property(o, "color", key: key) else { return d }
        if let name = c["systemColor"] ?? c["name"] { return Self.words(name).capitalized }
        if let w = c["white"] { return w == "1" ? "White" : w == "0" ? "Black" : "Custom" }
        return "Custom"
    }

    /// "System 17.0", "Headline", or "Default".
    func fontDescription(_ o: Object) -> String {
        guard let f = property(o, "fontDescription", key: "fontDescription") else { return "Default" }
        if let style = f["style"] { return Self.words(style.replacingOccurrences(of: "UICTFontTextStyle", with: "")).capitalized }
        let size = f["pointSize"].flatMap(Double.init).map { String(format: "%.1f", $0) } ?? ""
        let type = f["type"].map { Self.words($0).capitalized } ?? f["name"] ?? "System"
        return [type, size].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Layout Margins: Default, Fixed (`layoutMargins` insets) or Language
    /// Directional (`directionalLayoutMargins`).
    func layoutMargins(_ o: Object) -> String {
        if property(o, "directionalEdgeInsets", key: "directionalLayoutMargins") != nil { return "Language Directional" }
        if property(o, "edgeInsets", key: "layoutMargins") != nil { return "Fixed" }
        return "Default"
    }

    /// Key commands (`<keyCommand input=… action=…/>` children of `keyCommands`).
    func keyCommands(_ o: Object) -> [(input: String, action: String)] {
        (o.node.child("keyCommands")?.children ?? []).filter { $0.name == "keyCommand" }.map { ($0["input"] ?? "", $0["action"] ?? "") }
    }

    /// Writes one frame component.
    public func settingFrameComponent(_ component: String, _ value: CGFloat, of id: String) throws -> IBDocument {
        guard let f = byID[id]?.frame else { return self }
        var r = f
        switch component {
        case "x": r.origin.x = value
        case "y": r.origin.y = value
        case "width": r.size.width = max(0, value)
        default: r.size.height = max(0, value)
        }
        return try settingFrame(r, of: id)
    }

    /// Under Top / Bottom Bars: edits `<extendedEdge key="edgesForExtendedLayout">`.
    /// Absent means every edge; the element, once written, lists the edges
    /// that stay included.
    public func settingExtendedEdge(_ edge: String, _ on: Bool, of id: String) throws -> IBDocument {
        guard let o = byID[id] else { return self }
        if let n = o.node.children.first(where: { $0.name == "extendedEdge" && $0["key"] == "edgesForExtendedLayout" }) {
            return try edited([XMLEdit.setAttribute(edge, on ? "YES" : nil, on: n, in: source)])
        }
        guard !on else { return self }
        let kept = ["top", "left", "bottom", "right"].filter { $0 != edge }
        let line = "<extendedEdge key=\"edgesForExtendedLayout\"" + kept.map { " \($0)=\"YES\"" }.joined() + "/>"
        let base = XMLEdit.indentation(of: o.node, in: source) + "    "
        if let end = o.node.endTag {
            var ls = end.lowerBound
            while ls > 0, source[ls - 1] != 0x0A { ls -= 1 }
            return try edited([XMLEdit(ls..<ls, base + line + "\n")])
        }
        let close = o.node.startTag.upperBound
        return try edited([XMLEdit(close - 2..<close, ">\n" + base + line + "\n" + XMLEdit.indentation(of: o.node, in: source) + "</\(o.element)>")])
    }
}
