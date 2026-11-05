import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Context menus (round R11; public API: `contextMenu(menuItems:)`,
// `contextMenu(menuItems:preview:)`, `contextMenu(forSelectionType:menu:
// primaryAction:)`).
//
// Design (Ycode's): a `contextMenu` modifier registers its items with the
// window. A secondary click (mouse button 3) — or a touch held 0.5 s without
// moving more than 10 points — opens the items of the innermost view under
// the pointer that has a context menu, as an R8 pop-up menu at the pointer;
// the press in progress is cancelled (its buttons do not fire). Shift+F10
// opens the context menu of the focused view at its top-leading corner. A
// list's `contextMenu(forSelectionType:)` gives each row a menu of the
// selection when the row is selected, else of the row alone (the selection
// is not changed); an empty set is passed for the empty area of the list.
// Menus whose content is empty are not opened. The preview of
// `contextMenu(menuItems:preview:)` is not shown on the desktop.

/// The context menus of one window.
@MainActor
package final class ContextMenuCenter {
    final class Registration {
        weak var node: ViewNode?
        var items: () -> AnyView?
        init(node: ViewNode, items: @escaping () -> AnyView?) {
            self.node = node
            self.items = items
        }
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]
    /// The long press in progress: pointer, start point and time.
    var pendingPress: (pointer: Int, start: CGPoint, deadline: TimeInterval)?
    /// Context menus opened (tests and tools).
    package private(set) var openedCount = 0

    package init() {}

    func register(_ node: ViewNode, items: @escaping () -> AnyView?) {
        registrations[ObjectIdentifier(node)] = Registration(node: node, items: items)
    }

    func unregister(_ node: ViewNode) { registrations[ObjectIdentifier(node)] = nil }

    /// The items of the innermost view with a context menu on `chain` (root
    /// first).
    func items(on chain: [ViewNode]) -> AnyView? {
        for n in chain.reversed() {
            if let r = registrations[ObjectIdentifier(n)], r.node === n, !n.isInSuspendedSubtree, let v = r.items() {
                return v
            }
        }
        return nil
    }

    var isEmpty: Bool { registrations.isEmpty }

    func noteOpened() { openedCount += 1 }
}

struct ContextMenuModifier: PrimitiveModifier {
    let items: @MainActor () -> AnyView?

    private final class State { weak var center: ContextMenuCenter? }

    private func sync(_ node: ViewNode) {
        let s = (node.primitiveState as? State) ?? State()
        node.primitiveState = s
        guard let center = node.environment._windowServices?.contextMenus else { return }
        s.center = center
        center.register(node, items: items)
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: ContextMenuModifier, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) { (node.primitiveState as? State)?.center?.unregister(node) }
}

extension View {
    /// Items shown in a menu on a secondary click or a long press.
    public func contextMenu<MenuItems: View>(@ViewBuilder menuItems: () -> MenuItems) -> some View {
        let items = AnyView(menuItems())
        return modifier(ContextMenuModifier(items: { items }))
    }

    /// The same; the preview is not shown on the desktop.
    public func contextMenu<M: View, P: View>(@ViewBuilder menuItems: () -> M, @ViewBuilder preview: () -> P) -> some View {
        contextMenu(menuItems: menuItems)
    }

    /// A context menu for the selected rows of a list (applied to the list).
    public func contextMenu<I: Hashable, M: View>(forSelectionType itemType: I.Type = I.self,
                                                  @ViewBuilder menu: @escaping (Set<I>) -> M,
                                                  primaryAction: ((Set<I>) -> Void)? = nil) -> some View {
        let make = ListContextMenu(make: { ids in
            let set = Set(ids.compactMap { $0.base as? I })
            return AnyView(menu(set))
        })
        return environment(\._listContextMenu, make)
            .modifier(ContextMenuModifier(items: { AnyView(menu([])) }))
    }
}

/// A list's selection context menu (rows read it from the environment).
struct ListContextMenu {
    let make: @MainActor ([AnyHashable]) -> AnyView
}

private enum ListContextMenuKey: EnvironmentKey { static let defaultValue: ListContextMenu? = nil }

extension EnvironmentValues {
    var _listContextMenu: ListContextMenu? {
        get { self[ListContextMenuKey.self] }
        set { self[ListContextMenuKey.self] = newValue }
    }
}

extension WindowHost {
    /// Opens the context menu under `point` (window points); true if one
    /// opened.
    @discardableResult
    package func openContextMenu(at point: CGPoint) -> Bool {
        if graph.needsUpdate { update() }
        let chain = gestures.hitPath(at: point)
        guard let items = services.contextMenus.items(on: chain), let popups = services.popups else { return false }
        gestures.cancel()
        // Anchored at the point: near the window's bottom it opens upward.
        guard popups.presentPopup(content: items, origin: point, anchor: CGRect(origin: point, size: .zero), minWidth: 160, chrome: .menu,
                                  fallbackKeys: nil, onDismiss: {}) != nil else {
            return false
        }
        services.contextMenus.noteOpened()
        return true
    }

    /// Shift+F10: the context menu of the focused view.
    func openContextMenuForFocus() -> Bool {
        guard let focused = services.focus.focusedNode else { return false }
        var chain: [ViewNode] = []
        var n: ViewNode? = focused
        while let x = n {
            chain.insert(x, at: 0)
            n = x.parent
        }
        guard let items = services.contextMenus.items(on: chain), let popups = services.popups else { return false }
        let f = HitTesting.frame(of: focused, mirrorWidth: nil) ?? .zero
        guard popups.presentPopup(content: items, origin: CGPoint(x: f.minX + 8, y: f.minY + 8), minWidth: 160, chrome: .menu,
                                  onDismiss: {}) != nil else { return false }
        services.contextMenus.noteOpened()
        return true
    }

    /// Long-press tracking for touches (0.5 s, 10 points).
    func trackContextPress(_ p: PointerEvent) {
        let center = services.contextMenus
        guard !center.isEmpty else { return }
        switch p.phase {
        case .down where p.kind != .mouse:
            center.pendingPress = (p.pointer, p.location, p.timestamp + 0.5)
            services.setTimer(center, at: p.timestamp + 0.5) { [weak self] _ in
                guard let self, let pending = self.services.contextMenus.pendingPress else { return }
                self.services.contextMenus.pendingPress = nil
                self.openContextMenu(at: pending.start)
            }
        case .moved:
            if let pending = center.pendingPress, pending.pointer == p.pointer,
               hypot(p.location.x - pending.start.x, p.location.y - pending.start.y) > 10 {
                center.pendingPress = nil
                services.setTimer(center, at: nil) { _ in }
            }
        case .up, .cancelled:
            if center.pendingPress?.pointer == p.pointer {
                center.pendingPress = nil
                services.setTimer(center, at: nil) { _ in }
            }
        default:
            break
        }
    }
}
