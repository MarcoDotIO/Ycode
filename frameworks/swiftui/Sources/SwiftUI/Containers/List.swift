import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// List (round R9; 06 §3, PARITY §5.4 R12: the navigators need selection and
// outlines).
//
// A list is a vertical scroll view over a lazy container (LazyStacks.swift)
// whose items are the list's rows: rows are created as they scroll into view
// (06 §3: 13 rows of 52 points in the reference's 678-point window). Rows
// are at least `defaultMinListRowHeight` high (52 at the default content
// size, 06 §3). Spec values: the inset-grouped rows' content at x = 40 (a
// 20-point section inset and a 20-point row inset, 06 §2.1) and the content
// offset of `scrollTo(500, anchor: .top)`, 500 × 52 + 13.33, which puts the
// first row 13.33 points below the list's top (06 §3; golden `list.two`, an
// informative row, shows 35, the form's first-row offset). Plain lists inset
// rows 20 points (golden `list.plain`). Everything else is Ycode's look
// (09-open-design.md §4.2 palette): separators inset like the row content,
// rounded section groups (radius 10), footnote headers, 20 points between
// sections; the sidebar style is Ycode's desktop navigator: 28-point rows,
// 16 points of indentation per outline level, a rounded selection.
//
// Selection (Ycode's desktop rules): a click selects the row (and focuses
// the list); with a multiple selection, Ctrl (or Super) toggles the row and
// Shift extends from the last clicked row. When the list has keyboard focus,
// Up and Down move the selection (Shift extends), Home and End go to the
// ends, Right expands an outline row (or moves to its first child), Left
// collapses it (or moves to its parent); the selected row is scrolled into
// view. A row's selection value is its `tag(_:)`, else its `ForEach` ID.

// MARK: - Styles

/// How a list looks.
@MainActor @preconcurrency
public protocol ListStyle {
    var _ovListKind: ListKind { get }
}

/// Ycode's list looks.
public enum ListKind: Sendable, Equatable {
    case plain, insetGrouped, grouped, inset, sidebar
}

public struct DefaultListStyle: ListStyle {
    public init() {}
    public var _ovListKind: ListKind { .insetGrouped }
}

public struct PlainListStyle: ListStyle {
    public init() {}
    public var _ovListKind: ListKind { .plain }
}

public struct InsetGroupedListStyle: ListStyle {
    public init() {}
    public var _ovListKind: ListKind { .insetGrouped }
}

public struct GroupedListStyle: ListStyle {
    public init() {}
    public var _ovListKind: ListKind { .grouped }
}

public struct InsetListStyle: ListStyle {
    public init() {}
    public var _ovListKind: ListKind { .inset }
}

public struct SidebarListStyle: ListStyle {
    public init() {}
    public var _ovListKind: ListKind { .sidebar }
}

extension ListStyle where Self == DefaultListStyle {
    public static var automatic: DefaultListStyle { DefaultListStyle() }
}

extension ListStyle where Self == PlainListStyle {
    public static var plain: PlainListStyle { PlainListStyle() }
}

extension ListStyle where Self == InsetGroupedListStyle {
    public static var insetGrouped: InsetGroupedListStyle { InsetGroupedListStyle() }
}

extension ListStyle where Self == GroupedListStyle {
    public static var grouped: GroupedListStyle { GroupedListStyle() }
}

extension ListStyle where Self == InsetListStyle {
    public static var inset: InsetListStyle { InsetListStyle() }
}

extension ListStyle where Self == SidebarListStyle {
    public static var sidebar: SidebarListStyle { SidebarListStyle() }
}

private enum ListKindKey: EnvironmentKey { static let defaultValue = ListKind.insetGrouped }
private enum ScrollContentBackgroundKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var _listKind: ListKind {
        get { self[ListKindKey.self] }
        set { self[ListKindKey.self] = newValue }
    }

    var _scrollContentBackgroundVisible: Bool {
        get { self[ScrollContentBackgroundKey.self] }
        set { self[ScrollContentBackgroundKey.self] = newValue }
    }
}

extension View {
    public func listStyle<S: ListStyle>(_ style: S) -> some View { environment(\._listKind, style._ovListKind) }

    /// `.hidden` removes the list's (or form's) own background.
    public func scrollContentBackground(_ visibility: Visibility) -> some View {
        environment(\._scrollContentBackgroundVisible, visibility != .hidden)
    }
}

