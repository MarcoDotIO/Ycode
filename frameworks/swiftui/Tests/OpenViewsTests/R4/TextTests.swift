import Foundation
import Testing
import OVText
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Round R4: fonts, Dynamic Type and text (07-text-images-color.md §1–2,
// 04-layout.md §3; plan suites T-TEXT and T-L10N).

private let categories = DynamicTypeSize.allCases

/// The default measurer on the bundled fonts only (deterministic).
let notoMeasurer = TypesetTextMeasurer(fonts: CatalogFontProvider(catalog: .bundled))

@Suite("T-TEXT: text styles and Dynamic Type (07 §1)")
struct DynamicTypeTests {
    /// 07 §1.1, columns xSmall … AX5.
    static let pointSizes: [(DynamicTypeTable.Style, [CGFloat])] = [
        (.largeTitle, [31, 32, 33, 34, 36, 38, 40, 44, 48, 52, 56, 60]),
        (.title1, [25, 26, 27, 28, 30, 32, 34, 38, 43, 48, 53, 58]),
        (.title2, [19, 20, 21, 22, 24, 26, 28, 34, 39, 44, 50, 56]),
        (.title3, [17, 18, 19, 20, 22, 24, 26, 31, 37, 43, 49, 55]),
        (.headline, [14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53]),
        (.subheadline, [12, 13, 14, 15, 17, 19, 21, 25, 30, 36, 42, 49]),
        (.body, [14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53]),
        (.callout, [13, 14, 15, 16, 18, 20, 22, 26, 32, 38, 44, 51]),
        (.footnote, [12, 12, 12, 13, 15, 17, 19, 23, 27, 33, 38, 44]),
        (.caption1, [11, 11, 11, 12, 14, 16, 18, 22, 26, 32, 37, 43]),
        (.caption2, [11, 11, 11, 11, 13, 15, 17, 20, 24, 29, 34, 40]),
        (.extraLargeTitle, [33, 34, 35, 36, 38, 40, 42, 44, 46, 48, 50, 52]),
        (.extraLargeTitle2, [25, 26, 27, 28, 30, 32, 34, 36, 38, 40, 42, 44]),
    ]

    static let swiftUIStyles: [(Font.TextStyle, DynamicTypeTable.Style)] = [
        (.largeTitle, .largeTitle), (.title, .title1), (.title2, .title2), (.title3, .title3),
        (.headline, .headline), (.subheadline, .subheadline), (.body, .body), (.callout, .callout),
        (.footnote, .footnote), (.caption, .caption1), (.caption2, .caption2),
    ]

    @Test("Point size table: 13 styles × 12 categories")
    func pointSizeTable() {
        for (style, sizes) in Self.pointSizes {
            for (i, c) in categories.enumerated() {
                #expect(DynamicTypeTable.pointSize(style, c) == sizes[i], "\(style) \(c)")
            }
        }
    }

    @Test("Font text styles resolve to the table's size in every category")
    func resolution() {
        for (font, row) in Self.swiftUIStyles {
            let sizes = Self.pointSizes.first { $0.0 == row }!.1
            for (i, c) in categories.enumerated() {
                let r = Font.system(font).resolve(in: Font.Context(dynamicTypeSize: c))
                #expect(r.pointSize == sizes[i], "\(font) \(c)")
            }
        }
    }

    @Test("headline is semibold, the others regular; the extra-large titles are bold")
    func weights() {
        #expect(Font.headline.resolve(in: Font.Context()).weight == .semibold)
        #expect(Font.body.resolve(in: Font.Context()).weight == .regular)
        #expect(Font.headline.weight(.light).resolve(in: Font.Context()).weight == .light)
        #expect(DynamicTypeTable.weight(.extraLargeTitle) == .bold)
        #expect(Font.title.bold().resolve(in: Font.Context()).isBold)
    }

    @Test("System fonts of a fixed size do not scale; custom fonts scale relative to their style")
    func fixedAndCustom() {
        let ax5 = Font.Context(dynamicTypeSize: .accessibility5)
        #expect(Font.system(size: 17).resolve(in: ax5).pointSize == 17)
        #expect(Font.custom("X", fixedSize: 17).resolve(in: ax5).pointSize == 17)
        #expect(Font.custom("X", size: 34).resolve(in: Font.Context(dynamicTypeSize: .xSmall)).pointSize == 28)
        let relative = Font.custom("X", size: 20, relativeTo: .largeTitle)
            .resolve(in: Font.Context(dynamicTypeSize: .accessibility5)).pointSize
        #expect(abs(relative - CGFloat(20) * 60 / 34) < 1e-9)
        #expect(Font.body.pointSize(30).resolve(in: Font.Context()).pointSize == 30)
        #expect(Font.body.scaled(by: 2).resolve(in: Font.Context()).pointSize == 34)
    }

    @Test("Bold Text (legibility weight .bold) makes text heavier")
    func legibility() {
        let bold = Font.Context(dynamicTypeSize: .large, legibilityWeight: .bold)
        #expect(Font.body.resolve(in: bold).weight == .semibold)
        #expect(Font.headline.resolve(in: bold).weight == .heavy)
    }

    @Test("Font.Resolved reports traits")
    func resolvedTraits() {
        let r = Font.body.italic().monospaced().width(.condensed).smallCaps().resolve(in: Font.Context())
        #expect(r.isItalic && r.isMonospaced && r.isSmallCaps && r.width == Font.Width.condensed.value)
        #expect(Font.Weight.bold.weightClass == 700 && Font.Weight.medium.weightClass == 500)
        #expect(Font.Width.expanded.widthClass == 7)
    }

    /// 07 §1.3: height of Text("Ag").font(style) per Dynamic Type size.
    static let heights: [(Font.TextStyle, [CGFloat])] = [
        (.largeTitle, [37, 38.33, 39.67, 40.67, 43, 45.67, 48, 52.67, 57.33, 62.33, 67, 71.67]),
        (.title, [30, 31.33, 32.33, 33.67, 36, 38.33, 40.67, 45.67, 51.33, 57.33, 63.33, 69.33]),
        (.title2, [23, 24, 25.33, 26.33, 28.67, 31.33, 33.67, 40.67, 46.67, 52.67, 60, 67]),
        (.title3, [20.33, 21.67, 23, 24, 26.33, 28.67, 31.33, 37, 44.33, 51.33, 58.67, 65.67]),
        (.headline, [17, 18, 19.33, 20.33, 23, 25.33, 27.67, 33.67, 39.67, 48, 56.33, 63.33]),
        (.subheadline, [14.33, 15.67, 17, 18, 20.33, 23, 25.33, 30, 36, 43, 50.33, 58.67]),
        (.body, [17, 18, 19.33, 20.33, 23, 25.33, 27.67, 33.67, 39.67, 48, 56.33, 63.33]),
        (.callout, [15.67, 17, 18, 19.33, 21.67, 24, 26.33, 31.33, 38.33, 45.67, 52.67, 61]),
        (.footnote, [14.33, 14.33, 14.33, 15.67, 18, 20.33, 23, 27.67, 32.33, 39.67, 45.67, 52.67]),
        (.caption, [13.33, 13.33, 13.33, 14.33, 17, 19.33, 21.67, 26.33, 31.33, 38.33, 44.33, 51.33]),
        (.caption2, [13.33, 13.33, 13.33, 13.33, 15.67, 18, 20.33, 24, 28.67, 34.67, 40.67, 48]),
    ]

    @Test("Line heights per style and category (07 §1.3): ascent + descent rounded up to the pixel grid")
    func heights() {
        for (style, hs) in Self.heights {
            for (i, c) in categories.enumerated() {
                let m = Fixture.measurer.measure(ResolvedText("Ag", font: .style(style, c)), proposal: .unspecified)
                #expect(Golden.close(m.size.height, hs[i]), "\(style) \(c): \(m.size.height) vs \(hs[i])")
            }
        }
    }

    @Test("Reference metrics (07 §1.2): ascender and descender ratios, line height, rounded baselines")
    func referenceMetrics() {
        let rows: [(CGFloat, Double, Double, Double)] = [   // size, ascender, descender, line height
            (34, 32.37, 8.20, 40.57), (28, 26.66, 6.75, 33.41), (22, 20.95, 5.31, 26.25), (20, 19.04, 4.82, 23.87),
            (17, 16.19, 4.10, 20.29), (16, 15.23, 3.86, 19.09), (13, 12.38, 3.14, 15.51), (12, 11.43, 2.89, 14.32),
            (11, 10.47, 2.65, 13.13),
        ]
        for (size, asc, desc, lh) in rows {
            let m = ReferenceFont.regular.lineMetrics(size: Double(size))
            #expect(abs(m.ascent - asc) < 0.006 && abs(m.descent - desc) < 0.006 && abs(m.lineHeight - lh) < 0.011,
                    "\(size)")
        }
        // Body: one line 20.33, pitch 22, baselines 16.33 / 38.33 (04 §3).
        let two = Fixture.measurer.measure(ResolvedText("Hello\nWorld"), proposal: .unspecified)
        #expect(Golden.close(two.size.height, 42.33) && Golden.close(two.firstBaseline!, 16.33)
                && Golden.close(two.lastBaseline!, 38.33))
    }

    @Test("A truncated line ends with an ellipsis (Noto Sans)")
    func truncationEllipsis() {
        let t = ResolvedText("Hello wonderful world", lineLimit: 1)
        let l = notoMeasurer.layout(t, width: 80, height: nil)
        #expect(l.isTruncated && l.lines.count == 1 && l.lines[0].ellipsis == .after)
        #expect(l.width <= 80 && l.lines[0].ellipsisWidth > 0)
        let m = notoMeasurer.measure(t, proposal: ProposedViewSize(width: 80, height: nil))
        #expect(m.size.width <= 80)
    }
}

