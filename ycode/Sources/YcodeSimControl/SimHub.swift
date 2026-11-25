// Device Hub's side of ycrun (specs/ide/ycrun.md §11; device-hub.md "Ycode
// decisions (2026-11-17)"): a device ycrun booted has a pid file,
// `<data>/ycrun/<device>.pid`, naming its launcher. Both IDEs' hubs treat
// such a device as running and stop it as ycrun does, with SIGTERM to that
// pid (ycrun's `shutdown`). The hubs ask here and nowhere else.

import Foundation

public enum YcrunDeviceFiles {
    /// ycrun's own files on a host: `<data>/ycrun`.
    public static func stateDirectory(data: String) -> String { data + "/ycrun" }

    /// `<data>/ycrun/<device directory>.pid`.
    public static func pidFile(data: String, directory: String) -> String { stateDirectory(data: data) + "/" + directory + ".pid" }

    /// `<data>/ycrun/<device directory>.log`.
    public static func logFile(data: String, directory: String) -> String { stateDirectory(data: data) + "/" + directory + ".log" }

    /// One command printing `YCRUN-BOOTED <device directory>` for each pid
    /// file under `<data>/ycrun` whose process lives.
    public static func bootedCommand(data: String) -> String {
        "for f in \(shq(stateDirectory(data: data)))/*.pid; do [ -f \"$f\" ] || continue; p=$(cat \"$f\" 2>/dev/null); "
            + "[ -n \"$p\" ] && kill -0 \"$p\" 2>/dev/null && printf 'YCRUN-BOOTED %s\\n' \"$(basename \"$f\" .pid)\"; done; true"
    }

    /// The device directories `bootedCommand` printed.
    public static func parseBooted(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("YCRUN-BOOTED ") ? String(line.dropFirst("YCRUN-BOOTED ".count)) : nil
        })
    }

    /// Stops the launcher a pid file names: SIGTERM, up to `grace` seconds
    /// for it to save and end, then its session killed; the pid file goes.
    /// Exit status 3: no live process (ycrun did not boot it).
    public static func stopCommand(pidFile: String, grace: Int) -> String {
        let pid = shq(pidFile)
        return "p=$(cat \(pid) 2>/dev/null); [ -n \"$p\" ] && kill -0 \"$p\" 2>/dev/null || exit 3; "
            + "kill -TERM \"$p\"; i=0; while kill -0 \"$p\" 2>/dev/null && [ $i -lt \(grace) ]; do sleep 1; i=$((i+1)); done; "
            + "if kill -0 \"$p\" 2>/dev/null; then kill -KILL -- -\"$p\" 2>/dev/null || kill -KILL \"$p\"; echo YCRUN-KILLED; fi; rm -f \(pid)"
    }
}
