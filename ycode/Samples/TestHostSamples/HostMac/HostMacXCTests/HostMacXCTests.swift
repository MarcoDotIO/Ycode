import XCTest
@testable import HostMac

/// Runs inside HostMac.app (TEST_HOST): three tests pass, one fails on
/// purpose, one is skipped.
final class HostMacXCTests: XCTestCase {
    func testAddsInTheApp() {
        XCTAssertEqual(Arithmetic.add(2, 3), 5)
    }

    @MainActor
    func testRunsAfterLaunch() {
        XCTAssertTrue(LaunchState.launched)
        XCTAssertNotNil(NSApplication.shared.delegate)
    }

    /// The test plan's environment reaches the host app.
    func testPlanEnvironment() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["HOSTMAC_PLAN"])
        XCTAssertNil(ProcessInfo.processInfo.environment["HOSTMAC_UNUSED"])
    }

    func testFailsOnPurpose() {
        XCTAssertEqual(Arithmetic.add(2, 2), 5, "fails as written")
    }

    func testSkipped() throws {
        throw XCTSkip("skipped as written")
    }
}
