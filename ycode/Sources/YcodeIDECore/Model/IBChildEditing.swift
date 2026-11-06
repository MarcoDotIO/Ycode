import Foundation

/// Inserting child elements byte-minimally: new lines go in at the
/// parent's indentation plus one level, before a chosen child or last, and
/// a self-closing parent is opened. Used by Library inserts and by
/// inspector edits that add value elements (`interface-builder.md`
/// §Editing, `library.md` §Insert defaults, canonical child order).
extension IBDocument {
    /// The byte offset where the line holding `i` starts.
    func lineStart(_ i: Int) -> Int {
        var k = i
        while k > 0, source[k - 1] != 0x0A { k -= 1 }
        return k
    }

    /// Whether only spaces or tabs come before byte `i` on its line.
    func onlySpacesBefore(_ i: Int) -> Bool {
        var k = i
        while k > 0, source[k - 1] != 0x0A {
            if source[k - 1] != 0x20 && source[k - 1] != 0x09 { return false }
            k -= 1
        }
        return true
    }

    /// Lines (depth, text) as text at an indentation, each ending in a newline.
    static func text(_ lines: [(Int, String)], indent: String) -> String {
        lines.map { indent + String(repeating: "    ", count: $0.0) + $0.1 + "\n" }.joined()
    }

    /// An edit adding `lines` as children of `node`, before its first child
    /// that `before` accepts, else after the last one. A self-closing
    /// `node` gets an end tag.
    func childInsertion(_ lines: [(Int, String)], into node: XMLSourceNode, before: (XMLSourceNode) -> Bool = { _ in false }) -> XMLEdit {
        let base = XMLEdit.indentation(of: node, in: source)
        let inner = base + "    "
        if node.selfClosing {
            let close = node.startTag.upperBound
            return XMLEdit(close - 2..<close, ">\n" + Self.text(lines, indent: inner) + base + "</\(node.name)>")
        }
        if let c = node.children.first(where: before), onlySpacesBefore(c.startTag.lowerBound) {
            let at = lineStart(c.startTag.lowerBound)
            return XMLEdit(at..<at, Self.text(lines, indent: inner))
        }
        let end = node.endTag?.lowerBound ?? node.startTag.upperBound
        if onlySpacesBefore(end) {
            let at = lineStart(end)
            return XMLEdit(at..<at, Self.text(lines, indent: inner))
        }
        return XMLEdit(end..<end, "\n" + Self.text(lines, indent: inner) + base)
    }

    /// An edit appending `lines` to the container element `name` of `node`
    /// (`subviews`, `items`, `prototypes`, `connections`, …), making the
    /// container before the first child `containerBefore` accepts when it
    /// is missing.
    func containerInsertion(_ lines: [(Int, String)], container name: String, of node: XMLSourceNode,
                            containerBefore: (XMLSourceNode) -> Bool = { _ in false }) -> XMLEdit {
        if let c = node.child(name) { return childInsertion(lines, into: c) }
        return childInsertion([(0, "<\(name)>")] + lines.map { ($0.0 + 1, $0.1) } + [(0, "</\(name)>")], into: node, before: containerBefore)
    }

    /// Children that come after `subviews` in the canonical order
    /// (`library.md` §Insert defaults, item 1): the safe area, the
    /// background colour, constraints, then connections and the like.
    static func comesAfterSubviews(_ n: XMLSourceNode) -> Bool {
        if n.name == "viewLayoutGuide" { return n["key"] == "safeArea" }
        if n.name == "color" { return n["key"] == "backgroundColor" }
        return ["constraints", "connections", "userDefinedRuntimeAttributes", "variation", "accessibility", "keyCommands"].contains(n.name)
    }

    /// Children that come after a view's kind children: `subviews` and
    /// everything after it.
    static func comesAfterKindChildren(_ n: XMLSourceNode) -> Bool { n.name == "subviews" || comesAfterSubviews(n) }

    /// Children that come after value elements (`fontDescription`,
    /// colours, sizes): kind children and everything after them.
    static func comesAfterValues(_ n: XMLSourceNode) -> Bool {
        let values: Set<String> = ["rect", "autoresizingMask", "fontDescription", "font", "color", "nil", "size", "string", "attributedString", "inset", "point"]
        if n.name == "color" { return n["key"] == "backgroundColor" }
        return !values.contains(n.name)
    }

    /// System colours named by `<color systemColor=…>`, in file order.
    var usedSystemColors: [String] {
        var used: [String] = []
        documentNode.walk { n in if n.name == "color", let s = n["systemColor"], !used.contains(s) { used.append(s) } }
        return used
    }

    /// Adds `<systemColor>` resources for system colours an edit started
    /// using (not in `before`) that the document does not define (Ycode's
    /// own table of their public values). Colours the document already used
    /// are left as they were.
    func addingSystemColorResources(since before: IBDocument) throws -> IBDocument {
        let old = Set(before.usedSystemColors)
        var defined = Set<String>()
        documentNode.walk { n in if n.name == "systemColor", let s = n["name"] { defined.insert(s) } }
        let missing = usedSystemColors.filter { !old.contains($0) && !defined.contains($0) && Self.systemColorValues[$0] != nil }
        guard !missing.isEmpty else { return self }
        let lines = missing.sorted().flatMap { name -> [(Int, String)] in
            [(0, "<systemColor name=\"\(name)\">"), (1, Self.systemColorValues[name]!), (0, "</systemColor>")]
        }
        if let r = documentNode.child("resources") { return try edited([childInsertion(lines, into: r)]) }
        return try edited([containerInsertion(lines, container: "resources", of: documentNode)])
    }

    /// The colours Ycode can write by name, with their public component
    /// values (as published for UIKit's system colours, light appearance).
    static let systemColorValues: [String: String] = [
        "systemBackgroundColor": "<color white=\"1\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"genericGamma22GrayColorSpace\"/>",
        "systemGroupedBackgroundColor": "<color red=\"0.94901960784313721\" green=\"0.94901960784313721\" blue=\"0.96862745098039216\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"sRGB\"/>",
        "labelColor": "<color white=\"0.0\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"genericGamma22GrayColorSpace\"/>",
        "secondaryLabelColor": "<color red=\"0.23529411764705882\" green=\"0.23529411764705882\" blue=\"0.2627450980392157\" alpha=\"0.59999999999999998\" colorSpace=\"custom\" customColorSpace=\"sRGB\"/>",
        "systemBlueColor": "<color red=\"0.0\" green=\"0.47843137254901963\" blue=\"1\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"sRGB\"/>",
        "systemRedColor": "<color red=\"1\" green=\"0.23137254901960785\" blue=\"0.18823529411764706\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"sRGB\"/>",
        "systemGreenColor": "<color red=\"0.20392156862745098\" green=\"0.7803921568627451\" blue=\"0.34901960784313724\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"sRGB\"/>",
        "systemOrangeColor": "<color red=\"1\" green=\"0.58431372549019611\" blue=\"0.0\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"sRGB\"/>",
        "systemYellowColor": "<color red=\"1\" green=\"0.80000000000000004\" blue=\"0.0\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"sRGB\"/>",
        "systemGrayColor": "<color red=\"0.55686274509803924\" green=\"0.55686274509803924\" blue=\"0.57647058823529407\" alpha=\"1\" colorSpace=\"custom\" customColorSpace=\"sRGB\"/>",
    ]
}
