// The parts of a simulator tree a device needs to boot and run apps
// (specs/ide/ycrun.md §8.3; docs/SIMULATOR-LINUX.md §5): ycode-simd, the EL1
// shim, Ycode's host libraries, the guest frameworks, the shader translator
// and the guest tools. `ycrun remote setup` checks each on the host, builds
// the missing ones in a source tree there, and copies the guest tools
// (which build only on a Mac, with the simulator SDK) from this computer.
// `ycrun remote test` reports each.

import Foundation

public enum SimTreeParts {
    public struct Part: Equatable, Sendable {
        public var id: String
        public var title: String
        /// Paths relative to the tree; the part is there when all exist (any of `alternatives`).
        public var paths: [String]
        public var alternatives: [String] = []
        /// The shell lines that build it in a source tree (run in the tree, Swift on the PATH); nil: cannot be built there.
        public var build: String?
    }

    public static let simdBuild = "swift build -c release -j \"$J\" --product ycode-simd && swift build -c release -j \"$J\" --product ycode "
        + "&& swift build -c release -j \"$J\" --product ycode-simhost"

    /// The parts, in build order.
    public static let all: [Part] = [
        Part(id: "simd", title: "ycode-simd", paths: [".build/release/ycode-simd"], build: simdBuild),
        Part(id: "shim", title: "the EL1 shim (SimShim)", paths: ["SimShim/out/shim.bin", "SimShim/out/host_stubs.bin"], build: "sh SimShim/build.sh"),
        Part(id: "hostlibs", title: "Ycode's host libraries (SimHostLibs)",
             paths: ["SimHostLibs/out/libsystem_kernel.dylib", "SimHostLibs/out/libsystem_platform.dylib", "SimHostLibs/out/libsystem_pthread.dylib"],
             build: "{ [ -x .build/release/ycode ] || swift build -c release -j \"$J\" --product ycode; } && YCODE=\"$PWD/.build/release/ycode\" sh SimHostLibs/build.sh"),
        Part(id: "frameworks", title: "the guest frameworks (SimGuestFrameworks)", paths: ["SimGuestFrameworks/out/SimHID.framework"],
             build: "sh SimGuestFrameworks/build.sh"),
        Part(id: "translator", title: "the shader translator (ycode-airc)", paths: ["Translator/build/ycode-airc"],
             alternatives: [".build/release/ycode-airc"], build: "FLATPAK_BUILDER_N_JOBS=\"$J\" sh Translator/build.sh"),
    ]

    /// The guest tools' file a run cannot do without.
    public static let guestToolsMarker = "ylaunch"
    /// Where ycode-simd looks for the guest tools in a tree by default.
    public static let defaultGuestTools = "SimShim/out/guest-tests/stage7"

    /// One command printing `PART <id> ok|missing` for each part of the tree
    /// and `PART guesttools ok|missing <folder>`, plus `TREE source|release`.
    public static func checkCommand(tree: String, guestTools: String?) -> String {
        var s = "T=\(shq(tree)); "
        for p in all {
            let all = p.paths.map { "[ -e \"$T/\($0)\" ]" }.joined(separator: " && ")
            let alt = p.alternatives.map { " || [ -e \"$T/\($0)\" ]" }.joined()
            s += "if { \(all); }\(alt); then echo 'PART \(p.id) ok'; else echo 'PART \(p.id) missing'; fi; "
        }
        let gt = guestTools.map(shq) ?? "\"$T/\(defaultGuestTools)\""
        s += "G=\(gt); if [ -s \"$G/\(guestToolsMarker)\" ]; then echo \"PART guesttools ok $G\"; else echo \"PART guesttools missing $G\"; fi; "
        s += "if [ -f \"$T/Package.swift\" ]; then echo 'TREE source'; else echo 'TREE release'; fi"
        return s
    }

    public struct Report: Equatable, Sendable {
        public var parts: [String: Bool] = [:]
        public var guestToolsFolder = ""
        public var isSource = false
        public var missing: [String] { (all.map(\.id) + ["guesttools"]).filter { parts[$0] == false } }
    }

    public static func parse(_ text: String) -> Report {
        var r = Report()
        for line in text.split(whereSeparator: \.isNewline) {
            let w = line.split(separator: " ", maxSplits: 3).map(String.init)
            if w.count >= 3, w[0] == "PART" {
                r.parts[w[1]] = w[2] == "ok"
                if w[1] == "guesttools", w.count == 4 { r.guestToolsFolder = w[3] }
            } else if w.count == 2, w[0] == "TREE" {
                r.isSource = w[1] == "source"
            }
        }
        return r
    }

    /// Builds the missing parts in a source tree, in order, stopping at the
    /// first that fails (`BUILT <id> ok|failed`). Swift comes from swiftly
    /// when it is not on the PATH.
    public static func buildCommand(tree: String, missing: [String], jobs: Int) -> String {
        var s = "cd \(shq(tree)) || exit 2; J=\(jobs); "
            + "command -v swift >/dev/null 2>&1 || for f in \"${SWIFTLY_HOME_DIR:-/nonexistent}/env.sh\" \"$HOME/.local/share/swiftly/env.sh\"; do "
            + "[ -f \"$f\" ] && . \"$f\" >/dev/null 2>&1 && break; done; "
        for p in all where missing.contains(p.id) {
            guard let b = p.build else { continue }
            s += "if ( \(b) ) > build-\(p.id).log 2>&1; then echo 'BUILT \(p.id) ok'; else echo 'BUILT \(p.id) failed'; tail -n 15 build-\(p.id).log; exit 1; fi; "
        }
        return s + "true"
    }

    /// The guest tools to copy from this computer: `--guest-tools`, else
    /// `$YCODE_GUEST_TOOLS`, else the app's `Resources/simulator-host/guest-tools.tar`
    /// (macOS app) or the package's `share/ycode/guest-tools.tar`, next to ycrun.
    public static func localGuestTools(option: String?, environment: [String: String], executable: String,
                                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        if let option { return option }
        if let e = environment["YCODE_GUEST_TOOLS"], !e.isEmpty { return e }
        let bin = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        for rel in ["../Resources/simulator-host/guest-tools.tar", "../share/ycode/guest-tools.tar"] {
            let p = bin.appendingPathComponent(rel).standardizedFileURL.path
            if exists(p) { return p }
        }
        return nil
    }

    /// What to say when the host has no guest tools and none were given.
    public static let guestToolsAdvice = "the host has no guest tools (ylaunch and Ycode's guest agents): devices boot, but cannot install or launch apps "
        + "or change settings. They build only on a Mac with the iOS simulator SDK: run `packaging/flatpak/build-guest-tools.sh <dir>` from Ycode's "
        + "source there, then the setup again with `--guest-tools <dir>` (Ycode's aarch64 release tree already has them)"

    /// Appends `KEY=value` lines a file lacks (existing values stay).
    public static func ensureKeysCommand(file: String, _ pairs: [(String, String)]) -> String {
        var s = "mkdir -p \(shq((file as NSString).deletingLastPathComponent)) && touch \(shq(file))"
        for (k, v) in pairs {
            s += " && { grep -q \(shq("^" + k + "=")) \(shq(file)) || printf '%s\\n' \(shq(k + "=" + shq(v))) >> \(shq(file)); }"
        }
        return s
    }
}
