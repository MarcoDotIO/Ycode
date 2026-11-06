import Testing
@testable import YcodeMetalHost

/// The system UI that never loses GPU access (metal-sim-protocol.md §8.8):
/// recognised by launchd label or executable path, never by a pid.
@Suite struct MetalSystemUITests {
    @Test func renderServerAndSpringBoardByLabel() {
        #expect(MetalSystemUI.isSystemUI(label: "com.apple.backboardd", executablePath: nil))
        #expect(MetalSystemUI.isSystemUI(label: "com.apple.SpringBoard", executablePath: ""))
    }

    @Test func byExecutablePathWhenTheLabelIsMissing() {
        #expect(MetalSystemUI.isSystemUI(label: "", executablePath: "/usr/libexec/backboardd"))
        #expect(MetalSystemUI.isSystemUI(label: nil, executablePath: "/System/Library/CoreServices/SpringBoard.app/SpringBoard"))
        // A host path keeps the runtime root in front.
        #expect(MetalSystemUI.isSystemUI(label: nil, executablePath: "/rt/RuntimeRoot/usr/libexec/backboardd"))
    }

    @Test func appsAndExtensionsAreNot() {
        #expect(!MetalSystemUI.isSystemUI(label: "com.apple.MercuryPoster.55F66599-1BF4-918D-8214-D63264716981",
                                          executablePath: "/System/Library/PrivateFrameworks/X.framework/PlugIns/MercuryPosterExtension.appex/MercuryPosterExtension"))
        #expect(!MetalSystemUI.isSystemUI(label: "UIKitApplication:com.apple.Preferences[a1b2]",
                                          executablePath: "/Applications/Preferences.app/Preferences"))
        // Same names elsewhere do not count: the path must end in the system UI's own path.
        #expect(!MetalSystemUI.isSystemUI(label: "com.example.backboardd", executablePath: "/usr/local/bin/backboardd"))
        #expect(!MetalSystemUI.isSystemUI(label: nil, executablePath: "/Applications/SpringBoard.app/SpringBoard"))
        #expect(!MetalSystemUI.isSystemUI(label: nil, executablePath: nil))
    }
}
