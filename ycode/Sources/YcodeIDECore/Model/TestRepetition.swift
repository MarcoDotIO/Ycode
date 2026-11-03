import Foundation
import YcodeBuild

/// Running tests repeatedly (`specs/ide/testing.md` §Repetitions): a
/// fixed number of iterations, until a test fails, or retrying the tests
/// that failed. The three modes are xcodebuild's public
/// `-test-iterations`, `-run-tests-until-failure` and
/// `-retry-tests-on-failure` (`man xcodebuild`); Ycode runs the iterations
/// itself, one test run each.
public struct TestRepetition: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case fixed = "Fixed Iterations"
        case untilFailure = "Until Failure"
        case retryOnFailure = "Retry on Failure"
    }

    public var mode: Mode
    /// The most iterations (at least 1).
    public var maximum: Int

    public init(_ mode: Mode, maximum: Int) {
        self.mode = mode
        self.maximum = max(1, maximum)
    }

    /// The default the sheet offers.
    public static let defaultMaximum = 100

    /// What the next iteration runs after iteration `n` (1-based) produced
    /// `outcomes` for `selection` (the tests asked for; empty = all): nil
    /// to stop; otherwise the tests (empty = all again).
    public func next(after n: Int, outcomes: [TestOutcome], selection: [DiscoveredTest], discovered: [DiscoveredTest]) -> [DiscoveredTest]? {
        guard n < maximum else { return nil }
        let failed = outcomes.contains { $0.status == .failed }
        switch mode {
        case .fixed: return selection
        case .untilFailure: return failed ? nil : selection
        case .retryOnFailure:
            guard failed else { return nil }
            let pool = selection.isEmpty ? discovered : selection
            let retry = pool.filter { t in outcomes.contains { $0.status == .failed && t.matches($0) } }
            // Failures that match no discovered test: run the same set again.
            return retry.isEmpty ? selection : retry
        }
    }

    /// One line for the console after the last iteration.
    public static func summary(iterations: Int, failedIterations: Int, mode: Mode) -> String {
        let runs = iterations == 1 ? "1 iteration" : "\(iterations) iterations"
        let fails = failedIterations == 0 ? "no failures" : (failedIterations == 1 ? "1 with failures" : "\(failedIterations) with failures")
        return "Ycode: \(mode.rawValue): \(runs), \(fails)."
    }
}
