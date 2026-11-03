import XCTest
@testable import HostPhone

/// Runs inside HostPhone.app on the simulator (TEST_HOST).
final class HostPhoneTests: XCTestCase {
    func testAppTitle() {
        XCTAssertEqual(PhoneModel.title, "HostPhone")
    }

    @MainActor
    func testRunsInTheApp() {
        XCTAssertNotNil(Bundle.main.bundleIdentifier)
        XCTAssertEqual(Bundle.main.bundleURL.pathExtension, "app")
    }

    func testFailsOnPurpose() {
        XCTAssertEqual(PhoneModel.title, "Other", "fails as written")
    }
}
