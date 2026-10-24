import Foundation

/// Byte-minimal edits of an Interface Builder document: each returns new
/// file bytes in which only the touched attributes or the inserted
/// element differ. See `specs/ide/interface-builder.md` §Editing.
extension IBDocument {
    /// Objects the Library can insert.
    public enum NewObject: String, CaseIterable, Sendable {
        case label = "Label", button = "Button", textField = "Text Field", imageView = "Image View", view = "View", stackView = "Stack View"

        public var defaultSize: CGSize {
            switch self {
            case .label: CGSize(width: 100, height: 21)
            case .button: CGSize(width: 90, height: 32)
            case .textField: CGSize(width: 150, height: 24)
            case .imageView: CGSize(width: 64, height: 64)
            case .view: CGSize(width: 160, height: 120)
            case .stackView: CGSize(width: 160, height: 40)
            }
        }
    }

    /// Number text as written in frames: whole numbers without a fraction
    /// (`400`), zero as `0.0`, others with up to two decimals.
    public static func number(_ v: CGFloat) -> String {
        let r = (v * 100).rounded() / 100
        if r == 0 { return "0.0" }
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.2f", Double(r))
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    /// A fresh object ID in the `abc-de-fgh` form (3-2-3 letters and
    /// digits), unused in the document.
    public func makeObjectID<G: RandomNumberGenerator>(using g: inout G) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        while true {
            func part(_ n: Int) -> String { String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count, using: &g)] }) }
            let id = "\(part(3))-\(part(2))-\(part(3))"
            if byID[id] == nil && !String(decoding: source, as: UTF8.self).contains("\"\(id)\"") { return id }
        }
    }

    public func makeObjectID() -> String {
        var g = SystemRandomNumberGenerator()
        return makeObjectID(using: &g)
    }

    func edited(_ edits: [XMLEdit?]) throws -> IBDocument {
        let list = edits.compactMap { $0 }
        return list.isEmpty ? self : try IBDocument(data: Data(XMLEdit.apply(list, to: source)))
    }

    // MARK: Frames

    /// Writes a frame (in the parent's coordinates, as stored).
    public func settingFrame(_ f: CGRect, of id: String) throws -> IBDocument {
        guard let n = byID[id]?.frameNode else { return self }
        return try edited([("x", f.minX), ("y", f.minY), ("width", f.width), ("height", f.height)].map {
            XMLEdit.setAttribute($0.0, Self.number($0.1), on: n, in: source)
        })
    }

    /// A frame given in root-view coordinates (top-left), converted to the
    /// parent's stored coordinates.
    public func storedFrame(forRootFrame r: CGRect, of id: String) -> CGRect? {
        guard let o = byID[id], let p = o.parent, p.isView, let pr = frameInRoot(p), let pf = p.frame else {
            return byID[id].map { CGRect(origin: $0.frame?.origin ?? .zero, size: r.size) }
        }
        let localTop = r.minY - pr.minY
        let y = isFlippedRuntime ? localTop : pf.height - localTop - r.height
        return CGRect(x: r.minX - pr.minX, y: y, width: r.width, height: r.height)
    }

    // MARK: Attributes

    /// The object holding text-like attributes: the cell when there is one.
    func cell(of o: Object) -> Object? { o.children.first { $0.key == "cell" } }

    /// The title or text shown by a control: `title` (object or cell) or
    /// `text`; for iOS buttons the `normal` state's `title`.
    public func title(of id: String) -> String? {
        guard let o = byID[id] else { return nil }
        if let t = o.attribute("title") ?? o.attribute("text") { return t }
        if let c = cell(of: o), let t = c.attribute("title") { return t }
        return o.node.child("state", key: "normal")?["title"]
    }

    public func settingTitle(_ value: String, of id: String) throws -> IBDocument {
        guard let o = byID[id] else { return self }
        if o.attribute("text") != nil || o.element == "label" { return try edited([XMLEdit.setAttribute("text", value, on: o.node, in: source)]) }
        if o.attribute("title") != nil { return try edited([XMLEdit.setAttribute("title", value, on: o.node, in: source)]) }
        if let c = cell(of: o) { return try edited([XMLEdit.setAttribute("title", value, on: c.node, in: source)]) }
        if let state = o.node.child("state", key: "normal") { return try edited([XMLEdit.setAttribute("title", value, on: state, in: source)]) }
        return try edited([XMLEdit.setAttribute("title", value, on: o.node, in: source)])
    }

    public func placeholder(of id: String) -> String? {
        guard let o = byID[id] else { return nil }
        return o.attribute("placeholder") ?? cell(of: o)?.attribute("placeholderString")
    }

    public func settingPlaceholder(_ value: String?, of id: String) throws -> IBDocument {
        guard let o = byID[id] else { return self }
        let v = value?.isEmpty == true ? nil : value
        if let c = cell(of: o) { return try edited([XMLEdit.setAttribute("placeholderString", v, on: c.node, in: source)]) }
        return try edited([XMLEdit.setAttribute("placeholder", v, on: o.node, in: source)])
    }

    /// `hidden="YES"` on the view; absent means visible.
    public func isHidden(_ id: String) -> Bool { byID[id]?.attribute("hidden") == "YES" }

    public func settingHidden(_ hidden: Bool, of id: String) throws -> IBDocument {
        guard let o = byID[id] else { return self }
        return try edited([XMLEdit.setAttribute("hidden", hidden ? "YES" : nil, on: o.node, in: source)])
    }

    /// `enabled="NO"` on the cell (macOS) or the control; absent means enabled.
    public func isEnabled(_ id: String) -> Bool {
        guard let o = byID[id] else { return true }
        return (cell(of: o)?.attribute("enabled") ?? o.attribute("enabled")) != "NO"
    }

    public func settingEnabled(_ enabled: Bool, of id: String) throws -> IBDocument {
        guard let o = byID[id] else { return self }
        return try edited([XMLEdit.setAttribute("enabled", enabled ? nil : "NO", on: (cell(of: o) ?? o).node, in: source)])
    }

    /// Text alignment: the cell's `alignment` (macOS) or `textAlignment`.
    public func alignment(of id: String) -> String? {
        guard let o = byID[id] else { return nil }
        return cell(of: o)?.attribute("alignment") ?? o.attribute("textAlignment")
    }

    public func settingAlignment(_ value: String, of id: String) throws -> IBDocument {
        guard let o = byID[id] else { return self }
        if let c = cell(of: o) { return try edited([XMLEdit.setAttribute("alignment", value, on: c.node, in: source)]) }
        return try edited([XMLEdit.setAttribute("textAlignment", value, on: o.node, in: source)])
    }

    // MARK: Inserting

    /// Element lines for a new object (depth, text), per runtime.
    func template(_ kind: NewObject, id: String, frame f: CGRect, ids: () -> String) -> [(Int, String)] {
        let rect = "<rect key=\"frame\" x=\"\(Self.number(f.minX))\" y=\"\(Self.number(f.minY))\" width=\"\(Self.number(f.width))\" height=\"\(Self.number(f.height))\"/>"
        let tamic = "translatesAutoresizingMaskIntoConstraints=\"NO\""
        if isFlippedRuntime {
            switch kind {
            case .label:
                return [(0, "<label opaque=\"NO\" userInteractionEnabled=\"NO\" contentMode=\"left\" text=\"Label\" textAlignment=\"natural\" lineBreakMode=\"tailTruncation\" \(tamic) id=\"\(id)\">"),
                        (1, rect), (0, "</label>")]
            case .button:
                return [(0, "<button opaque=\"NO\" contentMode=\"scaleToFill\" contentHorizontalAlignment=\"center\" contentVerticalAlignment=\"center\" buttonType=\"system\" \(tamic) id=\"\(id)\">"),
                        (1, rect), (1, "<state key=\"normal\" title=\"Button\"/>"), (0, "</button>")]
            case .textField:
                return [(0, "<textField opaque=\"NO\" contentHorizontalAlignment=\"left\" contentVerticalAlignment=\"center\" borderStyle=\"roundedRect\" textAlignment=\"natural\" minimumFontSize=\"17\" \(tamic) id=\"\(id)\">"),
                        (1, rect), (0, "</textField>")]
            case .imageView:
                return [(0, "<imageView clipsSubviews=\"YES\" userInteractionEnabled=\"NO\" contentMode=\"scaleAspectFit\" \(tamic) id=\"\(id)\">"), (1, rect), (0, "</imageView>")]
            case .view:
                return [(0, "<view contentMode=\"scaleToFill\" \(tamic) id=\"\(id)\">"), (1, rect), (0, "</view>")]
            case .stackView:
                return [(0, "<stackView opaque=\"NO\" contentMode=\"scaleToFill\" \(tamic) id=\"\(id)\">"), (1, rect), (0, "</stackView>")]
            }
        }
        switch kind {
        case .label:
            return [(0, "<textField focusRingType=\"none\" horizontalHuggingPriority=\"251\" verticalHuggingPriority=\"750\" \(tamic) id=\"\(id)\">"),
                    (1, rect), (1, "<textFieldCell key=\"cell\" lineBreakMode=\"clipping\" title=\"Label\" id=\"\(ids())\">"),
                    (2, "<font key=\"font\" metaFont=\"system\"/>"), (1, "</textFieldCell>"), (0, "</textField>")]
        case .button:
            return [(0, "<button verticalHuggingPriority=\"750\" \(tamic) id=\"\(id)\">"), (1, rect),
                    (1, "<buttonCell key=\"cell\" type=\"push\" title=\"Button\" bezelStyle=\"rounded\" alignment=\"center\" borderStyle=\"border\" imageScaling=\"proportionallyDown\" inset=\"2\" id=\"\(ids())\">"),
                    (2, "<font key=\"font\" metaFont=\"system\"/>"), (1, "</buttonCell>"), (0, "</button>")]
        case .textField:
            return [(0, "<textField focusRingType=\"none\" verticalHuggingPriority=\"750\" \(tamic) id=\"\(id)\">"), (1, rect),
                    (1, "<textFieldCell key=\"cell\" scrollable=\"YES\" lineBreakMode=\"clipping\" selectable=\"YES\" editable=\"YES\" sendsActionOnEndEditing=\"YES\" borderStyle=\"bezel\" drawsBackground=\"YES\" id=\"\(ids())\">"),
                    (2, "<font key=\"font\" metaFont=\"system\"/>"), (1, "</textFieldCell>"), (0, "</textField>")]
        case .imageView:
            return [(0, "<imageView horizontalHuggingPriority=\"251\" verticalHuggingPriority=\"251\" \(tamic) id=\"\(id)\">"), (1, rect),
                    (1, "<imageCell key=\"cell\" refusesFirstResponder=\"YES\" alignment=\"left\" imageScaling=\"proportionallyDown\" id=\"\(ids())\"/>"),
                    (0, "</imageView>")]
        case .view:
            return [(0, "<customView \(tamic) id=\"\(id)\">"), (1, rect), (0, "</customView>")]
        case .stackView:
            return [(0, "<stackView distribution=\"fill\" orientation=\"horizontal\" alignment=\"top\" spacing=\"8\" \(tamic) id=\"\(id)\">"),
                    (1, rect), (0, "</stackView>")]
        }
    }

    /// Inserts a new object as the last subview of `parentID`, with a frame
    /// in the parent's stored coordinates. Returns the document and new ID.
    public func inserting(_ kind: NewObject, into parentID: String, frame: CGRect) throws -> (IBDocument, String) {
        guard let parent = byID[parentID], parent.isView, let frameNode = parent.frameNode else { return (self, "") }
        var taken = Set<String>()
        var g = SystemRandomNumberGenerator()
        func fresh() -> String {
            while true { let id = makeObjectID(using: &g); if taken.insert(id).inserted { return id } }
        }
        let id = fresh()
        let lines = template(kind, id: id, frame: frame, ids: fresh)
        if let subviews = parent.node.child("subviews"), let end = subviews.endTag {
            let indent = XMLEdit.indentation(of: subviews, in: source) + "    "
            var lineStart = end.lowerBound
            while lineStart > 0, source[lineStart - 1] != 0x0A { lineStart -= 1 }
            let text = lines.map { indent + String(repeating: "    ", count: $0.0) + $0.1 + "\n" }.joined()
            return (try edited([XMLEdit(lineStart..<lineStart, text)]), id)
        }
        let indent = XMLEdit.indentation(of: frameNode, in: source)
        let text = "\n" + indent + "<subviews>\n" + lines.map { indent + "    " + String(repeating: "    ", count: $0.0) + $0.1 + "\n" }.joined()
            + indent + "</subviews>"
        let at = frameNode.range.upperBound
        return (try edited([XMLEdit(at..<at, text)]), id)
    }
}
