// Preparing a simulator host (#70): how the wizard runs the setup script
// (`HostSetupScript`) over ssh, reads its `YCODE-` lines into the
// checklist, and decides the KVM SVE kernel check from the probe's facts
// (`docs/postmortem-kvm-sve.md`). Ycode never handles a password: steps that
// need root run in the user's own terminal through `sudo`.

import Foundation

/// What a run of the script reported.
public struct HostSetupOutput: Sendable, Equatable {
    public struct Step: Sendable, Equatable, Identifiable {
        public var id: String
        public var command: String
        public var needsRoot: Bool
    }

    public var mode = ""
    public var facts: [String: String] = [:]
    /// Root steps first, then the user's (the script prints them in that order).
    public var steps: [Step] = []
    public var checks: [RuntimeCheck] = []
    /// `RAN <id> ok|failed` of an apply or root run.
    public var ran: [String: Bool] = [:]
    public var sve: [String: String]?
    public var passed: Bool?
    public var errors: [String] = []

    public init() {}

    public var rootSteps: [Step] { steps.filter(\.needsRoot) }
    public var userSteps: [Step] { steps.filter { !$0.needsRoot } }
    /// Nothing left to do: a second run only reports.
    public var isSettled: Bool { steps.isEmpty }

    /// Parses the script's standard output (other lines are ignored).
    public static func parse(_ text: String) -> HostSetupOutput {
        var o = HostSetupOutput()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.hasPrefix("YCODE-") else { continue }
            let body = line.dropFirst("YCODE-".count)
            let (kind, rest) = split(String(body))
            switch kind {
            case "SETUP":
                o.mode = keyValues(rest)["mode"] ?? ""
            case "FACT":
                if let eq = rest.firstIndex(of: "=") { o.facts[String(rest[..<eq])] = String(rest[rest.index(after: eq)...]) }
            case "ROOT", "USER":
                let (id, cmd) = split(rest)
                o.steps.append(Step(id: id, command: cmd, needsRoot: kind == "ROOT"))
            case "CHECK":
                let (id, r1) = split(rest)
                let (state, reason) = split(r1)
                o.checks.append(RuntimeCheck(id, title(of: id), SetupCheckState(rawValue: state) ?? .unknown, reason))
            case "RAN":
                let (id, status) = split(rest)
                o.ran[id] = status == "ok"
            case "SVE":
                o.sve = keyValues(rest)
            case "DONE":
                o.passed = rest == "pass"
            case "ERROR":
                o.errors.append(rest)
            default: break
            }
        }
        // Root steps first, whatever order the lines came in.
        o.steps = o.rootSteps + o.userSteps
        return o
    }

    static func split(_ s: String) -> (String, String) {
        guard let sp = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<sp]), String(s[s.index(after: sp)...]))
    }

    /// `a=1 b=two` (values without spaces).
    static func keyValues(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for w in s.split(separator: " ") {
            guard let eq = w.firstIndex(of: "=") else { continue }
            out[String(w[..<eq])] = String(w[w.index(after: eq)...])
        }
        return out
    }

    public static func title(of id: String) -> String {
        switch id {
        case "setup.os": "Operating system"
        case "setup.arch": "Architecture"
        case "setup.kvm": "KVM access"
        case "setup.packages": "Packages"
        case "setup.swift": "Swift toolchain"
        case "setup.data": "Data folder"
        case "setup.service": "Simulator service"
        case "setup.simhost": "ycode-simhost"
        case "setup.firewall": "Firewall"
        case "setup.ports": "Link ports"
        case "setup.selftest": "Service self-test"
        case "setup.sve": "Kernel: KVM SVE fix"
        default: id
        }
    }

    /// The checklist rows: the script's checks with their fixes (a root step
    /// is a command for the user's terminal; a user step is Apply), then
    /// the kernel check decided from the probe's facts.
    public func checklist(destination: String, invocation: HostSetupInvocation) -> [RuntimeCheck] {
        var out = checks.map { c -> RuntimeCheck in
            var c = c
            guard c.state != .ok else { return c }
            let key = c.id.replacingOccurrences(of: "setup.", with: "")
            let related: [String: [String]] = ["kvm": ["kvm-group"], "packages": ["packages"], "swift": ["swift"],
                                               "data": ["data-dir", "data-owner", "data-folders"], "service": ["service-config", "service-unit", "launcher"],
                                               "simhost": ["release"], "selftest": ["release", "launcher", "service-config"], "firewall": ["firewall"]]
            let ids = related[key] ?? []
            if steps.contains(where: { ids.contains($0.id) && $0.needsRoot }) {
                c.fix = .command(invocation.rootCommand(destination: destination))
            } else if steps.contains(where: { ids.contains($0.id) }) {
                c.fix = .action(.provisionApply)
            }
            return c
        }
        if let sve { out.append(KVMSVEProbe.check(KVMSVEProbe.Facts(sve))) }
        return out
    }
}

