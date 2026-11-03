import XCTest

final class HostPhoneUITests: XCTestCase {
    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
    }
}
