import XCTest

/// A UI test bundle. Ycode runs it in its own runner; tests that drive the
/// app through XCUIApplication need the reference's automation service,
/// which Ycode does not provide (specs/ide/testing.md, "Ycode implementation").
final class HostMacUITests: XCTestCase {
    func testRunnerStarts() {
        XCTAssertEqual(1 + 1, 2)
    }

    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
    }
}
