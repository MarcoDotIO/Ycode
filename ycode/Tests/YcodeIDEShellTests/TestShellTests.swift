import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeIDEShell

/// A package with an XCTest class and a Swift Testing suite, and a stand-in
/// for `swift` that prints a test run's output (Linux forms) and records
/// its arguments.
struct TestPackage {
    let pkg: TempPackage
    var url: URL { pkg.url }
    let argsFile: URL
    let runner: URL

    init() throws {
        pkg = try TempPackage()
        let tests = pkg.url.appendingPathComponent("Tests/DemoCoreTests")
        try """
        import XCTest
        @testable import DemoCore

        final class GreetingXCTests: XCTestCase {
            func testGreets() {
                XCTAssertEqual(1, 1)
            }

            func testGreetsAll() {
                XCTAssertEqual(1, 2)
            }
        }

        """.write(to: tests.appendingPathComponent("GreetingXCTests.swift"), atomically: true, encoding: .utf8)
        try """
        import Testing

        @Suite struct GreetingSwiftTests {
            @Test func greetsByName() {
                #expect(true)
            }

            @Test func greetsEveryone() {
                #expect(1 == 2)
            }
        }

        """.write(to: tests.appendingPathComponent("GreetingSwiftTests.swift"), atomically: true, encoding: .utf8)
        let dir = pkg.url.deletingLastPathComponent()
        argsFile = dir.appendingPathComponent("args.txt")
        runner = dir.appendingPathComponent("fake-swift.sh")
        let xctest = tests.appendingPathComponent("GreetingXCTests.swift").path
        try """
        #!/bin/sh
        printf '%s ' "$@" > "\(argsFile.path)"
        cat <<'OUT'
        Building for debugging...
        Test Case 'GreetingXCTests.testGreets' started at 2026-11-04 12:00:00.000
        Test Case 'GreetingXCTests.testGreets' passed (0.001 seconds)
        Test Case 'GreetingXCTests.testGreetsAll' started at 2026-11-04 12:00:00.001
        \(xctest):10: error: GreetingXCTests.testGreetsAll : XCTAssertEqual failed: ("1") is not equal to ("2") -
        Test Case 'GreetingXCTests.testGreetsAll' failed (0.002 seconds)
        ◇ Test run started.
        ✔ Test greetsByName() passed after 0.001 seconds.
        ✘ Test greetsEveryone() recorded an issue at GreetingSwiftTests.swift:9:9: Expectation failed: 1 == 2
        ✘ Test greetsEveryone() failed after 0.001 seconds with 1 issue.
        ✘ Test run with 2 tests in 1 suite failed after 0.001 seconds with 1 issue.
        OUT
        exit 1

        """.write(to: runner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
    }

    func path(_ rel: String) -> String { pkg.path(rel) }
    func remove() { pkg.remove() }
}

@MainActor
@Suite(.serialized) struct TestShellTests {
    func model(_ p: TestPackage) async throws -> WorkspaceShellModel {
        let m = try WorkspaceShellModel(url: p.url, engine: ScriptedEngine(lines: [], issues: []))
        m.session.testRunner.swift = ["/bin/sh", p.runner.path]
        await m.testing.discovered()
        return m
    }

    @Test func theNavigatorGroupsTargetsSuitesAndTests() async throws {
        let p = try TestPackage()
        defer { p.remove() }
        let m = try await model(p)
        let rows = m.testing.rows
        #expect(rows.first?.title == "Demo")
        #expect(rows.first?.detail == "5 Tests")
        #expect(rows.map(\.title).contains("DemoCoreTests"))
        #expect(rows.map(\.title).contains("GreetingXCTests"))
        #expect(rows.map(\.title).contains("GreetingSwiftTests"))
        #expect(rows.map(\.title).contains("testGreetsAll()"))
        // The free function test sits under its target, without a suite.
        let free = try #require(rows.first { $0.title == "greets()" })
        #expect(free.level == 2)
        // Before a run every diamond is outlined.
        #expect(Set(rows.compactMap(\.trailingSymbol)) == ["diamond"])
    }

