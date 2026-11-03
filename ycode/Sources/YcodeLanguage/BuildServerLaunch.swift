import Foundation
import YcodeDebug
import YcodeSubprocess

/// Connects sourcekit-lsp to Ycode's build server for a project or
/// workspace: a private folder holds the connection file
/// (`.bsp/ycode.json`) that names `ycode-bsp`, and the language server is
/// opened on that folder. sourcekit-lsp then starts the build server and
/// asks it for targets, sources and compiler arguments. See
/// `specs/ide/language.md` §Build server.
public enum BuildServerLaunch {
    /// The setting (`UserDefaults`, default on): Settings key
    /// `Ycode.buildServer`. `YCODE_BUILD_SERVER=0` turns it off for one run.
    public static let defaultsKey = "Ycode.buildServer"

    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 defaults: UserDefaults = .standard) -> Bool {
        if let v = environment["YCODE_BUILD_SERVER"] { return !["0", "no", "false", "off"].contains(v.lowercased()) }
        return defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The build server executable: `YCODE_BSP`, else `ycode-bsp` next to
    /// the running executable or in the app bundle's `Contents/Helpers`,
    /// else on `PATH`.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              executableURL: URL? = Bundle.main.executableURL) -> String? {
        let fm = FileManager.default
        if let p = environment["YCODE_BSP"], fm.isExecutableFile(atPath: p) { return p }
        if let dir = executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            for c in [dir.appendingPathComponent("ycode-bsp"), dir.deletingLastPathComponent().appendingPathComponent("Helpers/ycode-bsp")]
            where fm.isExecutableFile(atPath: c.path) {
                return c.path
            }
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where fm.isExecutableFile(atPath: "\(dir)/ycode-bsp") {
            return "\(dir)/ycode-bsp"
        }
        return nil
    }

    /// sourcekit-lsp's options for a folder Ycode prepared. Ycode wrote the
    /// folder's connection file itself (naming its own build server), so
    /// it skips sourcekit-lsp's workspace-trust prompt for workspace-scoped
    /// configuration (`bypassWorkspaceTrust`; older servers ignore the key).
    public static let initializationOptions: JSON = ["bypassWorkspaceTrust": true]

    /// The build server's command line for a container.
    public static func argv(server: String, container: URL, scheme: String? = nil, destination: String? = nil) -> [String] {
        var a = ["serve", container.standardizedFileURL.path]
        if let scheme { a += ["--scheme", scheme] }
        if let destination { a += ["--destination", destination] }
        return HostTool.commandOnHost(tool: server, arguments: a)
    }

    /// The connection file's contents (the BSP connection protocol).
    public static func configJSON(argv: [String]) -> JSON {
        [
            "name": "Ycode",
            "version": "0.1",
            "bspVersion": "2.2.0",
            "languages": ["swift", "c", "objective-c", "cpp", "objective-cpp"],
            "argv": .array(argv.map(JSON.string)),
        ]
    }

    /// The folder sourcekit-lsp opens for a container: under the user's
    /// caches (`~/Library/Caches/Ycode/BuildServer` on macOS,
    /// `$XDG_CACHE_HOME/ycode/build-server` on Linux), one per container,
    /// so that nothing is written into the project.
    public static func workspaceFolder(for container: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["HOME"] ?? NSHomeDirectory()
        #if os(macOS)
        let root = home + "/Library/Caches/Ycode/BuildServer"
        #else
        let root = (environment["XDG_CACHE_HOME"] ?? home + "/.cache") + "/ycode/build-server"
        #endif
        let path = container.standardizedFileURL.path
        let name = container.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_")
        return URL(fileURLWithPath: root).appendingPathComponent("\(name)-\(hash(path))")
    }

    /// Writes `<folder>/.bsp/ycode.json`; returns the file.
    @discardableResult
    public static func writeConfig(argv: [String], into folder: URL) throws -> URL {
        let dir = folder.appendingPathComponent(".bsp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ycode.json")
        try configJSON(argv: argv).encoded().write(to: file, options: .atomic)
        return file
    }

    /// Prepares the folder to open sourcekit-lsp on for a project or
    /// workspace; nil when the setting is off, the container is a package
    /// (sourcekit-lsp reads packages itself) or the server is not found.
    public static func prepareWorkspaceFolder(container: URL, scheme: String? = nil, destination: String? = nil,
                                              environment: [String: String] = ProcessInfo.processInfo.environment,
                                              defaults: UserDefaults = .standard) -> URL? {
        guard ["xcodeproj", "xcworkspace"].contains(container.pathExtension), isEnabled(environment: environment, defaults: defaults),
              let server = locate(environment: environment) else { return nil }
        let folder = workspaceFolder(for: container, environment: environment)
        do {
            try writeConfig(argv: argv(server: server, container: container, scheme: scheme, destination: destination), into: folder)
        } catch {
            return nil
        }
        return folder
    }

    /// FNV-1a, 64 bits, as 16 hex digits (a stable folder name, not security).
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", h)
    }
}
