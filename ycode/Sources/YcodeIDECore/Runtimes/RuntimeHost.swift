// Runtimes on a simulator host (#69; `runtime-onboarding.md` §11.5,
// `sim-link.md`): the host's checks (reachable with an ssh key, paired over
// Ycode's link, arm64 Linux, KVM, disk space, Ycode's version), the runtimes
// in its data folder, and a copy of a runtime to it that shows progress and
// resumes after an interruption. An offline host marks its rows unknown, not
// missing. The checks reuse the wizard's checklist model (`RuntimeCheck`).

import Foundation

/// The simulator host the wizard sets up.
public struct RuntimeHostSettings: Sendable, Equatable, Codable {
    /// `user@host`: an ssh destination, keys only.
    public var destination = ""
    /// Ycode's data folder on the host (`$YCODE_DATA`): runtimes, devices.
    public var dataDirectory = ""
    /// The host's name on Ycode's link (`ycode sim remote pair … --name`),
    /// when it differs from the ssh host name.
    public var linkName = ""
    /// A built `ycode` on the host, for the version check (empty: on PATH).
    public var ycodePath = ""
    /// Where the setup script writes `simhost.env` (empty: `~/.config/ycode`).
    public var configDirectory = ""
    /// The link's ports on the host (`simhost.env`; another user's service may hold the defaults).
    public var tcpPort = 47800
    public var udpPort = 47801

    public init(destination: String = "", dataDirectory: String = "", linkName: String = "", ycodePath: String = "") {
        self.destination = destination
        self.dataDirectory = dataDirectory
        self.linkName = linkName
        self.ycodePath = ycodePath
    }

    /// The host part of the destination ("user@sim-host" → "sim-host").
    public var hostName: String {
        let d = destination.split(separator: "@").last.map(String.init) ?? destination
        return d.split(separator: ":").first.map(String.init) ?? d
    }

    /// The name its link peer has.
    public var peerName: String { linkName.isEmpty ? hostName : linkName }

    enum CodingKeys: String, CodingKey { case destination, dataDirectory, linkName, ycodePath, configDirectory, tcpPort, udpPort }

    /// Fields saved by an older Ycode may be missing; they keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        dataDirectory = try c.decodeIfPresent(String.self, forKey: .dataDirectory) ?? ""
        linkName = try c.decodeIfPresent(String.self, forKey: .linkName) ?? ""
        ycodePath = try c.decodeIfPresent(String.self, forKey: .ycodePath) ?? ""
        configDirectory = try c.decodeIfPresent(String.self, forKey: .configDirectory) ?? ""
        tcpPort = try c.decodeIfPresent(Int.self, forKey: .tcpPort) ?? 47800
        udpPort = try c.decodeIfPresent(Int.self, forKey: .udpPort) ?? 47801
    }

    /// "47800/47801" (or "47800 47801") → the TCP and UDP ports; nil when not two ports.
    public static func ports(_ text: String) -> (Int, Int)? {
        let p = text.split(whereSeparator: { $0 == "/" || $0 == " " || $0 == "," }).compactMap { Int($0) }
        guard p.count == 2, p.allSatisfy({ (1...65535).contains($0) }) else { return nil }
        return (p[0], p[1])
    }

    public var isComplete: Bool { !destination.trimmed.isEmpty && !dataDirectory.trimmed.isEmpty }

    public var runtimesFolder: String { RuntimeFolders.host(dataDirectory: dataDirectory) }
}

/// The host's checks (reachable, link, platform, KVM, disk, version, runtimes).
public struct RuntimeHostChecker: Sendable {
    public var host: RuntimeHostSettings
    public var choices: RuntimeSetupChoices
    /// Runs on the host (ssh with a key; tests answer for it).
    public var runner: any HeadsetCommandRunner
    /// The hosts paired over Ycode's link on this machine (their names).
    public var pairedHosts: [String]
    /// Runtime roots configured by hand for this host (Settings ▸ Simulators).
    public var configuredRoots: [String]
    public var localVersion: String

