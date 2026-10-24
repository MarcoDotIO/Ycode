import Foundation
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// A test-only spelling of layout trees that mirrors the probe sources of
// golden-layout.md (lower-case names, because the real view types arrive in
// round R2): `HStack { Text("A") }` is written `hstack { text("A") }`.

@resultBuilder
enum NodeBuilder {
    static func buildExpression(_ n: LayoutNode) -> [LayoutNode] { [n] }
    static func buildExpression(_ ns: [LayoutNode]) -> [LayoutNode] { ns }
    static func buildBlock(_ parts: [LayoutNode]...) -> [LayoutNode] { parts.flatMap { $0 } }
    static func buildArray(_ parts: [[LayoutNode]]) -> [LayoutNode] { parts.flatMap { $0 } }
    static func buildOptional(_ p: [LayoutNode]?) -> [LayoutNode] { p ?? [] }
}

@resultBuilder
enum GridBuilder {
    static func buildExpression(_ r: GridContent) -> [GridContent] { [r] }
    static func buildExpression(_ n: LayoutNode) -> [GridContent] { [.single(n)] }
    static func buildBlock(_ parts: [GridContent]...) -> [GridContent] { parts.flatMap { $0 } }
}

func hstack(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
            @NodeBuilder _ content: () -> [LayoutNode]) -> LayoutNode {
    .hstack(alignment: alignment, spacing: spacing, content())
}

func vstack(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
            @NodeBuilder _ content: () -> [LayoutNode]) -> LayoutNode {
    .vstack(alignment: alignment, spacing: spacing, content())
}

func zstack(alignment: Alignment = .center, @NodeBuilder _ content: () -> [LayoutNode]) -> LayoutNode {
    .zstack(alignment: alignment, content())
}

func grid(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil,
          @GridBuilder _ content: () -> [GridContent]) -> LayoutNode {
    .grid(alignment: alignment, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing, content())
}

func gridRow(alignment: VerticalAlignment? = nil, @NodeBuilder _ content: () -> [LayoutNode]) -> GridContent {
    .row(alignment: alignment, cells: content())
}

func lazyVGrid(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
               @NodeBuilder _ content: () -> [LayoutNode]) -> LayoutNode {
    .lazyVGrid(columns: columns, alignment: alignment, spacing: spacing, content())
}

func viewThatFits(in axes: Axis.Set = [.horizontal, .vertical], @NodeBuilder _ content: () -> [LayoutNode]) -> LayoutNode {
    .viewThatFits(in: axes, content())
}

func geometryReader(@NodeBuilder _ content: () -> [LayoutNode]) -> LayoutNode { .geometryReader(content()) }

func forEach(_ range: Range<Int>, _ body: (Int) -> LayoutNode) -> [LayoutNode] { range.map(body) }

func text(_ s: String) -> LayoutNode { .text(s) }
func color() -> LayoutNode { .color() }
func rectangle() -> LayoutNode { .rectangle() }
func circle() -> LayoutNode { .circle() }
func capsule() -> LayoutNode { .capsule() }
func spacer(minLength: CGFloat? = nil) -> LayoutNode { .spacer(minLength: minLength) }
func divider() -> LayoutNode { .divider() }
func image(systemName: String) -> LayoutNode { .image(systemName: systemName) }
func emptyView() -> LayoutNode { .empty() }

extension TextFont {
    static let largeTitle = TextFont.style(.largeTitle)
    static let title = TextFont.style(.title)
    static let title2 = TextFont.style(.title2)
    static let title3 = TextFont.style(.title3)
    static let headline = TextFont.style(.headline)
    static let subheadline = TextFont.style(.subheadline)
    static let callout = TextFont.style(.callout)
    static let footnote = TextFont.style(.footnote)
    static let caption = TextFont.style(.caption)
    static let caption2 = TextFont.style(.caption2)
    static func system(size: CGFloat) -> TextFont { TextFont(size: size) }
}

extension LayoutNode {
    /// The probe of golden-layout.md: a geometry reader in the background,
    /// which reports its own frame (aligned to the probed view's centre
    /// guides, explicit ones included).
    func probe(_ name: String) -> LayoutNode {
        background(LayoutNode.geometryReader().named(name))
    }

    /// `.font(_:)` applied directly to a text or symbol.
    func font(_ f: TextFont) -> LayoutNode {
        if let t = behavior as? TextLeaf {
            var r = t.text
            for i in r.runs.indices { r.runs[i].font = f }
            return .text(r)
        }
        if let i = behavior as? ImageLeaf { return LayoutNode(ImageLeaf(i.source, resizable: i.resizable, font: f)) }
        fatalError("font(_:) is only supported directly on a text or image in tests")
    }

    /// `Image.resizable()`.
    func resizable() -> LayoutNode {
        guard let i = behavior as? ImageLeaf else { fatalError("resizable() needs an image") }
        return LayoutNode(ImageLeaf(i.source, resizable: true, font: i.font))
    }

    /// `.lineLimit(_:)` applied directly to a text.
    func lineLimit(_ n: Int?) -> LayoutNode {
        guard let t = behavior as? TextLeaf else { fatalError("lineLimit(_:) needs a text") }
        var r = t.text
        r.paragraph.lineLimit = n
        return .text(r)
    }

    /// `Text.bold()`.
    func bold() -> LayoutNode {
        guard let t = behavior as? TextLeaf else { fatalError("bold() needs a text") }
        var r = t.text
        for i in r.runs.indices { r.runs[i].font = r.runs[i].font.bolded() }
        return .text(r)
    }
}