/// Whether something is shown.
public enum Visibility: Hashable, Sendable, CaseIterable {
    case automatic, visible, hidden
}

/// Metrics of a list look.
struct ListMetrics {
    let kind: ListKind
    let minRowHeight: CGFloat

    init(kind: ListKind, minRowHeight: CGFloat) {
        self.kind = kind
        self.minRowHeight = kind == .sidebar ? Self.sidebarRowHeight : minRowHeight
    }

    static let sidebarRowHeight: CGFloat = 28
    static let indent: CGFloat = 16
    static let sectionGap: CGFloat = 20
    static let cornerRadius: CGFloat = 10

    /// Margin between the list's edges and its section groups.
    var margin: CGFloat { kind == .insetGrouped || kind == .inset ? 20 : 0 }
    /// Leading and trailing inset of row content inside the group.
    var rowInset: CGFloat { kind == .sidebar ? 10 : 20 }
    /// Space above the first section (06 §3: 13.33 for the inset-grouped list).
    var top: CGFloat {
        switch kind {
        case .insetGrouped, .grouped: return 13.33
        case .sidebar: return 8
        default: return 0
        }
    }
    var bottom: CGFloat { kind == .plain ? 0 : 20 }
    var grouped: Bool { kind == .insetGrouped || kind == .grouped || kind == .inset }
}

// MARK: - Selection

/// A list's selection, type-erased.
@MainActor
struct ListSelection {
    let allowsMultiple: Bool
    /// The selection value an ID or tag stands for (nil: another type).
    let accepts: (AnyHashable) -> AnyHashable?
    let current: () -> Set<AnyHashable>
    let set: (Set<AnyHashable>) -> Void

    static func single<V: Hashable>(_ b: Binding<V?>) -> ListSelection {
        ListSelection(allowsMultiple: false, accepts: { t in Self.convert(t, V.self) },
                      current: { b.wrappedValue.map { [AnyHashable($0)] } ?? [] },
                      set: { s in
                          let v = s.first?.base as? V
                          if b.wrappedValue != v { b.wrappedValue = v }
                      })
    }

    static func multiple<V: Hashable>(_ b: Binding<Set<V>>) -> ListSelection {
        ListSelection(allowsMultiple: true, accepts: { t in Self.convert(t, V.self) },
                      current: { Set(b.wrappedValue.map(AnyHashable.init)) },
                      set: { s in
                          let v = Set(s.compactMap { $0.base as? V })
                          if b.wrappedValue != v { b.wrappedValue = v }
                      })
    }

    private static func convert<V: Hashable>(_ t: AnyHashable, _: V.Type) -> AnyHashable? {
        if let v = t.base as? V { return AnyHashable(v) }
        return nil
    }
}

/// Connects a list's rows, keyboard handling and scrolling.
@MainActor
final class ListController {
    weak var state: LazyContainerState?
    let focusRef = NodeRef()
    var selection: ListSelection?
    var anchor: AnyHashable?
    var lastHasSelection: Bool?

    /// The selection value of item `i` (its tag when materialised and
    /// tagged, else its ID).
    func value(ofItem i: Int) -> AnyHashable? {
        guard let state, let selection, i < state.items.count else { return nil }
        let item = state.items.item(at: i)
        guard item.role == .row else { return nil }
        if let t = tags[item.key] { return selection.accepts(t) }
        return item.id.flatMap(selection.accepts)
    }

    /// Tags of materialised rows, by item key.
    var tags: [AnyHashable: AnyHashable] = [:]

    func index(ofValue v: AnyHashable) -> Int? {
        guard let state else { return nil }
        for i in 0..<state.items.count where value(ofItem: i) == v { return i }
        return nil
    }

    func click(_ v: AnyHashable, modifiers: KeyModifiers) {
        guard let selection else { return }
        if let node = focusRef.node, let services = node.environment._windowServices {
            services.focus.focus(node)
        }
        var s = selection.current()
        if selection.allowsMultiple && (modifiers.contains(.control) || modifiers.contains(.command)) {
            if s.contains(v) { s.remove(v) } else { s.insert(v) }
            anchor = v
        } else if selection.allowsMultiple && modifiers.contains(.shift), let a = anchor,
                  let i = index(ofValue: a), let j = index(ofValue: v) {
            s = Set((min(i, j)...max(i, j)).compactMap { value(ofItem: $0) })
        } else {
            s = [v]
            anchor = v
        }
        selection.set(s)
    }

