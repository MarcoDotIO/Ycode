// simctl's output shapes (public `simctl help` and `list -j` keys; specs/ide/ycrun.md §7.2).

import Foundation
import YcodeIDECore

public enum SimctlFormat {
    public static func json(_ o: Any) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    /// A search term matches any of the strings (case-insensitive substring).
    public static func matches(_ term: String, _ fields: String...) -> Bool {
        fields.contains { $0.range(of: term, options: .caseInsensitive) != nil }
    }

    /// "this machine" or "<host> (user@host)".
    public static func location(_ ctx: SimHostContext) -> String {
        ctx.entry.isLocal ? "on this machine" : "on \(ctx.label), \(ctx.entry.destination)"
    }

    public static func deviceTypeJSON(_ t: YcodeSimulatorDeviceType) -> [String: Any] {
        var o: [String: Any] = ["identifier": t.id, "name": t.name, "productFamily": SimDeviceTypes.productFamily(t),
                                "minRuntimeVersionString": t.minRuntimeVersion, "platform": t.platform]
        if let max = t.newestDefaultRuntimeVersion { o["maxRuntimeVersionString"] = max }
        return o
    }

    public static func runtimeJSON(_ r: SimRuntime, ctx: SimHostContext) -> [String: Any] {
        var o: [String: Any] = ["identifier": r.identifier, "name": r.name, "platform": r.platform, "isAvailable": true,
                                "runtimeRoot": r.root, "host": ctx.label, "placement": ctx.entry.isLocal ? "local" : "remote",
                                "supportedArchitectures": ["arm64"],
                                "supportedDeviceTypes": SimDeviceTypes.all.filter { $0.platform == r.platform && $0.runs(onRuntimeVersion: r.version) }
                                    .map { ["identifier": $0.id, "name": $0.name, "productFamily": SimDeviceTypes.productFamily($0)] }]
        if let v = r.version { o["version"] = v }
        if let b = r.build { o["buildversion"] = b }
        return o
    }

    public static func runtimeLine(_ r: SimRuntime, ctx: SimHostContext) -> String {
        let v = (r.version ?? "?") + (r.build.map { " - " + $0 } ?? "")
        return "\(r.name) (\(v)) - \(r.identifier) (\(location(ctx)))"
    }

    public static func deviceJSON(_ d: SimDevice, ctx: SimHostContext) -> [String: Any] {
        ["udid": d.udid, "name": d.name, "state": d.state.rawValue, "isAvailable": true, "deviceTypeIdentifier": d.type.id,
         "dataPath": d.path, "logPath": ctx.logFile(d), "host": d.host, "placement": d.isLocal ? "local" : "remote",
         "runtimeRoot": d.runtime.root, "isCreated": d.isCreated]
    }

    /// The last lines a failed command printed (standard error, else output).
    public static func lastLines(_ r: SimCommandResult, _ n: Int = 6) -> String {
        let text = (r.errorText.isEmpty ? r.text : r.errorText).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n").suffix(n).joined(separator: "\n")
        return lines.isEmpty ? "exit status \(r.status)" : lines
    }

    /// A control reply without its "ok "/"error: " word.
    public static func reply(_ s: String) -> String {
        if s.hasPrefix("ok ") { return String(s.dropFirst(3)) }
        if s == "ok" { return "" }
        if s.hasPrefix("error: ") { return String(s.dropFirst(7)) }
        return s
    }

    /// A Ycode tool: `$<variable>`, else next to this program (an app's
    /// Helpers, a package's bin), else on the PATH.
    public static func toolPath(_ tool: String, next executable: String, environment: [String: String], variable: String? = nil) -> String {
        if let variable, let v = environment[variable], !v.isEmpty { return v }
        let me = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let candidate = me.deletingLastPathComponent().appendingPathComponent(tool).path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : tool
    }
}

/// `ycrun simctl help` and what Ycode's simulator cannot do yet.
public enum SimctlHelp {
    public static let overview = """
        usage: ycrun simctl [--local | --remote | --host <name>] <verb> [arguments]

        Ycode's own simulators, with simctl's verbs (devices are Ycode's, not Xcode's).
        Devices run on this machine on arm64 Linux with /dev/kvm, else on the simulator
        host set up with `ycrun remote setup`. --local, --remote and --host override that.

        Verbs:
          list [-j] [devices|devicetypes|runtimes|pairs] [<search>|available] [--all-hosts]
          create <name> <device type> [<runtime>]      prints the new device's UDID
          delete <device>… | unavailable | all
          rename <device> <name>
          boot <device> [--wait]          bootstatus <device> [-b]
          shutdown <device> | all         reboot <device>
          erase <device> | all
          install <device> <App.app>      launch <device> <bundle id> [<argv>…]
          io <device> screenshot [--display=internal|LCD|LCD-1] <file or ->
          location <device> set <lat>,<lon> | clear | list | run <scenario> | start …
          ui <device> appearance [light|dark] | content_size [<size>] | increase_contrast [enabled|disabled]
          pair <watch> <phone>  |  unpair <pair UUID>  |  pair_activate <pair UUID>
          view <device> [viewer options]  (Ycode only: the live screen in ycode-sim-viewer)
          help [<verb>]

        A device is `booted`, a UDID or a name. Not supported by Ycode's simulator yet:
        \(unsupported.keys.sorted().joined(separator: ", ")).
        """