@MainActor
@Suite("Text: concatenation, styling and paragraph settings")
struct TextStylingTests {
    private func resolved<V: View>(_ v: V) -> [ResolvedText] {
        var out: [ResolvedText] = []
        ViewGraph.layoutNode(for: v).forEachNode { n in
            if let t = n.behavior as? TextLeaf { out.append(t.text) }
        }
        return out
    }

    @Test("Text + Text keeps each segment's style; an outer modifier fills only unset attributes")
    func concatenation() {
        let t = (Text("a").font(.body) + Text("b")).font(.title)
        let r = resolved(t)[0]
        #expect(r.runs.map(\.string) == ["a", "b"])
        #expect(r.runs.map(\.font.textStyle) == [.body, .title])
        let b = resolved(Text("a").bold() + Text("b"))[0]
        #expect(b.runs.map(\.font.isBold) == [true, false])
        #expect((Text("x") + Text("y")).string == "xy")
    }

    @Test("Character attributes: tracking, kerning, baseline offset, weight, italic, design")
    func attributes() {
        let r = resolved(Text("a").tracking(2).kerning(1).baselineOffset(3).fontWeight(.light).italic()
            .fontDesign(.monospaced))[0].runs[0]
        #expect(r.tracking == 2 && r.kerning == 1 && r.baselineOffset == 3)
        #expect(r.font.weight == .light && r.font.isItalic && r.font.design == .monospaced)
    }

