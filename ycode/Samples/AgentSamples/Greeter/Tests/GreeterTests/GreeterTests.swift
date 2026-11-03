import XCTest
@testable import Greeter

final class GreeterTests: XCTestCase {
    func testGreeting() {
        XCTAssertEqual(Greeter().greeting(for: "Ada"), "Hello, Ada!")
    }

    func testSalutation() {
        XCTAssertEqual(Greeter(salutation: "Hi").greeting(for: "Bo"), "Hi, Bo!")
    }
}