/// How the script is run on the host.
public struct HostSetupInvocation: Sendable, Equatable {
    public var dataDirectory: String
    /// Empty: the default (`~/.config/ycode`).
    public var configDirectory = ""
    public var swiftVersion = "6.4"
    public var probeSeconds = 3
    /// Where the script is saved on the host for the root step (sudo needs a file).
    public var remotePath = "~/.cache/ycode/ycode-host-setup"

    /// The Ycode release the host's service comes from (this machine's version).
    public var ycodeVersion = ""
    public var tcpPort = 47800
    public var udpPort = 47801

    public init(dataDirectory: String, configDirectory: String = "", swiftVersion: String = "6.4", probeSeconds: Int = 3, ycodeVersion: String = "",
                tcpPort: Int = 47800, udpPort: Int = 47801) {
        self.dataDirectory = dataDirectory
        self.configDirectory = configDirectory
        self.swiftVersion = swiftVersion
        self.probeSeconds = probeSeconds
        self.ycodeVersion = ycodeVersion
        self.tcpPort = tcpPort
        self.udpPort = udpPort
    }

    public func arguments(mode: String) -> [String] {
        var a = ["--" + mode, "--data-dir", dataDirectory, "--swift", swiftVersion, "--probe-seconds", String(probeSeconds)]
        if !configDirectory.isEmpty { a += ["--config-dir", configDirectory] }
        if !ycodeVersion.isEmpty { a += ["--ycode-version", ycodeVersion] }
        if tcpPort != 47800 || udpPort != 47801 { a += ["--tcp-port", String(tcpPort), "--udp-port", String(udpPort)] }
        return a
    }

    /// Runs the script from standard input (nothing is left on the host).
    public func streamedCommand(mode: String) -> String {
        "bash -s -- " + arguments(mode: mode).map(\.shellQuoted).joined(separator: " ")
    }

    /// Saves the script on the host (from standard input) for the root step.
    public var saveCommand: String {
        "mkdir -p ~/.cache/ycode && cat > \(remotePath) && chmod 0700 \(remotePath)"
    }

    /// What the user runs in their own terminal for the root steps: ssh with
    /// a terminal, then sudo, which asks them for their password itself.
    public func rootCommand(destination: String) -> String {
        "ssh -t \(destination.shellQuoted) " + ("sudo bash \(remotePath) " + arguments(mode: "root").map(\.shellQuoted).joined(separator: " ")).shellQuoted
    }
}

/// The kernel check for the KVM arm64 SVE bug (`docs/postmortem-kvm-sve.md`).
public enum KVMSVEProbe {
    public static let postmortem = "https://github.com/MarcoDotIO/Ycode/blob/main/docs/postmortem-kvm-sve.md"
    /// Runs needed before "no loss" counts as a pass (an unpatched kernel
    /// loses predicates in about 0.7% of runs at much smaller windows).
    public static let minimumRuns: UInt64 = 100_000

