import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Form and Section (round R8, grouped look). 06 §4 (informative; the
// reference hosts rows in UIKit views): rows inset 20 + 20 points from the
// container's edges, the first row 35 points down, rows at least
// `defaultMinListRowHeight` (52) high. Ycode's grouped look: the grouped
// background colour behind everything, each section a rounded group in the
// row colour (radius 10) with hairline separators inset 20 points, section
// headers and footers in the footnote style, secondary colour, 20 points
// between sections. Loose rows (outside a `Section`) form sections of their
// own. A form takes all the space proposed to it; scrolling arrives with R9.
//
// Rows are found at layout: every layout node a section's content produces
// is a row (tuples, `ForEach`, groups and conditionals all flatten).

/// Passes layout through to its one child; marks a form section's output.
struct FormSectionMarker: NodeBehavior {
    var traitChild: Int? { 0 }

    func sizeThatFits(_ p: ProposedViewSize, node: LayoutNode) -> CGSize {
        node.children.first?.sizeThatFits(p) ?? .zero
    }

    func placeChildren(size: CGSize, proposal: ProposedViewSize, node: LayoutNode) -> [ChildPlacement] {
        node.children.isEmpty ? [] : [ChildPlacement(index: 0, origin: .zero, size: size, proposal: proposal)]
    }
}

/// The `.columns` look (Ycode's desktop form, the macOS IDE's Settings
/// panes, `specs/ide/metrics.md` §8): no groups; the content 20 points
/// from the top and bottom and 28 from the sides; headings in bold 12-point
/// text; rows 10 points apart; each control's label right-aligned in a
/// 200-point column with the control 8 points after it; footers in 11-point
/// secondary text. The form's background is its container's.
enum ColumnsFormMetrics {
    static let top: CGFloat = 20
    static let sides: CGFloat = 28
    static let rowSpacing: CGFloat = 10
    static let labelColumn: CGFloat = 200
    static let headingSize: CGFloat = 12
    static let footerSize: CGFloat = 11
}

enum FormMetrics {
    static let margin: CGFloat = 20
    static let rowInset: CGFloat = 20
    static let firstRowTop: CGFloat = 35
    static let sectionSpacing: CGFloat = 20
    static let cornerRadius: CGFloat = 10
    static let headerBottom: CGFloat = 6
}

/// A filled rectangle (or rounded rectangle) layout node.
@MainActor
func fillNode(_ color: Color, environment env: EnvironmentValues, cornerRadius: CGFloat = 0) -> LayoutNode {
    let n = LayoutNode.color()
    if cornerRadius > 0 {
        n.draw = shapeDraw(shape: RoundedRectangle(cornerRadius: cornerRadius), style: color, mode: .fill(FillStyle()),
                           environment: env)
    } else {
        n.draw = shapeDraw(shape: Rectangle(), style: color, mode: .fill(FillStyle()), environment: env)
    }
    return n
}

/// A grouped section: `rows` in a rounded group with separators.
@MainActor
func formGroup(_ rows: [LayoutNode], environment env: EnvironmentValues) -> LayoutNode {
    let palette = ControlPalette(env.colorScheme)
    let hairline = 1 / max(1, env.displayScale)
    let minHeight = env.defaultMinListRowHeight
    var out: [LayoutNode] = []
    for (i, r) in rows.enumerated() {
        var row = r.frame(minWidth: 0, maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .padding(EdgeInsets(top: 0, leading: FormMetrics.rowInset, bottom: 0, trailing: FormMetrics.rowInset))
        if i < rows.count - 1 {
            let sep = fillNode(palette.separator, environment: env).frame(height: hairline)
                .padding(EdgeInsets(top: 0, leading: FormMetrics.rowInset, bottom: 0, trailing: 0))
            row = row.overlay(sep, alignment: .bottom)
        }
        out.append(row)
    }
    return LayoutNode.vstack(alignment: .leading, spacing: 0, out)
        .background(fillNode(palette.groupedRow, environment: env, cornerRadius: FormMetrics.cornerRadius))
}

// MARK: - Form

/// A container of grouped rows of controls.
public struct Form<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public typealias Body = Never
}

extension Form: PrimitiveView {
    package func _makeChildren(node: ViewNode, old: Form?, transaction: Transaction) {
        let columns = node.environment._formStyleKind == 1
        node.reconcileChildren([(AnyHashable(0), content.environment(\._inForm, true)
            .environment(\._formColumnWidth, columns ? ColumnsFormMetrics.labelColumn : nil))], transaction: transaction)
    }

    package func _lower(node: ViewNode) -> [LayoutNode] {
        let env = node.environment
        if env._formStyleKind == 1 { return [columnsLayout(node.lowerChildren())] }
        let palette = ControlPalette(env.colorScheme)
        var sections: [LayoutNode] = []
        var loose: [LayoutNode] = []
        func flush() {
            guard !loose.isEmpty else { return }
            sections.append(formGroup(loose, environment: env))
            loose = []
        }
        for n in node.lowerChildren() {
            if n.behavior is FormSectionMarker {
                flush()
                sections.append(n)
            } else {
                loose.append(n)
            }
        }
        flush()
        let stack = LayoutNode.vstack(alignment: .leading, spacing: FormMetrics.sectionSpacing, sections)
            .padding(EdgeInsets(top: FormMetrics.firstRowTop, leading: FormMetrics.margin,
                                bottom: FormMetrics.margin, trailing: FormMetrics.margin))
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        return [stack.background(fillNode(palette.groupedBackground, environment: env))]
    }
}

extension Form {
    /// The `.columns` look: sections and loose rows in one column.
    func columnsLayout(_ parts: [LayoutNode]) -> LayoutNode {
        let rows = parts.map { $0.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading) }
        return LayoutNode.vstack(alignment: .leading, spacing: ColumnsFormMetrics.rowSpacing, rows)
            .padding(EdgeInsets(top: ColumnsFormMetrics.top, leading: ColumnsFormMetrics.sides,
                                bottom: ColumnsFormMetrics.top, trailing: ColumnsFormMetrics.sides))
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Section

/// Rows under an optional header and above an optional footer.
public struct Section<Parent, Content, Footer> {
    let header: Parent
    let content: Content
    let footer: Footer
    public typealias Body = Never
}

@MainActor
extension Section: View where Parent: View, Content: View, Footer: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }
}

