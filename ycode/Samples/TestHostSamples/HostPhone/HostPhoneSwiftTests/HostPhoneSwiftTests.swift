import Testing
@testable import HostPhone

/// Swift Testing inside HostPhone.app on the simulator (TEST_HOST).
struct HostPhoneSwiftTests {
    @Test func title() {
        #expect(PhoneModel.title == "HostPhone")
    }

    @Test func failsOnPurpose() {
        #expect(PhoneModel.title.count == 3)
    }
}
