import Darwin
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// `@Suite(.previewHostCheck, ...)`: no preview host outlives the test that
/// started it (specs/ide/previews.md §The macOS host). After each test,
/// passed, failed or thrown, a child of this process whose name starts with
/// `YcodePreview` (the long-lived Mac host or a built SwiftPM host) that is
/// still alive after a short grace fails the test and is killed.
///
/// Use it only on `.heavyIntegration` suites: they run one at a time, so the
/// children seen belong to the test being checked.
struct PreviewHostCheckTrait: SuiteTrait, TestTrait, TestScoping {
    static let prefix = "YcodePreview"

    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard !test.isSuite else { try await function(); return }
        var thrown: (any Error)?
        do { try await function() } catch { thrown = error }
        let left = ProcessAudit.leftovers(grace: 5) { $0.name.hasPrefix(Self.prefix) }
        if !left.isEmpty {
            Issue.record("\(test.name) left preview hosts running: \(left.map(\.description).joined(separator: ", "))")
            ProcessAudit.kill(left)
        }
        // Forget hosts that were killed (and end any the registry still holds).
        PreviewRenderer.stopMacHosts()
        if let thrown { throw thrown }
    }
}

extension Trait where Self == PreviewHostCheckTrait {
    static var previewHostCheck: Self { Self() }
}
