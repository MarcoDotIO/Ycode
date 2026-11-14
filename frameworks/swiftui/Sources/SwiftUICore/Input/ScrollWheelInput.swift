import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One scroll event as the view graph routes it (B6-OPENVIEWS): the delta
/// in points (positive y scrolls towards the top of the content) with the
/// touchpad gesture's phase and the momentum's phase. A wheel notch has
/// `.none` in both. The platform's `ScrollEvent` maps onto it one to one.
package struct ScrollWheelInput: Sendable, Equatable {
    /// The phases of `OVPlatform.ScrollPhase`, in the same order.
    package enum Phase: UInt8, Sendable, Hashable {
        case none, began, changed, ended, cancelled
    }

    package var delta: CGSize
    package var phase: Phase
    package var momentumPhase: Phase
    package var isPrecise: Bool
    package var timestamp: TimeInterval
    package var window: UInt32

    package init(delta: CGSize, phase: Phase = .none, momentumPhase: Phase = .none, isPrecise: Bool = false,
                 timestamp: TimeInterval = 0, window: UInt32 = 0) {
        self.delta = delta
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.isPrecise = isPrecise
        self.timestamp = timestamp
        self.window = window
    }

    /// The events after a gesture's first: its changes, its end, and all of
    /// its momentum.
    package var continuesGesture: Bool {
        momentumPhase != .none || phase == .changed || phase == .ended || phase == .cancelled
    }
}
