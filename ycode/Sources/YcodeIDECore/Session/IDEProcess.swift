import Foundation

/// Facts about the running IDE process that the model needs and that do not
/// depend on a UI toolkit.
public enum IDEProcess {
    /// Whether this process is a test runner (XCTest or swift-testing),
    /// where the model keeps state in memory or temporary domains instead of
    /// the user's defaults and files.
    public static let isTestProcess: Bool = {
        let name = ProcessInfo.processInfo.processName
        return name.contains("xctest") || name.contains("swiftpm-testing-helper") || name.hasSuffix("PackageTests")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()

    /// Posted when the app is about to quit. The name is AppKit's
    /// (`NSApplication.willTerminateNotification`), so the AppKit shell posts
    /// it unchanged; another shell posts the same name before it exits.
    public static let willTerminateNotification = Notification.Name("NSApplicationWillTerminateNotification")
}
