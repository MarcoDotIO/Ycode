// The Linux IDE's Interface Builder symbols (the Identity and Size
// inspector tabs, outline rows for views and constraints), drawn for Ycode
// in the same plain style as SymbolArtwork.swift: outlines on the 24 × 24
// grid, stroke 1.5 to 1.75. Licence: the repository's (MIT).

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension SymbolArtwork {
    static let interfaceBuilderSymbols: [SymbolArtwork] = {
        typealias S = Shapes
        let size = CGSize(width: 62.0 / 3, height: 62.0 / 3)
        func make(_ name: String, _ ops: [Operation]) -> SymbolArtwork {
            SymbolArtwork(name: name, operations: ops, bodySize: size, bodyBaselineOffset: 11.0 / 3)
        }
        func s(_ p: RenderPath, _ width: Double) -> Operation { .stroke(p, width: width) }
        // A card with a head and shoulders on its left and two text lines.
        var shoulders = RenderPath()
        shoulders.move(to: CGPoint(x: 5.5, y: 16.5))
        shoulders.cubic(to: CGPoint(x: 12.5, y: 16.5), control1: CGPoint(x: 6, y: 13), control2: CGPoint(x: 12, y: 13))
        let card = make("person.crop.rectangle", [s(S.roundedRect(2.5, 4.5, 19, 15, 2.5), 1.75), s(S.circle(9, 10, 2.2), 1.5), s(shoulders, 1.5),
                                                    s(S.join([S.poly([(15, 10), (19, 10)]), S.poly([(15, 14), (18, 14)])]), 1.5)])
        // A ruler: a long bar with ticks of two lengths.
        var ticks: [RenderPath] = []
        for i in 0..<5 {
            let x = 6.0 + Double(i) * 3
            ticks.append(S.poly([(x, 9), (x, i % 2 == 0 ? 12.5 : 11)]))
        }
        let ruler = make("ruler", [s(S.roundedRect(2.5, 8, 19, 8, 1.5), 1.75), s(S.join(ticks), 1.25)])
        // A square drawn with dashes (a view's outline on the canvas).
        var dashes: [RenderPath] = []
        for (x0, y0, x1, y1) in [(4.0, 4.0, 9.0, 4.0), (15.0, 4.0, 20.0, 4.0), (20.0, 4.0, 20.0, 9.0), (20.0, 15.0, 20.0, 20.0),
                                 (20.0, 20.0, 15.0, 20.0), (9.0, 20.0, 4.0, 20.0), (4.0, 20.0, 4.0, 15.0), (4.0, 9.0, 4.0, 4.0)] {
            dashes.append(S.poly([(x0, y0), (x1, y1)]))
        }
        let dashed = make("square.dashed", [s(S.join(dashes), 1.75)])
        return [card, ruler, dashed]
    }()
}
