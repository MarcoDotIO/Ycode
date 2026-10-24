import Foundation
import YcodeBuild

/// Which xcodebuild-compatible tool runs a project's or workspace's tests.
/// With Ycode's build system chosen (swift-build), tests go through
/// `ycodebuild`, which writes the coverage summary the test report's
/// Coverage page reads (`YCODE_COVERAGE_SUMMARY`). With xcodebuild chosen,
/// when no `ycodebuild` is found, or when the runner's tool was set
/// explicitly, the runner is left as it is.
public enum TestRunnerSelection {
    /// `YCODE_BUILD_TOOL`, else `ycodebuild` next to the running
    /// executable, else `ycodebuild` on `PATH`.
    public static func locateYcodebuild(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        executableDirectory: String? = Bundle.main.executableURL?.deletingLastPathComponent().path) -> String? {
        let fm = FileManager.default
        if let p = environment["YCODE_BUILD_TOOL"], fm.isExecutableFile(atPath: p) { return p }
        if let d = executableDirectory, fm.isExecutableFile(atPath: d + "/ycodebuild") { return d + "/ycodebuild" }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where fm.isExecutableFile(atPath: "\(dir)/ycodebuild") {
            return "\(dir)/ycodebuild"
        }
        return nil
    }

    /// The runner for a preference: `ycodebuild` replaces xcodebuild for
    /// swift-build when it can be found.
    public static func runner(_ base: TestRunner, preference: BuildSystemPreference, locate: () -> String? = { locateYcodebuild() }) -> TestRunner {
        // A runner whose tool was set explicitly (tests, stubs) is kept.
        guard preference == .swiftBuild, base.xcodebuild == TestRunner().xcodebuild, let tool = locate() else { return base }
        var r = base
        r.xcodebuild = [tool]
        return r
    }
}
