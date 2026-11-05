// The wizard's Get a Runtime step (`runtime-downloads.md` §6.1;
// `runtime-onboarding.md` §9–§11): the three routes in their order — on a
// Mac, Xcode's own tool (C), then Ycode's direct download (B), then a runtime
// the user has (A, the Add a Runtime step); on Linux, B then A, with C as
// the way to fetch one on a Mac. Each route starts only from a confirmation
// that shows the exact command; progress, Cancel, errors and Retry are here.
// Shared by the macOS window and the Linux sheet.

import Foundation
import Observation

@MainActor
@Observable
public final class RuntimeDownloadModel {
    public enum Route: String, Sendable { case xcode, direct }

    /// What is running, or what last ran.
    public struct Activity: Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case running
            case finished(String)
            case cancelled
            /// The words, whether Retry can help, and whether Apple refused this computer (§4.1 O1).
            case failed(String, retry: Bool, refused: Bool)
        }
        public var route: Route
        public var title: String
        public var phase: String
        public var fraction: Double?
        public var state: State

        public var isRunning: Bool { state == .running }
    }

    public enum IndexState: Sendable, Equatable { case idle, loading, loaded, failed(String) }

    public let machine: SetupMachine
    public var folder: String
    public private(set) var platform: SimPlatform = .iOS
    public private(set) var index: RuntimeIndex?
    public private(set) var indexState: IndexState = .idle
    /// The build chosen in the list; nil is the recommended one.
    public private(set) var selectedBuild: String?
    public private(set) var exportCopy = false
    public private(set) var exportPath: String
    /// The routes' prerequisites (`download.*`): Xcode, the decryptor, the disk image reader, disk space.
    public private(set) var checks: [RuntimeCheck] = []
    public private(set) var activity: Activity?
    public private(set) var log = ""
    public private(set) var lastAction: RuntimeAction?

    @ObservationIgnored public var onChange: (() -> Void)?
    /// After a route finished: the session reads the runtimes again.
    @ObservationIgnored public var onInstalled: (() -> Void)?
    @ObservationIgnored public var runner: any HeadsetCommandRunner
    @ObservationIgnored public var environment: [String: String]
    /// Makes route B's pipeline (tests answer for Apple).
    @ObservationIgnored public var makeDirect: (String) -> RuntimeDirectDownload
    @ObservationIgnored public var host: RuntimeHostDescription
    @ObservationIgnored var direct: RuntimeDirectDownload?
    @ObservationIgnored var xcodeRun: XcodebuildDownloadRun?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var pendingReturn = false

    public init(machine: SetupMachine, folder: String, runner: any HeadsetCommandRunner = LocalHeadsetRunner(timeout: 30),
                environment: [String: String] = ProcessInfo.processInfo.environment, host: RuntimeHostDescription = .current()) {
        self.machine = machine
        self.folder = folder
        self.runner = runner
        self.environment = environment
        self.host = host
        exportPath = NSHomeDirectory() + "/Downloads/Ycode Runtimes"
        let env = environment
        makeDirect = { f in RuntimeDirectDownload(folder: f, expander: RuntimeExpanders.standard(folder: f, environment: env),
                                                  reader: RuntimeImageReaders.standard(environment: env)) }
    }

    func changed() { onChange?() }

    // MARK: Choices

    public func setPlatform(_ p: SimPlatform, check: Bool = true) {
        guard p != platform else { return }
        platform = p
        selectedBuild = nil
        changed()
        if check { Task { await checkPrerequisites() } }
    }

    public func select(build: String?) {
        selectedBuild = build
        changed()
        Task { await checkPrerequisites() }
    }

    public func setExportCopy(_ on: Bool) {
        exportCopy = on
        changed()
    }

    public func setExportPath(_ p: String) {
        exportPath = p
        changed()
    }

    // MARK: The index

    public var candidates: [RuntimeIndexEntry] {
        guard let index else { return [] }
        return RuntimeSelection.candidates(index, platform: platform, host: .current)
    }

    public var recommended: RuntimeIndexEntry? {
        guard let index else { return nil }
        return try? RuntimeSelection.select(index, RuntimeRequest(platform: platform), host: .current)
    }

    /// What route B would fetch.
    public var chosen: RuntimeIndexEntry? {
        if let b = selectedBuild, let e = candidates.first(where: { $0.build == b }) { return e }
        return recommended
    }

    /// Reads Apple's index (only when asked: the step's Show Versions, or route B).
    public func loadIndex(force: Bool = false) {
        guard indexState != .loading else { return }
        indexState = .loading
        changed()
        let d = makeDirect(folder)
        Task { [weak self] in
            do {
                let i = try await d.index(force: force)
                self?.index = i
                self?.indexState = .loaded
            } catch {
                self?.indexState = .failed(RuntimeSecrets.scrub(String(describing: error)))
            }
            self?.changed()
            await self?.checkPrerequisites()
        }
    }

    // MARK: Prerequisites

    /// Xcode on a Mac (route C): a full Xcode is selected, or a stand-in is named.
    public var xcodeAvailable: Bool { checks.first { $0.id == "download.xcode" }?.state == .ok }

    /// Whether route B can start (its decryptor and reader are here).
    public var directReady: Bool {
        checks.filter { ["download.decryptor", "download.reader"].contains($0.id) }.allSatisfy { $0.state == .ok }
    }

    public func checkPrerequisites() async {
        var out: [RuntimeCheck] = []
        if machine.isMac {
            if let t = environment["YCODE_XCODEBUILD"], !t.isEmpty {
                out.append(RuntimeCheck("download.xcode", "Xcode", FileManager.default.isExecutableFile(atPath: t) ? .ok : .missing, "Using \(t)."))
            } else {
                let r = await runner.run("xcode-select -p")
                let path = r.output.trimmed
                if r.ok, path.hasSuffix(".app/Contents/Developer") {
                    out.append(RuntimeCheck("download.xcode", "Xcode", .ok, "xcodebuild from \(path.replacingOccurrences(of: "/Contents/Developer", with: "")) downloads runtimes from Apple and installs them on this Mac."))
                } else {
                    out.append(RuntimeCheck("download.xcode", "Xcode", .missing, "Xcode is not selected (\(r.ok ? path : "no developer directory")). Install Xcode and select it, or use Ycode's download below.",
                                            fix: .command("sudo xcode-select -s /Applications/Xcode.app")))
                }
            }
        }
        let expander = RuntimeExpanders.standard(folder: folder, environment: environment)
        if let py = expander as? PythonAEAExpander {
            let r = await runner.run(PythonAEAExpander.checkCommand(python: py.python))
            if r.ok, r.output.contains("python-aea") {
                out.append(RuntimeCheck("download.decryptor", "Decryptor", .ok, "\(r.output.trimmed) (MIT), run as a separate program."))
            } else {
                out.append(RuntimeCheck("download.decryptor", "Decryptor", .missing,
                                        "Ycode decrypts with python-aea (MIT) in a Python environment of its own. It is not set up yet.",
                                        fix: .action(.installDecryptor)))
            }
        } else {
            out.append(RuntimeCheck("download.decryptor", "Decryptor", .ok, "macOS's Apple Archive framework."))
        }
        if let reader = RuntimeImageReaders.standard(environment: environment) {
            out.append(RuntimeCheck("download.reader", "Disk image reader", .ok, reader.title + "."))
        } else {
            out.append(RuntimeCheck("download.reader", "Disk image reader", .missing, "Ycode reads the runtime's disk image with 7-Zip 23 or later, which is not installed.",
                                    fix: .command("sudo apt install 7zip")))
        }
        let need = (chosen?.fileSize ?? platform.typicalImageBytes) * 4
        if let free = RuntimeDirectDownload.freeBytes(folder) {
            out.append(free >= need
                ? RuntimeCheck("download.disk", "Disk space", .ok, "\(RuntimeSize.format(free)) free in Ycode's runtime folder; a download needs about \(RuntimeSize.format(need)) while it unpacks.")
                : RuntimeCheck("download.disk", "Disk space", .missing, "\(RuntimeSize.format(free)) free in Ycode's runtime folder; a download needs about \(RuntimeSize.format(need)) while it unpacks.",
                               fix: .instructions("Free some space, or choose another folder with YCODE_DATA.")))
        }
        checks = out
        changed()
    }

    // MARK: Actions

    public var xcodeDownload: XcodebuildDownload {
        XcodebuildDownload(platform: platform, exportPath: exportCopy && !exportPath.isEmpty ? exportPath : nil)
    }

    /// Route C's action (a Mac with Xcode).
    public var xcodeAction: RuntimeAction? { machine.isMac && xcodeAvailable ? .downloadWithXcode(xcodeDownload) : nil }

    /// Route B's action, once the index named what it fetches.
    public var directAction: RuntimeAction? {
        guard let e = chosen else { return nil }
        return .downloadDirect(RuntimeRequest(platform: platform, build: e.build))
    }

    /// The command line that does what route B's button does.
    public func directCommand(_ r: RuntimeRequest) -> String {
        RuntimeCommands.line(["ycode", "runtime", "download", r.platform.rawValue] + (r.build.map { ["--build", $0] } ?? []))
    }

    public func confirmation(for action: RuntimeAction) -> RuntimeConfirmation? {
        switch action {
        case .downloadWithXcode(let d):
            var m = "Ycode will run Apple's own tool. Xcode downloads the \(d.platform.title) runtime from Apple and installs it on this Mac"
            m += d.exportPath.map { ", and saves a copy in \($0) for a Linux computer or a simulator host." } ?? "."
            m += " Progress shows here, and Cancel stops it."
            return RuntimeConfirmation(title: "Download \(d.platform.title) with Xcode?", message: m, command: d.shownCommand, confirmTitle: "Download", action: action)
        case .downloadDirect(let r):
            let e = chosen.flatMap { $0.build == r.build ? $0 : nil } ?? candidates.first { $0.build == r.build }
            let name = e?.title ?? "\(r.platform.title) \(r.build ?? "")"
            let size = e.map { RuntimeSize.format($0.fileSize) } ?? "several GB"
            let reader = RuntimeImageReaders.standard(environment: environment)?.title ?? "7-Zip"
            let expander = RuntimeExpanders.standard(folder: folder, environment: environment).title
            let m = """
                Ycode will ask Apple's asset service for \(name), describing this computer as \(host.summary). \
                It then downloads \(size) from Apple into Ycode's folder (a stopped download resumes), checks its size and SHA-256, \
                decrypts it with the key Apple returns to you (\(expander)), reads its disk image (\(reader)) and puts its RuntimeRoot in \(folder). \
                The archive is removed afterwards. Nothing is shared or kept for anyone else.
                """
            return RuntimeConfirmation(title: "Download \(name) from Apple?", message: m, command: directCommand(r), confirmTitle: "Download", action: action)
        case .installDecryptor:
            return RuntimeConfirmation(title: "Set Up the Decryptor?",
                                       message: "Ycode will make a Python environment in its runtime folder and install python-aea \(PythonAEAExpander.version) (MIT) from PyPI into it. It needs Python 3.11 or later and no root.",
                                       command: PythonAEAExpander.installCommand(folder: folder), confirmTitle: "Set Up", action: action)
        default:
            return nil
        }
    }

    /// Starts a confirmed route.
    public func start(_ action: RuntimeAction) {
        guard activity?.isRunning != true else { return }
        lastAction = action
        switch action {
        case .downloadWithXcode(let d): runXcode(d)
        case .downloadDirect(let r): runDirect(r)
        default: break
        }
    }

    public func cancel() {
        direct?.cancel()
        xcodeRun?.cancel()
    }

    /// Retry (and Resume after Cancel): the last route again.
    public func retry() { if let a = lastAction { start(a) } }

    /// Adds output; a carriage return rewrites the current line, as a terminal would.
    func append(_ s: String) {
        let parts = RuntimeSecrets.scrub(s).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\r", omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            if i > 0 { pendingReturn = true }
            if part.isEmpty { continue }
            if pendingReturn {
                if !part.hasPrefix("\n") {
                    if let nl = log.lastIndex(of: "\n") { log = String(log[...nl]) } else { log = "" }
                }
                pendingReturn = false
            }
            log += part
        }
        if log.count > 120_000 { log = String(log.suffix(90_000)) }
    }

    func runXcode(_ d: XcodebuildDownload) {
        let tool = environment["YCODE_XCODEBUILD"].flatMap { $0.isEmpty ? nil : $0 } ?? XcodebuildDownload.tool(environment: environment)
        let run = XcodebuildDownloadRun(d, tool: tool)
        xcodeRun = run
        log = "$ \(d.shownCommand)\n"
        activity = Activity(route: .xcode, title: "Downloading \(d.platform.title) with Xcode", phase: "Starting xcodebuild…", fraction: nil, state: .running)
        changed()
        task = Task { [weak self] in
            let outcome = await run.run(output: { s in
                Task { @MainActor in self?.append(s); self?.changed() }
            }, progress: { p in
                Task { @MainActor in
                    guard let self, var a = self.activity, a.isRunning else { return }
                    a.fraction = p.fraction ?? a.fraction
                    if let done = p.done, let total = p.total {
                        a.phase = "\(p.stage ?? "Downloading"): \(RuntimeSize.format(done)) of \(RuntimeSize.format(total))"
                    } else if let f = p.fraction {
                        a.phase = "\(p.stage ?? "Downloading"): \(Int(f * 100))%"
                    } else if let s = p.stage { a.phase = s + "…" }
                    self.activity = a
                    self.changed()
                }
            })
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            var a = self.activity ?? Activity(route: .xcode, title: "", phase: "", fraction: nil, state: .running)
            switch outcome {
            case .finished:
                a.state = .finished("Xcode installed the \(d.platform.title) runtime" + (d.exportPath.map { " and saved a copy in \($0)" } ?? "") + ".")
                a.fraction = 1
            case .cancelled:
                a.state = .cancelled
                a.title = "Stopped: \(d.platform.title) with Xcode"
            case .failed(let status, let tail):
                a.title = "Could not download \(d.platform.title) with Xcode"
                a.state = .failed("xcodebuild stopped with status \(status)" + (tail.isEmpty ? "." : ":\n\(tail)"), retry: true, refused: false)
            }
            self.activity = a
            self.xcodeRun = nil
            self.changed()
            if case .finished = a.state { self.onInstalled?() }
        }
    }

    func runDirect(_ r: RuntimeRequest) {
        let d = makeDirect(folder)
        direct = d
        log = "$ \(directCommand(r))\n"
        activity = Activity(route: .direct, title: "Downloading \(chosen?.title ?? r.platform.title) from Apple", phase: "Starting…", fraction: nil, state: .running)
        changed()
        task = Task { [weak self] in
            do {
                let rec = try await d.run(.runtime(r), event: { p in
                    Task { @MainActor in
                        guard let self, var a = self.activity, a.isRunning else { return }
                        a.phase = p.title
                        a.fraction = p.fraction
                        self.activity = a
                        self.changed()
                    }
                }, log: { line in Task { @MainActor in self?.append(line + "\n"); self?.changed() } })
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
                var a = self.activity!
                a.state = .finished("\(rec?.title ?? "The runtime") is in Ycode's folder: \(rec?.runtimeRoot ?? self.folder).")
                a.title = "\(rec?.title ?? "The runtime") is ready"
                a.phase = a.state == .running ? a.phase : "Done."
                a.fraction = 1
                self.activity = a
                self.direct = nil
                self.changed()
                self.onInstalled?()
            } catch {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
                var a = self.activity!
                let name = a.title.replacingOccurrences(of: "Downloading ", with: "").replacingOccurrences(of: " from Apple", with: "")
                a.title = "Could not download \(name)"
                if let e = error as? RuntimeDownloadError {
                    if e == .cancelled { a.state = .cancelled; a.title = "Stopped: \(name)" } else {
                        var refused = false
                        if case .refused = e { refused = true }
                        a.state = .failed(RuntimeSecrets.scrub(e.description), retry: e.isRetryable, refused: refused)
                    }
                } else {
                    a.state = .failed(RuntimeSecrets.scrub(String(describing: error)), retry: true, refused: false)
                }
                self.activity = a
                self.direct = nil
                self.changed()
            }
        }
    }

    /// What the Linux wizard tells the user about route C.
    public func macRouteNote(_ p: SimPlatform) -> String {
        "On a Mac with Xcode: xcodebuild -downloadPlatform \(p.downloadName) -exportPath <folder>, then copy the folder here and add it with Add a Runtime (or ycode runtime import <folder>)."
    }
}
