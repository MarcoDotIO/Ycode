import Foundation

/// Which String Catalog compiler a build uses (`specs/ide/string-catalog.md`,
/// "Ycode implementation"): Xcode's `xcstringstool`, which swift-build runs
/// for `.xcstrings` files, or Ycode's `ycode strings`, which accepts the same
/// `compile` and `generate-symbols` command lines.
///
/// The setting is `YCODE_STRINGS_COMPILER` = `xcstringstool` | `ycode`, as a
/// build setting on the command line or in the environment. The default is
/// `ycode` off macOS, and on macOS when the selected Xcode has no
/// `xcstringstool`. The `ycode` binary is `YCODE_STRINGS_TOOL` (setting or
/// environment), else the one `AssetCompilerHook` finds.
///
/// swift-build has no build setting naming the tool: it looks `xcstringstool`
/// up in its executable search paths, the first of which come from the
/// client's `__XCODE_BUILT_PRODUCTS_DIR_PATHS` environment variable. The hook
/// writes a wrapper named `xcstringstool` and puts its folder there, in the
/// environment of the swift-build process.
public enum StringsCompilerHook {
    public enum Choice: String, Sendable { case xcstringstool, ycode }

    public static let settingName = "YCODE_STRINGS_COMPILER"
    public static let toolSettingName = "YCODE_STRINGS_TOOL"
    public static let wrapperName = "xcstringstool"
    public static let searchPathVariable = "__XCODE_BUILT_PRODUCTS_DIR_PATHS"

    static func last(_ name: String, _ settings: [(String, String)]) -> String? { settings.last { $0.0 == name }?.1 }

    /// Whether the selected Xcode (`DEVELOPER_DIR`, else the `xcode-select`
    /// link, else `/Applications/Xcode.app`) has an `xcstringstool`.
    public static func xcodeHasStringsTool(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let fm = FileManager.default
        var dev = environment["DEVELOPER_DIR"]
        if dev == nil, let link = try? fm.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") { dev = link }
        let base = dev ?? "/Applications/Xcode.app/Contents/Developer"
        return ["usr/bin/xcstringstool", "Toolchains/XcodeDefault.xctoolchain/usr/bin/xcstringstool"]
            .contains { fm.isExecutableFile(atPath: (base as NSString).appendingPathComponent($0)) }
    }

    public static func choice(settings: [(String, String)], environment: [String: String] = ProcessInfo.processInfo.environment) -> Choice {
        if let v = last(settingName, settings) ?? environment[settingName], let c = Choice(rawValue: v.lowercased()) { return c }
        #if os(macOS)
        return xcodeHasStringsTool(environment: environment) ? .xcstringstool : .ycode
        #else
        return .ycode
        #endif
    }

    public static func ycodeExecutable(settings: [(String, String)] = [], environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let p = last(toolSettingName, settings) ?? environment[toolSettingName] { return FileManager.default.isExecutableFile(atPath: p) ? p : nil }
        return AssetCompilerHook.ycodeExecutable(settings: settings, environment: environment)
    }

    /// `#!/bin/sh` that runs `ycode strings` with every argument.
    public static func wrapperScript(ycode: String) -> String {
        "#!/bin/sh\n# Written by Ycode: the String Catalog compiler swift-build runs (YCODE_STRINGS_COMPILER=ycode).\n"
            + "exec '\(ycode.replacingOccurrences(of: "'", with: "'\\''"))' strings \"$@\"\n"
    }

    /// The environment for the swift-build process: `base` with the
    /// wrapper's folder (`directory`) first in `__XCODE_BUILT_PRODUCTS_DIR_PATHS`.
    /// Nil when the choice is `xcstringstool` or no `ycode` is found.
    public static func environment(settings: [(String, String)], directory: URL,
                                   base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String]? {
        guard choice(settings: settings, environment: base) == .ycode,
              let ycode = ycodeExecutable(settings: settings, environment: base) else { return nil }
        let wrapper = directory.appendingPathComponent(wrapperName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(wrapperScript(ycode: ycode).utf8).write(to: wrapper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        } catch {
            return nil
        }
        var env = base
        env[searchPathVariable] = directory.path + (base[searchPathVariable].map { ":" + $0 } ?? "")
        return env
    }

    /// Build-setting overrides that go with Ycode's compiler. Off macOS,
    /// swift-build cannot guess a `.strings` file's encoding, so files with
    /// no encoding of their own (the compiled tables) are read as UTF-8:
    /// `STRINGS_FILE_INPUT_ENCODING = $(InputFileTextEncoding:default=utf-8)`,
    /// unless the setting is given.
    public static func overrides(settings: [(String, String)], environment: [String: String] = ProcessInfo.processInfo.environment) -> [(String, String)] {
        #if os(macOS)
        return []
        #else
        guard choice(settings: settings, environment: environment) == .ycode, last("STRINGS_FILE_INPUT_ENCODING", settings) == nil else { return [] }
        return [("STRINGS_FILE_INPUT_ENCODING", "$(InputFileTextEncoding:default=utf-8)")]
        #endif
    }
}
