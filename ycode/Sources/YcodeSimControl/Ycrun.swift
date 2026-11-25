// `ycrun`, Ycode's xcrun-style front end for its own simulators
// (specs/ide/ycrun.md §2): `ycrun simctl …`, `ycrun remote …`, `--find`,
// `--install-link`, and Ycode's other tools by name.

import Foundation

public enum Ycrun {
    public static let usage = """
        usage: ycrun [--local | --remote | --host <name>] simctl <verb> [arguments]   Ycode's simulators with simctl's verbs
               ycrun remote setup|list|status|test|link|remove …                    set up, check and link simulator hosts
               ycrun --find <tool>                                                 the path of one of Ycode's tools
               ycrun <tool> [arguments]                                            run one of Ycode's tools (\(tools.joined(separator: ", ")))
               ycrun --install-link [<dir>]                                        put ycrun on your PATH (a link in /usr/local/bin or ~/.local/bin)
               ycrun --version | --help

        Devices run on this machine on arm64 Linux with a usable /dev/kvm; on x86-64 Linux and on macOS
        they run on the simulator host `ycrun remote setup` sets up (the same host the IDEs use).
        `ycrun simctl help` lists the verbs; docs/YCRUN.md has the details.
        """

    /// Ycode's tools `ycrun <tool>` and `--find` know.
    public static let tools = ["ycode", "ycodebuild", "ycode-sim-viewer", "ycode-simhost", "ycode-bsp"]

    public static func main(_ arguments: [String], env: YcrunEnvironment) -> Int32 {
        var a = arguments
        var request = SimPlacementRequest()
        // Placement options before the tool (and, for simctl, before its verb).
        func takePlacement() throws {
            while let first = a.first {
                switch first {
                case "--local": request.local = true; a.removeFirst()
                case "--remote": request.remote = true; a.removeFirst()
                case "--host":
                    guard a.count > 1 else { throw YcrunError.usage("--host needs a name") }
                    request.host = a[1]
                    a.removeFirst(2)
                default: return
                }
            }
        }
        do {
            try takePlacement()
            guard let tool = a.first else { env.out(usage); return YcrunExit.usage }
            a.removeFirst()
            switch tool {
            case "-h", "--help", "help":
                env.out(usage)
                return YcrunExit.ok
            case "simctl":
                try takePlacement()
                return Simctl(env: env, request: request).run(a)
            case "remote":
                return RemoteCommands(env: env).run(a)
            case "--find", "-f":
                guard let t = a.first else { throw YcrunError.usage("--find <tool>") }
                let path = SimctlFormat.toolPath(t, next: env.executable, environment: env.environment)
                guard path.hasPrefix("/") else { throw YcrunError("\(t) was not found next to ycrun") }
                env.out(path)
                return YcrunExit.ok
            case "--install-link":
                return try installLink(a.first, env: env)
            default:
                guard tools.contains(tool) else { throw YcrunError.usage("unknown tool `\(tool)`\n" + usage) }
                let path = SimctlFormat.toolPath(tool, next: env.executable, environment: env.environment)
                return env.foreground([path] + a, [:])
            }
        } catch let e as YcrunError {
            env.err("ycrun: \(e.description)")
            return e.status
        } catch {
            env.err("ycrun: \(error)")
            return YcrunExit.failure
        }
    }

    // MARK: - The PATH link (--install-link)

    /// What `--install-link` puts on the PATH: a link to this program, or in
    /// a Flatpak a small script that runs it through `flatpak run`.
    public enum LinkPlan: Equatable, Sendable {
        case symlink(at: String, to: String)
        case script(at: String, text: String)
    }

    /// The folder: the one given, else /usr/local/bin when it is writable,
    /// else ~/.local/bin (no sudo, ever).
    public static func linkPlan(directory: String?, executable: String, environment: [String: String],
                                isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }) -> LinkPlan {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let dir = directory ?? (isWritable("/usr/local/bin") && environment["FLATPAK_ID"] == nil ? "/usr/local/bin" : home + "/.local/bin")
        let at = dir + "/ycrun"
        if let id = environment["FLATPAK_ID"], !id.isEmpty {
            return .script(at: at, text: "#!/bin/sh\n# ycrun from the Ycode Flatpak (ycrun --install-link)\nexec flatpak run --command=ycrun \(id) \"$@\"\n")
        }
        return .symlink(at: at, to: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path)
    }

    static func installLink(_ directory: String?, env: YcrunEnvironment) throws -> Int32 {
        let plan = linkPlan(directory: directory, executable: Bundle.main.executableURL?.path ?? env.executable, environment: env.environment)
        let fm = FileManager.default
        let at: String
        switch plan {
        case .symlink(let path, let target):
            at = path
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: path), existing == target { env.out("\(path) already links to \(target)"); break }
            if fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                guard (try? fm.destinationOfSymbolicLink(atPath: path)) != nil else { throw YcrunError("\(path) exists and is not a link; remove it first") }
                try fm.removeItem(atPath: path)
            }
            try fm.createSymbolicLink(atPath: path, withDestinationPath: target)
            env.out("Linked \(path) → \(target)")
        case .script(let path, let text):
            at = path
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            env.out("Wrote \(path) (runs ycrun from the Flatpak)")
        }
        let dir = (at as NSString).deletingLastPathComponent
        let path = (env.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if !path.contains(dir) { env.out("Add \(dir) to your PATH to run `ycrun` by name.") }
        return YcrunExit.ok
    }
}
