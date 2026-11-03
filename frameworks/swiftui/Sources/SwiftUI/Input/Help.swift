import Foundation
import Observation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Help tags (round R13; `help(_:)`, public documentation: a tooltip on
// macOS, and the view's accessibility hint).
//
// Design (Ycode's): a pointer that rests on a view with help text for
// `TooltipMetrics.delay` seconds shows the text in a small box under the
// pointer, kept inside the window (above the pointer when there is no room
// below). Leaving the view, pressing a pointer button or a key hides it; a
// tooltip that was just hidden by leaving shows again at once on the next
// view with help (within `TooltipMetrics.grace`), as desktop tooltips do.
// The box is drawn in the window, over everything else, and takes no input.

enum TooltipMetrics {
    static let delay: TimeInterval = 0.8
    static let grace: TimeInterval = 0.5
    /// Below the pointer (room for the cursor).
    static let offset: CGFloat = 18
    static let maxWidth: CGFloat = 320
}

/// The tooltip a window shows.
@MainActor
@Observable
package final class TooltipCenter {
    package struct Tip: Equatable {
        package let text: String
        /// The pointer in window coordinates when the tip appeared.
        package let point: CGPoint
        package let owner: ObjectIdentifier
    }

    package private(set) var current: Tip?
    @ObservationIgnored var lastHidden: TimeInterval = -.infinity

    package init() {}

    func show(_ tip: Tip) { if current != tip { current = tip } }

    func hide(owner: ObjectIdentifier? = nil, at time: TimeInterval) {
        guard let c = current, owner == nil || c.owner == owner else { return }
        current = nil
        lastHidden = time
    }

    /// Hides whatever is shown (a press or a key).
    package func dismiss() {
        current = nil
        lastHidden = -.infinity
    }
}

/// Hover state of one view with help text.
@MainActor
final class HelpState: HoverHandling {
    var text: String
    weak var services: WindowServices?
    private var inside = false
    private var point = CGPoint.zero

    init(text: String) { self.text = text }

    nonisolated func hover(location: CGPoint?, frame: CGRect) {
        MainActor.assumeIsolated { hoverOnMain(location: location, frame: frame) }
    }

    private func hoverOnMain(location: CGPoint?, frame: CGRect) {
        guard let services else { return }
        let id = ObjectIdentifier(self)
        let now = services.lastEventTime
        if let l = location {
            point = CGPoint(x: frame.minX + l.x, y: frame.minY + l.y)
            guard !inside else { return }
            inside = true
            guard !text.isEmpty else { return }
            if now - services.tooltips.lastHidden < TooltipMetrics.grace {
                services.tooltips.show(.init(text: text, point: point, owner: id))
            } else {
                services.setTimer(self, at: now + TooltipMetrics.delay) { [weak self] _ in self?.fire() }
            }
        } else if inside {
            inside = false
            services.setTimer(self, at: nil) { _ in }
            services.tooltips.hide(owner: id, at: now)
        }
    }

    private func fire() {
        guard inside, !text.isEmpty, let services else { return }
        services.tooltips.show(.init(text: text, point: point, owner: ObjectIdentifier(self)))
    }

    func removed() {
        guard let services else { return }
        services.setTimer(self, at: nil) { _ in }
        services.tooltips.hide(owner: ObjectIdentifier(self), at: services.lastEventTime)
    }
}

struct HelpModifier: PrimitiveModifier {
    let text: String

    private func sync(_ node: ViewNode) {
        let s = (node.primitiveState as? HelpState) ?? HelpState(text: text)
        s.text = text
        s.services = node.environment._windowServices
        node.primitiveState = s
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: HelpModifier, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) { (node.primitiveState as? HelpState)?.removed() }
}

extension View {
    /// Help text: a tooltip while the pointer rests on the view, and the
    /// view's accessibility hint.
    public func help(_ textKey: LocalizedStringKey) -> some View { help(Text(textKey)) }

    public func help(_ text: Text) -> some View {
        let s = text.plainString
        return modifier(HelpModifier(text: s)).accessibilityHint(Text(verbatim: s))
    }

    @_disfavoredOverload
    public func help<S: StringProtocol>(_ text: S) -> some View { help(Text(verbatim: String(text))) }
}

/// The window's tooltip layer (over the content, presentations and
/// overlay pop-ups).
struct TooltipLayer: View {
    let center: TooltipCenter
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let tip = center.current {
            let palette = ControlPalette(scheme)
            TooltipPlacement(point: tip.point) {
                Text(verbatim: tip.text)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .frame(maxWidth: TooltipMetrics.maxWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(palette.menuBackground)
                    .overlay { Rectangle().strokeBorder(palette.outline, lineWidth: 1) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// Places its one subview under `point`, kept inside the bounds.
struct TooltipPlacement: Layout {
    let point: CGPoint

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let s = subviews.first else { return }
        let size = s.sizeThatFits(ProposedViewSize(width: min(TooltipMetrics.maxWidth + 14, bounds.width - 8), height: nil))
        var x = bounds.minX + point.x
        var y = bounds.minY + point.y + TooltipMetrics.offset
        x = max(bounds.minX + 4, min(x, bounds.maxX - size.width - 4))
        if y + size.height > bounds.maxY - 4 { y = bounds.minY + point.y - size.height - 6 }
        y = max(bounds.minY + 4, y)
        s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}