    public init(host: RuntimeHostSettings, choices: RuntimeSetupChoices, runner: any HeadsetCommandRunner, pairedHosts: [String] = [],
                configuredRoots: [String] = [], localVersion: String = ProductIdentity.version) {
        self.host = host
        self.choices = choices
        self.runner = runner
        self.pairedHosts = pairedHosts
        self.configuredRoots = configuredRoots
        self.localVersion = localVersion
    }

    public enum Command {
        public static let uname = "uname -sm"
        public static let kvm = RuntimeSetupChecker.Command.kvm

        /// The named ycode's version; else the release the setup installed in
        /// the data folder, read from its folder without running it (its
        /// `manifest.json`, else `Ycode-<version>-<arch>`: the release's tools
        /// may not start outside the Flatpak runtime); else the data folder's
        /// or PATH's `ycode --version`.
        public static func version(_ ycodePath: String, dataDirectory: String = "") -> String {
            if !ycodePath.isEmpty { return "\(ycodePath.shellQuoted) --version 2>/dev/null | head -1" }
            let mine = (dataDirectory + "/bin/ycode").shellQuoted, host = (dataDirectory + "/bin/ycode-simhost").shellQuoted
            return "{ r=$(readlink -f \(host)); t=${r%/bin/*}; v=''; "
                + "[ -n \"$r\" ] && [ -f \"$t/manifest.json\" ] && v=$(grep -o '\"version\"[[:space:]]*:[[:space:]]*\"[^\"]*\"' \"$t/manifest.json\" | head -1 | sed 's/.*\"\\([^\"]*\\)\"$/\\1/'); "
                + "[ -n \"$v\" ] || { [ -n \"$r\" ] && v=$(basename \"$t\" | sed -nE 's/^Ycode-(.*)-(aarch64|x86_64)$/\\1/p'); }; "
                + "if [ -n \"$v\" ]; then echo \"ycode $v (release folder)\"; elif [ -x \(mine) ]; then \(mine) --version; else ycode --version; fi; } 2>/dev/null | head -1"
        }

        /// One line per runtime: `RT\t<path>\t<kilobytes or ->\t<SystemVersion.plist base64>\t<marker base64 or ->`.
        /// Ycode's folders give their size from the marker (no `du` over 16 GB).
        public static func listRuntimes(folder: String, extraRoots: [String]) -> String {
            let roots = extraRoots.map(\.shellQuoted).joined(separator: " ")
            return """
            b64() { base64 < "$1" | tr -d '\\n'; }; \
            for d in \(folder.shellQuoted)/*/; do d=${d%/}; [ -f "$d/\(RuntimeFolders.marker)" ] || continue; \
            sv="$d/RuntimeRoot/\(RuntimeBundleReader.systemVersionPath)"; [ -f "$sv" ] || continue; \
            printf 'RT\\t%s\\t-\\t%s\\t%s\\n' "$d" "$(b64 "$sv")" "$(b64 "$d/\(RuntimeFolders.marker)")"; done; \
            for d in \(folder.shellQuoted)/*\(RuntimeFolders.incomingSuffix); do [ -d "$d" ] || continue; \
            printf 'IN\\t%s\\t%s\\n' "$d" "$(du -sk "$d" | cut -f1)"; done; \
            for r in \(roots); do sv="$r/\(RuntimeBundleReader.systemVersionPath)"; [ -f "$sv" ] || continue; \
            printf 'RT\\t%s\\t-\\t%s\\t-\\n' "$r" "$(b64 "$sv")"; done; true
            """
        }
    }

