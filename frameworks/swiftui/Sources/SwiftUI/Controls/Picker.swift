import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Picker (round R8): segmented, menu and inline styles. 06 §4: in a Form the
// default style shows the selection with a menu. Golden `picker.segmented`:
// 84 × 31 for "A" and "Bee" unproposed (equal segments: the widest label + 8
// + 8; Ycode's segment font is the subheadline style), the proposed width
// otherwise, 31 high, baselines 20.67.
//
// The options are the views of the content that carry a `tag(_:)` (or, in a
// `ForEach`, the element IDs when they have the selection's type). The
// content is kept in the graph but not laid out; each style draws the
// option views itself.

// MARK: - Tags

/// The value a view stands for in a picker.
struct TagModifier<V: Hashable>: PrimitiveModifier {
    let value: V
    let includeOptional: Bool
}

extension View {
    /// Sets the value this view stands for in a `Picker` (or a `TabView`).
    public func tag<V: Hashable>(_ tag: V, includeOptional: Bool = true) -> some View {
        modifier(TagModifier(value: tag, includeOptional: includeOptional))
    }
}

@MainActor
protocol TaggedView {
    var _tag: AnyHashable { get }
    var _includeOptional: Bool { get }
    var _taggedContent: any View { get }
}

extension ModifiedContent: TaggedView where Content: View, Modifier: TagModifierProtocol {
    var _tag: AnyHashable { modifier._anyTag }
    var _includeOptional: Bool { modifier._includeOptional }
    var _taggedContent: any View { content }
}

@MainActor protocol TagModifierProtocol {
    var _anyTag: AnyHashable { get }
    var _includeOptional: Bool { get }
}

extension TagModifier: TagModifierProtocol {
    var _anyTag: AnyHashable { AnyHashable(value) }
    var _includeOptional: Bool { includeOptional }
}

/// `ForEach` views give their element IDs as implicit tags.
@MainActor protocol ImplicitTagSource {}
extension ForEach: ImplicitTagSource where Content: View {}

/// One choice of a picker.
struct PickerOption {
    let tag: AnyHashable
    let view: AnyView
}

/// The options found below `root` for a selection of type `V`.
@MainActor
func collectOptions<V: Hashable>(_ root: ViewNode, selection: V.Type) -> [PickerOption] {
    var out: [PickerOption] = []
    func matches(_ tag: AnyHashable, includeOptional: Bool) -> AnyHashable? {
        if tag.base is V { return tag }
        // A tag of type T matches a selection of type T? (includeOptional).
        if includeOptional, let v = tag.base as? V { return AnyHashable(v) }
        return nil
    }
    func walk(_ n: ViewNode, implicit: AnyHashable?) {
        if let t = n.view as? any TaggedView {
            if let tag = matches(t._tag, includeOptional: t._includeOptional) {
                out.append(PickerOption(tag: tag, view: AnyView(_fromValue: t._taggedContent) ?? AnyView(EmptyView())))
            }
            return
        }
        if n.view is any ImplicitTagSource {
            for (k, c) in zip(n.childKeys, n.children) {
                let explicit = c.containsTag
                if explicit {
                    walk(c, implicit: nil)
                } else if let tag = matches(k, includeOptional: true) {
                    out.append(PickerOption(tag: tag, view: AnyView(_fromValue: c.view) ?? AnyView(EmptyView())))
                }
            }
            return
        }
        for c in n.children { walk(c, implicit: implicit) }
    }
    walk(root, implicit: nil)
    return out
}

extension ViewNode {
    /// True if a tagged view is in this subtree.
    @MainActor var containsTag: Bool {
        var found = false
        forEachNode { if $0.view is any TaggedView { found = true } }
        return found
    }
}

// MARK: - Picker

/// A control that selects one of its tagged options.
public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {
    let selection: Binding<SelectionValue>
    let label: Label
    let content: Content

    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.selection = selection
        self.content = content()
        self.label = label()
    }

    public typealias Body = Never
}

extension Picker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(title) }
    }
}

extension Picker where Label == _TitleAndIconLabel {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, selection: Binding<SelectionValue>,
                @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { _TitleAndIconLabel(titleKey, systemImage: systemImage) }
    }
}

