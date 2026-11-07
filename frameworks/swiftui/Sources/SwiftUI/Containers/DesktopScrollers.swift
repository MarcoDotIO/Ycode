import Foundation
import OVRender
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Desktop scrollers (B5-OPENVIEWS; ScrollView.swift's header has the rules
// and the measured values).

/// How scroll bars look on a desktop (OpenViews; not SwiftUI API).
///
/// - `automatic`: the desktop's setting (overlay scroll bars unless the
///   desktop asks for always-visible ones); `.scrollIndicators(.visible)`
///   picks `legacy`.
/// - `overlay`: a thin knob over the content while scrolling.
/// - `legacy`: a lane beside the content with a slot and a knob, always
///   shown when the content overflows.
public enum ScrollerStyle: Sendable, Equatable {
    case automatic, overlay, legacy

    /// The look of a scroll view on a desktop, nil on the phone host.
    static func resolved(_ env: EnvironmentValues,
                         indicators: (vertical: ScrollIndicatorVisibility, horizontal: ScrollIndicatorVisibility))
        -> ScrollerStyle? {
        guard env._desktopChrome else { return nil }
        if env.scrollerStyle != .automatic { return env.scrollerStyle }
        if indicators.vertical == .visible || indicators.horizontal == .visible { return .legacy }
        return env._prefersOverlayScrollers ? .overlay : .legacy
    }
}

/// The desktop scrollers' geometry.
package enum DesktopScrollerMetrics {
    /// The lane of an always-visible scroller.
    package static let lane: CGFloat = 17
    /// Its slot and knob.
    package static let knob: CGFloat = 11
    package static let inset: CGFloat = 3
    package static let minimumKnob: CGFloat = 20
    /// The overlay knob.
    package static let overlayKnob: CGFloat = 7
    package static let overlayInset: CGFloat = 2
}

private enum ScrollerStyleKey: EnvironmentKey { static let defaultValue = ScrollerStyle.automatic }
private enum PrefersOverlayScrollersKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// OpenViews: the desktop scroller look of the scroll views inside.
    public var scrollerStyle: ScrollerStyle {
        get { self[ScrollerStyleKey.self] }
        set { self[ScrollerStyleKey.self] = newValue }
    }

    /// The desktop's preference (PlatformSettings.overlayScrollers).
    package var _prefersOverlayScrollers: Bool {
        get { self[PrefersOverlayScrollersKey.self] }
        set { self[PrefersOverlayScrollersKey.self] = newValue }
    }
}

extension View {
    /// OpenViews: the desktop scroller look of the scroll views inside
    /// (`.legacy` keeps the scroll bars shown, as the macOS IDE's). Not
    /// SwiftUI API.
    public func scrollerStyle(_ style: ScrollerStyle) -> some View {
        environment(\.scrollerStyle, style)
    }
}

/// The parts of the desktop scrollers in a scroll view of `size` (tests and
/// drawing): lanes, slots and knobs per axis.
package struct DesktopScrollerParts: Equatable {
    package var lanes: [CGRect] = []
    package var slots: [CGRect] = []
    package var knobs: [CGRect] = []
}

@MainActor
package func desktopScrollerParts(size: CGSize, state s: ScrollViewState) -> DesktopScrollerParts {
    var parts = DesktopScrollerParts()
    guard let style = s.desktopScroller else { return parts }
    let vis = s.indicators
    let vb = s.insets.bottom, vt = s.insets.top
    let showV = s.axes.contains(.vertical) && vis.vertical != .hidden && vis.vertical != .never
        && s.contentSize.height > s.viewportSize.height + 0.5
    let showH = s.axes.contains(.horizontal) && vis.horizontal != .hidden && vis.horizontal != .never
        && s.contentSize.width > s.viewportSize.width + 0.5
    if style == .legacy {
        let m = DesktopScrollerMetrics.self
        if showV {
            let lane = CGRect(x: size.width - m.lane, y: vt, width: m.lane, height: size.height - vt - vb)
            let slot = lane.insetBy(dx: m.inset, dy: m.inset)
            let len = max(m.minimumKnob, slot.height * size.height / max(s.contentSize.height, 1))
            let frac = s.maxOffset.y > 0 ? s.offset.y / s.maxOffset.y : 0
            parts.lanes.append(lane)
            parts.slots.append(slot)
            parts.knobs.append(CGRect(x: slot.minX, y: slot.minY + (slot.height - len) * frac, width: m.knob, height: len))
        }
        if showH {
            let lane = CGRect(x: 0, y: size.height - vb - m.lane, width: size.width - (showV ? m.lane : 0), height: m.lane)
            let slot = lane.insetBy(dx: m.inset, dy: m.inset)
            let len = max(m.minimumKnob, slot.width * size.width / max(s.contentSize.width, 1))
            let frac = s.maxOffset.x > 0 ? s.offset.x / s.maxOffset.x : 0
            parts.lanes.append(lane)
            parts.slots.append(slot)
            parts.knobs.append(CGRect(x: slot.minX + (slot.width - len) * frac, y: slot.minY, width: len, height: m.knob))
        }
    } else {
        let t = DesktopScrollerMetrics.overlayKnob, inset = DesktopScrollerMetrics.overlayInset, minLength: CGFloat = 20
        if showV {
            let track = size.height - 2 * inset - vt - vb
            let len = max(minLength, track * size.height / max(s.contentSize.height, 1))
            let frac = s.maxOffset.y > 0 ? s.offset.y / s.maxOffset.y : 0
            parts.knobs.append(CGRect(x: size.width - inset - t, y: vt + inset + (track - len) * frac, width: t, height: len))
        }
        if showH {
            let track = size.width - 2 * inset
            let len = max(minLength, track * size.width / max(s.contentSize.width, 1))
            let frac = s.maxOffset.x > 0 ? s.offset.x / s.maxOffset.x : 0
            parts.knobs.append(CGRect(x: inset + (track - len) * frac, y: size.height - inset - t - vb, width: len, height: t))
        }
    }
    return parts
}

@MainActor
func drawDesktopScrollers(_ rec: inout DrawRecorder, size: CGSize, state s: ScrollViewState, environment: EnvironmentValues) {
    let parts = desktopScrollerParts(size: size, state: s)
    guard !parts.knobs.isEmpty else { return }
    let dark = environment.colorScheme == .dark
    func paint(_ c: Color) -> RenderPaint { .color(c.resolve(in: environment).renderColor) }
    if s.desktopScroller == .legacy {
        for lane in parts.lanes where dark {
            rec.add(.fill(Rectangle().path(in: lane).renderPath, paint(Color.black.opacity(0.22)), .nonZero))
        }
        for slot in parts.slots {
            rec.add(.fill(Capsule().path(in: slot).renderPath,
                          paint(dark ? Color.white.opacity(0.04) : Color.black.opacity(0.047)), .nonZero))
        }
        let knob = dark ? Color(ycodeHex: 0x9E9F9F) : Color(ycodeHex: 0x7A7A7A)
        for k in parts.knobs { rec.add(.fill(Capsule().path(in: k).renderPath, paint(knob), .nonZero)) }
        return
    }
    let opacity = s.indicatorOpacity?.presented ?? 0
    guard opacity > 0.001 else { return }
    let knob = (dark ? Color.white : Color.black).opacity(0.5 * opacity)
    for k in parts.knobs { rec.add(.fill(Capsule().path(in: k).renderPath, paint(knob), .nonZero)) }
}
