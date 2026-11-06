#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Inserting Library objects (`interface-builder.md` §Inserting objects,
/// `library.md` §Insert defaults): views go into a view's `subviews`
/// (made before the safe area, background colour and constraints when
/// missing); controllers become new scenes (storyboards) or top-level
/// objects (xibs); cells, bar items, menus and gesture recognizers go into
/// the nearest object that can hold them. Only the new lines are added.
extension IBDocument {
    /// One edit's fresh IDs: unused in the document and in the edit.
    struct IDMaker {
        let document: IBDocument
        var taken = Set<String>()
        var generator = SystemRandomNumberGenerator()

        mutating func make() -> String {
            while true {
                let id = document.makeObjectID(using: &generator)
                if taken.insert(id).inserted { return id }
            }
        }
    }

    /// Where views inserted into `o` go: a cell's or an effect view's
    /// content view, else `o`.
    public func subviewContainer(_ o: Object) -> Object {
        if ["tableViewCell", "collectionViewCell", "visualEffectView"].contains(o.element),
           let c = o.children.first(where: { $0.key == "contentView" }) { return c }
        return o
    }

    /// Inserts a view as the last subview of `parentID`, with a frame in the
    /// parent's stored coordinates. Returns the document and the new ID, or
    /// `(self, "")` when the parent is not a view.
    public func inserting(_ kind: NewObject, into parentID: String, frame: CGRect) throws -> (IBDocument, String) {
        guard let parent = byID[parentID], parent.isView else { return (self, "") }
        var maker = IDMaker(document: self)
        let id = maker.make()
        var ids: [String: String] = [:]
        var edits: [XMLEdit] = []
        if kind == .containerView, isFlippedRuntime, isStoryboard {
            // The embedded controller: its own scene, as big as the container.
            let controller = maker.make()
            ids["@5"] = controller
            ids["@6"] = maker.make()
            var inner: [String: String] = [:]
            let vc = Self.expand(Self.iosTemplate(.viewController), id: controller, frame: CGRect(origin: .zero, size: frame.size), storyboard: true,
                                 ids: &inner, fresh: { maker.make() })
            edits.append(sceneInsertion(vc, title: "View Controller", maker: &maker))
        }
        let template = isFlippedRuntime ? Self.iosTemplate(kind) : Self.macTemplate(kind)
        let lines = Self.expand(template, id: id, frame: frame, storyboard: isStoryboard, ids: &ids, fresh: { maker.make() })
        edits.append(containerInsertion(lines, container: "subviews", of: parent.node, containerBefore: Self.comesAfterSubviews))
        return (try edited(edits).addingSystemColorResources(since: self), id)
    }

    /// A new scene holding `lines` (a controller) and a First Responder,
    /// after the last scene, with a title comment; its canvas location is
    /// right of the rightmost scene.
    func sceneInsertion(_ lines: [(Int, String)], title: String, maker: inout IDMaker) -> XMLEdit {
        let located = roots.compactMap(\.canvasLocation)
        let x = located.map(\.x).max().map { $0 + 520 } ?? CGFloat(roots.count) * 520
        let y = located.max { $0.x < $1.x }?.y ?? 0
        let scene: [(Int, String)] = [(0, "<!--\(title)-->"), (0, "<scene sceneID=\"\(maker.make())\">"), (1, "<objects>")]
            + lines.map { ($0.0 + 2, $0.1) }
            + [(2, "<placeholder placeholderIdentifier=\"IBFirstResponder\" id=\"\(maker.make())\" userLabel=\"First Responder\" customClass=\"UIResponder\" sceneMemberID=\"firstResponder\"/>"),
               (1, "</objects>"), (1, "<point key=\"canvasLocation\" x=\"\(Self.number(x))\" y=\"\(Self.number(y))\"/>"), (0, "</scene>")]
        return containerInsertion(scene, container: "scenes", of: documentNode, containerBefore: { $0.name == "resources" })
    }

