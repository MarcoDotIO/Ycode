// The runtime wizard's checklist (`specs/simulator/runtime-onboarding.md`
// §9, §11; the pattern of the headset checklist, `device-hub.md` §I.12):
// each check has a state (ok, missing, unknown, not applicable), a reason
// and at most one fix, and Re-check runs it again. Checks only look: they
// run read-only commands through a `HeadsetCommandRunner` (the same runner
// protocol the headset checklist uses). Anything that changes a machine is
// a `RuntimeAction`, which runs only after the user confirmed the exact
// command. Ycode never downloads a runtime (#55): where the reference
// would fetch one, the wizard explains how to get one with the user's own
// Xcode. Portable: the macOS window, the Linux shell and the command line
// show the same list.

import Foundation

/// A check's state.
public enum SetupCheckState: String, Sendable, Equatable, Codable {
    case ok, missing, unknown
    /// The check does not apply to this machine (an x86-64 host's SVE check).
    case notApplicable = "na"

    public var title: String {
        switch self {
        case .ok: "Passed"
        case .missing: "Needs attention"
        case .unknown: "Unknown"
        case .notApplicable: "Not applicable"
        }
    }
}

/// How a runtime file is added to a Mac's CoreSimulator (§6, §7.2).
public enum RuntimeImportTool: String, Sendable, Equatable, CaseIterable {
    case simctl, xcodebuild

    /// The exact command the confirmation shows and Ycode then runs.
    public func command(file: String) -> [String] {
        switch self {
        case .simctl: ["xcrun", "simctl", "runtime", "add", file]
        case .xcodebuild: ["xcodebuild", "-importPlatform", file]
        }
    }
}

/// Something that changes a machine. Each one is shown with its exact
/// command and runs only when the user confirms it.
public enum RuntimeAction: Sendable, Equatable {
    /// A runtime image the user picked, added to this Mac's CoreSimulator.
    case importImage(path: String, tool: RuntimeImportTool)
    /// A bundle or RuntimeRoot (or a Mac's runtime) copied into Ycode's
    /// folder on this machine (Linux).
    case copyToThisMachine(source: String, record: SimRuntimeRecord)
    /// A runtime copied to a simulator host (resumes a copy that stopped).
    case copyToHost(source: String, record: SimRuntimeRecord, host: String)
    /// One of Ycode's own runtime folders removed (here or on a host).
    case remove(SimRuntimeRecord)
    /// The provisioning script's steps that need no root, on the host (#70).
    case provisionApply
}

/// The one way to put a check right.
public enum RuntimeFix: Sendable, Equatable {
    /// A command the user runs in a terminal (shown with Copy; never run by Ycode).
    case command(String)
    /// Ycode does it after a confirmation that shows the command.
    case action(RuntimeAction)
    /// Words.
    case instructions(String)
    /// Go to a step of the wizard.
    case step(RuntimeSetupStep)
}

/// One line of the checklist.
public struct RuntimeCheck: Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var state: SetupCheckState
    public var reason: String
    public var fix: RuntimeFix?

    public init(_ id: String, _ title: String, _ state: SetupCheckState, _ reason: String, fix: RuntimeFix? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.reason = reason
        self.fix = fix
    }

    /// "runtime.iOS", "host.runtime.visionOS".
    public static func runtimeID(_ p: SimPlatform, host: Bool = false) -> String { (host ? "host.runtime." : "runtime.") + p.rawValue }
}

/// Where the simulator runs.
public enum RuntimeTarget: Sendable, Equatable {
    /// This Mac (CoreSimulator), or this arm64 Linux machine (Ycode's simulator).
    case thisMachine
    /// A simulator host reached with an ssh key (and Ycode's link).
    case host(RuntimeHostSettings)

    public var isHost: Bool { if case .host = self { true } else { false } }
}

/// The machine Ycode runs on.
public struct SetupMachine: Sendable, Equatable {
    public var isMac: Bool
    /// `uname -m`: arm64, aarch64, x86_64.
    public var architecture: String
    public init(isMac: Bool, architecture: String) {
        self.isMac = isMac
        self.architecture = architecture
    }

