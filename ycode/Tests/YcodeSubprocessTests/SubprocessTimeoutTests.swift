import Foundation
import Testing
@testable import YcodeSubprocess

/// A child that hangs is stopped at its timeout (beta 4 hygiene: tests that
/// wait on git never hang for ever).
@Suite struct SubprocessTimeoutTests {
    @Test func aHangingChildIsStoppedAtItsTimeout() throws {
        let start = Date()
        #expect(throws: Subprocess.TimedOut.self) {
            try Subprocess.run("/bin/sleep", ["30"], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func aQuickChildIsNotAffected() throws {
        let out = try Subprocess.run("/bin/echo", ["ok"], timeout: 30)
        #expect(out.status == 0 && out.stdoutText == "ok\n")
    }
}
