import AppKit

/// The navigator's header rows give way below their natural width (P-024,
/// `letHeadersCompress`): their stacks resist clipping, and their controls
/// resist compression, below the usual priorities. AppKit re-solves those
/// weak constraints, and such a stack checks again for clipping and builds
/// its constraints anew, whenever the layout engine changes, which it does
/// on every frame of another area's slide (the inspector's) even though
/// the navigator does not move: about 2 ms a frame on the owner's Mac
/// (12 → 10 ms) and several times that on the 3-core CI runner
/// (B5-FIX-CI). While the navigator's width cannot change, the stacks and
/// controls that are not giving way hold at the usual priorities; their
/// layout is the same, since they are at or above their natural width.
@MainActor
final class NavigatorHeaderHold {
    /// The stacks held, with the clipping resistance each had.
    var stacks: [(NSStackView, NSLayoutConstraint.Priority)] = []
    /// The views held, with the compression resistance each had.
    var views: [(NSView, NSLayoutConstraint.Priority)] = []
    var isHolding = false
}

extension NavigatorAreaController {
    /// Holds (true) or releases (false) the header rows that give way below
    /// their natural width. Holding twice holds once.
    func holdHeaderClipping(_ hold: Bool) {
        let h = headerHold
        guard hold != h.isHolding else { return }
        h.isHolding = hold
        guard hold else {
            for (stack, p) in h.stacks { stack.setClippingResistancePriority(p, for: .horizontal) }
            for (v, p) in h.views { v.setContentCompressionResistancePriority(p, for: .horizontal) }
            h.stacks = []
            h.views = []
            return
        }
        func walk(_ v: NSView) {
            // The rows' scroll views are not header rows.
            if v is NSScrollView { return }
            if let s = v as? NSStackView, s.orientation == .horizontal {
                let p = s.clippingResistancePriority(for: .horizontal)
                // A stack narrower than its content is giving way: leave it.
                if p < .required, s.bounds.width + 0.5 >= s.fittingSize.width {
                    h.stacks.append((s, p))
                    s.setClippingResistancePriority(.required, for: .horizontal)
                }
            }
            let natural = v.intrinsicContentSize.width
            let p = v.contentCompressionResistancePriority(for: .horizontal)
            // Only a view at or above its natural width (a compressed one
            // would grow).
            if p < .defaultHigh, natural != NSView.noIntrinsicMetric, v.frame.width + 0.5 >= natural {
                h.views.append((v, p))
                v.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            }
            v.subviews.forEach(walk)
        }
        walk(view)
    }

    /// Whether the header rows are held now, and how many (tests).
    var heldHeaderCounts: (stacks: Int, views: Int)? {
        headerHold.isHolding ? (headerHold.stacks.count, headerHold.views.count) : nil
    }
}
