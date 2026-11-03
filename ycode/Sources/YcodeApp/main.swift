import AppKit
import YcodeRelease
import YcodeUI

// Ycode.app entry point. The bundle wrapper is made by
// `ycode/scripts/make-app.sh`.
YcodeRelease.handleVersionFlag(tool: "Ycode")
YcodeRelease.adoptBundledHelpers()
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