    /// Keyboard navigation (header comment).
    func handleKey(_ k: KeyEvent) -> Bool {
        guard k.isDown, let state, let selection else { return false }
        let n = state.items.count
        guard n > 0 else { return false }
        let current = selection.current()
        let focusValue = anchor.flatMap { current.contains($0) ? $0 : nil } ?? current.first
        let i = focusValue.flatMap(index(ofValue:))
        func selectable(from start: Int, step: Int) -> Int? {
            var j = start
            while j >= 0 && j < n {
                if value(ofItem: j) != nil { return j }
                j += step
            }
            return nil
        }
        var target: Int?
        switch k.key {
        case .downArrow: target = i.map { selectable(from: $0 + 1, step: 1) } ?? selectable(from: 0, step: 1)
        case .upArrow: target = i.map { selectable(from: $0 - 1, step: -1) } ?? selectable(from: n - 1, step: -1)
        case .home: target = selectable(from: 0, step: 1)
        case .end: target = selectable(from: n - 1, step: -1)
        case .rightArrow, .leftArrow:
            guard let i else { return false }
            let item = state.items.item(at: i)
            guard let o = item.outline else { return false }
            if k.key == .rightArrow {
                if o.hasChildren && !o.isExpanded {
                    o.toggle()
                    return true
                }
                if o.hasChildren, i + 1 < n { target = i + 1 } else { return true }
            } else {
                if o.hasChildren && o.isExpanded {
                    o.toggle()
                    return true
                }
                guard let p = o.parentKey, let pi = (0..<i).last(where: { state.keys[$0] == p }) else { return true }
                target = pi
            }
        default:
            return false
        }
        guard let t = target ?? i, let v = value(ofItem: t) else { return true }
        if selection.allowsMultiple && k.modifiers.contains(.shift), let a = anchor, let ai = index(ofValue: a) {
            selection.set(Set((min(ai, t)...max(ai, t)).compactMap { value(ofItem: $0) }))
        } else {
            selection.set([v])
            anchor = v
        }
        reveal(item: t)
        return true
    }

    /// Scrolls item `i` into view.
    func reveal(item i: Int) {
        guard let state, let node = state.windowFrameNode, let viewport = node.enclosingScrollViewport,
              let wf = state.windowFrame, let f = state.frame(ofItem: i) else { return }
        viewport.reveal(CGRect(x: wf.minX, y: wf.minY + f.minY, width: wf.width, height: f.height), anchor: nil,
                        transaction: Transaction())
    }
}

extension LazyContainerState {
    /// The container's node (for its scroll view).
    @MainActor var windowFrameNode: ViewNode? { node }
}

// MARK: - Rows

/// What a row's own modifiers ask of the list (`listRowInsets`,
/// `listRowBackground`, `listRowSeparator`, `tag`).
@MainActor
struct RowTraits {
    var insets: EdgeInsets?
    var background: AnyView?
    var separatorHidden = false
    var tag: AnyHashable?

    init(_ view: any View) {
        var v: any View = view
        var depth = 0
        while depth < 32 {
            depth += 1
            if let t = v as? any TaggedView, tag == nil { tag = t._tag }
            guard let m = v as? any ModifiedContentInspecting else { break }
            switch m._inspectedModifier {
            case let r as ListRowInsetsModifier: if insets == nil { insets = r.insets }
            case let b as ListRowBackgroundModifier: if background == nil { background = b.view }
            case let s as ListRowSeparatorModifier: if s.visibility == .hidden { separatorHidden = true }
            default: break
            }
            v = m._inspectedContent
        }
    }
}

@MainActor
protocol ModifiedContentInspecting {
    var _inspectedModifier: Any { get }
    var _inspectedContent: any View { get }
}

extension ModifiedContent: ModifiedContentInspecting where Content: View {
    var _inspectedModifier: Any { modifier }
    var _inspectedContent: any View { content }
}

struct ListRowInsetsModifier: ViewModifier {
    let insets: EdgeInsets?
    func body(content: Content) -> some View { content }
}

struct ListRowBackgroundModifier: ViewModifier {
    let view: AnyView?
    func body(content: Content) -> some View { content }
}

struct ListRowSeparatorModifier: ViewModifier {
    let visibility: Visibility
    func body(content: Content) -> some View { content }
}

