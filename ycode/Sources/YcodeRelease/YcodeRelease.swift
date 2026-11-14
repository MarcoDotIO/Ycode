import Foundation

/// The release's version. `ycode/VERSION` is the one source of truth: the
/// packaging scripts read that file, and `YcodeReleaseTests` fails when this
/// constant, the file and the Flatpak metainfo disagree. Foundation only,
/// because `Tools/ycode-swb` compiles the same source through a symbolic link.
public enum YcodeRelease {
    public static let version = "1.0.0-beta.3"
    /// The name people read in release notes and on the download page.
    public static let marketingVersion = "1.0.0 Beta"

    /// The line every shipped tool prints for `--version`.
    public static func versionLine(tool: String) -> String { "\(tool) \(version)" }

    /// `<tool> --version` prints the line and exits. Call it first in a
    /// tool's `main`, so it needs no configuration and opens no window.
    public static func handleVersionFlag(tool: String, arguments: [String] = CommandLine.arguments) {
        guard arguments.count == 2, arguments[1] == "--version" else { return }
        print(versionLine(tool: tool))
        exit(0)
    }
}

extension YcodeRelease {
    /// The app bundle's helper tools live in `Contents/Helpers` (`ycode` cannot
    /// sit next to `Ycode` on a case-insensitive disk). Every lookup that falls
    /// back on `PATH` then finds them, and so do the tools the app starts, wherever
    /// the bundle was copied. Nil when this executable is not in such a bundle.
    public static func pathWithBundledHelpers(executable: URL, path: String?, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        let helpers = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers").path
        guard fileExists(helpers) else { return nil }
        return helpers + ":" + (path ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    /// The Linux package (`<package>/bin`, `<package>/libexec/ycode-host`, unpacked
    /// anywhere): the settings a tool needs to find the package's other tools.
    /// In a Flatpak the host tools' wrappers come first, because the runtime has
    /// none of those tools. Empty when this executable is not in such a package.
    public static func packageEnvironment(executable: URL, environment: [String: String],
                                          fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String: String] {
        let bin = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let wrappers = bin.deletingLastPathComponent().appendingPathComponent("libexec/ycode-host").path
        guard fileExists(wrappers) else { return [:] }
        var first = [bin.path]
        if !(environment["FLATPAK_ID"] ?? "").isEmpty { first.insert(wrappers, at: 0) }
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        guard !path.hasPrefix(first.joined(separator: ":") + ":") else { return [:] }
        return ["PATH": (first + [path]).joined(separator: ":"),
                "YCODE": bin.appendingPathComponent("ycode").path,
                "YCODE_SWB": bin.appendingPathComponent("ycode-swb").path].filter { environment[$0.key] == nil || $0.key == "PATH" }
    }

    /// Call at the start of a tool, before anything looks for another tool.
    public static func adoptBundledHelpers() {
        guard let exe = Bundle.main.executableURL else { return }
        let environment = ProcessInfo.processInfo.environment
        #if os(macOS)
        if let path = pathWithBundledHelpers(executable: exe, path: environment["PATH"]) { setenv("PATH", path, 1) }
        #else
        for (name, value) in packageEnvironment(executable: exe, environment: environment) { setenv(name, value, 1) }
        #endif
    }
}
