import Foundation

/// Per-workspace interface state kept in the workspace's user data
/// (`reference-ui-5.md` §3.5, §4.3, §5.1): the Start Page's Recent Files
/// (L9), the project navigator's expanded rows (N4) and the run
/// destination remembered per scheme (T1).
///
/// Stored as JSON at
/// `<container>/xcuserdata/<user>.xcuserdatad/ycode-ui-state.json`
/// (packages: `.swiftpm/xcode/xcuserdata/…`), next to the bookmarks.
public struct WorkspaceUserState: Codable, Equatable, Sendable {
    /// Files opened in the editor, oldest first (absolute paths).
    public var recentFiles: [String] = []
    /// Expansion keys of the project navigator's expanded rows; nil until
    /// the user has expanded or collapsed something (first open).
    public var expandedRows: [String]?
    /// Scheme name → the destination the user chose: its identifier
    /// (simulators, devices) or else its specifier.
    public var destinations: [String: String] = [:]
    /// The debug area's height when last shown (reference-ui-5.md §8.2);
    /// nil until it has been shown and resized or hidden.
    public var debugAreaHeight: Double?

    public init() {}

    /// How many recent files are kept.
    public static let recentFileLimit = 20

    /// The state file for a container.
    public static func fileURL(container: URL, isPackage: Bool, user: String = NSUserName()) -> URL {
        let base = isPackage ? container.appendingPathComponent(".swiftpm/xcode") : container
        return base.appendingPathComponent("xcuserdata/\(user).xcuserdatad/ycode-ui-state.json")
    }

    /// Reads the file; a missing or unreadable file is the empty state.
    public static func load(from url: URL) -> WorkspaceUserState {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return s
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: url, options: .atomic)
    }

    /// Records an opened file (most recent last), keeping the newest
    /// `recentFileLimit`.
    public mutating func noteRecentFile(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.append(path)
        if recentFiles.count > Self.recentFileLimit { recentFiles.removeFirst(recentFiles.count - Self.recentFileLimit) }
    }

    /// Recent files that still exist.
    public var existingRecentFiles: [String] { recentFiles.filter { FileManager.default.fileExists(atPath: $0) } }
}
