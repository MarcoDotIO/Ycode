import Testing
@testable import HostMac

/// Swift Testing inside HostMac.app (TEST_HOST).
struct HostMacSwiftTests {
    @Test func addsInTheApp() {
        #expect(Arithmetic.add(2, 3) == 5)
    }

    @MainActor @Test func runsAfterLaunch() {
        #expect(LaunchState.launched)
    }

    @Test func failsOnPurpose() {
        #expect(Arithmetic.add(2, 2) == 5)
    }

    @Test(arguments: [1, 2, 3]) func doubles(_ n: Int) {
        #expect(Arithmetic.add(n, n) == 2 * n)
    }
}