    public var isARM64: Bool { ["arm64", "aarch64"].contains(architecture) }
    /// Whether Ycode's simulator can run here: a Mac (Apple's), or arm64 Linux.
    public var canRunSimulatorHere: Bool { isMac || isARM64 }

    public static var current: SetupMachine {
        var u = utsname()
        uname(&u)
        let arch = withUnsafePointer(to: &u.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        #if os(macOS)
        return SetupMachine(isMac: true, architecture: arch)
        #else
        return SetupMachine(isMac: false, architecture: arch)
        #endif
    }

    public var title: String { isMac ? "This Mac" : "This computer" }
}

/// The wizard's steps. Some are left out for a target (`steps(for:)`).
public enum RuntimeSetupStep: Int, Sendable, CaseIterable, Codable {
    case target, runtimes, add, host, prepare, finish

    public var title: String {
        switch self {
        case .target: "Where to Run"
        case .runtimes: "Runtimes"
        case .add: "Add a Runtime"
        case .host: "Simulator Host"
        case .prepare: "Prepare Host"
        case .finish: "Ready"
        }
    }

    public func summary(machine: SetupMachine, target: RuntimeTarget) -> String {
        switch self {
        case .target:
            return "Choose the platforms you build for and where their simulators run. Ycode uses runtimes you already have; it never downloads one."
        case .runtimes:
            if target.isHost { return "The runtimes on the simulator host, and the ones here that can be copied to it." }
            return machine.isMac ? "The simulator runtimes registered on this Mac. Runtimes that Xcode installed are listed here; manage them in Xcode."
                : "The runtimes in Ycode's folder on this computer. Ycode's simulator boots a runtime's RuntimeRoot."
        case .add:
            if target.isHost { return "Copy a runtime you have to the simulator host. A copy that stops resumes where it left off." }
            return machine.isMac ? "Add a runtime disk image you downloaded yourself. Ycode shows the command and runs it only when you confirm."
                : "Copy a runtime bundle or RuntimeRoot from your own Xcode installation into Ycode's folder."
        case .host:
            return "The arm64 Linux machine with KVM that runs the simulator. Ycode logs in with an ssh key and pairs over its own link."
        case .prepare:
            return "A setup script for the host. It only reports until you choose to apply it. Steps that need root run in your own terminal with sudo."
        case .finish:
            return "What is ready, and the run destinations it gives you."
        }
    }

    /// The steps a target goes through, in order.
    public static func steps(for target: RuntimeTarget) -> [RuntimeSetupStep] {
        target.isHost ? [.target, .host, .prepare, .runtimes, .add, .finish] : [.target, .runtimes, .add, .finish]
    }

    /// The checks each step shows (ids; the platform rows go with `.runtimes`).
    public func shows(_ check: RuntimeCheck) -> Bool {
        switch self {
        case .target: ["machine", "tools", "kvm"].contains(check.id)
        case .runtimes: check.id.hasPrefix("runtime.") || check.id.hasPrefix("host.runtime.")
        case .add: ["disk", "host.disk", "transfer"].contains(check.id)
        case .host: check.id.hasPrefix("host.") && !check.id.hasPrefix("host.runtime.") && check.id != "host.disk"
        case .prepare: check.id.hasPrefix("setup.")
        case .finish: false
        }
    }
}

/// A full round of checks.
public struct RuntimeSetupReport: Sendable, Equatable {
    public var checks: [RuntimeCheck]
    /// The runtimes this machine has (CoreSimulator's and Ycode's).
    public var local: [SimRuntimeRecord]
    /// The runtimes on the host (when the target is one).
    public var host: [SimRuntimeRecord]

    public init(checks: [RuntimeCheck] = [], local: [SimRuntimeRecord] = [], host: [SimRuntimeRecord] = []) {
        self.checks = checks
        self.local = local
        self.host = host
    }

    public func check(_ id: String) -> RuntimeCheck? { checks.first { $0.id == id } }
    public func checks(in step: RuntimeSetupStep) -> [RuntimeCheck] { checks.filter(step.shows) }

