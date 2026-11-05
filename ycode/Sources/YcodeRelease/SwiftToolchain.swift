import Foundation

/// The Swift toolchain that swift-build uses on a host without Xcode (Linux).
/// swift-build's own search takes the real path of `swift` on `PATH` and
/// expects it in a `usr/bin` folder. swiftly's `swift` is a proxy in
/// `~/.local/share/swiftly/bin`, and the Flatpak's is a wrapper that runs the
/// host's, so that search fails and swift-build cannot open a session
/// ("Could not initialize build system"). The `ycode-swb` helper names the
/// toolchain itself, found here. See `specs/xcodebuild/show-build-settings.md` §3.
/// Foundation only: `Tools/ycode-swb` compiles this file through a link.
public enum SwiftToolchain {
    /// The toolchain's root: the folder that holds `usr/bin/swift` (`/` for a
    /// toolchain installed in `/usr`). In order:
    /// 1. `YCODE_SWIFT_TOOLCHAIN`, when it holds `usr/bin/swift`;
    /// 2. `SWIFT_EXEC`, then each `swift` on `PATH`, whose real path is in a
    ///    `usr/bin` or `usr/local/bin` folder;
    /// 3. the first `swift` on `PATH` asked for its target info: the folder
    ///    above `usr/lib/swift` in its `runtimeResourcePath`, when this
    ///    process sees `usr/bin/swift` there (swiftly's proxy, the Flatpak's
    ///    wrapper for a toolchain in the home folder).
    /// Nil when none is found.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                              realPath: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                              targetInfo: (String) -> Data? = { SwiftToolchain.targetInfo(swift: $0) }) -> String? {
        if let root = environment["YCODE_SWIFT_TOOLCHAIN"], !root.isEmpty, isExecutable(join(root, "usr/bin/swift")) {
            return root
        }
        var candidates: [String] = []
        if let exec = environment["SWIFT_EXEC"], !exec.isEmpty { candidates.append(exec) }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(join(String(dir), "swift"))
        }
        candidates = candidates.filter(isExecutable)
        for c in candidates {
            if let root = root(ofExecutable: realPath(c)) { return root }
        }
        // A proxy or wrapper: ask it where its runtime is.
        guard let first = candidates.first,
              let data = targetInfo(first),
              let root = root(fromTargetInfo: data),
              isExecutable(join(root, "usr/bin/swift")) else { return nil }
        return root
    }

    /// `/opt/swift/usr/bin/swift` → `/opt/swift`; `/usr/bin/swift` → `/`;
    /// `/usr/local/bin/swift` → `/`. Nil for any other layout.
    public static func root(ofExecutable path: String) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        for suffix in ["/usr/local/bin", "/usr/bin"] where dir.hasSuffix(suffix) {
            let root = String(dir.dropLast(suffix.count))
            return root.isEmpty ? "/" : root
        }
        return nil
    }

    /// The toolchain root in `swift -print-target-info` output: its
    /// `paths.runtimeResourcePath` without the trailing `usr/lib/swift`.
    public static func root(fromTargetInfo data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = obj["paths"] as? [String: Any],
              let resource = paths["runtimeResourcePath"] as? String else { return nil }
        let trimmed = resource.hasSuffix("/") ? String(resource.dropLast()) : resource
        guard trimmed.hasSuffix("/usr/lib/swift") else { return nil }
        let root = String(trimmed.dropLast("/usr/lib/swift".count))
        return root.isEmpty ? "/" : root
    }

    /// Runs `<swift> -print-target-info`; nil when it fails.
    public static func targetInfo(swift: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: swift)
        p.arguments = ["-print-target-info"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    static func join(_ dir: String, _ rest: String) -> String {
        dir.hasSuffix("/") ? dir + rest : dir + "/" + rest
    }
}