    @Test("View-level text modifiers reach the texts inside; Text's own settings win")
    func viewModifiers() {
        let r = resolved(VStack {
            Text("a")
            Text("b").fontWeight(.light)
        }.fontWeight(.heavy).italic())
        #expect(r.map(\.firstFont.weight) == [.heavy, .light])
        #expect(r.allSatisfy { $0.firstFont.isItalic })
        let bold = resolved(VStack { Text("a") }.bold())[0]
        #expect(bold.firstFont.isBold)
    }

    @Test("Environment font, Dynamic Type and legibility weight are resolved at lowering")
    func environmentFont() {
        let r = resolved(Text("a").font(.body).dynamicTypeSize(.accessibility5))[0]
        #expect(r.firstFont.size == 53)
        let lw = resolved(Text("a").environment(\.legibilityWeight, .bold))[0]
        #expect(lw.firstFont.weight == .semibold)
    }

    @Test("Paragraph settings come from the environment")
    func paragraph() {
        let p = resolved(Text("a").lineLimit(2).lineSpacing(4).multilineTextAlignment(.center)
            .truncationMode(.middle).minimumScaleFactor(0.5).allowsTightening(true))[0].paragraph
        #expect(p.lineLimit == 2 && p.lineSpacing == 4 && p.alignment == .center && p.truncation == .middle)
        #expect(p.minimumScaleFactor == 0.5 && p.allowsTightening)
        let range = resolved(Text("a").lineLimit(2...4))[0].paragraph
        #expect(range.lineLimit == 4 && range.minimumLines == 2)
        let reserved = resolved(Text("a").lineLimit(3, reservesSpace: true))[0].paragraph
        #expect(reserved.lineLimit == 3 && reserved.minimumLines == 3)
    }

    @Test("textCase transforms the shown string")
    func textCase() {
        #expect(resolved(Text("Hello").textCase(.uppercase))[0].string == "HELLO")
        #expect(resolved(Text("Hello").textCase(.lowercase))[0].string == "hello")
    }

    @Test("Reserved lines make a short text as tall as the minimum; line spacing adds per line")
    func reservedAndSpacing() {
        let one = layoutFrames(Text("Hello").probe("t"))
        let reserved = layoutFrames(Text("Hello").lineLimit(3, reservesSpace: true).probe("t"))
        #expect(Golden.close(one.frames["t"]!.height, 20.33))
        #expect(Golden.close(reserved.frames["t"]!.height, 20.33 + 2 * 22))
        let spaced = layoutFrames(Text("Hello\nWorld").lineSpacing(5).probe("t"))
        #expect(Golden.close(spaced.frames["t"]!.height, 42.33 + 5))
    }

