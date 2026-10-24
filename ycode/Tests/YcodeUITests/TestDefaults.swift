import Foundation

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
