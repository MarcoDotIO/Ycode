// Which picture each eye shows (specs/simulator/xr-viewer.md §3, §4): the
// mono picture and the two eye pictures live in their own swapchains, so a
// change of mode never shows one eye's picture in the other eye or at
// another picture's pose. Pure logic: tested without a headset.

import Foundation
import YcodeDisplayStream

struct XRLayerPlan: Equatable {
    /// Swapchain slots (CYcodeOpenXR.h): the eyes 0 and 1, mono 10; the
    /// insets 4 and 5, mono's 11.
    static let monoSlot = 10, monoInsetSlot = 11

    struct Shown: Equatable {
        var sequence: UInt64
        var pose: SpatialPose
        var fov: XRFieldOfView
    }

    private(set) var mono: Shown?
    private(set) var eyes: [Shown?] = [nil, nil]

    mutating func show(_ view: XRView, _ s: Shown) {
        switch view {
        case .mono: mono = s
        case .left: eyes[0] = s
        case .right: eyes[1] = s
        }
    }

    /// The slot each view shows its picture from (nil: nothing yet), and
    /// the picture (view, sequence, pose, fov) behind it. The newest kind
    /// wins: a mono picture newer than both eyes' is shown to both; else
    /// each eye shows its own picture, or the mono one until it has one.
    func layout() -> [(slot: Int, view: XRView, shown: Shown)]? {
        let eyeSeq = max(eyes[0]?.sequence ?? 0, eyes[1]?.sequence ?? 0)
        if let m = mono, m.sequence > eyeSeq {
            return [(Self.monoSlot, .mono, m), (Self.monoSlot, .mono, m)]
        }
        var out: [(slot: Int, view: XRView, shown: Shown)] = []
        for e in 0..<2 {
            if let s = eyes[e] { out.append((e, e == 0 ? .left : .right, s)) }
            else if let m = mono { out.append((Self.monoSlot, .mono, m)) }
            else if let other = eyes[1 - e] { out.append((1 - e, e == 0 ? .right : .left, other)) }
            else { return nil }
        }
        return out
    }

    static func insetSlot(for view: XRView) -> Int {
        switch view {
        case .mono: monoInsetSlot
        case .left: 4
        case .right: 5
        }
    }
}