@MainActor
extension Section where Parent: View, Content: View, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

@MainActor
extension Section where Parent == EmptyView, Content: View, Footer: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

@MainActor
extension Section where Parent == EmptyView, Content: View, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

@MainActor
extension Section where Parent == Text, Content: View, Footer == EmptyView {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(titleKey) }, footer: { EmptyView() })
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension Section: PrimitiveView where Parent: View, Content: View, Footer: View {
    package func _makeChildren(node: ViewNode, old: Section?, transaction: Transaction) {
        if node.environment._formColumnWidth != nil {
            // The columns look: bold headings in the label colour, small
            // secondary footers.
            node.reconcileChildren([
                (AnyHashable(0), AnyView(header.font(.system(size: ColumnsFormMetrics.headingSize, weight: .bold)).foregroundStyle(.primary))),
                (AnyHashable(1), AnyView(content)),
                (AnyHashable(2), AnyView(footer.font(.system(size: ColumnsFormMetrics.footerSize)).foregroundStyle(.secondary))),
            ], transaction: transaction)
            return
        }
        node.reconcileChildren([
            (AnyHashable(0), AnyView(header.font(.footnote).foregroundStyle(.secondary))),
            (AnyHashable(1), AnyView(content)),
            (AnyHashable(2), AnyView(footer.font(.footnote).foregroundStyle(.secondary))),
        ], transaction: transaction)
    }

    package func _lower(node: ViewNode) -> [LayoutNode] {
        guard node.children.count == 3 else { return node.lowerChildren() }
        let env = node.environment
        let header = node.children[0].lower()
        let rows = node.children[1].lower()
        let footer = node.children[2].lower()
        guard env._inForm else { return header + rows + footer }
        if env._formColumnWidth != nil {
            // Columns: the heading, the rows and the footer, 10 apart.
            let parts = (header + rows + footer).map { $0.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading) }
            return [LayoutNode(FormSectionMarker(), children: [
                LayoutNode.vstack(alignment: .leading, spacing: ColumnsFormMetrics.rowSpacing, parts),
            ])]
        }
        let inset = EdgeInsets(top: 0, leading: FormMetrics.rowInset, bottom: 0, trailing: FormMetrics.rowInset)
        var parts: [LayoutNode] = []
        if !header.isEmpty {
            parts.append(LayoutNode.vstack(alignment: .leading, header).padding(inset)
                .padding(EdgeInsets(top: 0, leading: 0, bottom: FormMetrics.headerBottom, trailing: 0)))
        }
        if !rows.isEmpty { parts.append(formGroup(rows, environment: env)) }
        if !footer.isEmpty {
            parts.append(LayoutNode.vstack(alignment: .leading, footer).padding(inset)
                .padding(EdgeInsets(top: FormMetrics.headerBottom, leading: 0, bottom: 0, trailing: 0)))
        }
        return [LayoutNode(FormSectionMarker(), children: [LayoutNode.vstack(alignment: .leading, spacing: 0, parts)])]
    }
}

// MARK: - Form styles

/// How a form arranges its content: grouped (the default) or columns.
@MainActor @preconcurrency
public protocol FormStyle {
    var _ovStyleKind: Int { get }
}

public struct AutomaticFormStyle: FormStyle {
    public init() {}
    public var _ovStyleKind: Int { 0 }
}

public struct GroupedFormStyle: FormStyle {
    public init() {}
    public var _ovStyleKind: Int { 0 }
}

public struct ColumnsFormStyle: FormStyle {
    public init() {}
    public var _ovStyleKind: Int { 1 }
}

extension FormStyle where Self == AutomaticFormStyle {
    public static var automatic: AutomaticFormStyle { AutomaticFormStyle() }
}

extension FormStyle where Self == GroupedFormStyle {
    public static var grouped: GroupedFormStyle { GroupedFormStyle() }
}

extension FormStyle where Self == ColumnsFormStyle {
    public static var columns: ColumnsFormStyle { ColumnsFormStyle() }
}

extension View {
    /// The look of forms below: grouped (the default) or columns (labels
    /// right-aligned in a column, controls after it; the desktop's
    /// settings form).
    public func formStyle<S: FormStyle>(_ style: S) -> some View {
        environment(\._formStyleKind, style._ovStyleKind)
    }
}