    /// The step's mark: ok when every check passed (or does not apply),
    /// missing when one needs attention, else unknown; nil without checks.
    public func state(of step: RuntimeSetupStep) -> SetupCheckState? {
        let cs = checks(in: step)
        guard !cs.isEmpty else { return nil }
        if cs.allSatisfy({ $0.state == .ok || $0.state == .notApplicable }) { return .ok }
        return cs.contains { $0.state == .missing } ? .missing : .unknown
    }

    /// The platforms with a usable runtime where the simulator runs.
    public var readyPlatforms: [SimPlatform] {
        SimPlatform.allCases.filter { p in
            checks.contains { ($0.id == RuntimeCheck.runtimeID(p) || $0.id == RuntimeCheck.runtimeID(p, host: true)) && $0.state == .ok }
        }
    }

    /// The first step with something that needs attention.
    public func firstProblemStep(for target: RuntimeTarget) -> RuntimeSetupStep {
        for s in RuntimeSetupStep.steps(for: target) where s != .target && state(of: s) == .missing { return s }
        return readyPlatforms.isEmpty ? .runtimes : .finish
    }
}

/// What the user chose (kept per Ycode installation).
public struct RuntimeSetupChoices: Sendable, Equatable, Codable {
    public var platforms: Set<SimPlatform> = [.iOS]
    /// Lowest versions the runtimes must have (a project's deployment targets).
    public var minimumVersions: [SimPlatform: String] = [:]
    /// Run on a simulator host instead of this machine.
    public var useHost = false
    public var host = RuntimeHostSettings()

    public init() {}

    static let key = "Ycode.runtimeSetup.choices"
    /// Set once the wizard was offered at first launch.
    public static let offeredKey = "Ycode.runtimeSetup.offered"

    public static func load(_ d: UserDefaults) -> RuntimeSetupChoices {
        guard let data = d.data(forKey: key), let c = try? JSONDecoder().decode(RuntimeSetupChoices.self, from: data) else { return RuntimeSetupChoices() }
        return c
    }

    public func save(_ d: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }

    public var target: RuntimeTarget { useHost ? .host(host) : .thisMachine }
}

/// Runs the checks for this machine (the host's are `RuntimeHostChecker`'s).
public struct RuntimeSetupChecker: Sendable {
    public var machine: SetupMachine
    public var choices: RuntimeSetupChoices
    public var runner: any HeadsetCommandRunner
    /// Ycode's runtime folder on this machine.
    public var folder: String

    public init(machine: SetupMachine = .current, choices: RuntimeSetupChoices, runner: any HeadsetCommandRunner = LocalHeadsetRunner(timeout: 60),
                folder: String = RuntimeFolders.local()) {
        self.machine = machine
        self.choices = choices
        self.runner = runner
        self.folder = folder
    }

    /// The commands' words (tests and the spec name them).
    public enum Command {
        public static let simctlHelp = "xcrun --find simctl"
        public static let images = "xcrun simctl runtime list -j"
        public static let runtimes = "xcrun simctl list runtimes -j"
        public static let kvm = "if [ -c /dev/kvm ]; then if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then echo access; else echo denied; fi; else echo absent; fi"
        /// Free kilobytes of the file system that holds `path` (or its nearest existing parent).
        public static func freeKB(_ path: String) -> String {
            "p=\(path.shellQuoted); while [ ! -e \"$p\" ] && [ \"$p\" != / ]; do p=$(dirname \"$p\"); done; df -Pk \"$p\" | awk 'NR==2 {print $4}'"
        }
    }

    public func run() async -> RuntimeSetupReport {
        var report = RuntimeSetupReport()
        report.checks.append(checkMachine())
        if machine.isMac {
            let tools = await checkTools()
            report.checks.append(tools)
            if tools.state == .ok { report.local = await readCoreSimulator() }
        } else if machine.isARM64 {
            report.checks.append(await checkKVM())
        }
        report.local += RuntimeBundleReader.ycodeRuntimes(in: folder)
        if !choices.useHost {
            for p in SimPlatform.allCases where choices.platforms.contains(p) {
                report.checks.append(Self.checkRuntime(p, records: report.local, minimum: choices.minimumVersions[p], machine: machine, host: nil))
            }
            report.checks.append(await checkDisk())
        }
        return report
    }

