import Foundation
import Testing
@testable import YcodeAssistant

@Suite struct HTTPUnreachableTests {
    /// Linux's URLSession sometimes reports a refused connect as `.unknown`
    /// with curl's message: still "nothing answered", so a provider says
    /// its server is not running.
    @Test func curlsFailedConnectIsUnreachable() {
        let failed = URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to 127.0.0.1 port 33617 after 0 ms: Could not connect to server"])
        #expect(HTTP.isUnreachable(failed))
        #expect(HTTP.isUnreachable(URLError(.cannotConnectToHost)))
        #expect(!HTTP.isUnreachable(URLError(.unknown)))
        #expect(!HTTP.isUnreachable(URLError(.cancelled)))
    }
}
