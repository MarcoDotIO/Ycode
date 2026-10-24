import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

/// One row of golden-layout.md.
struct GoldenCase {
    struct Fit {
        var proposal: ProposedViewSize
        var expected: CGSize
    }
    var id: String
    var placed: CGSize
    var fits: [Fit]
    var frames: [String: CGRect]
    var baselines: (first: CGFloat, last: CGFloat)?
}

/// Runs a golden case against the engine with the R3 stubs (Fixture).
///
/// Every check is computed on a fresh tree. A check whose computation asked
/// the text stub for something it cannot measure exactly (a text narrower
/// than its single line, or the baseline of a zero-size text) is *skipped*
/// (recorded, not compared); everything else must match within the spec's
/// tolerance of 0.01 pt (04-layout.md §9, 10-plan.md T-LAYOUT-F).
enum Golden {
    static let tolerance: CGFloat = 0.01

    struct Report {
        var passed: [String] = []
        var skipped: [String] = []
        var failed: [String] = []
    }

    static func close(_ a: CGFloat, _ b: CGFloat) -> Bool {
        if a.isInfinite || b.isInfinite { return a == b }
        return abs(a - b) <= tolerance
    }

    static func describe(_ p: ProposedViewSize) -> String {
        func d(_ v: CGFloat?) -> String { v.map { $0.isInfinite ? "∞" : String(format: "%g", Double($0)) } ?? "nil" }
        return "\(d(p.width))×\(d(p.height))"
    }

    @discardableResult
    static func run(_ c: GoldenCase, sourceLocation: SourceLocation = #_sourceLocation,
                    _ build: () -> LayoutNode) -> Report {
        var r = Report()
        let engine = Fixture.engine
        for fit in c.fits {
            let label = "fit[\(describe(fit.proposal))]"
            let (size, exact) = engine.sizeThatFits(build(), fit.proposal)
            guard exact else { r.skipped.append(label); continue }
            if close(size.width, fit.expected.width) && close(size.height, fit.expected.height) {
                r.passed.append(label)
            } else {
                r.failed.append(label)
                Issue.record("\(c.id) \(label): got \(size), expected \(fit.expected)", sourceLocation: sourceLocation)
            }
        }
        if !c.frames.isEmpty || c.baselines != nil {
            let result = engine.layout(build(), proposal: ProposedViewSize(c.placed))
            let frames = result.namedFrames
            let baselines = result.baselines
            if result.isExact {
                for (name, expected) in c.frames.sorted(by: { $0.key < $1.key }) {
                    let label = "frame[\(name)]"
                    guard let f = frames[name] else {
                        r.failed.append(label)
                        Issue.record("\(c.id) \(label): not placed", sourceLocation: sourceLocation)
                        continue
                    }
                    if close(f.minX, expected.minX) && close(f.minY, expected.minY)
                        && close(f.width, expected.width) && close(f.height, expected.height) {
                        r.passed.append(label)
                    } else {
                        r.failed.append(label)
                        Issue.record("\(c.id) \(label): got \(f), expected \(expected)", sourceLocation: sourceLocation)
                    }
                }
                if let b = c.baselines {
                    if close(baselines.first, b.first) && close(baselines.last, b.last) {
                        r.passed.append("baselines")
                    } else {
                        r.failed.append("baselines")
                        Issue.record("\(c.id) baselines: got \(baselines), expected \(b)", sourceLocation: sourceLocation)
                    }
                }
            } else {
                r.skipped.append(contentsOf: c.frames.keys.sorted().map { "frame[\($0)]" })
                if c.baselines != nil { r.skipped.append("baselines") }
            }
        }
        print("GOLDEN \(c.id) pass=\(r.passed.count) skip=\(r.skipped.count) fail=\(r.failed.count)"
              + (r.skipped.isEmpty ? "" : " skipped=\(r.skipped.joined(separator: ","))")
              + (r.failed.isEmpty ? "" : " FAILED=\(r.failed.joined(separator: ","))"))
        return r
    }
}

extension CGRect {
    init(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) { self.init(x: x, y: y, width: w, height: h) }
}

extension GoldenCase.Fit {
    init(_ w: CGFloat?, _ h: CGFloat?, _ ew: CGFloat, _ eh: CGFloat) {
        self.init(proposal: ProposedViewSize(width: w, height: h), expected: CGSize(width: ew, height: eh))
    }
}

let inf = CGFloat.infinity

/// Checks one entry of the default-spacing matrix: the distance from the
/// `from` view to the `to` view placed after it, horizontally and vertically.
enum GoldenSpacing {
    static func check(_ id: String, from: () -> LayoutNode, to: () -> LayoutNode,
                      horizontal: CGFloat, vertical: CGFloat,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        let engine = Fixture.engine
        let a = from(), b = to()
        engine.prepare(a)
        engine.prepare(b)
        let h = a.spacing.distance(to: b.spacing, along: .horizontal)
        let v = a.spacing.distance(to: b.spacing, along: .vertical)
        #expect(Golden.close(h, horizontal), "\(id) horizontal: got \(h), expected \(horizontal)", sourceLocation: sourceLocation)
        #expect(Golden.close(v, vertical), "\(id) vertical: got \(v), expected \(vertical)", sourceLocation: sourceLocation)
    }
}
