import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Scroll events with their touchpad phases for views that scroll themselves
// (B6-OPENVIEWS). The host infers the phases and synthesizes the momentum
// where the back end has neither (`ScrollGestureTracker`); a view gets every
// event of a gesture it began over, its momentum included, through
// `textSurfaceScroll(events:)`.

extension ScrollWheelInput {
    init(_ e: ScrollEvent) {
        self.init(delta: e.delta, phase: Phase(rawValue: e.phase.rawValue) ?? .none,
                  momentumPhase: Phase(rawValue: e.momentumPhase.rawValue) ?? .none, isPrecise: e.isPrecise,
                  timestamp: e.timestamp, window: e.window)
    }
}

extension ScrollEvent {
    /// The routed event, at `location` in the receiving view's coordinates.
    init(_ input: ScrollWheelInput, location: CGPoint) {
        self.init(window: input.window, location: location, delta: input.delta, isPrecise: input.isPrecise,
                  timestamp: input.timestamp, phase: ScrollPhase(rawValue: input.phase.rawValue) ?? .none,
                  momentumPhase: ScrollPhase(rawValue: input.momentumPhase.rawValue) ?? .none)
    }
}

extension View {
    /// Every scroll event over this view, with its gesture and momentum
    /// phases (`ScrollEvent.phase`, `momentumPhase`; the location in the
    /// view's coordinates). A touchpad gesture's later events and its
    /// momentum come here once its first did, wherever the pointer is, also
    /// those without motion (the phases' ends). Return true when used.
    public func textSurfaceScroll(events action: @escaping @MainActor (ScrollEvent) -> Bool) -> some View {
        _onScrollInput { input, p in MainActor.assumeIsolated { action(ScrollEvent(input, location: p)) } }
    }
}
