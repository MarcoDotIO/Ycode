import Foundation
import YcodeBuild
import YcodeIDECore
import YcodeSubprocess

/// Running tests from the window (`specs/ide/testing.md`): Product ▸ Test,
/// Test Again, a Test navigator row and a gutter diamond.
extension WorkspaceShellModel {
    /// Runs every test (`only` empty) or the given ones; results go to the
    /// Test navigator and the gutter, failures to the Issue navigator and
    /// the editor, and the run to the Report navigator.
    @discardableResult
    public func runTests(_ only: [DiscoveredTest] = []) async -> [TestOutcome] {
        guard saveAllBeforeBuilding() else { return [] }
        #if os(Linux)
        // No toolchain: the build engine says what to install, as Build does.
        if session.model.kind == .package, session.testRunner.swift == TestRunner().swift, !HostTool.isInFlatpak(),
           ShellToolchain.locate("swift") == nil {
            await build(.test)
            return []
        }
        #endif
        isDebugAreaShown = true
        debugPane = .buildLog
        testing.noteRunning(only)
        let outcomes = await session.runTests(only: only)
        testing.noteFinished()
        return outcomes
    }

    /// Product ▸ Perform Action ▸ Test Again: the last run's tests.
    public func testAgain() async {
        guard let last = session.lastTestRun else { return }
        await runTests(last.tests)
    }

    /// A Test navigator row's run button.
    public func runTests(forRow id: String) {
        let list = testing.tests(forRow: id)
        guard !list.isEmpty, !isBusy else { return }
        Task { await runTests(id == "tests:root" ? [] : list) }
    }

    /// A gutter diamond at `line` of the open file: that test, or the
    /// suite declared there.
    public func runTests(atLine line: Int) {
        guard let path = document?.path, !isBusy else { return }
        let list = session.testsForDiamond(file: path, line: line)
        guard !list.isEmpty else { return }
        Task { await runTests(list) }
    }

    /// The open file's diamonds by line (the gutter).
    public var testDiamonds: [Int: TestOutcome.Status?] {
        guard let path = document?.path else { return [:] }
        return testing.diamonds(in: path)
    }
}
