import Foundation
import OVText
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
#else
@testable import SwiftUICore
#endif

// B5-OPENVIEWS (`cross-platform-parity.md` §15 OV-4): Inter with the
// `desktopUI` tracking takes the widths of the macOS IDE's UI font, so
// wrapping and truncation match.

@Suite("B5 font metric adjustment")
struct FontTrackingTests {
    /// The macOS IDE's widths of IDE strings (Core Text on Ycode's macOS
    /// host, the system font): string, size, weight class, width.
    static let reference: [(String, CGFloat, Int, Double)] = [
        ("Sources", 11, 400, 42.60),
        ("No Explicit Line Endings", 11, 400, 125.89),
        ("Default - Swift Source", 11, 400, 115.87),
        ("Identity and Type", 11, 600, 95.07),
        ("Are you sure you want to merge from", 13, 600, 232.58),
        ("Simulator Runtimes…", 13, 400, 127.92),
        ("Relative to Group", 11, 400, 90.48),
        ("Uncommitted Changes", 13, 400, 138.80),
    ]

    static func measurer(adjusted: Bool) -> TypesetTextMeasurer {
        let c = FontCatalog()
        c.addBundledFonts()
        c.setFamilies(["Inter 24pt", "Noto Sans"], for: .default)
        if adjusted { c.setTracking(.desktopUI, forFamily: FontTracking.desktopUIFamily) }
        return TypesetTextMeasurer(fonts: CatalogFontProvider(catalog: c))
    }

    static func width(_ m: TypesetTextMeasurer, _ s: String, _ size: CGFloat, _ weight: Int) -> Double {
        let w: Font.Weight = weight >= 600 ? .semibold : .regular
        var text = ResolvedText(s, font: TextFont(size: size, weight: w))
        text.paragraph.displayScale = 2
        return m.layout(text, width: nil, height: nil).lines.map(\.width).max() ?? 0
    }

    @Test func adjustedInterMatchesTheMacWidthsWithinTwoPercent() {
        let plain = Self.measurer(adjusted: false), adjusted = Self.measurer(adjusted: true)
        var before = 0.0, after = 0.0
        for (s, size, weight, ref) in Self.reference {
            let a = Self.width(adjusted, s, size, weight), p = Self.width(plain, s, size, weight)
            #expect(abs(a - ref) / ref < 0.02, "\(s) \(size): \(a) against \(ref)")
            before += abs(p - ref) / ref
            after += abs(a - ref) / ref
        }
        // The plain face ran about 4 % narrower on these strings.
        #expect(before / Double(Self.reference.count) > 0.025)
        #expect(after / Double(Self.reference.count) < 0.012)
    }

    @Test func trackingInterpolatesAndOnlyTouchesTheSystemFont() {
        let t = FontTracking.desktopUI
        #expect(abs(t.tracking(size: 11, weight: 400) - 0.3127) < 1e-9)
        #expect(abs(t.tracking(size: 11.5, weight: 400) - (0.3127 + 0.2653) / 2) < 1e-9)
        #expect(abs(t.tracking(size: 11, weight: 450) - (0.3127 + 0.3663) / 2) < 1e-9)
        #expect(abs(t.tracking(size: 44, weight: 400) - (-0.5134 * 2)) < 1e-9)
        #expect(abs(FontTracking.desktopMonospaced.tracking(size: 13, weight: 400) - 0.2366) < 1e-9)
        // An explicit family is drawn as asked.
        let c = FontCatalog()
        c.addBundledFonts()
        c.setTracking(.desktopUI, forFamily: "Inter 24pt")
        let provider = CatalogFontProvider(catalog: c)
        var named = TextFont(size: 11)
        named.family = "Inter 24pt"
        let face = provider.face(for: named)
        #expect(provider.trackingAdjustment(for: named, face: face) == 0)
        #expect(provider.trackingAdjustment(for: TextFont(size: 11), face: face) > 0.3)
    }
}