    public func run() async -> RuntimeSetupReport {
        var report = RuntimeSetupReport()
        guard host.isComplete else {
            report.checks.append(RuntimeCheck("host.reach", "Host", .missing, "Name the simulator host and Ycode's data folder on it.",
                                              fix: .instructions("Enter its ssh destination (user@host) and a folder on a volume with room for runtimes. Ycode logs in with a key only and never asks for a password.")))
            return report
        }
        guard host.dataDirectory.hasPrefix("/") else {
            report.checks.append(RuntimeCheck("host.reach", "Host", .missing, "The data folder must be an absolute path on the host (such as /data/ycode).",
                                              fix: .step(.host)))
            return report
        }
        let u = await runner.run(Command.uname)
        guard u.ok else {
            // Offline or no key: every host row is unknown (§11.5), with the reason.
            report.checks.append(RuntimeCheck("host.reach", "Reachable", .unknown,
                                              "\(host.destination) did not answer, or does not accept your ssh key. The host may be offline.",
                                              fix: .command("ssh-copy-id \(host.destination)")))
            for (id, title) in [("host.link", "Ycode's link"), ("host.platform", "arm64 Linux"), ("host.kvm", "KVM"), ("host.version", "Ycode version"), ("host.disk", "Disk space")] {
                report.checks.append(RuntimeCheck(id, title, .unknown, "The host is offline."))
            }
            for p in SimPlatform.allCases where choices.platforms.contains(p) {
                report.checks.append(RuntimeCheck(RuntimeCheck.runtimeID(p, host: true), "Runtime for \(p.title)", .unknown, "The host is offline."))
            }
            return report
        }
        report.checks.append(RuntimeCheck("host.reach", "Reachable", .ok, "\(host.destination) answers with your ssh key."))
        report.checks.append(checkLink())
        report.checks.append(Self.checkPlatform(u.output.trimmed))
        report.checks.append(await checkKVM())
        report.checks.append(await checkVersion())
        let listing = await runner.run(Command.listRuntimes(folder: host.runtimesFolder, extraRoots: configuredRoots))
        let parsed = Self.parseListing(listing.output, host: host.destination, folder: host.runtimesFolder)
        report.host = parsed.records
        for p in SimPlatform.allCases where choices.platforms.contains(p) {
            report.checks.append(RuntimeSetupChecker.checkRuntime(p, records: parsed.records, minimum: choices.minimumVersions[p],
                                                                  machine: SetupMachine(isMac: false, architecture: "aarch64"), host: host.destination))
        }
        let need = choices.platforms.map(\.typicalUnpackedBytes).max() ?? 0
        report.checks.append(RuntimeSetupChecker.diskCheck(id: "host.disk", title: "Disk space on the host",
                                                           output: await runner.run(RuntimeSetupChecker.Command.freeKB(host.dataDirectory)),
                                                           needBytes: need, place: host.dataDirectory))
        if let inc = parsed.incoming.first {
            report.checks.append(RuntimeCheck("transfer", "Copy in progress", .missing,
                                              "\((inc.path as NSString).lastPathComponent) stopped after \(RuntimeSize.format(inc.bytes)). Copy it again to resume."))
        }
        return report
    }

    func checkLink() -> RuntimeCheck {
        if pairedHosts.contains(host.peerName) { return RuntimeCheck("host.link", "Ycode's link", .ok, "Paired as \(host.peerName).") }
        return RuntimeCheck("host.link", "Ycode's link", .missing,
                            "Not paired. On the host run ycode-simhost pair; it prints a one-time code. Then run the command here with that code.",
                            fix: .command("ycode sim remote pair \(host.hostName) <code> --name \(host.peerName)"))
    }

    /// `uname -sm` → arm64 Linux or not.
    public static func checkPlatform(_ unameSM: String) -> RuntimeCheck {
        let words = unameSM.split(separator: " ").map(String.init)
        let os = words.first ?? "", arch = words.last ?? ""
        if os == "Linux", ["aarch64", "arm64"].contains(arch) { return RuntimeCheck("host.platform", "arm64 Linux", .ok, "Linux on \(arch).") }
        return RuntimeCheck("host.platform", "arm64 Linux", .missing,
                            "The host runs \(os) on \(arch); Ycode's simulator needs arm64 Linux with KVM (a Jetson-class board, for example).",
                            fix: .instructions("Choose an arm64 Linux machine as the simulator host."))
    }

