import Foundation
import Observation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Toolbars (round R9 basics, R11 window toolbars): items register with the
// navigation page they are in and show in its bar (Navigation.swift).
// Leading placements (`navigation`, `topBarLeading`, `cancellationAction`)
// go after the back button, `principal` replaces the inline title, the
// others go to the trailing end in declaration order.
//
// R11 (Ycode's design): outside a navigation container, items go to the
// window toolbar, a bar of its own under the menu bar (WindowChrome.swift):
// leading placements at the leading end, `principal` (and `status`) centred,
// the rest (`automatic`, `primaryAction`, `secondaryAction`,
// `confirmationAction`, `destructiveAction`, `topBarTrailing`) at the
// trailing end in declaration order; `bottomBar` items in a bar at the bottom
// of the window. A flexible `ToolbarSpacer` pushes the items after it to the
// end of their side; a fixed one leaves 12 points. View > Hide Toolbar and
// `toolbar(.hidden, for: .windowToolbar)` hide it.

/// Where a toolbar item goes.
public struct ToolbarItemPlacement: Equatable, Sendable {
    let kind: Int
    public static let automatic = ToolbarItemPlacement(kind: 0)
    public static let principal = ToolbarItemPlacement(kind: 1)
    public static let navigation = ToolbarItemPlacement(kind: 2)
    public static let primaryAction = ToolbarItemPlacement(kind: 3)
    public static let secondaryAction = ToolbarItemPlacement(kind: 4)
    public static let status = ToolbarItemPlacement(kind: 5)
    public static let confirmationAction = ToolbarItemPlacement(kind: 6)
    public static let cancellationAction = ToolbarItemPlacement(kind: 7)
    public static let destructiveAction = ToolbarItemPlacement(kind: 8)
    public static let keyboard = ToolbarItemPlacement(kind: 9)
    public static let topBarLeading = ToolbarItemPlacement(kind: 10)
    public static let topBarTrailing = ToolbarItemPlacement(kind: 11)
    public static let bottomBar = ToolbarItemPlacement(kind: 12)
    public static let navigationBarLeading = ToolbarItemPlacement(kind: 10)
    public static let navigationBarTrailing = ToolbarItemPlacement(kind: 11)

    package var isLeading: Bool { self == .navigation || self == .topBarLeading || self == .cancellationAction }
}

/// One item of a toolbar as its bar shows it.
public struct ToolbarEntry {
    package let placement: ToolbarItemPlacement
    package let view: AnyView
    /// A `ToolbarSpacer`: nil for items, else whether it is flexible.
    package var spacer: Bool?
    package init(placement: ToolbarItemPlacement, view: AnyView, spacer: Bool? = nil) {
        self.placement = placement
        self.view = view
        self.spacer = spacer
    }

    /// The view a bar shows for the entry (spacers become spacers).
    @MainActor package var barView: AnyView {
        switch spacer {
        case true?: return AnyView(Spacer(minLength: 0))
        case false?: return AnyView(Color.clear.frame(width: 12, height: 1))
        case nil: return view
        }
    }
}

/// Toolbar content: items and groups, or a type whose `body` lists others
/// (R13: custom toolbar content types).
@MainActor @preconcurrency
public protocol ToolbarContent {
    associatedtype Body: ToolbarContent
    @ToolbarContentBuilder @MainActor @preconcurrency var body: Body { get }
    /// The items as bars show them; primitive content implements it, a
    /// custom type gets its body's.
    var _toolbarEntries: [ToolbarEntry] { get }
}

extension ToolbarContent {
    public var _toolbarEntries: [ToolbarEntry] { body._toolbarEntries }
}

extension ToolbarContent where Body == Never {
    public var body: Never { fatalError("\(Self.self) is primitive toolbar content") }
}

extension Never: ToolbarContent {
    public var _toolbarEntries: [ToolbarEntry] { [] }
}

/// Toolbar content whose items people may customise; OpenViews shows the
/// items without customisation.
@MainActor @preconcurrency
public protocol CustomizableToolbarContent: ToolbarContent where Body: CustomizableToolbarContent {}

extension Never: CustomizableToolbarContent {}

/// Builds toolbar content from items.
@MainActor @resultBuilder
public struct ToolbarContentBuilder {
    public static func buildBlock() -> TupleToolbarContent { TupleToolbarContent(entries: []) }

    public static func buildBlock<C: ToolbarContent>(_ content: C) -> C { content }

    public static func buildBlock<each C: ToolbarContent>(_ content: repeat each C) -> TupleToolbarContent {
        var entries: [ToolbarEntry] = []
        repeat entries += (each content)._toolbarEntries
        return TupleToolbarContent(entries: entries)
    }

    /// (An existential: the branch that is not taken gives no type.)
    public static func buildOptional(_ content: (any ToolbarContent)?) -> TupleToolbarContent {
        TupleToolbarContent(entries: content?._toolbarEntries ?? [])
    }

    public static func buildEither<C: ToolbarContent>(first: C) -> TupleToolbarContent {
        TupleToolbarContent(entries: first._toolbarEntries)
    }