    @Test func runningAllRecordsResultsFailuresAndAReport() async throws {
        let p = try TestPackage()
        defer { p.remove() }
        let m = try await model(p)
        #expect(m.isEnabled(.test))
        #expect(!m.isEnabled(.testAgain))
        let outcomes = await m.runTests()
        #expect(outcomes.count == 4)
        let t = m.testing
        #expect(t.running == nil)
        func status(_ name: String) -> TestOutcome.Status? { t.results.first { $0.key.name == name }?.value }
        #expect(status("testGreets") == .passed)
        #expect(status("testGreetsAll") == .failed)
        #expect(status("greetsByName") == .passed)
        #expect(status("greetsEveryone") == .failed)
        #expect(t.rows.first { $0.title == "GreetingXCTests" }?.trailingSymbol == "xmark.diamond.fill")
        #expect(t.rows.first { $0.title == "testGreets()" }?.trailingTint == .success)
        // Failures are issues at their lines, with whole paths.
        let issues = m.allIssues.filter { $0.severity == .error }
        let xc = p.path("Tests/DemoCoreTests/GreetingXCTests.swift"), st = p.path("Tests/DemoCoreTests/GreetingSwiftTests.swift")
        #expect(issues.contains { $0.file == xc && $0.line == 10 && $0.message.hasPrefix("XCTAssertEqual failed") })
        #expect(issues.contains { $0.file == st && $0.line == 9 })
        // The gutter: a red diamond on the failing test and its suite.
        m.open(xc)
        let lines = m.testDiamonds
        #expect(lines[5] == .some(.passed))
        #expect(lines[9] == .some(.failed))
        #expect(lines[4] == .some(.failed))
        // The run is in the Report navigator, with its Tests page.
        let reportRow = try #require(t.reportRows.first { $0.id.hasPrefix("report:") })
        t.selectReport(reportRow.id)
        #expect(t.shownReport?.page == "Tests")
        let report = try #require(t.report)
        #expect(TestShellModel.summary(report) == "2 passed, 2 failed")
        #expect(TestShellModel.reportTests(report).first?.status == .failed)
        #expect(t.reportRows.contains { $0.title == "Tests" && $0.trailing == "2" })
        // Opening a file hides the report.
        m.open(st)
        #expect(t.shownReport == nil)
        #expect(m.isEnabled(.testAgain))
    }

    @Test func aRowOrADiamondRunsOnlyItsTests() async throws {
        let p = try TestPackage()
        defer { p.remove() }
        let m = try await model(p)
        let t = m.testing
        let row = try #require(t.rows.first { $0.title == "testGreets()" })
        _ = await m.runTests(t.tests(forRow: row.id))
        var args = try String(contentsOf: p.argsFile, encoding: .utf8)
        #expect(args.contains("test --filter GreetingXCTests.testGreets\\b"))
        #expect(!args.contains("testGreetsAll"))
        // Only the test that ran has a result.
        #expect(t.results.count == 1)
        // A suite's declaration line runs its tests.
        m.open(p.path("Tests/DemoCoreTests/GreetingSwiftTests.swift"))
        #expect(m.session.testsForDiamond(file: p.path("Tests/DemoCoreTests/GreetingSwiftTests.swift"), line: 3).count == 2)
        let suite = try #require(t.rows.first { $0.title == "GreetingSwiftTests" })
        _ = await m.runTests(t.tests(forRow: suite.id))
        args = try String(contentsOf: p.argsFile, encoding: .utf8)
        #expect(args.contains("--filter GreetingSwiftTests.greetsByName\\b --filter GreetingSwiftTests.greetsEveryone\\b"))
        // Test Again repeats the last selection.
        await m.testAgain()
        #expect(try String(contentsOf: p.argsFile, encoding: .utf8) == args)
    }
}

@Suite struct TestResultLinuxTests {
    @Test func linuxXCTestFailuresAttachToTheirTest() {
        let out = TestResultParser.parse("""
        /p/T.swift:7: error: MathTests.testAdds : XCTAssertEqual failed: ("1") is not equal to ("2") -
        Test Case 'MathTests.testAdds' failed (0.001 seconds)
        """)
        #expect(out.count == 1)
        #expect(out.first?.failures.first?.location?.line == 7)
        #expect(out.first?.failures.first?.message.hasPrefix("XCTAssertEqual failed") == true)
    }

    @Test func swiftTestingFileNamesBecomeWholePaths() {
        let t = DiscoveredTest(file: "/p/Tests/A/ATests.swift", suite: nil, name: "adds", line: 3, kind: .swiftTesting)
        let o = TestOutcome(suite: nil, name: "adds", status: .failed,
                            failures: [Diagnostic(severity: .error, message: "x", location: .init(file: "ATests.swift", line: 4, column: 5))])
        #expect(TestFailureFiles.resolve([o], tests: [t]).first?.failures.first?.location?.file == "/p/Tests/A/ATests.swift")
    }
}
