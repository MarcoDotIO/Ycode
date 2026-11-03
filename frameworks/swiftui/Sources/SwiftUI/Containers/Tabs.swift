import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// TabView (round R9; 06 §2.3).
//
// Measured: only the selected tab is built at launch; selecting another tab
// creates it, its `onAppear` running before the old tab's `onDisappear` in
// the same update, without animation; returning to a tab runs its
// `onAppear` again; tab content is laid out under the floating tab bar (the
// bar does not add to the safe area).
//
// Design (Ycode's): tabs, once built, keep their state while not selected
// (they are suspended, like covered navigation pages). The tab bar is a
// floating capsule centred 8 points above the bottom edge: one item per tab,
// a symbol over a caption, the selected item in the tint.

/// A tab of a `TabView`.
public struct Tab<Value: Hashable, Content: View, Label: View>: View {
    let value: Value?
    let label: Label
    let content: Content
    public var body: some View { content }
}

extension Tab where Label == DefaultTabLabel {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, value: Value, @ViewBuilder content: () -> Content) {
        self.value = value
        label = DefaultTabLabel(title: Text(titleKey), systemImage: systemImage)
        self.content = content()
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, systemImage: String, value: Value, @ViewBuilder content: () -> Content) {
        self.value = value
        label = DefaultTabLabel(title: Text(title), systemImage: systemImage)
        self.content = content()
    }
}

extension Tab where Label == DefaultTabLabel, Value == Never {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        value = nil
        label = DefaultTabLabel(title: Text(titleKey), systemImage: systemImage)
        self.content = content()
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, systemImage: String, @ViewBuilder content: () -> Content) {
        value = nil
        label = DefaultTabLabel(title: Text(title), systemImage: systemImage)
        self.content = content()
    }
}

/// The label of a `Tab` made from a title and a symbol.
public struct DefaultTabLabel: View {
    let title: Text
    let systemImage: String
    public var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
            title.font(.caption2)
        }
    }
}

/// What a tab's view tells the tab view.
@MainActor
protocol TabDescribing {
    var _tabValue: AnyHashable? { get }
    var _tabLabel: AnyView { get }
}

extension Tab: TabDescribing {
    var _tabValue: AnyHashable? { value.map(AnyHashable.init) }
    var _tabLabel: AnyView { AnyView(label) }
}

struct TabItemModifier: ViewModifier {
    let label: AnyView
    func body(content: Content) -> some View { content }
}

extension View {
    /// The tab bar item of this view in a `TabView` (the older form).
    public func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> some View {
        modifier(TabItemModifier(label: AnyView(VStack(spacing: 2) { label() }.font(.caption2).labelStyle(TabItemLabelStyle()))))
    }

    public func tabViewStyle<S: TabViewStyle>(_ style: S) -> some View { self }
}

/// Labels in tab items: the icon over the title.
struct TabItemLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

/// How a tab view looks (accepted; one look).
@MainActor @preconcurrency
public protocol TabViewStyle {}

public struct DefaultTabViewStyle: TabViewStyle { public init() {} }
public struct PageTabViewStyle: TabViewStyle {
    public struct IndexDisplayMode: Sendable, Equatable {
        let kind: Int
        public static let automatic = IndexDisplayMode(kind: 0)
        public static let always = IndexDisplayMode(kind: 1)
        public static let never = IndexDisplayMode(kind: 2)
    }
    public init(indexDisplayMode: IndexDisplayMode = .automatic) {}
}
public struct SidebarAdaptableTabViewStyle: TabViewStyle { public init() {} }
public struct TabBarOnlyTabViewStyle: TabViewStyle { public init() {} }

extension TabViewStyle where Self == DefaultTabViewStyle {
    public static var automatic: DefaultTabViewStyle { DefaultTabViewStyle() }
}

extension TabViewStyle where Self == PageTabViewStyle {
    public static var page: PageTabViewStyle { PageTabViewStyle() }
    public static func page(indexDisplayMode: PageTabViewStyle.IndexDisplayMode) -> PageTabViewStyle {
        PageTabViewStyle(indexDisplayMode: indexDisplayMode)
    }
}

extension TabViewStyle where Self == SidebarAdaptableTabViewStyle {
    public static var sidebarAdaptable: SidebarAdaptableTabViewStyle { SidebarAdaptableTabViewStyle() }
}

extension TabViewStyle where Self == TabBarOnlyTabViewStyle {
    public static var tabBarOnly: TabBarOnlyTabViewStyle { TabBarOnlyTabViewStyle() }
}

final class TabViewState {
    var selectedIndex = 0
    var built: Set<AnyHashable> = []
}

