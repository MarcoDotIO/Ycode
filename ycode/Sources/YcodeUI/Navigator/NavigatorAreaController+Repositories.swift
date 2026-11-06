import AppKit
import YcodeIDECore

/// The Source Control navigator's first view (`navigators.md` round 3 §2,
/// checklist row 82): only the repository and Branches open; the other
/// groups stay collapsed until opened, and a refresh keeps what the person
/// opened.
extension NavigatorAreaController {
    /// The Changes | Repositories control's inset from each side.
    static let modeControlInset = CGFloat(RepositoriesViewStyle.modeControlInset)

    /// The keys of the expanded Source Control rows (nil: none shown yet).
    func expandedSourceControlKeys() -> Set<String>? {
        // Only a refresh of the Repositories tree keeps them (not the
        // switch from Changes).
        guard isViewLoaded, selectedIndex == 1, outline.numberOfRows > 0, Self.isRepositoriesTree(shownRoots) else { return nil }
        var keys = Set<String>()
        for r in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: r) as? OutlineItem, outline.isItemExpanded(item) else { continue }
            keys.insert(Self.expansionKey(item))
        }
        return keys
    }

    static func isRepositoriesTree(_ roots: [OutlineItem]) -> Bool {
        roots.contains { $0.children.contains { $0.scmKey == "group:Branches" } }
    }

    static func expansionKey(_ item: OutlineItem) -> String { item.scmKey ?? "title:" + item.title }

    /// Expands the Source Control rows: `kept` (a refresh), or the first
    /// view's rule; the Changes tree opens fully.
    func expandSourceControlRows(keeping kept: Set<String>?) {
        let roots = shownRoots
        guard Self.isRepositoriesTree(roots) else { outline.expandItem(nil, expandChildren: true); return }
        func walk(_ item: OutlineItem) {
            let open = kept.map { $0.contains(Self.expansionKey(item)) } ?? SourceControlNavigatorModel.expandsInitially(item)
            guard open else { return }
            outline.expandItem(item)
            item.children.forEach(walk)
        }
        roots.forEach(walk)
    }
}