    @Test("multilineTextAlignment places lines; leading flips in right-to-left")
    func alignment() {
        var t = ResolvedText("aaa\nbbbbbbbbbb")
        let size = CGSize(width: 300, height: 60)
        let leading = notoMeasurer.placedLines(t, size: size)
        #expect(leading[0].origin.x == 0)
        t.paragraph.alignment = .center
        let center = notoMeasurer.placedLines(t, size: size)
        #expect(abs(center[0].origin.x - (300 - center[0].line.width) / 2) < 1e-9)
        t.paragraph.alignment = .trailing
        let trailing = notoMeasurer.placedLines(t, size: size)
        #expect(abs(trailing[1].origin.x + trailing[1].line.width - 300) < 1e-9)
        t.paragraph.alignment = .leading
        t.paragraph.layoutDirection = .rightToLeft
        let rtl = notoMeasurer.placedLines(t, size: size)
        #expect(abs(rtl[0].origin.x + rtl[0].line.width - 300) < 1e-9)
        #expect(leading[1].origin.y > leading[0].origin.y)
    }

    @Test("minimumScaleFactor shrinks a one-line text to fit its width (Noto Sans)")
    func minimumScaleFactor() {
        var t = ResolvedText("A sentence that is far too long for its frame", lineLimit: 1)
        let full = notoMeasurer.measure(t, proposal: ProposedViewSize(width: 120, height: nil))
        t.paragraph.minimumScaleFactor = 0.3
        let scaled = notoMeasurer.measure(t, proposal: ProposedViewSize(width: 120, height: nil))
        #expect(scaled.size.width <= 120 && scaled.size.height < full.size.height)
        let l = notoMeasurer.layout(t, width: 120, height: nil)
        #expect(!l.isTruncated && l.scale < 1 && l.scale >= 0.3)
    }
}

@MainActor
@Suite("T-L10N: string tables and formatting (08 §3)")
struct LocalizationTests {
    /// A bundle directory with en, fr and ar tables (the probe's keys of 08 §3).
    static let bundle: Bundle = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openviews-l10n-\(ProcessInfo.processInfo.processIdentifier).bundle")
        let tables = [
            "en": "\"greeting\" = \"Hello world\";\n\"items %lld\" = \"%lld items\";\n",
            "fr": "/* French */\n\"greeting\" = \"Bonjour tout le monde\";\n\"items %lld\" = \"%lld éléments\";\n",
            "ar": "\"items %lld\" = \"%lld عناصر\";\n",
        ]
        for (lang, text) in tables {
            let l = dir.appendingPathComponent("\(lang).lproj")
            try? FileManager.default.createDirectory(at: l, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: l.appendingPathComponent("Localizable.strings"))
        }
        return Bundle(url: dir)!
    }()

    private func string(_ t: Text, _ locale: String) -> String {
        var env = EnvironmentValues()
        env.locale = Locale(identifier: locale)
        return t.resolve(in: env).string
    }

    @Test("Keys are looked up in the locale's table; verbatim text is not")
    func lookup() {
        let b = Self.bundle
        #expect(string(Text("greeting", bundle: b), "en_US") == "Hello world")
        #expect(string(Text("greeting", bundle: b), "fr_FR") == "Bonjour tout le monde")
        #expect(string(Text(verbatim: "greeting"), "fr_FR") == "greeting")
        #expect(string(Text("missing key", bundle: b), "fr_FR") == "missing key")
    }

    @Test("Interpolations use the %lld key and locale digits")
    func interpolation() {
        let b = Self.bundle
        let key: LocalizedStringKey = "items \(3)"
        #expect(key.key == "items %lld")
        #expect(string(Text(key, bundle: b), "en_US") == "3 items")
        #expect(string(Text(key, bundle: b), "fr_FR") == "3 éléments")
        #expect(string(Text(key, bundle: b), "ar_SA") == "٣ عناصر")
    }

    @Test("Format strings: positions, %% and string arguments")
    func format() {
        let args: [LocalizedStringKey.Argument] = [.string("a"), .integer(2)]
        #expect(LocalizedStringKey.format("%2$lld-%1$@ 100%%", args, locale: nil) == "2-a 100%")
        let k: LocalizedStringKey = "\("x") and \(Text("y"))"
        #expect(k.key == "%@ and %@" && k.resolved == "x and y")
    }

    @Test(".strings syntax: comments, escapes, unquoted keys")
    func stringsFile() {
        let t = StringsFile.parse("// c\n\"a\\nb\" = \"x\\\"y\"; /* c */ key = value;\n\"u\" = \"\\U00e9\";")
        #expect(t == ["a\nb": "x\"y", "key": "value", "u": "é"])
        #expect(StringsFile.parse("\"a\" = ") == nil)
    }
}
