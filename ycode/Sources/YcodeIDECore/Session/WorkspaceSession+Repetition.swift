import Foundation
import YcodeBuild

/// Run Repeatedly (`specs/ide/testing.md` §Repetitions): test runs one
/// after another, each like Product ▸ Test of the same tests (its report,
/// results and issues); the last one's results stay.
extension WorkspaceSession {
    /// What a repeated run did.
    public struct RepetitionResult: Equatable, Sendable {
        /// The tests each iteration ran (empty = all), in order.
        public var iterations: [[DiscoveredTest]]
        /// How many iterations had a failed test.
        public var failedIterations: Int
    }

    /// Runs `only` (empty = all tests) as `repetition` says. Stop (⌘.)
    /// between iterations ends the series.
    @discardableResult
    public func runTestsRepeatedly(only: [DiscoveredTest] = [], repetition: TestRepetition) async -> RepetitionResult {
        var result = RepetitionResult(iterations: [], failedIterations: 0)
        var next: [DiscoveredTest]? = only
        repetitionCancelled = false
        while let tests = next, !repetitionCancelled {
            result.iterations.append(tests)
            // Only the outcomes of the tests asked for count (a runner's
            // filter may report others).
            let all = await runTests(only: tests)
            let outcomes = tests.isEmpty ? all : all.filter { o in tests.contains { $0.matches(o) } }
            if outcomes.contains(where: { $0.status == .failed }) { result.failedIterations += 1 }
            next = repetition.next(after: result.iterations.count, outcomes: outcomes, selection: tests, discovered: self.tests)
        }
        appendConsole(TestRepetition.summary(iterations: result.iterations.count, failedIterations: result.failedIterations, mode: repetition.mode) + "\n",
                      kind: .debugger)
        return result
    }

    /// Product ▸ Stop: ends a repeated run after the current iteration.
    public func cancelRepetition() { repetitionCancelled = true }
}