    public static func buildEither<C: ToolbarContent>(second: C) -> TupleToolbarContent {
        TupleToolbarContent(entries: second._toolbarEntries)
    }

    public static func buildExpression<C: ToolbarContent>(_ content: C) -> C { content }

    public static func buildLimitedAvailability<C: ToolbarContent>(_ content: C) -> TupleToolbarContent {
        TupleToolbarContent(entries: content._toolbarEntries)
    }
}

/// Several toolbar items.
public struct TupleToolbarContent: CustomizableToolbarContent {
    public typealias Body = Never
    let entries: [ToolbarEntry]
    public var _toolbarEntries: [ToolbarEntry] { entries }
}

/// One toolbar item.
public struct ToolbarItem<ID, Content: View>: CustomizableToolbarContent {
    public typealias Body = Never
    let placement: ToolbarItemPlacement
    let content: Content
    public var _toolbarEntries: [ToolbarEntry] { [ToolbarEntry(placement: placement, view: AnyView(content))] }
}

extension ToolbarItem where ID == () {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }
}

extension ToolbarItem where ID == String {
    public init(id: String, placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }
}

/// Several views in one placement.
public struct ToolbarItemGroup<Content: View>: CustomizableToolbarContent {
    public typealias Body = Never
    let placement: ToolbarItemPlacement
    let content: Content

    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }

    public var _toolbarEntries: [ToolbarEntry] {
        [ToolbarEntry(placement: placement, view: AnyView(HStack(spacing: 12) { content }))]
    }
}

/// Space between toolbar items: flexible (pushes what follows to the end of
/// its side) or fixed (12 points).
public struct ToolbarSpacer: CustomizableToolbarContent {
    public typealias Body = Never
    let sizing: SpacerSizing
    let placement: ToolbarItemPlacement
    public init(_ sizing: SpacerSizing = .flexible, placement: ToolbarItemPlacement = .automatic) {
        self.sizing = sizing
        self.placement = placement
    }
    public var _toolbarEntries: [ToolbarEntry] {
        [ToolbarEntry(placement: placement, view: AnyView(EmptyView()), spacer: sizing == .flexible)]
    }

    public struct SpacerSizing: Sendable, Equatable {
        let kind: Int
        public static let flexible = SpacerSizing(kind: 0)
        public static let fixed = SpacerSizing(kind: 1)
    }
}

/// Where bar options apply.
public struct ToolbarPlacement: Equatable, Sendable {
    let kind: Int
    public static let automatic = ToolbarPlacement(kind: 0)
    public static let navigationBar = ToolbarPlacement(kind: 1)
    public static let bottomBar = ToolbarPlacement(kind: 2)
    public static let tabBar = ToolbarPlacement(kind: 3)
    public static let windowToolbar = ToolbarPlacement(kind: 4)
}

extension View {
    /// Toolbar items for the page this view is in (outside navigation
    /// containers: the window toolbar).
    public func toolbar<Content: ToolbarContent>(@ToolbarContentBuilder content: () -> Content) -> some View {
        let entries = content()._toolbarEntries
        return modifier(ToolbarRegistrationModifier(entries: entries))
    }

    /// Customizable toolbars: the items, without customization.
    public func toolbar<Content: ToolbarContent>(id: String, @ToolbarContentBuilder content: () -> Content) -> some View {
        toolbar(content: content)
    }

    /// Views as toolbar items (trailing).
    @_disfavoredOverload
    public func toolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let entries = [ToolbarEntry(placement: .automatic, view: AnyView(HStack(spacing: 12) { content() }))]
        return modifier(ToolbarRegistrationModifier(entries: entries))
    }

    /// Shows or hides the navigation bar of the page (`.hidden`), or the
    /// window toolbar (`.windowToolbar`).
    public func toolbar(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View {
        let hidden = visibility == .hidden && (bars.isEmpty || bars.contains(.navigationBar) || bars.contains(.automatic))
        let window = bars.contains(.windowToolbar) ? (visibility != .hidden) : nil
        return modifier(PageRegistrationModifier(apply: { p, _ in if p.barHidden != hidden { p.barHidden = hidden } },
                                                 remove: nil))
            .modifier(WindowToolbarVisibilityModifier(visible: window))
    }

    public func toolbarBackground(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }

    public func toolbarRole(_ role: ToolbarRole) -> some View { self }
}

/// A toolbar item the system adds by itself (R13: `toolbar(removing:)`).
public struct ToolbarDefaultItemKind: Sendable, Equatable {
    let kind: Int
    /// The split view's button that shows and hides the sidebar.
    public static let sidebarToggle = ToolbarDefaultItemKind(kind: 0)
    /// The window title (accepted; OpenViews shows the title in the window
    /// frame).
    public static let title = ToolbarDefaultItemKind(kind: 1)
}

private enum SidebarToggleRemovedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// `toolbar(removing: .sidebarToggle)` above a split view.
    var _sidebarToggleRemoved: Bool {
        get { self[SidebarToggleRemovedKey.self] }
        set { self[SidebarToggleRemovedKey.self] = newValue }
    }
}

