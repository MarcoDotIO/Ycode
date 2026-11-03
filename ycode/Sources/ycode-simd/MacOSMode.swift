// ycode-simd --macos: run a macOS arm64 program on Ycode's own macOS
// userland (specs/macos/macos-apps.md §3, §9.1; dyld.md §3). The process is
// built like an --exec process, with three differences: the executable is
// a macOS one (platform 1), the first user code is Ycode's dyld from the
// macOS userland root (entered at its LC_MAIN with SP on the Mach header;
// no dyld_sim hand-off), and the guest's "/" is that root, read-only.

#if os(Linux) && arch(arm64)
import Foundation
import Glibc
import YcodeMachO

enum MacOSMode {
    /// Set once at start by `--macos`.
    nonisolated(unsafe) static var enabled = false

    /// `PLATFORM_MACOS` in LC_BUILD_VERSION (public <mach-o/loader.h>).
    static let platform: UInt32 = 1

    /// Whether an executable of `platform` may run in this mode: macOS
    /// programs only with --macos; simulator programs only without it.
    static func accepts(_ platform: Platform?) -> Bool {
        guard let platform else { return true }
        if enabled { return platform == .macOS }
        return platform.isSimulator  // iOS, tvOS, watchOS, visionOS simulator (watchos.md W-3)
    }

    /// The guest path of the dynamic linker in the userland root.
    static let dyldGuestPath = "/usr/lib/dyld"

    /// The environment of the root process (`--env` entries are added by
    /// the caller).
    static func environment() -> [String] {
        ["HOME=/tmp", "TMPDIR=/tmp/", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "USER=ycode", "LOGNAME=ycode", "SHELL=/bin/sh"]
    }

    /// The macOS userland root: `--macos-root`, else `MacUserland/out/root`
    /// in the current directory or next to the package that holds this
    /// executable. Dies when none has the dynamic linker.
    static func locateRoot(explicit: String?) -> String {
        var candidates: [String] = []
        if let explicit { candidates.append(absolutePath(explicit)) } else {
            candidates.append(absolutePath("MacUserland/out/root"))
            if let dir = executableDirectory() {
                for up in ["../..", "../../..", "../../../.."] {
                    candidates.append(absolutePath("\(dir)/\(up)/MacUserland/out/root"))
                }
            }
        }
        for c in candidates where access(c + dyldGuestPath, R_OK) == 0 { return c }
        die("no macOS userland root with \(dyldGuestPath) (tried \(candidates.joined(separator: ", "))); "
            + "run sh MacUserland/build.sh or pass --macos-root", status: 66)
    }
}
#endif