extension View {
    public func listRowInsets(_ insets: EdgeInsets?) -> some View { modifier(ListRowInsetsModifier(insets: insets)) }

    public func listRowBackground<V: View>(_ view: V?) -> some View {
        modifier(ListRowBackgroundModifier(view: view.map { AnyView($0) }))
    }

    public func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        modifier(ListRowSeparatorModifier(visibility: visibility))
    }

    public func listSectionSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View { self }

    public func listItemTint(_ tint: Color?) -> some View { self }

    public func headerProminence(_ prominence: Prominence) -> some View { self }

    public func selectionDisabled(_ isDisabled: Bool = true) -> some View { self }
}

public enum Prominence: Hashable, Sendable { case standard, increased }

/// One row of a list: the item's view in the look of the list's style.
struct ListRowView: View {
    let item: LazyItem
    let content: AnyView
    let traits: RowTraits
    let metrics: ListMetrics
    let value: AnyHashable?
    let isSelected: Bool
    let listFocused: Bool
    let sectionIndex: Int
    let controller: ListController
    @Environment(\.colorScheme) private var scheme
    @Environment(\._windowServices) private var services
    @Environment(\._listContextMenu) private var listMenu

    var body: some View {
        let palette = ControlPalette(scheme)
        let m = metrics
        if item.role != .row {
            header(palette)
        } else {
            row(palette, m)
        }
    }

    private func header(_ palette: ControlPalette) -> some View {
        let m = metrics
        let first = sectionIndex == 0
        let font: Font = m.kind == .sidebar ? .subheadline.weight(.semibold) : .footnote
        return content
            .font(font)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: m.kind == .sidebar ? ListMetrics.sidebarRowHeight : 0, alignment: .leading)
            .padding(EdgeInsets(top: item.role == .header ? (first ? 0 : (m.kind == .plain ? 6 : ListMetrics.sectionGap)) : 6,
                                leading: m.margin + m.rowInset, bottom: item.role == .header ? 6 : 0,
                                trailing: m.margin + m.rowInset))
    }

    @ViewBuilder
    private func row(_ palette: ControlPalette, _ m: ListMetrics) -> some View {
        let first = item.isFirstInSection, last = item.isLastInSection
        let radius: CGFloat = m.kind == .insetGrouped || m.kind == .inset ? ListMetrics.cornerRadius : 0
        let indent = CGFloat(item.depth) * ListMetrics.indent
        let insets = traits.insets ?? EdgeInsets(top: 0, leading: m.rowInset, bottom: 0, trailing: m.rowInset)
        let showSeparator = !traits.separatorHidden && m.kind != .sidebar && !(last && m.grouped)
        let topGap: CGFloat = (m.grouped && first && sectionIndex > 0 && item.section != nil && !hasHeaderAbove) ? ListMetrics.sectionGap : 0
        HStack(spacing: 4) {
            if item.outline != nil || item.depth > 0 {
                disclosure
            }
            content
        }
        .padding(EdgeInsets(top: insets.top, leading: insets.leading + indent, bottom: insets.bottom, trailing: insets.trailing))
        .frame(maxWidth: .infinity, minHeight: m.minRowHeight, alignment: .leading)
        .background {
            rowBackground(palette, m, radius: radius, first: first, last: last)
        }
        .overlay(alignment: .bottom) {
            if showSeparator {
                Rectangle().fill(palette.separator).frame(height: 1 / 3)
                    .padding(.leading, insets.leading + indent).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded {
            if let value { controller.click(value, modifiers: services?.pointerModifiers ?? []) }
        })
        .accessibilityAttributes { a in
            a.role = .row
            a.children = .combine
            if isSelected { a.addTraits = .isSelected }
            if let value { a.actions["default"] = { controller.click(value, modifiers: []) } }
            // R10 export: outline rows with children expand and collapse.
            if let o = item.outline, o.hasChildren {
                a.isExpanded = o.isExpanded
                a.actions["expand or collapse"] = o.toggle
            }
        }
        .modifier(ContextMenuModifier(items: { [listMenu, value, controller] in
            // R11: the selection when the row is in it, else the row alone.
            guard let listMenu, let value else { return nil }
            let current = controller.selection?.current() ?? []
            return listMenu.make(current.contains(value) ? Array(current) : [value])
        }))
        .padding(.horizontal, m.margin)
        .padding(.top, topGap)
    }

    private var hasHeaderAbove: Bool { false }

    @ViewBuilder
    private func rowBackground(_ palette: ControlPalette, _ m: ListMetrics, radius: CGFloat, first: Bool, last: Bool) -> some View {
        let base: Color = m.grouped ? palette.groupedRow : .clear
        ZStack {
            if let bg = traits.background {
                bg
            } else if m.grouped {
                RowGroupShape(radius: radius, top: first, bottom: last).fill(base)
            }
            if isSelected {
                if m.kind == .sidebar {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(listFocused ? AnyShapeStyle(.tint.opacity(palette.rowSelectionOpacity)) : AnyShapeStyle(palette.fill))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                } else {
                    RowGroupShape(radius: radius, top: first, bottom: last)
                        .fill(listFocused ? AnyShapeStyle(.tint.opacity(palette.rowSelectionOpacity)) : AnyShapeStyle(palette.fill))
                }
            }
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if let o = item.outline, o.hasChildren {
            Image(systemName: "chevron.right")
                .resizable()
                .frame(width: 9, height: 9)
                .rotationEffect(.degrees(o.isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
                .gesture(TapGesture().onEnded { o.toggle() })
                // The row's expanded state and its "expand or collapse"
                // action stand for the chevron (OV-ATSPI).
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 12, height: 16)
        }
    }
}

/// A rectangle with rounded top and/or bottom corners (section groups).
struct RowGroupShape: Shape {
    let radius: CGFloat
    let top: Bool
    let bottom: Bool

    func path(in r: CGRect) -> Path {
        let tr = top ? min(radius, r.height / 2) : 0, br = bottom ? min(radius, r.height / 2) : 0
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tr, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        if tr > 0 { p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + tr), control: CGPoint(x: r.maxX, y: r.minY)) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        if br > 0 { p.addQuadCurve(to: CGPoint(x: r.maxX - br, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY)) }
        p.addLine(to: CGPoint(x: r.minX + br, y: r.maxY))
        if br > 0 { p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - br), control: CGPoint(x: r.minX, y: r.maxY)) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tr))
        if tr > 0 { p.addQuadCurve(to: CGPoint(x: r.minX + tr, y: r.minY), control: CGPoint(x: r.minX, y: r.minY)) }
        p.closeSubpath()
        return p
    }
}

