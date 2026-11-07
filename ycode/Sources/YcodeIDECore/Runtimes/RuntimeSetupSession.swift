// The runtime wizard's state, shared by the macOS window and the Linux
// shell's sheet: the step, the user's choices, the last round of checks,
// what is running (a copy, an import, the setup script) with its output,
// and the confirmation an action waits for. Views read it and call its
// methods; it never runs an action the user did not confirm.

import Foundation
import Observation
import YcodeSubprocess

@MainActor
@Observable
public final class RuntimeSetupSession {
    public let machine: SetupMachine
    public private(set) var choices: RuntimeSetupChoices
    public private(set) var step: RuntimeSetupStep = .target
    public private(set) var report: RuntimeSetupReport?
    /// The setup script's last report on the host (#70).
    public private(set) var hostSetup: HostSetupOutput?
    public private(set) var isChecking = false
    /// A running action's name ("Copying iOS 27.0…"); nil when idle.
    public private(set) var running: String?
    /// The status line under the steps.
    public private(set) var status: String?
    /// The running (or last) action's output, and the step it belongs to.
    public private(set) var log = ""
    public private(set) var logStep: RuntimeSetupStep?
    /// What waits for the user's yes.
    public private(set) var confirmation: RuntimeConfirmation?
    public private(set) var transfer: RuntimeTransfer?
    public private(set) var transferState: RuntimeTransferState = .idle
    /// A file or folder the user picked in Add a Runtime.
    public private(set) var picked: PickedRuntime?
    /// Get a Runtime: routes C and B (#55).
    public let downloads: RuntimeDownloadModel

    public struct PickedRuntime: Sendable, Equatable {
        public var path: String
        public var kind: RuntimeFileKind
        public var record: SimRuntimeRecord?
    }

    /// Called after every change (the AppKit window redraws; SwiftUI observes).
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored public var localRunner: any HeadsetCommandRunner
    /// Runs commands on the host (tests answer for it).
    /// Replaces the ssh runner for the host's checks (tests).
    @ObservationIgnored public var hostRunner: ((RuntimeHostSettings) -> any HeadsetCommandRunner)?
    @ObservationIgnored public var pairedHosts: @Sendable () -> [String]
    /// Runtime roots already configured for the host (Settings ▸ Components ▸ Simulator Host).
    @ObservationIgnored public var configuredRoots: () -> [String]
    @ObservationIgnored public var folder: String
    @ObservationIgnored public var ssh: String
    @ObservationIgnored public var rsync: String
    @ObservationIgnored var process: SetupProcess?
    @ObservationIgnored var checkTask: Task<Void, Never>?

    public init(machine: SetupMachine = .current, defaults: UserDefaults = .standard, folder: String = RuntimeFolders.local(),
                localRunner: any HeadsetCommandRunner = LocalHeadsetRunner(timeout: 60),
                ssh: String = HostTool.path("ssh"), rsync: String = HostTool.path("rsync")) {
        self.machine = machine
        self.defaults = defaults
        self.folder = folder
        self.localRunner = localRunner
        self.ssh = ssh
        self.rsync = rsync
        var c = RuntimeSetupChoices.load(defaults)
        // A computer that cannot run the simulator uses a host.
        if !machine.canRunSimulatorHere { c.useHost = true }
        choices = c
        downloads = RuntimeDownloadModel(machine: machine, folder: folder, runner: localRunner)
        downloads.setPlatform(c.platforms.sorted().first ?? .iOS, check: false)
        pairedHosts = { RuntimeSetupSession.linkHosts() }
        configuredRoots = { [] }
        downloads.onChange = { [weak self] in self?.changed() }
        downloads.onInstalled = { [weak self] in self?.recheck() }
    }

    func changed() { onChange?() }

    // MARK: Steps

    public var steps: [RuntimeSetupStep] { RuntimeSetupStep.steps(for: choices.target) }

