// `ycode sim runtimes …` (#68–#70): the runtime wizard's checklist from a
// terminal, the same rows as the macOS window and the Linux shell, and the
// host setup script to read or save. It only looks; nothing is installed,
// copied or removed from here.

import Foundation

public enum RuntimeCLI {
    public static let usage = """
        usage: ycode sim runtimes check [--platform iOS|watchOS|tvOS|visionOS]... [--min VERSION] [--host user@host --data DIR]
               ycode sim runtimes script
          check   prints the checklist: this machine's runtimes (CoreSimulator's on a Mac, Ycode's folder on Linux), and with
                  --host the host's checks and runtimes (ssh with a key; never a password)
          script  prints the simulator host's setup script (bash; --report changes nothing): ycode sim runtimes script > ycode-host-setup
        """

    public static func main(_ arguments: [String], runner: (any HeadsetCommandRunner)? = nil, hostRunner: (any HeadsetCommandRunner)? = nil,
                            machine: SetupMachine = .current, out: @escaping @Sendable (String) -> Void = { print($0) }) async -> Int32 {
        var a = arguments
        guard let cmd = a.first else { out(usage); return 64 }
        a.removeFirst()
        switch cmd {
        case "script":
            out(HostSetupScript.text)
            return 0
        case "check":
            var choices = RuntimeSetupChoices()
            var platforms: Set<SimPlatform> = []
            var host = RuntimeHostSettings()
            var i = 0
            while i < a.count {
                let v = i + 1 < a.count ? a[i + 1] : ""
                switch a[i] {
                case "--platform": guard let p = SimPlatform(name: v) else { out("unknown platform \(v)"); return 64 }; platforms.insert(p); i += 1
                case "--min": for p in SimPlatform.allCases { choices.minimumVersions[p] = v }; i += 1
                case "--host": host.destination = v; i += 1
                case "--data": host.dataDirectory = v; i += 1
                default: out(usage); return 64
                }
                i += 1
            }
            if !platforms.isEmpty { choices.platforms = platforms }
            choices.useHost = !host.destination.isEmpty
            choices.host = host
            var report = await RuntimeSetupChecker(machine: machine, choices: choices, runner: runner ?? LocalHeadsetRunner(timeout: 60)).run()
            if choices.useHost {
                let h = await RuntimeHostChecker(host: host, choices: choices, runner: hostRunner ?? SSHHeadsetRunner(destination: host.destination, timeout: 60),
                                                 pairedHosts: RuntimeSetupSession.linkHosts()).run()
                report.checks += h.checks
                report.host = h.host
            }
            for line in lines(report) { out(line) }
            return report.checks.contains { $0.state == .missing } ? 1 : 0
        default:
            out(usage)
            return 64
        }
    }

    /// The report as text: the runtimes, then each check with its state, reason and fix.
    public static func lines(_ r: RuntimeSetupReport) -> [String] {
        var out: [String] = []
        for (title, list) in [("Runtimes here", r.local), ("Runtimes on the host", r.host)] where !list.isEmpty {
            out.append("\(title):")
            for x in list {
                let who: String
                switch x.owner {
                case .coreSimulator: who = "Xcode's (read-only)"
                case .ycode: who = "Ycode's"
                case .external: who = "configured"
                }
                out.append("  \(x.title)  \(x.sizeText)  \(x.isUsable ? "ready" : x.availabilityError ?? x.state)  \(who)")
            }
        }
        for c in r.checks {
            let mark = switch c.state {
            case .ok: "ok     "
            case .missing: "MISSING"
            case .unknown: "unknown"
            case .notApplicable: "n/a    "
            }
            out.append("\(mark)  \(c.title): \(c.reason)")
            switch c.fix {
            case .command(let cmd)?: out.append("         run: \(cmd)")
            case .instructions(let words)?: out.append("         \(words)")
            case .step(let s)?: out.append("         see the wizard's \(s.title) step (Window ▸ Downloads on Linux, Settings ▸ Components on macOS)")
            case .action?: out.append("         the wizard does this after you confirm its command")
            case nil: break
            }
        }
        return out
    }
}
