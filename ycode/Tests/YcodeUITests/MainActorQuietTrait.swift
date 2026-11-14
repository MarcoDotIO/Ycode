import Foundation
import Testing

/// `@Suite(.mainActorQuiet, ...)`: the suite starts once a hop to the main
/// actor is quick again.
///
/// A full `YcodeUITests` run starts hundreds of main-actor tests at once,
/// and most of them run synchronously for a second or more. The main queue
/// is first in, first out, so every hop to the main actor waits for the
/// work queued before it: in the first half of a full run one hop took
/// 50–110 s (the main-thread watchdog's ping, and a hub test's own
/// `Task.detached` result, waited that long). A synchronous test pays that
/// once; a test that awaits its controller's tasks, subprocesses and their
/// exits makes about ten hops in a row and pays it every time, so a test of
/// 1.5 s passed its 5-minute limit in every full run.
///
/// The wait happens in the suite's scope, before any of its tests starts,
/// so it does not count against their time limits: those still measure the
/// tests' own work. It ends when three probes in a row come back from the
/// main actor within `quick` seconds, or after `longest` seconds (then the
/// suite runs anyway).
struct MainActorQuietTrait: SuiteTrait, TestScoping {
    var quick: TimeInterval = 0.5
    var longest: TimeInterval = 20 * 60

    var isRecursive: Bool { false }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        await Self.waitForQuietMainActor(quick: quick, longest: longest)
        try await function()
    }

    /// Returns once three main-actor probes in a row answer within `quick`
    /// seconds, or after `longest` seconds.
    static func waitForQuietMainActor(quick: TimeInterval, longest: TimeInterval) async {
        let deadline = Date().addingTimeInterval(longest)
        var quickInARow = 0
        while quickInARow < 3, Date() < deadline {
            let sent = Date()
            await MainActor.run {}
            quickInARow = Date().timeIntervalSince(sent) <= quick ? quickInARow + 1 : 0
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}

extension Trait where Self == MainActorQuietTrait {
    static var mainActorQuiet: Self { Self() }
}