    public func show(_ s: RuntimeSetupStep) {
        guard steps.contains(s) else { return }
        step = s
        if s == .download {
            // The first platform without a runtime; its checks.
            if let missing = SimPlatform.allCases.first(where: { choices.platforms.contains($0) && !(report?.readyPlatforms.contains($0) ?? false) }) {
                downloads.setPlatform(missing, check: false)
            }
            Task { await downloads.checkPrerequisites() }
        }
        changed()
    }

    public func next() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        show(steps[i + 1])
    }

    public func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        show(steps[i - 1])
    }

    public var isLastStep: Bool { step == steps.last }
    public var isFirstStep: Bool { step == steps.first }

    /// The checks of the step on screen.
    public var shownChecks: [RuntimeCheck] { step == .download ? downloads.checks : report?.checks(in: step) ?? [] }

    /// The mark of a step in the list.
    public func state(of s: RuntimeSetupStep) -> SetupCheckState? {
        if s == .finish { return report.map { $0.readyPlatforms.isEmpty ? .missing : .ok } }
        if s == .download {
            switch downloads.activity?.state {
            case .finished?: return .ok
            case .failed?: return .missing
            default: return nil
            }
        }
        return report?.state(of: s)
    }

    // MARK: Choices

    public func setPlatform(_ p: SimPlatform, on: Bool) {
        if on { choices.platforms.insert(p) } else { choices.platforms.remove(p) }
        saveAndRecheck()
    }

    public func setUseHost(_ on: Bool) {
        guard machine.canRunSimulatorHere || on else { return }
        choices.useHost = on
        if !steps.contains(step) { step = .target }
        saveAndRecheck()
    }

    public func setHost(_ h: RuntimeHostSettings) {
        guard h != choices.host else { return }
        choices.host = h
        hostSetup = nil
        saveAndRecheck()
    }

    public func setMinimumVersion(_ v: String?, for p: SimPlatform) {
        choices.minimumVersions[p] = v?.isEmpty == false ? v : nil
        saveAndRecheck()
    }

    func saveAndRecheck() {
        choices.save(defaults)
        recheck()
    }

    // MARK: Checks

    /// Runs every check again (never cached: removed runtimes can come back, §9).
    @discardableResult
    public func recheck() -> Task<Void, Never> {
        checkTask?.cancel()
        isChecking = true
        changed()
        let choices = choices, machine = machine, folder = folder, runner = localRunner
        let host = choices.host
        let hostRunner: (any HeadsetCommandRunner)? = choices.useHost && host.isComplete
            ? (self.hostRunner?(host) ?? SSHHeadsetRunner(destination: host.destination, ssh: ssh, timeout: 60)) : nil
        let paired = pairedHosts, roots = configuredRoots()
        let t = Task { [weak self] in
            var r = await RuntimeSetupChecker(machine: machine, choices: choices, runner: runner, folder: folder).run()
            if choices.useHost {
                let checker = RuntimeHostChecker(host: host, choices: choices, runner: hostRunner ?? LocalHeadsetRunner(), pairedHosts: paired(),
                                                 configuredRoots: roots)
                let h = await checker.run()
                r.checks += h.checks
                r.host = h.host
            }
            guard !Task.isCancelled, let self else { return }
            self.report = r
            if let setup = self.hostSetup {
                self.report?.checks += setup.checklist(destination: host.destination, invocation: self.setupInvocation)
            }
            self.isChecking = false
            self.changed()
        }
        checkTask = t
        return t
    }

    /// The step to open on: the first with something to fix.
    public func openOnFirstProblem() {
        guard let r = report else { return }
        show(r.firstProblemStep(for: choices.target))
    }

    // MARK: Picking a runtime file

    /// The user picked a file or folder in Add a Runtime: Ycode looks at it
    /// and offers the one way to add it (nothing runs yet).
    public func pick(path: String) {
        let kind = RuntimeBundleReader.kind(of: path)
        var p = PickedRuntime(path: path, kind: kind, record: nil)
        if kind == .bundle || kind == .runtimeRoot {
            p.record = RuntimeBundleReader.read(path, measure: true)
        }
        picked = p
        if kind == .diskImage, !FileManager.default.fileExists(atPath: path) { status = "File not found at \(path)." }
        else if kind == .unknown { status = "\((path as NSString).lastPathComponent) is not a runtime disk image, bundle or RuntimeRoot." }
        else if (kind == .bundle || kind == .runtimeRoot) && p.record == nil { status = "Could not read the runtime's SystemVersion.plist." }
        else { status = nil }
        changed()
    }

    /// The action that adds the picked file where the simulator runs.
    public var pickedAction: RuntimeAction? {
        guard let p = picked else { return nil }
        switch p.kind {
        case .diskImage:
            guard machine.isMac, !choices.useHost, FileManager.default.fileExists(atPath: p.path) else { return nil }
            return .importImage(path: p.path, tool: .simctl)
        case .bundle, .runtimeRoot:
            guard let r = p.record, let root = r.runtimeRoot else { return nil }
            if choices.useHost { return .copyToHost(source: root, record: r, host: choices.host.destination) }
            return machine.isMac ? nil : .copyToThisMachine(source: root, record: r)
        case .unknown: return nil
        }
    }

    /// The runtimes here that can go to the host (or into Ycode's folder on Linux).
    /// Only the chosen platforms' usable runtimes, less the builds the host has.
    public var copyableRuntimes: [SimRuntimeRecord] {
        let there = Set((report?.host ?? []).map { "\($0.platform)|\($0.version)|\($0.build)" })
        return (report?.local ?? []).filter {
            $0.runtimeRoot != nil && $0.isUsable && choices.platforms.contains($0.platform) && !there.contains("\($0.platform)|\($0.version)|\($0.build)")
        }
    }

    // MARK: Actions

    /// Asks before an action: the confirmation shows the exact command.
    public func request(_ action: RuntimeAction) {
        confirmation = downloads.confirmation(for: action) ?? confirmationFor(action)
        changed()
    }

    public func cancelConfirmation() {
        confirmation = nil
        changed()
    }

    func confirmationFor(_ action: RuntimeAction) -> RuntimeConfirmation {
        switch action {
        case .importImage(let path, let tool):
            return RuntimeConfirmation(title: "Add Runtime to This Mac", message: "Ycode will run this command to add \((path as NSString).lastPathComponent) to CoreSimulator. It may take several minutes.",
                                       command: RuntimeCommands.line(tool.command(file: path)), confirmTitle: "Add Runtime", action: action)
        case .copyToThisMachine(let source, let r):
            return RuntimeConfirmation(title: "Copy \(r.title)", message: "Ycode will copy the RuntimeRoot (\(r.sizeText)) into its folder on this computer.",
                                       command: RuntimeCommands.copyLocal(source: source, folder: folder, record: r, markerJSON: "<ycode-runtime.json>", rsync: "rsync"),
                                       confirmTitle: "Copy", action: action)
        case .copyToHost(let source, let r, let host):
            let t = transferFor(source: source, record: r)
            let resumes = report?.check("transfer") != nil
            return RuntimeConfirmation(title: resumes ? "Resume Copy to \(host)" : "Copy \(r.title) to \(host)",
                                       message: "Ycode will copy the RuntimeRoot (\(RuntimeSize.format(t.totalBytes))) to \(choices.host.runtimesFolder) on the host with your ssh key. If the copy stops, copying again resumes it.",
                                       command: t.shownCommand(), confirmTitle: resumes ? "Resume" : "Copy", action: action)
        case .remove(let r):
            let path = removalPath(r) ?? "?"
            let cmd = RuntimeCommands.remove(path: path, folder: r.location == .thisMachine ? folder : choices.host.runtimesFolder) ?? "(refused)"
            let shown = r.location == .thisMachine ? cmd : "ssh \(choices.host.destination.shellQuoted) \(cmd.shellQuoted)"
            return RuntimeConfirmation(title: "Remove \(r.title)?", message: "Ycode copied this runtime; removing it frees \(r.sizeText) on \(r.location.title). Devices that use it stop working until it is copied again.",
                                       command: shown, confirmTitle: "Remove", isDestructive: true, action: action)
        case .downloadWithXcode, .downloadDirect, .installDecryptor:
            return downloads.confirmation(for: action)!
        case .provisionApply:
            let steps = hostSetup?.userSteps.map { "# \($0.id)\n\($0.command)" }.joined(separator: "\n") ?? ""
            return RuntimeConfirmation(title: "Apply Setup on \(choices.host.hostName)", message: "Ycode will run the setup script with --apply on the host, as your user. It runs these steps and none that need root:",
                                       command: steps.isEmpty ? "ssh \(choices.host.destination) " + setupInvocation.streamedCommand(mode: "apply") : steps,
                                       confirmTitle: "Apply", action: action)
        }
    }

    func removalPath(_ r: SimRuntimeRecord) -> String? {
        if case .ycode(let f) = r.owner { return f }
        return nil
    }

    /// The user said yes.
    public func confirm() {
        guard let c = confirmation else { return }
        confirmation = nil
        perform(c.action)
    }

    func perform(_ action: RuntimeAction) {
        switch action {
        case .importImage(let path, let tool):
            runLocal(tool.command(file: path), title: "Adding \((path as NSString).lastPathComponent)…")
        case .copyToThisMachine(let source, let r):
            let marker = RuntimeMarker(r, source: (source as NSString).lastPathComponent).json
            runLocal(["/bin/sh", "-c", RuntimeCommands.copyLocal(source: source, folder: folder, record: r, markerJSON: marker, rsync: rsync)],
                     title: "Copying \(r.title)…")
        case .copyToHost(let source, let r, _):
            startTransfer(transferFor(source: source, record: r))
        case .remove(let r):
            guard let path = removalPath(r) else { return }
            if r.location == .thisMachine {
                guard let cmd = RuntimeCommands.remove(path: path, folder: folder) else { return }
                runLocal(["/bin/sh", "-c", cmd], title: "Removing \(r.title)…")
            } else {
                guard let cmd = RuntimeCommands.remove(path: path, folder: choices.host.runtimesFolder) else { return }
                let host = choices.host.destination
                runLocal([ssh] + RuntimeTransfer.sshOptions + [host, cmd], title: "Removing \(r.title) from \(choices.host.hostName)…") { [weak self] status, _ in
                    if status == 0 { self?.unregisterRemoteRoot(path + "/RuntimeRoot", host: host) }
                }
            }
        case .provisionApply:
            runSetup(mode: "apply")
        case .downloadWithXcode, .downloadDirect:
            downloads.start(action)
        case .installDecryptor:
            runLocal(["/bin/sh", "-c", PythonAEAExpander.installCommand(folder: folder)], title: "Setting up the decryptor…") { [weak self] _, _ in
                Task { await self?.downloads.checkPrerequisites() }
            }
        }
    }

    /// Stops what is running (a copy stops resumably).
    public func stop() {
        stoppedByUser = true
        process?.terminate()
        downloads.cancel()
    }

    @ObservationIgnored var stoppedByUser = false

    func runLocal(_ argv: [String], title: String, stdin: String? = nil, then: ((Int32, String) -> Void)? = nil) {
        running = title
        status = title
        logStep = step
        log = "$ " + RuntimeCommands.line(argv.first == "/bin/sh" ? Array(argv.dropFirst(2)) : argv) + "\n"
        changed()
        let p = SetupProcess(argv, stdin: stdin) { [weak self] chunk in
            Task { @MainActor in
                guard let self else { return }
                self.log += chunk
                if self.log.count > 200_000 { self.log = String(self.log.suffix(150_000)) }
                self.changed()
            }
        }
        process = p
        Task { [weak self] in
            let s = await p.run()
            guard let self else { return }
            self.process = nil
            self.running = nil
            self.log = "$ " + RuntimeCommands.line(argv.first == "/bin/sh" ? Array(argv.dropFirst(2)) : argv) + "\n" + p.text
            self.status = s == 0 ? "\(title.replacingOccurrences(of: "…", with: "")): done." : "\(title.replacingOccurrences(of: "…", with: "")): failed (status \(s))."
            then?(s, p.text)
            self.changed()
            self.recheck()
        }
    }

    // MARK: Copy to the host

    func transferFor(source: String, record: SimRuntimeRecord) -> RuntimeTransfer {
        let total = record.unpackedBytes ?? record.sizeBytes ?? record.platform.typicalUnpackedBytes
        return RuntimeTransfer(source: source, record: record, host: choices.host, totalBytes: total)
    }

    func startTransfer(_ t: RuntimeTransfer) {
        stoppedByUser = false
        transfer = t
        transferState = .copying(copiedKB: 0)
        running = "Copying \(t.record.title) to \(t.host.hostName)…"
        logStep = step
        log = ""
        changed()
        let ssh = ssh, rsync = rsync
        let host = t.host.destination
        let base = [ssh] + RuntimeTransfer.sshOptions + [host]
        Task { [weak self] in
            let prep = await SetupProcess(base + [t.prepareCommand]).run()
            guard let self else { return }
            guard prep == 0 else { return self.endTransfer(.after(rsyncStatus: 255, copiedKB: 0)) }
            let p = SetupProcess([rsync] + t.rsyncArguments(ssh: ssh)) { [weak self] chunk in
                Task { @MainActor in self?.log += chunk; self?.changed() }
            }
            self.process = p
            // Progress: the .incoming folder's size, every second.
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let r = await SSHProbe.output(base + [t.progressCommand])
                    guard let kb = Int64(r.trimmed), let self else { continue }
                    if case .copying = self.transferState { self.transferState = .copying(copiedKB: kb); self.changed() }
                }
            }
            let status = await p.run()
            poll.cancel()
            self.process = nil
            let kb = Int64(await SSHProbe.output(base + [t.progressCommand]).trimmed) ?? 0
            var state = RuntimeTransferState.after(rsyncStatus: status, copiedKB: kb)
            if self.stoppedByUser, case .interrupted(let at, _) = state { state = .interrupted(copiedKB: at, reason: "You stopped the copy.") }
            self.stoppedByUser = false
            if state == .finished {
                let marker = RuntimeMarker(t.record, source: "\(ProcessInfo.processInfo.hostName): \((t.source as NSString).lastPathComponent)").json
                if await SetupProcess(base + [t.finishCommand(markerJSON: marker)]).run() != 0 { state = .failed("The runtime was copied but could not be put in place.") }
            }
            self.endTransfer(state)
        }
    }

    func endTransfer(_ s: RuntimeTransferState) {
        transferState = s
        running = nil
        switch s {
        case .finished:
            status = "Copied \(transfer?.record.title ?? "the runtime") to \(transfer?.host.hostName ?? "the host")."
            if let t = transfer, registerRemoteRoot(t.destination + "/RuntimeRoot", record: t.record, host: t.host.destination) {
                status! += " Its devices are run destinations now."
            }
        case .interrupted(_, let why): status = why + " Copy again to resume."
        case .failed(let why): status = why
        default: break
        }
        changed()
        recheck()
        // The service's configuration names the runtime: check the host again.
        if s == .finished, hostSetup != nil { runSetupReport() }
    }

    // MARK: Run destinations (#69)

    /// What the Ready step says about running on the host's devices.
    public var finishNotes: [String] {
        guard choices.useHost, !choices.host.destination.isEmpty else { return [] }
        let host = choices.host
        var out: [String] = []
        if machine.isMac {
            let named = RemoteSimulatorSettings.load(defaults).destination == host.destination
            out.append(named ? "Settings ▸ Components ▸ Simulator Host names \(host.destination): the runtimes Ycode copies there become run destinations."
                             : "Name \(host.destination) in Settings ▸ Components ▸ Simulator Host to run on its devices.")
        } else {
            out.append("Pair this computer with the host over Ycode's link (ycode sim remote pair) to see its devices as run destinations.")
        }
        if let root = report?.host.first(where: { $0.isUsable && $0.isRemovable })?.runtimeRoot {
            out.append("Over the link, the host boots the runtimes its simhost.env names, for example YCODE_SIM_RUNTIME=\(root)")
        }
        return out
    }

    /// A runtime copied to the host that Settings ▸ Components ▸ Simulator Host already names
    /// becomes one of its runtime roots (its destinations follow); true when
    /// it was added. Another host is left to the user (Settings ▸ Components ▸ Simulator Host).
    @discardableResult
    func registerRemoteRoot(_ root: String, record: SimRuntimeRecord, host: String) -> Bool {
        var s = RemoteSimulatorSettings.load(defaults)
        guard !s.destination.isEmpty, s.destination == host else { return false }
        if s.runtimeRoot.isEmpty { s.runtimeRoot = root } else if s.runtimeRoot != root, !s.otherRuntimeRoots.contains(root) { s.otherRuntimeRoots.append(root) }
        s.save(defaults)
        RemoteSimulatorSettings.saveRuntimeVersion(record.version, root: root, defaults, primary: s.runtimeRoot == root)
        RemoteSimulatorSettings.saveRuntimePlatform(record.platform.rawValue, root: root, defaults)
        return true
    }

    /// The other way: a removed runtime is no longer a runtime root of that host.
    func unregisterRemoteRoot(_ root: String, host: String) {
        var s = RemoteSimulatorSettings.load(defaults)
        guard s.destination == host, s.otherRuntimeRoots.contains(root) else { return }
        s.otherRuntimeRoots.removeAll { $0 == root }
        s.save(defaults)
    }

    // MARK: Host setup (#70)

    public var setupInvocation: HostSetupInvocation {
        HostSetupInvocation(dataDirectory: choices.host.dataDirectory, configDirectory: choices.host.configDirectory, ycodeVersion: ProductIdentity.version,
                            tcpPort: choices.host.tcpPort, udpPort: choices.host.udpPort)
    }

    /// Runs the script on the host in report mode (changes nothing).
    public func runSetupReport() { runSetup(mode: "report") }

    func runSetup(mode: String) {
        let host = choices.host
        guard host.isComplete else { status = "Name the host and its data folder first."; changed(); return }
        let inv = setupInvocation
        runLocal([ssh] + RuntimeTransfer.sshOptions + [host.destination, inv.streamedCommand(mode: mode)],
                 title: mode == "report" ? "Checking \(host.hostName) with the setup script…" : "Applying setup on \(host.hostName)…",
                 stdin: HostSetupScript.text) { [weak self] _, log in
            self?.hostSetup = HostSetupOutput.parse(log)
        }
    }

    /// The root steps' command needs the script on the host: saves it there
    /// (in `~/.cache/ycode`, the user's own folder), then shows the command.
    public func prepareRootSteps() {
        let host = choices.host
        runLocal([ssh] + RuntimeTransfer.sshOptions + [host.destination, setupInvocation.saveCommand], title: "Saving the setup script on \(host.hostName)…",
                 stdin: HostSetupScript.text) { [weak self] status, _ in
            guard let self else { return }
            self.status = status == 0 ? "Run the command below in your terminal; sudo asks for your password there." : "Could not save the script on the host."
        }
    }

    public var rootCommand: String { setupInvocation.rootCommand(destination: choices.host.destination) }

    /// Writes the script to a file (Save Script…).
    public func saveScript(to url: URL) throws {
        try HostSetupScript.text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        status = "Saved \(url.lastPathComponent). Run it with bash; --report changes nothing."
        changed()
    }

    // MARK: Link

    /// The hosts paired over Ycode's link on this machine: the names of the
    /// `host` peers in `trusted-peers.json` (`sim-link.md` §2).
    public nonisolated static func linkHosts(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let dir = environment["YCODE_SIM_LINK_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.config/ycode/sim-link"
        guard let d = FileManager.default.contents(atPath: dir + "/trusted-peers.json"),
              let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return list.compactMap { $0["role"] as? String == "host" ? $0["name"] as? String : nil }
    }
}