    func checkKVM() async -> RuntimeCheck {
        let r = await runner.run(Command.kvm)
        switch r.output.trimmed {
        case "access": return RuntimeCheck("host.kvm", "KVM", .ok, "/dev/kvm is open to \(host.destination.split(separator: "@").first.map(String.init) ?? "you").")
        case "denied": return RuntimeCheck("host.kvm", "KVM", .missing, "/dev/kvm exists, but your user may not open it.", fix: .step(.prepare))
        case "absent": return RuntimeCheck("host.kvm", "KVM", .missing, "The host has no /dev/kvm.", fix: .instructions("Turn on virtualization in the host's firmware and load the kvm module."))
        default: return RuntimeCheck("host.kvm", "KVM", .unknown, "Could not look at /dev/kvm on the host.")
        }
    }

    func checkVersion() async -> RuntimeCheck {
        let r = await runner.run(Command.version(host.ycodePath, dataDirectory: host.dataDirectory))
        let theirs = Self.version(inVersionOutput: r.output)
        guard r.ok, let theirs else {
            return RuntimeCheck("host.version", "Ycode version", .unknown, "No ycode on the host yet; Prepare Host installs Ycode \(localVersion) there.",
                                fix: .step(.prepare))
        }
        if theirs == localVersion { return RuntimeCheck("host.version", "Ycode version", .ok, "\(theirs) on both.") }
        return RuntimeCheck("host.version", "Ycode version", .missing, "The host has \(theirs), this machine \(localVersion). Prepare Host installs Ycode \(localVersion) there.",
                            fix: .step(.prepare))
    }

    /// The version in `ycode --version` ("ycode 1.0.0-beta.1 (…)" → "1.0.0-beta.1").
    public static func version(inVersionOutput s: String) -> String? {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "(" || $0 == ")" }).map(String.init)
            .first { $0.first?.isNumber == true && $0.contains(".") }
    }

    /// A copy that stopped: its folder and how much is there.
    public struct Incoming: Sendable, Equatable {
        public var path: String
        public var bytes: Int64
    }

    /// Parses `Command.listRuntimes`' lines.
    public static func parseListing(_ text: String, host: String, folder: String) -> (records: [SimRuntimeRecord], incoming: [Incoming]) {
        var records: [SimRuntimeRecord] = []
        var incoming: [Incoming] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "IN", f.count >= 3 {
                incoming.append(Incoming(path: f[1], bytes: (Int64(f[2]) ?? 0) * 1024))
                continue
            }
            guard f.first == "RT", f.count >= 5, let sv = Data(base64Encoded: f[3]) else { continue }
            let path = f[1]
            let marker = Data(base64Encoded: f[4]).flatMap { try? JSONDecoder().decode(RuntimeMarker.self, from: $0) }
            let owner: RuntimeOwner = marker != nil && RuntimeFolders.isRuntimeFolder(path, inside: folder) ? .ycode(folder: path) : .external
            guard var r = RuntimeBundleReader.record(systemVersion: sv, location: .host(host), owner: owner) else { continue }
            r.runtimeRoot = marker != nil ? path + "/RuntimeRoot" : path
            r.identifier = marker?.identifier
            r.unpackedBytes = marker?.sizeBytes ?? Int64(f[2]).map { $0 * 1024 }
            if let p = marker.flatMap({ SimPlatform(name: $0.platform) }) { r.platform = p }
            records.append(r)
        }
        return (SimctlRuntimeListing.sorted(records), incoming)
    }
}

// MARK: - Copying a runtime to the host