    /// The xib's top-level `objects`, or a storyboard scene's.
    func objectsInsertion(_ lines: [(Int, String)], scene: Object?) -> XMLEdit? {
        if isStoryboard {
            guard let s = scene ?? roots.first, let objects = s.node.child("objects") else { return nil }
            return childInsertion(lines, into: objects)
        }
        return containerInsertion(lines, container: "objects", of: documentNode, containerBefore: { $0.name == "resources" })
    }

    /// `lines` with `key="…"` as the first element's first attribute.
    static func keyed(_ lines: [(Int, String)], _ key: String) -> [(Int, String)] {
        guard var first = lines.first, let space = first.1.firstIndex(of: " ") else { return lines }
        first.1.insert(contentsOf: " key=\"\(key)\"", at: space)
        return [first] + lines.dropFirst()
    }

    /// Inserts an object that is not placed as a subview (controllers,
    /// cells, bar items, menus, gesture recognizers, scene objects), next to
    /// the object `targetID` (the selection): into it, an ancestor, or a
    /// descendant that can hold it. Returns `(self, "")` when nothing can.
    public func inserting(_ kind: NewObject, near targetID: String?) throws -> (IBDocument, String) {
        var maker = IDMaker(document: self)
        let id = maker.make()
        var ids: [String: String] = [:]
        func lines(_ f: CGRect = .zero) -> [(Int, String)] {
            Self.expand(Self.iosTemplate(kind), id: id, frame: f, storyboard: isStoryboard, ids: &ids, fresh: { maker.make() })
        }
        let target = targetID.flatMap { byID[$0] }
        func up(_ p: (Object) -> Bool) -> Object? {
            var o = target
            while let c = o { if p(c) { return c }; o = c.parent }
            return nil
        }
        func near(_ p: (Object) -> Bool) -> Object? {
            if let u = up(p) { return u }
            var hit: Object?
            target?.walk { if hit == nil, p($0) { hit = $0 } }
            return hit
        }
        let controller = up(isController) ?? near(isController)
        let scene = up { $0.element == "scene" }
        func navigationItem() -> Object? {
            if let n = up({ $0.element == "navigationItem" }) { return n }
            if let bar = near({ $0.element == "navigationBar" }), let n = bar.children.first(where: { $0.element == "navigationItem" }) { return n }
            return controller?.children.first { $0.element == "navigationItem" }
        }
        let afterKind: (XMLSourceNode) -> Bool = { Self.comesAfterKindChildren($0) }
        var edits: [XMLEdit?] = []
        switch kind.placement {
        case .subview, .topLevel:
            let size = kind.size(parentWidth: 393)
            let ls = lines(CGRect(origin: .zero, size: kind.placement == .topLevel ? size : size))
            edits.append(objectsInsertion(ls, scene: nil))
        case .scene:
            if isStoryboard {
                edits.append(sceneInsertion(lines(CGRect(x: 0, y: 0, width: 393, height: 852)), title: kind.rawValue, maker: &maker))
            } else {
                edits.append(objectsInsertion(lines(CGRect(x: 0, y: 0, width: 393, height: 852)), scene: nil))
            }
        case .sceneObject:
            edits.append(objectsInsertion(lines(), scene: scene))
        case .gesture:
            let view = up { $0.isView } ?? IBEditorSession.firstView(in: self)
            let home = view.flatMap { v -> Object? in var o: Object? = v; while let c = o, c.element != "scene" { o = c.parent }; return o }
            edits.append(objectsInsertion(lines(), scene: scene ?? home))
            if let v = view {
                let link = "<outletCollection property=\"gestureRecognizers\" destination=\"\(id)\" appends=\"YES\" id=\"\(maker.make())\"/>"
                edits.append(containerInsertion([(0, link)], container: "connections", of: v.node))
            }
        case .tableCell:
            guard let table = near({ $0.element == "tableView" }), let tf = table.frame else { return (self, "") }
            let y = table.children.filter { $0.element == "tableViewCell" }.compactMap(\.frame).map(\.maxY).max() ?? 0
            let f = CGRect(x: 0, y: y, width: tf.width, height: kind.info.height ?? 44)
            edits.append(containerInsertion(lines(f), container: "prototypes", of: table.node,
                                            containerBefore: { ["connections", "constraints", "subviews"].contains($0.name) }))
        case .collectionCell:
            guard let cv = near({ $0.element == "collectionView" }) else { return (self, "") }
            let n = cv.children.filter { $0.element == "collectionViewCell" }.count
            let f = CGRect(x: CGFloat(n % 2) * 138, y: CGFloat(n / 2) * 138, width: 128, height: 128)
            edits.append(containerInsertion(lines(f), container: "cells", of: cv.node,
                                            containerBefore: { $0.name == "collectionReusableView" || Self.comesAfterKindChildren($0) }))
        case .reusableView:
            guard let cv = near({ $0.element == "collectionView" }), let cf = cv.frame else { return (self, "") }
            let has = { (k: String) in cv.children.contains { $0.key == k } }
            guard !has("sectionHeaderView") || !has("sectionFooterView") else { return (self, "") }
            let key = has("sectionHeaderView") ? "sectionFooterView" : "sectionHeaderView"
            let h = kind.info.height ?? 50
            let f = CGRect(x: 0, y: key == "sectionHeaderView" ? 0 : max(0, cf.height - h), width: cf.width, height: h)
            edits.append(childInsertion(Self.keyed(lines(f), key), into: cv.node, before: afterKind))
        case .barItem:
            if let bar = near({ $0.element == "toolbar" }) {
                edits.append(containerInsertion(lines(), container: "items", of: bar.node, containerBefore: afterKind))
            } else if let nav = navigationItem() {
                let has = { (k: String) in nav.children.contains { $0.key == k } }
                guard !has("rightBarButtonItem") || !has("leftBarButtonItem") else { return (self, "") }
                edits.append(childInsertion(Self.keyed(lines(), has("rightBarButtonItem") ? "leftBarButtonItem" : "rightBarButtonItem"), into: nav.node))
            } else {
                return (self, "")
            }
        case .barItemGroup:
            guard let nav = navigationItem() else { return (self, "") }
            edits.append(containerInsertion(lines(), container: "centerItemGroups", of: nav.node))
        case .navigationItem:
            if let bar = near({ $0.element == "navigationBar" && $0.isView }) {
                edits.append(containerInsertion(lines(), container: "items", of: bar.node, containerBefore: afterKind))
            } else if let vc = controller, !vc.children.contains(where: { $0.key == "navigationItem" }) {
                edits.append(childInsertion(Self.keyed(lines(), "navigationItem"), into: vc.node, before: { $0.name == "connections" }))
            } else {
                return (self, "")
            }
        case .tabBarItem:
            if let bar = near({ $0.element == "tabBar" && $0.key != "tabBar" }) {
                edits.append(containerInsertion(lines(), container: "items", of: bar.node, containerBefore: afterKind))
            } else if let vc = controller, !vc.children.contains(where: { $0.key == "tabBarItem" }) {
                edits.append(childInsertion(Self.keyed(lines(), "tabBarItem"), into: vc.node, before: { $0.name == "connections" }))
            } else {
                return (self, "")
            }
        case .menuElement:
            if let menu = up({ $0.element == "menu" }) {
                edits.append(containerInsertion(lines(), container: "children", of: menu.node))
            } else if let button = up({ $0.element == "button" }) {
                let wrapped = [(0, "<menu key=\"menu\" id=\"\(maker.make())\">"), (1, "<children>")] + lines().map { ($0.0 + 2, $0.1) } + [(1, "</children>"), (0, "</menu>")]
                edits.append(childInsertion(wrapped, into: button.node, before: { $0.name == "state" || $0.name == "buttonConfiguration" || afterKind($0) }))
            } else {
                return (self, "")
            }
        }
        let list = edits.compactMap { $0 }
        guard !list.isEmpty else { return (self, "") }
        return (try edited(list).addingSystemColorResources(since: self), id)
    }
}