// MARK: - Processes

/// One process with its output streamed (stdout and stderr together), an
/// optional standard input, and Stop. Foundation's `Process`: the programs
/// here (ssh, rsync, xcrun) leave nothing running behind them.
final class SetupProcess: @unchecked Sendable {
    let argv: [String]
    let stdin: String?
    let output: (@Sendable (String) -> Void)?
    private let p = Process()
    private let lock = NSLock()
    private var stopped = false
    private var collected = ""

    /// Everything the process printed so far.
    var text: String { lock.withLock { collected } }

    private func take(_ d: Data) {
        guard !d.isEmpty else { return }
        let s = String(decoding: d, as: UTF8.self)
        lock.withLock { collected += s }
        output?(s)
    }

    init(_ argv: [String], stdin: String? = nil, output: (@Sendable (String) -> Void)? = nil) {
        self.argv = argv
        self.stdin = stdin
        self.output = output
    }

    func terminate() {
        lock.withLock { stopped = true }
        if p.isRunning { p.terminate() }
    }

    /// The exit status; 128 + the signal when a signal ended it.
    func run() async -> Int32 {
        await withCheckedContinuation { (k: CheckedContinuation<Int32, Never>) in
            let path = argv[0].hasPrefix("/") ? argv[0] : "/usr/bin/env"
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = argv[0].hasPrefix("/") ? Array(argv.dropFirst()) : argv
            let out: SpawnPipe, input: SpawnPipe?
            do {
                out = try SpawnPipe(childReads: false)
                input = stdin == nil ? nil : try SpawnPipe(childReads: true)
            } catch {
                take(Data("\(argv[0]): \(error)\n".utf8))
                return k.resume(returning: 127)
            }
            p.standardOutput = out.childEnd
            p.standardError = out.childEnd
            p.standardInput = input?.childEnd ?? FileHandle.nullDevice
            let reader = DispatchQueue(label: "ycode.setup-process")
            out.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                reader.sync { self?.take(d) }
            }
            p.terminationHandler = { [weak self] proc in
                out.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                reader.sync { self?.take(rest) }
                k.resume(returning: proc.terminationReason == .uncaughtSignal ? 128 + proc.terminationStatus : proc.terminationStatus)
            }
            do {
                try p.runWithSignalsUnblocked(closingChildEndsOf: out, input)
                if let stdin, let input {
                    let h = input.fileHandleForWriting
                    DispatchQueue.global().async {
                        h.write(Data(stdin.utf8))
                        try? h.close()
                    }
                }
            } catch {
                // The output's write end is closed now: stop watching it.
                out.fileHandleForReading.readabilityHandler = nil
                take(Data("\(argv[0]): \(error)\n".utf8))
                k.resume(returning: 127)
            }
        }
    }
}

/// A short command's output (the copy's progress).
enum SSHProbe {
    static func output(_ argv: [String]) async -> String {
        let p = SetupProcess(argv)
        _ = await p.run()
        return p.text
    }
}
