import Foundation
import Testing
@testable import YcodeIDECore

/// A runtime root's platform comes from the runtime's own name, not from
/// the directories above it (`specs/ide/device-hub.md`, visionOS runtimes):
/// an iOS root in a checkout named "visionos-…" gave no run destinations,
/// and RunTestTextsR42Tests failed in such checkouts only.
@Suite struct RuntimePlatformTests {
    func settings(_ root: String) -> RemoteSimulatorSettings {
        RemoteSimulatorSettings(destination: "tester@sim-host", dataDirectory: "/data/ycode", runtimeRoot: root, simdPath: "/data/ycode/bin/ycode-sim")
    }

    @Test func theRuntimesOwnNameCounts() {
        let s = settings("/rt/iOS-27.1/RuntimeRoot")
        for (root, platform) in [
            ("/rr/xrOS-27.0-24O353/RuntimeRoot", "visionOS"),
            ("/rr/visionOS-26.4/RuntimeRoot", "visionOS"),
            ("/rt/watchOS_27.0.simruntime/Contents/Resources/RuntimeRoot", "watchOS"),
            ("/rt/iOS-27.0-24A434/RuntimeRoot", "iOS"),
            ("/Users/u/src/visionos-r10b/ycode/.build-ide/r37-r42-1a2b3c4d/rr", "iOS"),
            ("/home/u/watchOS-work/runtimes/iOS 27.1", "iOS"),
            ("/data/xrOS-checkout/iOS_27.1.simruntime/Contents/Resources/RuntimeRoot", "iOS"),
        ] {
            #expect(s.runtimePlatform(forRoot: root) == platform, "\(root)")
        }
    }

    @Test func anIOSRootUnderAVisionNamedDirectoryHasRunDestinations() throws {
        let s = settings("/Users/u/src/visionos-r10b/ycode/.build-ide/r37-r42-1a2b3c4d/rr")
        let target = try #require(RemoteSimulator(settings: s).target)
        #expect(target.name.hasSuffix("(Ycode)"))
        #expect(RemoteSimulator(settings: s).destination.name.hasSuffix("(Ycode)"))
        #expect(s.visionTargets.isEmpty && s.watchTargets.isEmpty)
    }
}
