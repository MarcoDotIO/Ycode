import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct TestDiscoveryTests {
    @Test func findsXCTestAndSwiftTesting() {
        let text = """
        import XCTest
        import Testing

        final class MathTests: XCTestCase {
            func testAdds() { XCTAssertEqual(1 + 1, 2) }
            func helper() {}
            func testFails() { XCTAssertEqual(1, 2) }
        }

        class NotATest { func testIgnored() {} }

        @Suite struct Arithmetic {
            @Test func multiplies() { #expect(2 * 3 == 6) }
            @Test("Display name") func divides() {}
        }

        @Test func topLevel() {}
        // @Test func commented() {}
        """
        let tests = TestDiscovery.tests(in: text, file: "/p/T.swift")
        #expect(tests.map(\.identifier) == ["MathTests/testAdds", "MathTests/testFails", "Arithmetic/multiplies", "Arithmetic/divides", "topLevel"])
        #expect(tests.map(\.kind) == [.xctest, .xctest, .swiftTesting, .swiftTesting, .swiftTesting])
        #expect(tests.map(\.line) == [5, 7, 13, 14, 17])
    }

    @Test func findsObjectiveCTests() {
        let m = """
        #import <XCTest/XCTest.h>

        @interface MathTests : XCTestCase
        @end

        @interface Helper : NSObject
        @end

        @implementation MathTests
        - (void)testAdds {
            XCTAssertEqual(1 + 1, 2);
        }
        - (void)testWith:(int)x { }
        - (void)setUp { }
        // - (void)testCommented { }
        @end

        @implementation Helper
        - (void)testNotATest { }
        @end
        """
        let tests = TestDiscovery.tests(in: m, file: "/p/MathTests.m")
        #expect(tests.map(\.identifier) == ["MathTests/testAdds"])
        #expect(tests.first?.line == 10 && tests.first?.suiteLine == 9 && tests.first?.kind == .xctest)
    }

    @Test func parsesRunnerOutput() {
        let log = """
        Test Case '-[AppTests.MathTests testAdds]' started.
        Test Case '-[AppTests.MathTests testAdds]' passed (0.001 seconds).
        /p/T.swift:7: error: -[AppTests.MathTests testFails] : XCTAssertEqual failed: ("1") is not equal to ("2")
        Test Case '-[AppTests.MathTests testFails]' failed (0.002 seconds).
        Test Case 'MathTests.testLinux' passed (0.003 seconds)
        ✔ Test multiplies() passed after 0.001 seconds.
        ✘ Test divides() recorded an issue at T.swift:14:5: Expectation failed: 1 == 2
        ✘ Test divides() failed after 0.001 seconds with 1 issue.
        """
        let o = TestResultParser.parse(log)
        #expect(o.map(\.name) == ["testAdds", "testFails", "testLinux", "multiplies", "divides"])
        #expect(o.map(\.status) == [.passed, .failed, .passed, .passed, .failed])
        #expect(o[0].suite == "MathTests" && o[2].suite == "MathTests" && o[3].suite == nil)
        #expect(o[1].failures.first?.location == .init(file: "/p/T.swift", line: 7, column: 0))
        #expect(o[1].failures.first?.message.hasPrefix("XCTAssertEqual failed") == true)
        #expect(o[4].failures.first?.location?.line == 14)
    }

    @Test func runnerCommands() {
        let r = TestRunner()
        let pkg = r.command(for: BuildRequest(container: .package("/p")), only: ["MathTests/testAdds"])
        #expect(pkg.args.suffix(3) == ["test", "--filter", "MathTests.testAdds"] && pkg.cwd == "/p")
        let proj = r.command(for: BuildRequest(container: .project("/a/A.xcodeproj"), scheme: "A"), only: ["ATests/MathTests/testAdds"])
        #expect(proj.args.suffix(2) == ["-only-testing:ATests/MathTests/testAdds", "test"])
    }
}

/// A package whose tests run with `swift test`: XCTest (one pass, one
/// fail) and swift-testing (one pass).
func writeTestPackage(at dir: URL) throws {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    func write(_ rel: String, _ text: String) throws {
        let u = dir.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    try write("Package.swift", """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(name: "Calc", targets: [.target(name: "Calc"), .testTarget(name: "CalcTests", dependencies: ["Calc"])])

    """)
    try write("Sources/Calc/Calc.swift", "public func sum(_ a: Int, _ b: Int) -> Int { a + b }\n")
    try write("Tests/CalcTests/CalcTests.swift", """
    import XCTest
    import Testing
    @testable import Calc

    final class CalcTests: XCTestCase {
        func testAdds() { XCTAssertEqual(sum(1, 2), 3) }
        func testBroken() { XCTAssertEqual(sum(1, 1), 3) }
    }

    @Test func addsZero() { #expect(sum(5, 0) == 5) }

    """)
}

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct TestRunEndToEndTests {
    @Test func runsTestsAndMarksResults() async throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/test-run")
        try writeTestPackage(at: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        await session.testsDiscovered()   // read in the background
        #expect(session.tests.map(\.identifier) == ["CalcTests/testAdds", "CalcTests/testBroken", "addsZero"])
        let file = dir.appendingPathComponent("Tests/CalcTests/CalcTests.swift").path
        wc.open(path: file, line: nil)
        #expect(wc.editor.gutter.marks.tests == [5: .notRun, 6: .notRun, 7: .notRun, 10: .notRun])

        let outcomes = await session.runTests()
        #expect(outcomes.contains { $0.name == "testAdds" && $0.status == .passed })
        let byName = Dictionary(uniqueKeysWithValues: session.tests.map { ($0.name, session.testResults[$0]) })
        #expect(byName["testAdds"] == .passed && byName["testBroken"] == .failed && byName["addsZero"] == .passed)
        #expect(wc.editor.gutter.marks.tests == [5: .failed, 6: .passed, 7: .failed, 10: .passed])
        #expect(session.issues.contains { $0.location?.line == 7 })
        #expect(session.reports.first?.title.hasPrefix("Test") == true && session.reports.first?.succeeded == false)

        wc.navigator.select(5)
        let plan = try #require(wc.navigator.rows(5).first)
        // reference-ui-6.md §5.4 (R45): "<n> Tests" only.
        #expect(plan.detail?.hasSuffix("Tests") == true && plan.detail?.contains("Failing") == false)
        let suite = try #require(plan.children.first?.children.first)
        #expect(suite.title == "CalcTests" && suite.trailingSymbol == "xmark.diamond.fill")
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "test-navigator.png")

        // A test's diamond runs only that test; the class diamond runs the class.
        #expect(session.testsForDiamond(file: file, line: 6).map(\.identifier) == ["CalcTests/testAdds"])
        #expect(session.testsForDiamond(file: file, line: 5).map(\.identifier) == ["CalcTests/testAdds", "CalcTests/testBroken"])
        let single = await session.runTests(only: session.testsForDiamond(file: file, line: 6))
        #expect(single.map(\.name) == ["testAdds"] && single.first?.status == .passed)
        #expect(session.reports.first?.succeeded == true)
    }
}
