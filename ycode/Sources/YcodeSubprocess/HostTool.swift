import Foundation

/// Where a system tool lives. Normally `/usr/bin/<tool>`. In a Flatpak, `/usr`
/// is the runtime, which has no git, ssh or toolchain, and `host-tool` wrappers
/// in the package's `libexec/ycode-host` run those on the host
/// (packaging/flatpak/host-tool.sh, the one place that uses `flatpak-spawn`).
/// The package may be unpacked anywhere, so that folder is found from this
/// executable: `<package>/bin/<tool>` and `<package>/libexec/ycode-host`.
public enum HostTool {
    public static func isInFlatpak(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(environment["FLATPAK_ID"] ?? "").isEmpty
    }

    /// `libexec/ycode-host` of the package holding this executable, if any.
    public static func packagedToolDirectory(executable: URL? = Bundle.main.executableURL,
                                             fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard let bin = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        let dir = bin.deletingLastPathComponent().appendingPathComponent("libexec/ycode-host").path
        return fileExists(dir) ? dir : nil
    }

    public static func path(_ tool: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                            toolDirectory: String? = packagedToolDirectory()) -> String {
        if isInFlatpak(environment: environment), let toolDirectory { return "\(toolDirectory)/\(tool)" }
        return "/usr/bin/\(tool)"
    }

    /// The command line that runs one of the app's own tools from a process on
    /// the host: a host tool (sourcekit-lsp) cannot run a path inside the
    /// sandbox, so in the Flatpak it goes through `flatpak run`.
    public static func commandOnHost(tool: String, arguments: [String],
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        guard let id = environment["FLATPAK_ID"], !id.isEmpty else { return [tool] + arguments }
        let name = (tool as NSString).lastPathComponent
        return ["flatpak", "run", "--command=\(name)", id] + arguments
    }
}
