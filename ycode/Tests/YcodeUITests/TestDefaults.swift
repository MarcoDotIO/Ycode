import Foundation
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A `UserDefaults` backed by a plist file in the worktree's git-ignored
/// `.build-ide/defaults` folder (an absolute-path suite name), so tests
/// never write to `~/Library/Preferences`. Call `remove()` when done.
struct TestDefaults {
    let defaults: UserDefaults
    let suite: String

    init(_ name: String = "defaults") {
        let dir = ycodeDir.appendingPathComponent(".build-ide/defaults")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = dir.appendingPathComponent("\(name)-\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: suite)!
    }

    /// Clears the domain and deletes its file.
    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(atPath: suite + ".plist")
    }
}

/// `Preferences.shared` on a fresh `TestDefaults` domain until `restore()`,
/// so a test never sees what other runs left in the test runner's own
/// defaults (a remote simulator set up in Settings, for example).
@MainActor
final class IsolatedPreferences {
    private let t: TestDefaults
    private let old = Preferences.shared
    private let dir: URL

    init(_ name: String) {
        t = TestDefaults(name)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-prefs-\(UUID().uuidString)")
        Preferences.shared = Preferences(defaults: t.defaults, themesDirectory: dir.appendingPathComponent("Themes"))
    }

    func restore() {
        Preferences.shared = old
        t.remove()
        try? FileManager.default.removeItem(at: dir)
    }
}
