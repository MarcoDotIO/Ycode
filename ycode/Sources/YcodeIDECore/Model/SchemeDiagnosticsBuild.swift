import Foundation
import YcodeBuild
import YcodeWorkspace

/// What a scheme's Diagnostics change in builds and runs (`specs/ide/schemes.md`
/// §Diagnostics, Ycode implementation). The sanitizers are swift-build
/// settings (open-source swift-build: `ENABLE_ADDRESS_SANITIZER`,
/// `ENABLE_THREAD_SANITIZER`, `ENABLE_UNDEFINED_BEHAVIOR_SANITIZER`, which
/// add `-fsanitize=…` to compiles and links and copy the runtime library
/// into the product); stack use after return is a run-time option of the
/// address sanitizer (LLVM's AddressSanitizer documentation).
extension SchemeDiagnostics {
    /// Build-setting overrides, in a fixed order.
    public var buildSettings: [(String, String)] {
        var s: [(String, String)] = []
        if addressSanitizer { s.append(("ENABLE_ADDRESS_SANITIZER", "YES")) }
        if threadSanitizer { s.append(("ENABLE_THREAD_SANITIZER", "YES")) }
        if undefinedBehaviorSanitizer { s.append(("ENABLE_UNDEFINED_BEHAVIOR_SANITIZER", "YES")) }
        return s
    }

    /// Adds the run-time options to a launch environment: with ASan's
    /// stack-use-after-return on, `detect_stack_use_after_return=1` joins
    /// any `ASAN_OPTIONS` the scheme already sets (`:`-separated).
    public func applyLaunchEnvironment(_ env: inout [String: String]) {
        guard addressSanitizer, stackUseAfterReturn else { return }
        let option = "detect_stack_use_after_return=1"
        if let existing = env["ASAN_OPTIONS"], !existing.isEmpty {
            if !existing.contains("detect_stack_use_after_return") { env["ASAN_OPTIONS"] = existing + ":" + option }
        } else {
            env["ASAN_OPTIONS"] = option
        }
    }

    /// The scheme action whose Diagnostics apply to a build action: the
    /// test action for test builds, the launch action for the others; nil
    /// for clean.
    public static func schemeAction(for action: BuildRequest.Action) -> String? {
        switch action {
        case .clean: nil
        case .test, .buildForTesting, .testWithoutBuilding: "TestAction"
        case .build, .analyze: "LaunchAction"
        }
    }
}