// MARK: - List

/// A scrolling column of rows, optionally selectable (06 §3).
public struct List<SelectionValue: Hashable, Content: View>: View {
    let content: Content
    let selection: ListSelection?
    @Environment(\._listKind) private var kind
    @Environment(\._scrollContentBackgroundVisible) private var showsBackground
    @Environment(\.colorScheme) private var scheme
    @Environment(\.defaultMinListRowHeight) private var minRowHeight
    @State private var controller = ListController()
    @State private var focused = false
    @Environment(\._collapsedSplit) private var collapsedSplit
    @Environment(\._collapsedColumnIndex) private var columnIndex

    public var body: some View {
        let metrics = ListMetrics(kind: kind, minRowHeight: minRowHeight)
        let controller = controller
        controller.selection = selection
        let current = selection?.current() ?? []
        if let split = collapsedSplit, columnIndex >= 0, let selection {
            // In a collapsed split view a selection shows the next column
            // (06 §2.2); going back clears it.
            let has = !current.isEmpty
            if controller.lastHasSelection != has {
                controller.lastHasSelection = has
                split.show(columnIndex, has)
            }
            split.clearSelections[columnIndex] = { selection.set([]) }
        }
        let focused = self.focused
        let palette = ControlPalette(scheme)
        let background: Color = !showsBackground ? .clear
            : (metrics.grouped ? palette.groupedBackground : (kind == .sidebar ? palette.sidebarBackground : palette.plainBackground))
        let container = LazyContainer(content: content, axis: .vertical, spacing: 0, arrangement: .stack(.topLeading),
                                      wrap: { item, _ in
                                          let view = item.make()
                                          let traits = RowTraits(view)
                                          if let t = traits.tag { controller.tags[item.key] = t } else { controller.tags[item.key] = nil }
                                          let value = traits.tag.flatMap { selection?.accepts($0) } ?? item.id.flatMap { selection?.accepts($0) }
                                          return ListRowView(item: item, content: AnyView(_fromValue: view) ?? AnyView(EmptyView()),
                                                             traits: traits, metrics: metrics, value: value,
                                                             isSelected: value.map { current.contains($0) } ?? false,
                                                             listFocused: focused, sectionIndex: item.sectionIndex,
                                                             controller: controller)
                                      },
                                      attach: { controller.state = $0 })
        return ScrollView(.vertical) {
            container
                .padding(EdgeInsets(top: metrics.top, leading: 0, bottom: metrics.bottom, trailing: 0))
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .controlFocus($focused, ref: controller.focusRef) { k in controller.handleKey(k) }
        .accessibilityControl(.list, children: .contain)
    }
}

extension List where SelectionValue == Never {
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
        selection = nil
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, ID, RowContent> {
        self.content = ForEach(data, id: id, content: rowContent)
        selection = nil
    }

    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.content = ForEach(data, content: rowContent)
        selection = nil
    }