    // MARK: Checks

    func checkMachine() -> RuntimeCheck {
        if machine.isMac { return RuntimeCheck("machine", "This Mac", .ok, "Simulators run here with the runtimes registered with CoreSimulator.") }
        if machine.isARM64 { return RuntimeCheck("machine", "This computer", .ok, "arm64 Linux: Ycode's simulator can run here with KVM.") }
        if choices.useHost {
            return RuntimeCheck("machine", "This computer", .ok, "\(machine.architecture) Linux: the simulator runs on the host you choose.")
        }
        return RuntimeCheck("machine", "This computer", .missing,
                            "Ycode's simulator needs arm64 Linux with KVM; this computer is \(machine.architecture). Run it on another machine.",
                            fix: .step(.host))
    }

    func checkTools() async -> RuntimeCheck {
        let r = await runner.run(Command.simctlHelp)
        if r.ok { return RuntimeCheck("tools", "Simulator tools", .ok, "simctl from your Xcode (\(r.output.trimmed)).") }
        return RuntimeCheck("tools", "Simulator tools", .missing, "simctl was not found. Install Xcode, open it once, and choose it as the developer directory.",
                            fix: .command("xcodebuild -runFirstLaunch"))
    }

    func readCoreSimulator() async -> [SimRuntimeRecord] {
        let images = await runner.run(Command.images)
        let listed = await runner.run(Command.runtimes)
        guard images.ok else { return listed.ok ? SimctlRuntimeListing.parseRuntimes(Data(listed.output.utf8)) : [] }
        return SimctlRuntimeListing.parse(images: Data(images.output.utf8), runtimes: listed.ok ? Data(listed.output.utf8) : nil)
    }

    func checkKVM() async -> RuntimeCheck {
        let r = await runner.run(Command.kvm)
        switch r.output.trimmed {
        case "access": return RuntimeCheck("kvm", "KVM", .ok, "/dev/kvm is open to you.")
        case "denied": return RuntimeCheck("kvm", "KVM", .missing, "/dev/kvm exists, but you may not open it.", fix: .command("sudo usermod -aG kvm $USER"))
        case "absent": return RuntimeCheck("kvm", "KVM", .missing, "This computer has no /dev/kvm: turn on virtualization, or run the simulator on another machine.",
                                           fix: .step(.host))
        default: return RuntimeCheck("kvm", "KVM", .unknown, "Could not look at /dev/kvm.")
        }
    }

    func checkDisk() async -> RuntimeCheck {
        // A Mac adds images to CoreSimulator's storage on the system volume;
        // Linux unpacks a RuntimeRoot into Ycode's folder (§4.5).
        let path = machine.isMac ? "/" : folder
        let need = choices.platforms.map { machine.isMac ? $0.typicalImageBytes : $0.typicalUnpackedBytes }.max() ?? 0
        return Self.diskCheck(id: "disk", title: "Disk space", output: await runner.run(Command.freeKB(path)), needBytes: need,
                              place: machine.isMac ? "the system volume" : folder)
    }

    /// The free-space check from `df`'s kilobytes (§9: before any copy or import).
    public static func diskCheck(id: String, title: String, output r: HeadsetCommandResult, needBytes: Int64, place: String) -> RuntimeCheck {
        guard r.ok, let kb = Int64(r.output.trimmed) else { return RuntimeCheck(id, title, .unknown, "Could not read the free space of \(place).") }
        let free = kb * 1024
        if free >= needBytes { return RuntimeCheck(id, title, .ok, "\(RuntimeSize.format(free)) free on \(place).") }
        return RuntimeCheck(id, title, .missing,
                            "\(RuntimeSize.format(free)) free on \(place); a runtime needs about \(RuntimeSize.format(needBytes)).",
                            fix: .instructions("Free some space, or remove a runtime you no longer use."))
    }