extension Picker: PrimitiveView {
    private func build(_ node: ViewNode, _ transaction: Transaction) {
        // The content first (its tags are the options); an existing
        // presentation keeps its identity.
        if let c = node.children.first, node.children.count == 2 {
            c.update(content, environment: node.childEnvironment, transaction: transaction)
        } else {
            node.reconcileChildren([(AnyHashable(0), content)], transaction: transaction)
        }
        let options = node.children.first.map { collectOptions($0, selection: SelectionValue.self) } ?? []
        let env = node.environment
        let selected = node.trackContent { selection.wrappedValue }
        let index = options.firstIndex { $0.tag == AnyHashable(selected) }
        let binding = selection
        let choose: @MainActor (Int) -> Void = { i in
            guard options.indices.contains(i), let v = options[i].tag.base as? SelectionValue else { return }
            binding.wrappedValue = v
        }
        let presentation: AnyView
        var style = env._pickerStyle
        if style == 0 { style = 2 }
        switch style {
        case 1:
            presentation = AnyView(SegmentedPicker(options: options, selected: index, choose: choose))
        case 3, 4:
            let rows = InlinePicker(options: options, selected: index, choose: choose)
            presentation = env._labelsHidden || env._inForm
                ? AnyView(rows)
                : AnyView(VStack(alignment: .leading, spacing: 6) { label; rows })
        default:
            if env._inMenu {
                presentation = AnyView(InlinePicker(options: options, selected: index, choose: choose))
            } else {
                let button = MenuPickerButton(options: options, selected: index, choose: choose)
                presentation = env._labelsHidden || !env._inForm
                    ? AnyView(button)
                    : AnyView(ControlRowLayout(columnWidth: env._formColumnWidth) {
                        label.modifier(ColumnLabelAlignment(inColumn: env._formColumnWidth != nil))
                        button
                    })
            }
        }
        node.reconcileChildren([(AnyHashable(0), content), (AnyHashable(1), presentation)], transaction: transaction)
    }

    package func _makeChildren(node: ViewNode, old: Picker?, transaction: Transaction) { build(node, transaction) }

    package func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if node.updateWasDirty || environmentChanged || node.updateHadDirtyDescendant {
            build(node, transaction)
        } else {
            node.refreshChildren(transaction: transaction)
        }
    }

    package func _lower(node: ViewNode) -> [LayoutNode] {
        node.children.count > 1 ? node.children[1].lower() : []
    }

    package func _preferences(node: ViewNode) -> PreferenceValues {
        node.children.count > 1 ? node.children[1].preferenceValues() : PreferenceValues()
    }
}

// MARK: - Styles

/// How a picker presents its options.
@MainActor @preconcurrency
public protocol PickerStyle {
    /// Ycode's style identifier (the reference API has no public requirement).
    var _ovStyleKind: Int { get }
}

public struct DefaultPickerStyle: PickerStyle {
    public init() {}
    public var _ovStyleKind: Int { 0 }
}

public struct SegmentedPickerStyle: PickerStyle {
    public init() {}
    public var _ovStyleKind: Int { 1 }
}

public struct MenuPickerStyle: PickerStyle {
    public init() {}
    public var _ovStyleKind: Int { 2 }
}

public struct InlinePickerStyle: PickerStyle {
    public init() {}
    public var _ovStyleKind: Int { 3 }
}

/// Shown inline (Linux has no wheel).
public struct WheelPickerStyle: PickerStyle {
    public init() {}
    public var _ovStyleKind: Int { 4 }
}

extension PickerStyle where Self == DefaultPickerStyle {
    public static var automatic: DefaultPickerStyle { DefaultPickerStyle() }
}

extension PickerStyle where Self == SegmentedPickerStyle {
    public static var segmented: SegmentedPickerStyle { SegmentedPickerStyle() }
}

extension PickerStyle where Self == MenuPickerStyle {
    public static var menu: MenuPickerStyle { MenuPickerStyle() }
}

extension PickerStyle where Self == InlinePickerStyle {
    public static var inline: InlinePickerStyle { InlinePickerStyle() }
}

extension PickerStyle where Self == WheelPickerStyle {
    public static var wheel: WheelPickerStyle { WheelPickerStyle() }
}

private enum PickerStyleKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    var _pickerStyle: Int {
        get { self[PickerStyleKey.self] }
        set { self[PickerStyleKey.self] = newValue }
    }
}

extension View {
    public func pickerStyle<S: PickerStyle>(_ style: S) -> some View { environment(\._pickerStyle, style._ovStyleKind) }
}

// MARK: - Segmented

enum SegmentedMetrics {
    static let height: CGFloat = 31
    static let labelPadding: CGFloat = 8
    static let inset: CGFloat = 2
}

/// Equal segments: each the widest label's ideal width + 2 × 8 unproposed;
/// a proposed width is shared out evenly. 31 high. Each title is centred in
/// its segment, its top on the pixel grid (rounded down; that puts the
/// golden first baseline at 20.67).
struct SegmentedLayout: Layout {
    var scale: CGFloat = 3

    func spacing(subviews: Subviews, cache: inout ()) -> ViewSpacing { ViewSpacing() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let w = proposal.width { return CGSize(width: max(0, w), height: SegmentedMetrics.height) }
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: CGFloat(subviews.count) * (widest + 2 * SegmentedMetrics.labelPadding), height: SegmentedMetrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let w = bounds.width / CGFloat(subviews.count)
        let inner = max(0, w - 2 * SegmentedMetrics.labelPadding)
        for (i, s) in subviews.enumerated() {
            let p = ProposedViewSize(width: inner, height: bounds.height)
            let size = s.sizeThatFits(p)
            let x = bounds.minX + CGFloat(i) * w + (w - size.width) / 2
            let y = bounds.minY + ((bounds.height - size.height) / 2 * scale + 1e-6).rounded(.down) / scale
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: p)
        }
    }
}

struct SegmentedPicker: View {
    let options: [PickerOption]
    let selected: Int?
    let choose: @MainActor (Int) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale
    @State private var isFocused = false
    @State private var pressed: Int?