    public init<RowContent: View>(_ data: Range<Int>, @ViewBuilder rowContent: @escaping (Int) -> RowContent)
        where Content == ForEach<Range<Int>, Int, RowContent> {
        self.content = ForEach(data, content: rowContent)
        selection = nil
    }

    /// A hierarchical list (06; the IDE's navigators).
    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data, children: KeyPath<Data.Element, Data?>, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == OutlineGroup<Data, Data.Element.ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
              Data.Element: Identifiable {
        self.content = OutlineGroup(data, children: children, content: rowContent)
        selection = nil
    }
}

extension List {
    public init(selection: Binding<SelectionValue?>?, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = selection.map { ListSelection.single($0) }
    }

    public init(selection: Binding<Set<SelectionValue>>?, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = selection.map { ListSelection.multiple($0) }
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data, id: KeyPath<Data.Element, ID>, selection: Binding<SelectionValue?>?,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) where Content == ForEach<Data, ID, RowContent> {
        self.content = ForEach(data, id: id, content: rowContent)
        self.selection = selection.map { ListSelection.single($0) }
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data, id: KeyPath<Data.Element, ID>, selection: Binding<Set<SelectionValue>>?,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) where Content == ForEach<Data, ID, RowContent> {
        self.content = ForEach(data, id: id, content: rowContent)
        self.selection = selection.map { ListSelection.multiple($0) }
    }

    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data, selection: Binding<SelectionValue?>?, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.content = ForEach(data, content: rowContent)
        self.selection = selection.map { ListSelection.single($0) }
    }

    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data, selection: Binding<Set<SelectionValue>>?, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.content = ForEach(data, content: rowContent)
        self.selection = selection.map { ListSelection.multiple($0) }
    }

    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data, children: KeyPath<Data.Element, Data?>, selection: Binding<SelectionValue?>?,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == OutlineGroup<Data, Data.Element.ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
              Data.Element: Identifiable {
        self.content = OutlineGroup(data, children: children, content: rowContent)
        self.selection = selection.map { ListSelection.single($0) }
    }

    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data, children: KeyPath<Data.Element, Data?>, selection: Binding<Set<SelectionValue>>?,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
        where Content == OutlineGroup<Data, Data.Element.ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
              Data.Element: Identifiable {
        self.content = OutlineGroup(data, children: children, content: rowContent)
        self.selection = selection.map { ListSelection.multiple($0) }
    }
}

// MARK: - Sections in lazy containers

extension Section: LazyItemEnumerating where Parent: View, Content: View, Footer: View {
    package func _lazyItems(prefix: [AnyHashable], into items: inout LazyItems, context: LazyEnumerationContext) {
        let key = AnyHashable(prefix)
        let index = context.sectionCount
        context.sectionCount += 1
        // A section's element ID is not a row's selection value.
        context.elementID = nil
        let start = items.count
        if !(header is EmptyView) {
            let h = header
            items.append(LazyItem(key: AnyHashable(prefix + [AnyHashable("header")]), id: nil, role: .header, make: { h }))
        }
        let rowsStart = items.count
        enumerateLazyItems(content, prefix: prefix + [AnyHashable("rows")], into: &items, context: context)
        let rowsEnd = items.count
        if !(footer is EmptyView) {
            let f = footer
            items.append(LazyItem(key: AnyHashable(prefix + [AnyHashable("footer")]), id: nil, role: .footer, make: { f }))
        }
        items.markSection(key, index: index, from: start, to: items.count, rows: false)
        items.markSection(key, index: index, from: rowsStart, to: rowsEnd, rows: true)
    }
}
