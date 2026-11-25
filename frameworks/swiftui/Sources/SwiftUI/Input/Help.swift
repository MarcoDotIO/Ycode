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
// `TooltipTimings.delay` seconds shows the text in a small box under the
// pointer, kept inside the window (above the pointer when there is no room
// below). Pressing a pointer button or a key hides it at once. Leaving the
// view keeps it `TooltipTimings.hold` seconds, then fades it out linearly
// over `TooltipTimings.fade` (both 0 by default: it goes at once). A
// pointer that reaches another view with help while a tip is still drawn
// (or within `TooltipTimings.grace` of its hiding) replaces it in one
// frame once the hold is over, without a new delay, as desktop tooltips
// do. The box is drawn in the window, over everything else, and takes no
// input.

/// The tooltip's timing; an app sets its own once at launch (Ycode: 1.56 s,
/// a 350 ms hold and a 460 ms linear fade, P-197).
@MainActor
public enum TooltipTimings {
    /// From the pointer's arrival to the tip.
    public static var delay: TimeInterval = 0.8
    /// After the pointer leaves: how long the tip stays.
    public static var hold: TimeInterval = 0
    /// Then: the linear fade to nothing.
    public static var fade: TimeInterval = 0
    /// After a tip has gone: the next view's tip shows at once within this.
    public static var grace: TimeInterval = 0.5
}

enum TooltipMetrics {
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
    /// The tip is fading out (the layer animates its opacity to 0).
    package private(set) var fading = false
    @ObservationIgnored var lastHidden: TimeInterval = -.infinity
    /// When the pointer left the current tip's view (held, then fading).
    @ObservationIgnored private(set) var leftAt: TimeInterval?
    /// A tip that replaces the leaving one once its hold is over.
    @ObservationIgnored private(set) var pending: Tip?
    @ObservationIgnored weak var services: WindowServices?

    package init() {}

    /// Shows `tip` now (a view's delay ended, or a swap).
    func show(_ tip: Tip) {
        leftAt = nil
        pending = nil
        if fading { fading = false }
        if current != tip { current = tip }
        reschedule()
    }

    /// A view with help text is under the pointer at `time`: true when its
    /// tip is shown at once or by a swap (no delay of its own).
    func arrive(_ tip: Tip, at time: TimeInterval) -> Bool {
        if current != nil, let left = leftAt {
            // Still drawn: replaced when the hold ends (§8.1 of Ycode's spec).
            if time >= left + TooltipTimings.hold { show(tip) } else {
                pending = tip
                reschedule()
            }
            return true
        }
        if current == nil, time - lastHidden < TooltipTimings.grace {
            show(tip)
            return true
        }
        return false
    }

    /// The pointer left `owner`'s view at `time`.
    func hide(owner: ObjectIdentifier? = nil, at time: TimeInterval) {
        if let p = pending, owner == nil || p.owner == owner {
            // Left the next view before its swap: the old tip keeps leaving.
            pending = nil
            reschedule()
            return
        }
        guard let c = current, owner == nil || c.owner == owner, leftAt == nil else { return }
        if TooltipTimings.hold + TooltipTimings.fade <= 0 {
            remove(at: time)
            return
        }
        leftAt = time
        reschedule()
    }

    private func remove(at time: TimeInterval) {
        current = nil
        if fading { fading = false }
        leftAt = nil
        pending = nil
        lastHidden = time
        reschedule()
    }

    /// Hides whatever is shown (a press or a key).
    package func dismiss() {
        current = nil
        if fading { fading = false }
        leftAt = nil
        pending = nil
        lastHidden = -.infinity
        reschedule()
    }

    /// The center's one timer: the swap, the fade's start or its end.
    private func reschedule() {
        guard let services else { return }
        guard current != nil, let left = leftAt else {
            services.setTimer(self, at: nil) { _ in }
            return
        }
        let fadeStart = left + TooltipTimings.hold
        if let p = pending {
            services.setTimer(self, at: fadeStart) { [weak self] _ in self?.show(p) }
        } else if !fading {
            services.setTimer(self, at: fadeStart) { [weak self] t in
                guard let self else { return }
                if TooltipTimings.fade > 0 { self.fading = true }
                self.services?.setTimer(self, at: fadeStart + TooltipTimings.fade) { [weak self] t in self?.remove(at: t) }
                if TooltipTimings.fade <= 0 { self.remove(at: t) }
            }
        }
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
        let center = services.tooltips
        center.services = services
        if let l = location {
            point = CGPoint(x: frame.minX + l.x, y: frame.minY + l.y)
            guard !inside else { return }
            inside = true
            guard !text.isEmpty else { return }
            if !center.arrive(.init(text: text, point: point, owner: id), at: now) {
                services.setTimer(self, at: now + TooltipTimings.delay) { [weak self] _ in self?.fire() }
            }
        } else if inside {
            inside = false
            services.setTimer(self, at: nil) { _ in }
            center.hide(owner: id, at: now)
        }
    }

    private func fire() {
        guard inside, !text.isEmpty, let services else { return }
        services.tooltips.services = services
        services.tooltips.show(.init(text: text, point: point, owner: ObjectIdentifier(self)))
    }

    func removed() {
        guard let services else { return }
        services.setTimer(self, at: nil) { _ in }
        services.tooltips.services = services
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
            let fading = center.fading
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
            // Leaving: a linear fade to nothing (`TooltipTimings.fade`).
            .opacity(fading ? 0 : 1)
            .animation(fading ? .linear(duration: TooltipTimings.fade) : nil, value: fading)
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
