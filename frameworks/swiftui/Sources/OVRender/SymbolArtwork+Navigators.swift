// The Linux IDE's Symbol navigator symbol (Ycode's own navigator, which
// takes the third place of the selector there), drawn for Ycode in the same
// plain style as SymbolArtwork.swift: outlines on the 24 × 24 grid, stroke
// 1.5 to 1.75. Licence: the repository's (MIT).

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension SymbolArtwork {
    static let navigatorSymbols: [SymbolArtwork] = {
        typealias S = Shapes
        let size = CGSize(width: 62.0 / 3, height: 62.0 / 3)
        func make(_ name: String, _ ops: [Operation]) -> SymbolArtwork {
            SymbolArtwork(name: name, operations: ops, bodySize: size, bodyBaselineOffset: 11.0 / 3)
        }
        func s(_ p: RenderPath, _ width: Double) -> Operation { .stroke(p, width: width) }
        // A declaration and two members: the navigator's rows, the type a
        // badge (its letter square), the members dots under a tree line,
        // each with its name.
        func f(_ p: RenderPath) -> Operation { .fill(p, evenOdd: false) }
        let badge = S.roundedRect(3, 3, 6.5, 6.5, 1.75)
        let names = S.join([S.poly([(12.5, 6.25), (21, 6.25)]), S.poly([(15, 12.75), (21, 12.75)]), S.poly([(15, 18.75), (21, 18.75)])])
        let tree = S.join([S.poly([(6.25, 9.5), (6.25, 18.75), (9, 18.75)]), S.poly([(6.25, 12.75), (9, 12.75)])])
        let members = S.join([S.circle(11.5, 12.75, 1.9), S.circle(11.5, 18.75, 1.9)])
        return [
            make("list.bullet.indent", [s(badge, 1.75), s(names, 1.75), s(tree, 1.5), f(members)]),
        ]
    }()
}