/// A copy of a RuntimeRoot to the host: `rsync --partial` into
/// `<runtimes>/<name>.incoming/RuntimeRoot`, then the marker, then a rename
/// into place. Interrupted, the `.incoming` folder stays; the same copy run
/// again resumes (rsync sends only what is missing). Progress is the size
/// of the `.incoming` folder against the source's size.
public struct RuntimeTransfer: Sendable, Equatable {
    public var source: String
    public var record: SimRuntimeRecord
    public var host: RuntimeHostSettings
    public var totalBytes: Int64

    public init(source: String, record: SimRuntimeRecord, host: RuntimeHostSettings, totalBytes: Int64) {
        self.source = source
        self.record = record
        self.host = host
        self.totalBytes = totalBytes
    }

    public var destination: String { host.runtimesFolder + "/" + record.folderName }
    public var incoming: String { destination + RuntimeFolders.incomingSuffix }

    /// ssh options for rsync's `-e` and the commands: a key only, never prompt.
    public static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15"]

    /// `rsync` arguments (the local program runs them).
    public func rsyncArguments(ssh: String) -> [String] {
        ["-a", "--partial", "-e", ([ssh] + Self.sshOptions).joined(separator: " "),
         source.hasSuffix("/") ? source : source + "/", "\(host.destination):\(incoming)/RuntimeRoot/"]
    }

    /// Before: the folder exists. (Run on the host.)
    public var prepareCommand: String { "mkdir -p \((incoming + "/RuntimeRoot").shellQuoted)" }

    /// After a complete copy: the marker, then the rename. (Run on the host.)
    public func finishCommand(markerJSON: String) -> String {
        "printf '%s\\n' \(markerJSON.shellQuoted) > \((incoming + "/" + RuntimeFolders.marker).shellQuoted)"
            + " && rm -rf \(destination.shellQuoted) && mv \(incoming.shellQuoted) \(destination.shellQuoted)"
    }

    /// Kilobytes in the `.incoming` folder so far (run on the host).
    public var progressCommand: String { "du -sk \(incoming.shellQuoted) 2>/dev/null | cut -f1" }

    /// The command line the confirmation shows.
    public func shownCommand(ssh: String = "ssh") -> String {
        "ssh \(host.destination.shellQuoted) \(prepareCommand.shellQuoted)\n"
            + RuntimeCommands.line(["rsync"] + rsyncArguments(ssh: ssh)) + "\n"
            + "ssh \(host.destination.shellQuoted) '<write ycode-runtime.json, rename \(record.folderName).incoming to \(record.folderName)>'"
    }

    /// The fraction done (0…1) from the `.incoming` folder's kilobytes.
    public func fraction(copiedKB: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(copiedKB * 1024) / Double(totalBytes))
    }

    public func progressText(copiedKB: Int64) -> String {
        "\(RuntimeSize.format(copiedKB * 1024)) of \(RuntimeSize.format(totalBytes)) (\(Int(fraction(copiedKB: copiedKB) * 100))%)"
    }
}

/// A transfer's state as the wizard shows it.
public enum RuntimeTransferState: Sendable, Equatable {
    case idle
    case copying(copiedKB: Int64)
    /// Stopped before the end (a dropped connection, Stop): Copy resumes.
    case interrupted(copiedKB: Int64, reason: String)
    case finished
    case failed(String)

    /// An rsync exit status → the state after it (rsync's documented codes:
    /// 20 a signal, 30 a timeout, 12/23/35 partial or protocol trouble from a
    /// dropped connection, 255 ssh's own failure).
    public static func after(rsyncStatus s: Int32, copiedKB: Int64) -> RuntimeTransferState {
        switch s {
        case 0: .finished
        case 20, 30, 12, 23, 24, 35, 255, 128 + 15, 128 + 2, 128 + 9:
            .interrupted(copiedKB: copiedKB, reason: s == 255 ? "The connection to the host was lost." : "The copy stopped (rsync status \(s)).")
        default: .failed("rsync failed with status \(s).")
        }
    }
}