extension View {
    /// Removes a toolbar item the system adds by itself, such as the split
    /// view's sidebar toggle (nil: none).
    public func toolbar(removing defaultItemKind: ToolbarDefaultItemKind?) -> some View {
        environment(\._sidebarToggleRemoved, defaultItemKind == .sidebarToggle)
    }
}

public struct ToolbarRole: Sendable, Equatable {
    let kind: Int
    public static let automatic = ToolbarRole(kind: 0)
    public static let navigationStack = ToolbarRole(kind: 1)
    public static let browser = ToolbarRole(kind: 2)
    public static let editor = ToolbarRole(kind: 3)
}

// MARK: - Window toolbar (R11)

/// The items of a window's toolbar (outside navigation containers).
@MainActor
@Observable
package final class WindowToolbarModel {
    package private(set) var groups: [ToolbarEntryGroup] = []
    /// View > Show/Hide Toolbar.
    package var isVisible = true
    @ObservationIgnored private var order: [ObjectIdentifier] = []

    package init() {}

    package var entries: [ToolbarEntry] { groups.flatMap(\.entries) }
    package var hasItems: Bool { groups.contains { !$0.entries.isEmpty } }

    func set(_ id: ObjectIdentifier, _ entries: [ToolbarEntry]?) {
        if let entries {
            if !order.contains(id) { order.append(id) }
            var g = groups.filter { $0.id != id }
            g.append(ToolbarEntryGroup(id: id, entries: entries))
            groups = order.compactMap { o in g.first { $0.id == o } }
        } else {
            order.removeAll { $0 == id }
            if groups.contains(where: { $0.id == id }) { groups.removeAll { $0.id == id } }
        }
    }
}

/// `toolbar { }`: the enclosing navigation page's bar, else the window
/// toolbar.
struct ToolbarRegistrationModifier: PrimitiveModifier {
    let entries: [ToolbarEntry]

    private final class Reg {
        weak var page: NavigationPageContext?
        weak var window: WindowToolbarModel?
    }

    private func sync(_ node: ViewNode) {
        let reg = (node.primitiveState as? Reg) ?? Reg()
        node.primitiveState = reg
        let id = ObjectIdentifier(node)
        if let page = node.environment._navigationPage {
            reg.page = page
            page.setToolbar(id, entries)
        } else if let window = node.environment._windowServices?.toolbar {
            reg.window = window
            window.set(id, entries)
        }
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: ToolbarRegistrationModifier, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) {
        guard let reg = node.primitiveState as? Reg else { return }
        let id = ObjectIdentifier(node)
        reg.page?.setToolbar(id, nil)
        reg.window?.set(id, nil)
    }
}

struct WindowToolbarVisibilityModifier: PrimitiveModifier {
    let visible: Bool?
    private func sync(_ node: ViewNode) {
        guard let visible, let t = node.environment._windowServices?.toolbar, t.isVisible != visible else { return }
        t.isVisible = visible
    }
    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: WindowToolbarVisibilityModifier, node: ViewNode) { if old.visible != visible { sync(node) } }
}

extension ToolbarItemPlacement {
    /// Where a window toolbar puts the placement: -1 leading, 0 centre,
    /// 1 trailing, 2 the bottom bar.
    package var windowSide: Int {
        if isLeading { return -1 }
        if self == .principal || self == .status { return 0 }
        if self == .bottomBar { return 2 }
        return 1
    }
}

/// The window toolbar (under the menu bar).
struct WindowToolbarView: View {
    let model: WindowToolbarModel
    var bottom = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ControlPalette(scheme)
        let entries = model.entries
        let leading = entries.filter { $0.placement.windowSide == -1 }
        let centre = entries.filter { $0.placement.windowSide == 0 }
        let trailing = entries.filter { $0.placement.windowSide == 1 }
        let bottomItems = entries.filter { $0.placement.windowSide == 2 }
        let show = model.isVisible && (bottom ? !bottomItems.isEmpty : !(leading.isEmpty && centre.isEmpty && trailing.isEmpty))
        if show {
            ZStack {
                HStack(spacing: 10) {
                    if bottom {
                        ForEach(Array(bottomItems.enumerated()), id: \.offset) { $0.element.barView }
                    } else {
                        ForEach(Array(leading.enumerated()), id: \.offset) { $0.element.barView }
                        Spacer(minLength: 8)
                        ForEach(Array(trailing.enumerated()), id: \.offset) { $0.element.barView }
                    }
                }
                if !bottom && !centre.isEmpty {
                    // The principal items sit in the middle of the window.
                    HStack(spacing: 10) {
                        ForEach(Array(centre.enumerated()), id: \.offset) { $0.element.barView }
                    }
                }
            }
            // R13: `Label`s in the window toolbar show their icons (the
            // title stays their accessibility label), as desktop toolbars do.
            .labelStyle(.iconOnly)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: WindowToolbarView.height)
            .background(palette.barBackground)
            .overlay(alignment: bottom ? .top : .bottom) {
                Rectangle().fill(palette.separator).frame(height: 1 / 3).allowsHitTesting(false)
            }
            .accessibilityControl(.toolbar, children: .contain)
        }
    }

    static let height: CGFloat = 38
}