    public struct Facts: Sendable, Equatable {
        public var architecture: String
        public var hasSVE: Bool
        public var kvm: String
        public var kernel: String
        public var runs: UInt64?
        public var lost: UInt64?
        public var error: String?

        public init(architecture: String, hasSVE: Bool, kvm: String, kernel: String = "", runs: UInt64? = nil, lost: UInt64? = nil, error: String? = nil) {
            self.architecture = architecture
            self.hasSVE = hasSVE
            self.kvm = kvm
            self.kernel = kernel
            self.runs = runs
            self.lost = lost
            self.error = error
        }

        /// From the script's `YCODE-SVE` key=value line.
        public init(_ kv: [String: String]) {
            self.init(architecture: kv["arch"] ?? "", hasSVE: kv["sve"] == "yes", kvm: kv["kvm"] ?? "", kernel: kv["kernel"] ?? "",
                      runs: kv["runs"].flatMap { UInt64($0) }, lost: kv["lost"].flatMap { UInt64($0) }, error: kv["error"])
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// Not arm64, or no SVE: the bug cannot happen.
        case notApplicable(String)
        /// Predicates survived every run: the kernel has the fix (or is not affected).
        case fixed(runs: UInt64)
        /// Predicates were lost: the kernel lacks the fix.
        case affected(lost: UInt64, runs: UInt64)
        /// The probe could not run or ran too little.
        case unknown(String)
    }

    /// The decision, from the facts alone.
    public static func verdict(_ f: Facts) -> Verdict {
        if !["aarch64", "arm64"].contains(f.architecture) {
            return .notApplicable("This host is \(f.architecture.isEmpty ? "not arm64" : f.architecture); the bug is in KVM on arm64 with SVE.")
        }
        if !f.hasSVE || f.error == "no-sve" { return .notApplicable("This CPU has no SVE, so its predicate registers cannot be lost.") }
        if let lost = f.lost, let runs = f.runs {
            if lost > 0 { return .affected(lost: lost, runs: runs) }
            if runs >= minimumRuns { return .fixed(runs: runs) }
            return .unknown("The probe ran only \(runs) times; that is too few to tell.")
        }
        switch f.error ?? "" {
        case "no-kvm-access": return .unknown("The probe needs /dev/kvm; fix KVM access first.")
        case "no-compiler": return .unknown("The probe needs a C compiler (cc or the Swift toolchain's clang).")
        case "skipped": return .unknown("The probe was skipped.")
        case "": return .unknown("The probe gave no result.")
        case let e: return .unknown("The probe failed (\(e)).")
        }
    }

    public static func check(_ f: Facts) -> RuntimeCheck {
        let title = HostSetupOutput.title(of: "setup.sve")
        let kernel = f.kernel.isEmpty ? "" : " Kernel \(f.kernel)."
        switch verdict(f) {
        case .notApplicable(let why):
            return RuntimeCheck("setup.sve", title, .notApplicable, why)
        case .fixed(let runs):
            return RuntimeCheck("setup.sve", title, .ok, "No SVE state was lost in \(runs) KVM runs: the kernel has the fix.\(kernel)")
        case .affected(let lost, let runs):
            return RuntimeCheck("setup.sve", title, .missing,
                                "The kernel lost the SVE predicate registers in \(lost) of \(runs) KVM runs. Without the upstream fix (commit fbc7e61195e2), copies made by the simulator's threads can silently not happen. Ycode's built-in mitigations are on, so the simulator still runs correctly; a fixed kernel removes the risk.\(kernel)",
                                fix: .instructions("How to get a kernel with the fix: \(postmortem)"))
        case .unknown(let why):
            return RuntimeCheck("setup.sve", title, .unknown, why + kernel + " Ycode's mitigations are on either way.")
        }
    }
}
