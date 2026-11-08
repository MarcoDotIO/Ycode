import Foundation

/// Recently opened workspaces — projects, workspaces and package folders —
/// newest first (`reference-ui-5.md` §3.2, L3). File ▸ Open Recent and the
/// Welcome window's Recent Projects list both read it. Kept in the user
/// defaults, so entries survive relaunch; an entry whose file is gone is
/// dropped when the list is read.
@MainActor
public final class RecentProjects {
    /// Posted after the list changes.
    public static let didChange = Notification.Name("YcodeRecentProjectsDidChange")
    /// The app's list, in the standard user defaults (a test process uses
    /// a throwaway domain so it never writes the user's preferences).
    public static var shared = RecentProjects(defaults: IDEProcess.isTestProcess
        ? UserDefaults(suiteName: NSTemporaryDirectory() + "ycode-recent-projects-\(ProcessInfo.processInfo.processIdentifier)") ?? .standard
        : .standard)

    /// The defaults key holding the paths, newest first.
    public static let defaultsKey = "Ycode.recentProjects"
    /// The same cap as AppKit's recent-documents default.
    public static let limit = 10

    let defaults: UserDefaults

    /// A list stored in `defaults` (tests pass their own domain).
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The entries, newest first; missing files are removed.
    public var urls: [URL] {
        let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        let present = stored.filter { FileManager.default.fileExists(atPath: $0) }
        if present.count != stored.count { defaults.set(present, forKey: Self.defaultsKey) }
        return present.map { URL(fileURLWithPath: $0) }
    }

    /// Records an opened container (moves it to the front).
    public func note(_ url: URL) {
        let path = Self.containerURL(url).path
        var list = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: Self.defaultsKey)
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// File ▸ Open Recent ▸ Clear Menu.
    public func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// On Linux, writes the domain at once: swift-corelibs-foundation keeps
    /// changes in memory until a synchronization, and an app that ends with
    /// `exit` (the SwiftUI shell on OpenViews) would lose the list.
    private func persist() {
        #if os(Linux)
        defaults.synchronize()
        #endif
    }

    /// A package is recorded by its folder, not its manifest.
    static func containerURL(_ url: URL) -> URL {
        let u = url.standardizedFileURL
        return u.lastPathComponent == "Package.swift" ? u.deletingLastPathComponent() : u
    }

    // MARK: Presentation

    /// Open Recent titles: the container's file name ("App.xcodeproj") or
    /// the package folder's name. Titles shared by several entries become
    /// "<title> —  <parent folder name>" (an em dash and two spaces, as the
    /// reference shows them).
    public static func menuTitles(_ urls: [URL]) -> [String] {
        let names = urls.map(\.lastPathComponent)
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        return zip(urls, names).map { url, name in
            counts[name, default: 0] > 1 ? "\(name) \u{2014}  \(url.deletingLastPathComponent().lastPathComponent)" : name
        }
    }

    /// The Welcome list's primary text: the name without extension.
    public static func displayName(_ url: URL) -> String {
        url.pathExtension.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    /// The Welcome list's secondary text: the containing folder's path;
    /// on another volume, from the volume's name ("External/Samples"), on
    /// the startup volume, the path itself ("/Users/me/Projects").
    public static func folderText(_ url: URL) -> String {
        // The real path, symbolic links resolved ("/tmp/…" shows as
        // "/private/tmp/…"; `editor-area.md` H.10, council row 169); the
        // path as stored when the folder is not there.
        let folder = realFolder(url.deletingLastPathComponent().standardizedFileURL)
        let parts = folder.pathComponents  // ["/", "Volumes", "X", …]
        if parts.count >= 3, parts[1] == "Volumes" {
            return parts[2...].joined(separator: "/")
        }
        // On the startup volume, the stored path as it is (`editor-area.md`
        // F.11, checklist row 112: "/private/tmp/…", with no volume name in
        // front; the row truncates it at its head only when it does not fit).
        return folder.path
    }

    /// `folder` with every symbolic link resolved (realpath(3); Foundation's
    /// `resolvingSymlinksInPath` drops "/private" on macOS, the opposite
    /// of what the row shows), or `folder` itself when it cannot be.
    static func realFolder(_ folder: URL) -> URL {
        guard let p = realpath(folder.path, nil) else { return folder }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }
}