    /// Verbs Ycode's simulator cannot do yet, with the reason or what to do instead.
    public static let unsupported: [String: String] = [
        "terminate": "an app ends when its device shuts down (`ycrun simctl shutdown`); a launch restarts the device",
        "openurl": "the device cannot open a URL while it runs",
        "spawn": "processes start only through an app launch",
        "getenv": "",
        "uninstall": "erase the device to remove its apps",
        "get_app_container": "",
        "listapps": "",
        "appinfo": "",
        "privacy": "use Device Hub's camera and privacy controls",
        "push": "",
        "keychain": "",
        "addmedia": "",
        "pbcopy": "", "pbpaste": "", "pbsync": "",
        "status_bar": "",
        "clone": "",
        "upgrade": "",
        "diagnose": "the run log is <data>/ycrun/<device>.log on the host",
        "logverbose": "",
        "icloud_sync": "",
        "runtime": "use `ycode runtime` and `ycrun remote setup` to get and add runtimes",
    ]

    public static func text(for verb: String) -> String {
        switch verb {
        case "list": return "usage: ycrun simctl list [-j|--json] [devices|devicetypes|runtimes|pairs] [<search term>|available] [--all-hosts]\n"
            + "Lists the device types, runtimes, devices (with where each one lives) and pairs. --all-hosts lists every host's."
        case "create": return "usage: ycrun simctl create <name> <device type id> [<runtime id>]\n"
            + "Makes a device (it appears in Device Hub). The type is an id from `list devicetypes` (or its name, or a simctl-style identifier); "
            + "the runtime defaults to the newest that runs the type. Prints the UDID."
        case "delete": return "usage: ycrun simctl delete <device>… | unavailable | all\nDeletes created devices; a runtime's own devices are erased instead."
        case "boot": return "usage: ycrun simctl boot <device> [--arch=arm64] [--wait]\nStarts the device on its host and returns; --wait waits until it is booted."
        case "bootstatus": return "usage: ycrun simctl bootstatus <device> [-b]\nWaits until the device is booted; -b boots it first."
        case "shutdown": return "usage: ycrun simctl shutdown <device> | all\nStops a device ycrun booted (with warm boot it is saved first)."
        case "reboot": return "usage: ycrun simctl reboot <device>"
        case "erase": return "usage: ycrun simctl erase <device> | all\nErases a shut-down device's contents and saved state."
        case "install": return "usage: ycrun simctl install <device> <path to .app>\n"
            + "Copies the app to the device's host. Ycode's simulator installs it when it is launched."
        case "launch": return "usage: ycrun simctl launch [--terminate-running-process] <device> <bundle id> [<argv 1> … <argv n>]\n"
            + "Installs and launches an app installed with `install`; a running device restarts first (warm boot resumes it). Prints `<bundle id>: <pid>`."
        case "io": return "usage: ycrun simctl io <device> screenshot [--type=png] [--display=internal|LCD|LCD-1] <file or ->"
        case "location": return "usage: ycrun simctl location <device> set <lat>,<lon> | clear | list | run <scenario> | start [--speed=S] [--distance=M|--interval=S] <lat,lon>…"
        case "ui": return "usage: ycrun simctl ui <device> appearance [light|dark] | content_size [<size>|increment|decrement] | increase_contrast [enabled|disabled]"
        case "pair": return "usage: ycrun simctl pair <watch device> <phone device>\nPairs a watch with a phone; prints the pair's UUID."
        case "unpair": return "usage: ycrun simctl unpair <pair UUID>"
        case "pair_activate": return "usage: ycrun simctl pair_activate <pair UUID>"
        case "rename": return "usage: ycrun simctl rename <device> <new name>"
        case "view": return "usage: ycrun simctl view <device> [ycode-sim-viewer options]\nOpens the booted device's live screen (Ycode only)."
        case "": return overview
        default:
            if let why = unsupported[verb] { return "`simctl \(verb)` is not supported by Ycode's simulator yet" + (why.isEmpty ? "." : ": \(why).") }
            return overview
        }
    }
}
