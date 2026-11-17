import Foundation
import Testing

/// Keeps tests that change the app-wide appearance apart from tests that
/// read colours under an appearance they chose (beta 4 hygiene: the
/// MergeSheet flakes).
///
/// Settings ▸ Appearance is applied to every workspace window of the
/// process (`WorkspaceWindowController` sets `window.appearance` on each
/// preferences change, and back to the system's when the test restores
/// it). In a full `YcodeUITests` run suites interleave on the main actor,
/// so a suite that switched Light/Dark repainted the merge suites' windows
/// between their opening and their pixel checks: their alert, veil and
/// sheet colours came out in the other appearance. Readers
/// (`.appearanceReader`, suite level) run together; a writer
/// (`.appearanceWriter`, per test) waits for them and runs alone.
struct AppAppearanceExclusiveTrait: SuiteTrait, TestTrait, TestScoping {
    let writes: Bool

    var isRecursive: Bool { false }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        await AppearanceGate.shared.enter(writing: writes)
        do {
            try await function()
        } catch {
            await AppearanceGate.shared.leave(writing: writes)
            throw error
        }
        await AppearanceGate.shared.leave(writing: writes)
    }
}

extension Trait where Self == AppAppearanceExclusiveTrait {
    /// The suite checks colours under the appearance it set on its windows.
    static var appearanceReader: Self { .init(writes: false) }
    /// The test changes Settings ▸ Appearance, or needs no reader's
    /// windows open while it runs (it runs alone among them).
    static var appearanceWriter: Self { .init(writes: true) }
}

/// A readers–writer gate: any number of readers, or one writer.
actor AppearanceGate {
    static let shared = AppearanceGate()
    private var readers = 0
    private var writing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter(writing w: Bool) async {
        while w ? (writing || readers > 0) : writing {
            await withCheckedContinuation { waiters.append($0) }
        }
        if w { writing = true } else { readers += 1 }
    }

    func leave(writing w: Bool) {
        if w { writing = false } else { readers -= 1 }
        let all = waiters
        waiters = []
        for c in all { c.resume() }
    }
}
