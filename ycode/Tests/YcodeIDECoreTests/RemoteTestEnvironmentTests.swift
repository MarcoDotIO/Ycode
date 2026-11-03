import Foundation
import Testing
@testable import YcodeIDECore

/// Product ▸ Test on the Ycode simulator hands ycodebuild the simulator's
/// host through `YCODE_SIM_*` (specs/ide/testing.md, "Ycode implementation").
@Suite struct RemoteTestEnvironmentTests {
    @Test func variablesFollowTheRunSettings() {
        var s = RemoteSimulatorSettings(destination: "<user>@<host>", dataDirectory: "/data", runtimeRoot: "/rt/iOS 27.0/RuntimeRoot",
                                        simdPath: "/bin/ycode-sim", deviceName: "phone")
        s.additionalArguments = "--timeout-ms 5 '--x y'"
        s.leanBoot = true
        s.keepServices = "com.a, com.b"
        let env = RemoteSimulator(settings: s).testEnvironment
        #expect(env["YCODE_SIM_HOST"] == "<user>@<host>" && env["YCODE_SIM_DATA"] == "/data")
        #expect(env["YCODE_SIM_RUNTIME"] == "/rt/iOS 27.0/RuntimeRoot" && env["YCODE_SIM_SIMD"] == "/bin/ycode-sim")
        #expect(env["YCODE_SIM_OPTIONS"]?.contains("'--timeout-ms' '5' '--x y'") == true)
        #expect(env["YCODE_SIM_ENV"] == "YCODE_WARM_BOOT=1 YCODE_LEAN_BOOT=daemons YCODE_LEAN_BOOT_KEEP='com.a,com.b'")
        #expect(env["YCODE_SSH"] == nil)
        #expect(RemoteSimulator.testDestination == "platform=iOS Simulator,name=Ycode Simulator,arch=arm64")
        s.warmBoot = false
        s.leanBoot = false
        s.ssh = "/tmp/fake-ssh"
        let off = RemoteSimulator(settings: s).testEnvironment
        #expect(off["YCODE_SIM_ENV"] == "YCODE_WARM_BOOT=0" && off["YCODE_SSH"] == "/tmp/fake-ssh")
    }
}
