import Foundation

/// Document outline naming (reference-ui-4.md §11 item 2): "<Controller>
/// Scene" › "<Controller>" › "View" › "Safe Area", subviews by content
/// (with a kind badge) or class, then the scene's First Responder, Exit
/// and Storyboard Entry Point.
extension IBDocument {
    /// The outline row for the storyboard's initial-view-controller arrow.
    public static let entryPointTitle = "Storyboard Entry Point"

    /// Whether an object is a subview (a view inside another view), not a
    /// cell or a layout guide.
    func isSubview(_ o: Object) -> Bool {
        o.isView && o.parent?.isView == true && o.key != "cell"
    }

    /// The text a subview shows (title, text, its cell's title, placeholder).
    func content(of o: Object) -> String? {
        for a in ["title", "text", "placeholder"] { if let t = o.attribute(a), !t.isEmpty { return t } }
        if let t = o.children.first(where: { $0.key == "cell" })?.attribute("title"), !t.isEmpty { return t }
        if let t = o.node.children.first(where: { $0.name == "state" })?["title"], !t.isEmpty { return t }
        return nil
    }

    /// The document outline's title for an object: the user label, a fixed
    /// name (Safe Area, First Responder, Exit), a subview's content or class,
    /// else `displayName`.
    public func outlineTitle(_ o: Object) -> String {
        if let l = o.attribute("userLabel") { return l }
        if o.element == "viewLayoutGuide", o.key == "safeArea" { return "Safe Area" }
        if o.element == "placeholder", o.attribute("placeholderIdentifier") == "IBFirstResponder" { return "First Responder" }
        if o.element == "exit" { return "Exit" }
        if isSubview(o) { return content(of: o) ?? o.attribute("customClass") ?? Self.words(o.element) }
        return o.displayName
    }

    /// The kind badge after a subview named by its content ("Label").
    public func outlineBadge(_ o: Object) -> String? {
        guard o.attribute("userLabel") == nil, isSubview(o), content(of: o) != nil else { return nil }
        return o.attribute("customClass") ?? Self.words(o.element)
    }

    /// Children in outline order: the safe area first among a view's
    /// children; at scene level, controllers before First Responder and Exit.
    public func outlineChildren(_ o: Object) -> [Object] {
        func rank(_ c: Object) -> Int {
            if c.element == "viewLayoutGuide" { return 0 }
            if c.attribute("sceneMemberID") == "firstResponder" || c.attribute("placeholderIdentifier") == "IBFirstResponder" { return 2 }
            if c.element == "exit" || c.attribute("sceneMemberID") == "exit" { return 3 }
            return 1
        }
        return o.children.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// Whether a scene holds the initial view controller.
    public func isInitialScene(_ scene: Object) -> Bool {
        guard isStoryboard, let i = initialViewController else { return false }
        return scene.children.contains { $0.id == i }
    }

    /// Outline titles from the scene down to an object (the jump bar).
    public func outlinePath(to o: Object) -> [String] {
        var out: [String] = []
        var cur: Object? = o
        while let c = cur { out.insert(outlineTitle(c), at: 0); cur = c.parent }
        return out
    }
}