/// Tabs with a tab bar (06 §2.3).
public struct TabView<SelectionValue: Hashable, Content: View>: View {
    let content: Content
    let selection: Binding<SelectionValue>?
    public typealias Body = Never
}

extension TabView {
    public init(selection: Binding<SelectionValue>?, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = selection
    }
}

extension TabView where SelectionValue == Int {
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
        selection = nil
    }
}

struct TabDescription {
    let key: AnyHashable
    let value: AnyHashable?
    let label: AnyView
    let content: any View
}

extension TabView: PrimitiveView {
    private func state(_ node: ViewNode) -> TabViewState {
        if let s = node.primitiveState as? TabViewState { return s }
        let s = TabViewState()
        node.primitiveState = s
        return s
    }

    private func tabs() -> [TabDescription] {
        enumeratedViews(content).enumerated().map { i, pair in
            let (key, view) = pair
            if let t = view as? any TabDescribing {
                return TabDescription(key: key, value: t._tabValue ?? AnyHashable(i), label: t._tabLabel, content: view)
            }
            var label = AnyView(Text("Tab \(i + 1)"))
            var v: any View = view
            for _ in 0..<32 {
                guard let m = v as? any ModifiedContentInspecting else { break }
                if let t = m._inspectedModifier as? TabItemModifier { label = t.label }
                v = m._inspectedContent
            }
            let tag = RowTraits(view).tag
            return TabDescription(key: key, value: tag ?? AnyHashable(i), label: label, content: view)
        }
    }

    private func selectedIndex(_ s: TabViewState, _ tabs: [TabDescription]) -> Int {
        if let b = selection {
            let v = AnyHashable(b.wrappedValue)
            return tabs.firstIndex { $0.value == v } ?? 0
        }
        return min(s.selectedIndex, max(0, tabs.count - 1))
    }

    package func _makeChildren(node: ViewNode, old: TabView?, transaction: Transaction) {
        let s = state(node)
        let tabs = node.trackContent { self.tabs() }
        let sel = node.trackContent { selectedIndex(s, tabs) }
        guard !tabs.isEmpty else {
            node.reconcileChildren([], transaction: transaction)
            return
        }
        s.built.insert(tabs[sel].key)
        let selection = self.selection
        let choose: (Int) -> Void = { [weak node] i in
            guard let node else { return }
            if let b = selection, let v = tabs[i].value?.base as? SelectionValue {
                b.wrappedValue = v
            } else {
                s.selectedIndex = i
                node.invalidate(transaction: Transaction())
            }
        }
        var items: [(AnyHashable, any View)] = []
        for t in tabs where s.built.contains(t.key) { items.append((t.key, t.content)) }
        items.append((AnyHashable("tab bar"), TabBar(labels: tabs.map(\.label), selected: sel, choose: choose)))
        node.reconcileChildren(items, transaction: transaction)
        // The selected tab is shown, the others keep their state (06 §2.3:
        // the new tab appears before the old one disappears).
        for (k, c) in zip(node.childKeys, node.children) where k != AnyHashable("tab bar") {
            c.setSuspended(k != tabs[sel].key)
        }
        s.built = Set(tabs.map(\.key)).intersection(s.built)
    }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty { _makeChildren(node: node, old: self, transaction: transaction) } else {
            node.refreshChildren(transaction: transaction)
        }
    }

    package func _lower(node: ViewNode) -> [LayoutNode] {
        var layers: [LayoutNode] = []
        var bar: LayoutNode?
        for (k, c) in zip(node.childKeys, node.children) {
            if k == AnyHashable("tab bar") {
                let ns = c.lower()
                bar = ns.count == 1 ? ns[0] : .zstack(ns)
            } else if !c.isSuspended {
                let ns = c.lower()
                let n: LayoutNode = ns.count == 1 ? ns[0] : .zstack(ns)
                layers.append(n.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity))
            }
        }
        var base = LayoutNode.zstack(layers)
        if let bar { base = base.overlay(bar.padding(.bottom, 8), alignment: .bottom) }
        return [base.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)]
    }
}

/// The floating tab bar.
struct TabBar: View {
    let labels: [AnyView]
    let selected: Int
    let choose: (Int) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ControlPalette(scheme)
        HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { pair in
                let i = pair.offset
                Button { choose(i) } label: {
                    pair.element
                        .frame(minWidth: 64, minHeight: 44)
                        .foregroundStyle(i == selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background { Capsule().fill(palette.barBackground) }
        .overlay { Capsule().strokeBorder(palette.separator, lineWidth: 1 / 3).allowsHitTesting(false) }
    }
}

extension TabView: GraphInputComparable {
    nonisolated package func _isGraphInputEqual(to other: Any) -> Bool { false }
}
