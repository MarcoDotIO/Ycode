import Foundation
import YcodeBuild

/// The workspace's issues by kind, for the two places that show them
/// outside the Issue navigator (`editor-area.md` G.8, council rows 138 and
/// 139): the toolbar's issue capsule (a symbol and a count per kind, errors
/// first) and the issue stepper at the right end of every editor's jump bar
/// (the most severe kind's symbol between two chevrons). Both IDEs draw
/// both from this one value, so they always agree.
public struct IssueSummary: Equatable, Sendable {
    /// A kind of issue, in the order the capsule shows them.
    public enum Kind: Int, CaseIterable, Sendable {
        case error, warning, testFailure

        /// The symbol (a system symbol name on macOS; OpenViews' own
        /// artwork of the same name on Linux). Errors are a filled circle
        /// with a cross, warnings a filled triangle with an exclamation
        /// mark (G.8); test failures keep Ycode's diamond.
        public var symbol: String {
            switch self {
            case .error: "xmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .testFailure: "xmark.diamond.fill"
            }
        }

        /// The symbol in a narrow window, where the capsule collapses to the
        /// most severe kind's glyph alone (`workspace-window.md` W7, council
        /// round 8, row 198): an error is a filled octagon with a cross
        /// there; the other kinds keep their symbols.
        public var collapsedSymbol: String {
            switch self {
            case .error: "xmark.octagon.fill"
            case .warning, .testFailure: symbol
            }
        }

        /// The symbol's fill as 0xRRGGBB (its mark is white) in dark: the
        /// warning triangle #FFE015 (G.8), the error circle the system red.
        public var fill: UInt32 { fill(dark: true) }

        /// The symbol's fill in the light or dark appearance: the warning
        /// triangle #F5C200 in light (H.5, council row 161), #FFE015 in
        /// dark (G.8); the error circle the system red in both.
        public func fill(dark: Bool) -> UInt32 {
            switch self {
            case .error, .testFailure: 0xFF3B30
            case .warning: dark ? 0xFFE015 : 0xF5C200
            }
        }

        /// The accessibility title of the capsule's button for this kind.
        public var title: String {
            switch self {
            case .error: "Errors"
            case .warning: "Issues"
            case .testFailure: "Test Failures"
            }
        }
    }

    /// One kind with its count.
    public struct Part: Equatable, Sendable {
        public var kind: Kind
        public var count: Int
    }

    public var errors: Int
    public var warnings: Int
    public var failedTests: Int

    public init(errors: Int = 0, warnings: Int = 0, failedTests: Int = 0) {
        self.errors = errors
        self.warnings = warnings
        self.failedTests = failedTests
    }

    /// The counts of `diagnostics` (notes are not issues).
    public init(_ diagnostics: [Diagnostic], failedTests: Int = 0) {
        self.init(errors: diagnostics.filter { $0.severity == .error }.count,
                  warnings: diagnostics.filter { $0.severity == .warning }.count, failedTests: failedTests)
    }

    public func count(_ kind: Kind) -> Int {
        switch kind {
        case .error: errors
        case .warning: warnings
        case .testFailure: failedTests
        }
    }

    /// The kinds with issues, errors first; zero counts are left out.
    public var parts: [Part] { Kind.allCases.compactMap { k in count(k) > 0 ? Part(kind: k, count: count(k)) : nil } }

    /// No issues: the capsule is hidden (G.8: Ycode's choice until a
    /// capture without issues) and so is the jump bar's stepper.
    public var isEmpty: Bool { parts.isEmpty }

    /// The most severe kind (the stepper's symbol); nil without issues.
    public var mostSevere: Kind? { parts.first?.kind }

    /// The capsule's geometry (G.8, H.5; council rows 138, 161; in
    /// points): 36 tall; the first symbol 16.5 inside its left end; its
    /// count's ink 5 after the symbol, black in light and white in dark;
    /// a count's ink to the next part's symbol 24.5; the last count's ink
    /// 18 from the right end, so one warning with "1" is 61 wide and an
    /// error and a warning 111. The constants below are those distances
    /// for the count's text box at `countSize` (the system font's "1" has
    /// its ink from 0.83 to 4.4 of its 5.95 advance): 4 to the text, 23
    /// from a text's end to the next symbol, 16.5 from the last text's
    /// end. Symbols are drawn at `symbolSize` (the triangle's ink 17.5 ×
    /// 16); counts at `countSize`, regular.
    public enum Capsule {
        public static let height: Double = 36
        public static let leading: Double = 16.5
        public static let symbolToCount: Double = 4
        public static let partGap: Double = 23
        /// With symbols only, between a symbol and the next.
        public static let partGapSymbolsOnly: Double = 18
        public static let trailing: Double = 16.5
        /// With symbols only (a narrow window), the last symbol's end to
        /// the right end: the capsule keeps its leading inset on both sides.
        public static let trailingSymbolOnly: Double = 16.5
        public static let symbolSize: Double = 17
        public static let symbolWidth: Double = 17.5
        public static let countSize: Double = 13
        /// The gap to the scheme capsule before it.
        public static let gapAfterScheme: Double = 7.5
        /// With symbols only (a narrow window) the capsule is round, about
        /// 39 wide, and holds the most severe kind's glyph alone, centred
        /// (council round 8, row 198, at 1100 points with an error and a
        /// warning: the error's octagon in its own capsule between the
        /// scheme capsule and Add Editor's).
        public static let collapsedWidth: Double = 39
        /// The count's colour (0xRRGGBB): black in light (H.5), white in dark.
        public static func countColor(dark: Bool) -> UInt32 { dark ? 0xFFFFFF : 0x000000 }
        /// The gap between parts.
        public static func gap(symbolsOnly: Bool) -> Double { symbolsOnly ? partGapSymbolsOnly : partGap }

        /// The parts the capsule shows: all of them, or with symbols only the
        /// most severe one alone (`collapsedSymbol`).
        public static func shownParts(_ parts: [Part], symbolsOnly: Bool) -> [Part] {
            symbolsOnly ? Array(parts.prefix(1)) : parts
        }

        /// The symbol's left edge in the capsule for each shown part.
        public static func collapsedSymbolX() -> Double { (collapsedWidth - symbolWidth) / 2 }

        /// The capsule's width for `parts`, given each count's text width.
        public static func width(_ parts: [Part], symbolsOnly: Bool, countWidth: (String) -> Double) -> Double {
            guard !parts.isEmpty else { return 0 }
            if symbolsOnly { return collapsedWidth }
            var w = leading
            for (i, p) in parts.enumerated() {
                if i > 0 { w += gap(symbolsOnly: symbolsOnly) }
                w += symbolWidth
                if !symbolsOnly { w += symbolToCount + countWidth("\(p.count)") }
            }
            return w + (symbolsOnly ? trailingSymbolOnly : trailing)
        }
    }
}

extension IssueNavigatorModel {
    /// The capsule's and the stepper's summary: fresh issues and stale ones
    /// (as `capsuleCounts`), with the failed tests of the last test run.
    public func summary(fresh: [Diagnostic], failedTests: Int = 0) -> IssueSummary {
        let c = capsuleCounts(fresh: fresh)
        return IssueSummary(errors: c.errors, warnings: c.warnings, failedTests: failedTests)
    }
}
