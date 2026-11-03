#if os(Linux) && arch(arm64)
import Foundation
import Testing
import YcodeMachO
@testable import ycode_simd

/// `ycode-simd --macos` (specs/macos/macos-apps.md §3, §4): which
/// executables each mode accepts, the userland root, the environment.
@Suite(.serialized) struct MacOSModeTests {
    @Test func platformGateFollowsTheMode() {
        let saved = MacOSMode.enabled
        defer { MacOSMode.enabled = saved }
        MacOSMode.enabled = false
        #expect(MacOSMode.accepts(.iOSSimulator))
        #expect(MacOSMode.accepts(.visionOSSimulator))
        #expect(MacOSMode.accepts(.watchOSSimulator))
        #expect(!MacOSMode.accepts(.watchOS))
        #expect(!MacOSMode.accepts(.macOS))
        #expect(!MacOSMode.accepts(.iOS))
        #expect(MacOSMode.accepts(nil))
        MacOSMode.enabled = true
        #expect(MacOSMode.accepts(.macOS))
        #expect(!MacOSMode.accepts(.iOSSimulator))
        #expect(!MacOSMode.accepts(.macCatalyst))
        #expect(MacOSMode.accepts(nil))
        #expect(MacOSMode.platform == Platform.macOS.rawValue)
    }

    @Test func explicitRootNeedsTheDynamicLinker() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "ycode-macos-root-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/usr/lib", withIntermediateDirectories: true)
        #expect(fm.createFile(atPath: root + MacOSMode.dyldGuestPath, contents: Data([0xCF, 0xFA, 0xED, 0xFE])))
        #expect(MacOSMode.locateRoot(explicit: root) == (root as NSString).standardizingPath)
    }

    @Test func environmentIsAMacOSOne() {
        let env = MacOSMode.environment()
        #expect(env.contains("TMPDIR=/tmp/"))
        #expect(env.contains { $0.hasPrefix("PATH=/usr/bin") })
        #expect(!env.contains { $0.hasPrefix("DYLD_ROOT_PATH=") || $0.hasPrefix("SIMULATOR_ROOT=") })
    }
}
#endif
