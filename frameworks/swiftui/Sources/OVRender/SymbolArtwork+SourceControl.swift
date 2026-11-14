// Symbols of Ycode's Source Control, Test and Report navigators (B2-SCM), drawn
// for Ycode in the same plain style as SymbolArtwork.swift: outlines on
// the 24 × 24 grid, stroke 1.75. Licence: the repository's (MIT).

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension SymbolArtwork {
    static let sourceControlSymbols: [SymbolArtwork] = {
        typealias S = Shapes
        let w = 1.75
        let size = CGSize(width: 62.0 / 3, height: 62.0 / 3)
        func make(_ name: String, _ ops: [Operation]) -> SymbolArtwork {
            SymbolArtwork(name: name, operations: ops, bodySize: size, bodyBaselineOffset: 11.0 / 3)
        }
        func s(_ p: RenderPath, _ width: Double = w) -> Operation { .stroke(p, width: width) }
        func f(_ p: RenderPath) -> Operation { .fill(p, evenOdd: false) }
        func lines(_ l: [[(Double, Double)]]) -> RenderPath { S.join(l.map { S.poly($0) }) }
        // A disk drive: a slab with a light at its right.
        let drive = S.roundedRect(2.5, 7.5, 19, 9, 2.5)
        // A tray: an open box with a lip.
        let tray = S.poly([(3, 13), (3, 19.5), (21, 19.5), (21, 13), (16, 13), (15, 15.5), (9, 15.5), (8, 13), (3, 13)], closed: true)
        // An arc that turns back on itself (undo).
        var back = RenderPath()
        back.move(to: CGPoint(x: 8, y: 9))
        back.line(to: CGPoint(x: 15, y: 9))
        back.cubic(to: CGPoint(x: 15, y: 19), control1: CGPoint(x: 21.5, y: 9), control2: CGPoint(x: 21.5, y: 19))
        back.line(to: CGPoint(x: 9, y: 19))
        // A clock whose rim is an arrow going round.
        var rim = RenderPath()
        rim.move(to: CGPoint(x: 4.5, y: 12))
        rim.cubic(to: CGPoint(x: 12, y: 3.5), control1: CGPoint(x: 4.5, y: 7.3), control2: CGPoint(x: 7.8, y: 3.5))
        rim.cubic(to: CGPoint(x: 20.5, y: 12), control1: CGPoint(x: 16.7, y: 3.5), control2: CGPoint(x: 20.5, y: 7.3))
        rim.cubic(to: CGPoint(x: 12, y: 20.5), control1: CGPoint(x: 20.5, y: 16.7), control2: CGPoint(x: 16.7, y: 20.5))
        rim.cubic(to: CGPoint(x: 6, y: 18), control1: CGPoint(x: 9.6, y: 20.5), control2: CGPoint(x: 7.5, y: 19.5))
        let diamond = S.poly([(12, 2.5), (21.5, 12), (12, 21.5), (2.5, 12)], closed: true)
        return [
            make("externaldrive", [s(drive), f(S.circle(17.5, 12, 1.2)), s(S.poly([(6, 12), (12, 12)]), 1.5)]),
            make("externaldrive.fill", [f(drive)]),
            make("tray", [s(tray)]),
            // The filled pair of the Repositories view's groups (B6-OPENVIEWS,
            // `editor-area.md` H.9: filled grey group glyphs), on the
            // outlines' boxes. The tray: a box with rounded corners whose
            // upper part is cut away to leave its walls, over a solid base
            // that dips in the middle where things go in (the outline's lip).
            // The clock: its face as a solid disc over the outline's ink
            // (stroke edge included) with the hands cut out.
            make("tray.fill", [f(S.roundedRect(3, 4.5, 18, 15.5, 2.5)),
                               .knockout(S.poly([(5, 6.5), (19, 6.5), (19, 12.5), (15.5, 12.5), (14.5, 15), (9.5, 15), (8.5, 12.5), (5, 12.5)],
                                                closed: true), width: nil)]),
            make("clock.fill", [f(S.circle(12, 12, 9 + w / 2)), .knockout(S.poly([(12, 7), (12, 12), (15.5, 14)]), width: w)]),
            make("arrow.uturn.backward", [s(back), s(S.poly([(11.5, 5.5), (8, 9), (11.5, 12.5)]))]),
            make("clock.arrow.circlepath", [s(rim), s(S.poly([(2.5, 9.5), (4.5, 12.5), (7, 10)])), s(S.poly([(12, 8), (12, 12.5), (15, 14)]))]),
            make("square.and.pencil", [s(S.poly([(11, 4), (4, 4), (4, 20), (20, 20), (20, 13)])),
                                       s(S.poly([(10, 14.5), (10.5, 11.5), (18.5, 3.5), (20.5, 5.5), (12.5, 13.5)], closed: true))]),
            make("diamond", [s(diamond)]),
            make("diamond.fill", [f(diamond)]),
            make("xmark.diamond.fill", [f(diamond), .knockout(lines([[(9, 9), (15, 15)], [(15, 9), (9, 15)]]), width: 2)]),
            make("checkmark.diamond.fill", [f(diamond), .knockout(S.poly([(8.5, 12), (11, 14.5), (15.5, 9.5)]), width: 2)]),
            // A crosshair in a circle (a test target).
            make("scope", [s(S.circle(12, 12, 7.5)), s(lines([[(12, 2.5), (12, 7)], [(12, 17), (12, 21.5)], [(2.5, 12), (7, 12)], [(17, 12), (21.5, 12)]])),
                           f(S.circle(12, 12, 1.5))]),
            // A rounded square with a T (a test).
            make("t.square", [s(S.roundedRect(3.5, 3.5, 17, 17, 3)), s(lines([[(8, 8), (16, 8)], [(12, 8), (12, 17)]]))]),
            // A skipped test: an arrow in a circle.
            make("arrow.right.circle", [s(S.circle(12, 12, 9)), s(lines([[(7.5, 12), (16, 12)], [(12.5, 8.5), (16, 12), (12.5, 15.5)]]))]),
            make("play.circle", [s(S.circle(12, 12, 9)), f(S.poly([(10, 8), (16, 12), (10, 16)], closed: true))]),
        ]
    }()
}
