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

        /// The symbol's fill as 0xRRGGBB (its mark is white): the warning
        /// triangle #FFE015 (G.8), the error circle the system red.
        public var fill: UInt32 {
            switch self {
            case .error, .testFailure: 0xFF3B30
            case .warning: 0xFFE015
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

    /// The capsule's geometry (G.8, in points): 36 tall; the first symbol
    /// 16.5 inside its left end; the count 8 after its symbol; a part's
    /// count to the next part's symbol 16; the last count 11.5 from the
    /// right end, so one warning with "1" is 61 wide. Symbols are drawn
    /// at `symbolSize` (the triangle's ink 17.5 × 15.5); counts at
    /// `countSize`, regular, in the label colour.
    public enum Capsule {
        public static let height: Double = 36
        public static let leading: Double = 16.5
        public static let symbolToCount: Double = 8
        public static let partGap: Double = 18
        public static let trailing: Double = 13
        /// With symbols only (a narrow window), the last symbol's end to
        /// the right end: the capsule keeps its leading inset on both sides.
        public static let trailingSymbolOnly: Double = 16.5
        public static let symbolSize: Double = 17
        public static let symbolWidth: Double = 17.5
        public static let countSize: Double = 13
        /// The gap to the scheme capsule before it.
        public static let gapAfterScheme: Double = 7.5

        /// The capsule's width for `parts`, given each count's text width.
        public static func width(_ parts: [Part], symbolsOnly: Bool, countWidth: (String) -> Double) -> Double {
            guard !parts.isEmpty else { return 0 }
            var w = leading
            for (i, p) in parts.enumerated() {
                if i > 0 { w += partGap }
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