    var body: some View {
        let palette = ControlPalette(scheme)
        let n = options.count
        SegmentedLayout(scale: max(1, displayScale)) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                o.view
                    .font(.subheadline)
                    .lineLimit(1)
                    .opacity(pressed == i ? 0.5 : 1)
            }
        }
        .background {
            GeometryReader { g in
                let segment = n > 0 ? g.size.width / CGFloat(n) : 0
                ZStack(alignment: .topLeading) {
                    Capsule().fill(palette.fill)
                    if let selected, n > 0 {
                        Capsule().fill(palette.segmentSelected)
                            .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)
                            .frame(width: max(0, segment - 2 * SegmentedMetrics.inset),
                                   height: max(0, g.size.height - 2 * SegmentedMetrics.inset))
                            .offset(x: CGFloat(selected) * segment + SegmentedMetrics.inset, y: SegmentedMetrics.inset)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: selected)
            }
        }
        .overlay {
            HStack(spacing: 0) {
                ForEach(0..<n, id: \.self) { i in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(ControlPressGesture(onPressed: { p in pressed = p ? i : nil }, onAction: { choose(i) }))
                }
            }
        }
        .focusRing(isFocused, Capsule())
        .controlFocus($isFocused) { k in
            guard k.isDown, n > 0 else { return false }
            switch k.key {
            case .leftArrow: choose(max(0, (selected ?? 0) - 1))
            case .rightArrow: choose(min(n - 1, (selected ?? -1) + 1))
            default: return false
            }
            return true
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Menu and inline

/// The selection and a chevron in the tint colour; a click opens a pop-up
/// menu of the options with a check mark at the selected one.
struct MenuPickerButton: View {
    let options: [PickerOption]
    let selected: Int?
    let choose: @MainActor (Int) -> Void
    @Environment(\._windowServices) private var services
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\._formColumnWidth) private var columnWidth
    @Environment(\.colorScheme) private var scheme
    @State private var ref = NodeRef()
    @State private var box = PopupBox()
    @State private var isFocused = false
    @State private var isPressed = false

    var body: some View {
        let services = services, ref = ref, box = box
        let options = options, selected = selected, choose = choose
        let open: @MainActor () -> Void = {
            let rows = ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                MenuRow(label: o.view, checked: i == selected, trailing: nil, isDestructive: false, action: { choose(i) })
            }
            openPopup(services: services, ref: ref, box: box, submenu: false, content: AnyView(rows))
        }
        Group {
            if columnWidth != nil {
                // A `.columns` form's pop-up button (the desktop's): the
                // choice and up/down chevrons on a filled rounded bezel.
                HStack(spacing: 6) {
                    if let selected, options.indices.contains(selected) {
                        options[selected].view.lineLimit(1)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .frame(minWidth: 60, minHeight: 22)
                .background { RoundedRectangle(cornerRadius: 5).fill(ControlPalette(scheme).fill) }
            } else {
                HStack(spacing: 4) {
                    if let selected, options.indices.contains(selected) {
                        options[selected].view
                    }
                    Image(systemName: "chevron.down").imageScale(.small)
                }
                .foregroundStyle(.tint)
            }
        }
        .opacity(isPressed ? 0.4 : (isEnabled ? 1 : 0.4))
        .contentShape(Rectangle())
        .gesture(ControlPressGesture(onPressed: { p in isPressed = p }, onAction: { open() }))
        .controlFocus($isFocused) { k in
            guard isActivationKey(k) || (k.isDown && (k.key == .downArrow || k.key == .upArrow)) else { return false }
            open()
            return true
        }
        .focusRing(isFocused, RoundedRectangle(cornerRadius: 4))
        .modifier(NodeCaptureModifier(ref: ref))
    }
}

/// The options as rows with a check mark at the selected one.
struct InlinePicker: View {
    let options: [PickerOption]
    let selected: Int?
    let choose: @MainActor (Int) -> Void
    @Environment(\._inMenu) private var inMenu
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ControlPalette(scheme)
        if inMenu {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                MenuRow(label: o.view, checked: i == selected, trailing: nil, isDestructive: false, action: { choose(i) })
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                    VStack(spacing: 0) {
                        if i > 0 { Rectangle().fill(palette.separator).frame(height: 1) }
                        InlinePickerRow(label: o.view, checked: i == selected, action: { choose(i) })
                    }
                }
            }
        }
    }
}

struct InlinePickerRow: View {
    let label: AnyView
    let checked: Bool
    let action: @MainActor () -> Void
    @State private var isFocused = false
    @State private var isPressed = false

    var body: some View {
        HStack {
            label
            Spacer(minLength: 8)
            if checked { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .frame(minHeight: 32)
        .opacity(isPressed ? 0.5 : 1)
        .contentShape(Rectangle())
        .gesture(ControlPressGesture(onPressed: { p in isPressed = p }, onAction: { action() }))
        .controlFocus($isFocused) { k in
            guard isActivationKey(k) else { return false }
            action()
            return true
        }
        .focusRing(isFocused, RoundedRectangle(cornerRadius: 4))
    }
}
