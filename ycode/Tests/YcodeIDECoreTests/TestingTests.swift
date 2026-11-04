import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore

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
        #expect(pkg.args.suffix(3) == ["test", "--filter", "MathTests.testAdds\\b"] && pkg.cwd == "/p")
        let proj = r.command(for: BuildRequest(container: .project("/a/A.xcodeproj"), scheme: "A"), only: ["ATests/MathTests/testAdds"])
        #expect(proj.args.suffix(2) == ["-only-testing:ATests/MathTests/testAdds", "test"])
    }
}