    /// "Runtime for <platform>" (§11.1): ok for a usable runtime at or above
    /// the minimum version; the newest one is named.
    public static func checkRuntime(_ p: SimPlatform, records: [SimRuntimeRecord], minimum: String?, machine: SetupMachine, host: String?) -> RuntimeCheck {
        let id = RuntimeCheck.runtimeID(p, host: host != nil)
        let title = "Runtime for \(p.title)"
        let mine = records.filter { $0.platform == p }
        let usable = mine.filter(\.isUsable)
        let fitting = usable.filter { r in minimum.map { SimRuntimeRecord.compareVersions(r.version, $0) != .orderedAscending } ?? true }
        if let best = SimctlRuntimeListing.sorted(fitting).first {
            let more = fitting.count > 1 ? " and \(fitting.count - 1) more" : ""
            return RuntimeCheck(id, title, .ok, "\(best.title), \(best.sizeText)\(more).")
        }
        if let newest = SimctlRuntimeListing.sorted(usable).first, let minimum {
            return RuntimeCheck(id, title, .missing, "The newest is \(p.title) \(newest.version), older than the deployment target \(minimum). Add a newer runtime or lower the target.",
                                fix: .step(.add))
        }
        if let bad = mine.first {
            let why = bad.availabilityError ?? "its state is \(bad.state)"
            let fix: RuntimeFix = bad.isRemovable ? .action(.remove(bad)) : .instructions("Delete it in the IDE that installed it and add it again.")
            return RuntimeCheck(id, title, .missing, "\(bad.title) cannot be used: \(why).", fix: fix)
        }
        let whereText = host.map { "on \($0)" } ?? (machine.isMac ? "on this Mac" : "in Ycode's folder")
        return RuntimeCheck(id, title, .missing, "No \(p.title) runtime \(whereText).", fix: .step(.add))
    }

    /// Where Xcode would offer a download (§11.6): how to get a runtime with
    /// the user's own Apple tools; Ycode starts no download (#55).
    public static func acquisitionNote(_ p: SimPlatform) -> String {
        "Runtimes come from your own copy of Apple's tools: on a Mac, Xcode ▸ Settings ▸ Components, or xcodebuild -downloadPlatform \(p.downloadName) in Terminal. Ycode then uses the runtime you have."
    }
}

// MARK: - Confirmations

/// What a confirmation shows before an action runs: the exact command and where.
public struct RuntimeConfirmation: Sendable, Equatable {
    public var title: String
    public var message: String
    public var command: String
    public var confirmTitle: String
    public var isDestructive: Bool
    public var action: RuntimeAction

    public init(title: String, message: String, command: String, confirmTitle: String, isDestructive: Bool = false, action: RuntimeAction) {
        self.title = title
        self.message = message
        self.command = command
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.action = action
    }
}

public enum RuntimeCommands {
    /// One shell line for an argument vector.
    public static func line(_ argv: [String]) -> String { argv.map(\.shellQuoted).joined(separator: " ") }

    /// Copies a RuntimeRoot into `<folder>/<name>.incoming`, writes the
    /// marker, then renames it into place. Rerunning it resumes (rsync skips
    /// what is there; `--partial` keeps a half-copied file).
    public static func copyLocal(source: String, folder: String, record: SimRuntimeRecord, markerJSON: String, rsync: String = "rsync") -> String {
        let dest = folder + "/" + record.folderName
        let incoming = dest + RuntimeFolders.incomingSuffix
        return "mkdir -p \(incoming.shellQuoted)/RuntimeRoot && \(rsync) -a --partial \((source + "/").shellQuoted) \((incoming + "/RuntimeRoot/").shellQuoted)"
            + " && printf '%s\\n' \(markerJSON.shellQuoted) > \((incoming + "/" + RuntimeFolders.marker).shellQuoted)"
            + " && rm -rf \(dest.shellQuoted) && mv \(incoming.shellQuoted) \(dest.shellQuoted)"
    }

    /// Removes one of Ycode's runtime folders (refuses anything that is
    /// not a runtime folder directly inside `folder` with Ycode's marker).
    public static func remove(path: String, folder: String) -> String? {
        guard RuntimeFolders.isRuntimeFolder(path, inside: folder) else { return nil }
        let p = path.shellQuoted
        return "test -f \(p)/\(RuntimeFolders.marker) && rm -rf \(p)"
    }
}
