import Foundation
import Testing
import YcodeProject
@testable import YcodeIDECore

/// R38 (`specs/ide/reference-ui-6.md` §1.1–§1.3): the window title, the
/// Welcome window at launch, opening loose files, the editor at first open.
@MainActor
@Suite(.serialized) struct WindowIdentityR38Tests {
    // MARK: W2 — no Welcome window when launched with a document

    @Test func welcomeGateWaitsForOpensRequestedAtLaunch() {
        // Each step returns whether to show the Welcome window now.
        func run(_ steps: [(inout WelcomeLaunchGate) -> Bool]) -> [Bool] {
            var g = WelcomeLaunchGate()
            return steps.map { $0(&g) }
        }
        let request: (inout WelcomeLaunchGate) -> Bool = { $0.openRequested(); return false }
        func check(_ n: Int) -> (inout WelcomeLaunchGate) -> Bool { { $0.launchCheck(openDocuments: n) } }
        func finish(_ n: Int) -> (inout WelcomeLaunchGate) -> Bool { { $0.openFinished(openDocuments: n) } }
        // Launched by opening a document: the open is in flight at the
        // check; it opens, so no Welcome; later opens never show it.
        #expect(run([request, check(0), finish(1), request, finish(0)]) == [false, false, false, false, false])
        // The open fails: nothing is open in the end, so Welcome shows.
        #expect(run([request, check(0), finish(0)]) == [false, false, true])
        // The open finished before the check.
        #expect(run([request, finish(1), check(1)]) == [false, false, false])
        // Plain launch; a launch with restored windows.
        #expect(run([check(0)]) == [true])
        #expect(run([check(2)]) == [false])
    }
}
