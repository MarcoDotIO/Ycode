import Foundation
import YcodeBuild
import YcodeIDECore

/// Builds, cleans and tests a Swift package with the toolchain's own
/// SwiftPM (`swift build`, `swift package clean`, `swift test`), for hosts
/// where `ycodebuild` cannot build packages: on Linux it has no host
/// destination and needs the `ycode-swb` helper (docs/PARITY.md §5.8).
/// Compiler diagnostics become issues and the build log fills as with the
/// core's engines (`SwiftPMRun`).
public struct PackageBuildEngine: BuildEngine {
    public var name: String { "swiftpm" }
    /// The `swift` driver and any leading arguments. Tests replace it.
    public var swift: [String]

    public init(swift: [String] = ["/usr/bin/env", "swift"]) {
        self.swift = swift
    }

    /// The SwiftPM arguments for a request (without the driver); nil for a
    /// project or workspace.
    public static func arguments(for r: BuildRequest) -> [String]? {
        guard case .package(let dir) = r.container else { return nil }
        let release = r.configuration?.lowercased() == "release" ? ["-c", "release"] : []
        switch r.action {
        case .clean: return ["package", "--package-path", dir, "clean"]
        case .test, .testWithoutBuilding: return ["test", "--package-path", dir] + release
        case .buildForTesting: return ["build", "--package-path", dir, "--build-tests"] + release
        default: return ["build", "--package-path", dir] + release
        }
    }

    /// The activity text for a SwiftPM progress line: "[3/9] Compiling
    /// Greeter main.swift" → "Compiling main.swift"; linking and planning
    /// lines likewise.
    public static func activity(for line: String) -> String? {
        var rest = Substring(line)
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        let words = rest.split(separator: " ")
        guard let verb = words.first else { return nil }
        switch verb {
        case "Compiling", "Emitting", "Linking", "Write", "Planning", "Building":
            if verb == "Building", words.dropFirst().first == "for" { return "Planning" }
            let object = words.last.map(String.init) ?? ""
            let label = verb == "Write" ? "Writing" : String(verb)
            return words.count > 1 ? "\(label) \(object)" : label
        default:
            return nil
        }
    }

    public func start(_ request: BuildRequest) -> BuildOperation {
        guard let args = Self.arguments(for: request) else {
            return Self.failed("ycode: this engine builds Swift packages only; open the package folder.")
        }
        if swift == ["/usr/bin/env", "swift"], ShellToolchain.locate("swift") == nil { return Self.failed(issue: ShellToolchain.noSwift) }
        return SwiftPMRun.start(swift + args, currentDirectory: request.container.path)
    }

    /// The executable product Run launches: the product named like the
    /// scheme, else the first executable product, in SwiftPM's binary
    /// folder (`swift build --show-bin-path`).
    public func executablePath(for request: BuildRequest) -> String? {
        guard case .package(let dir) = request.container else { return nil }
        let release = request.configuration?.lowercased() == "release" ? ["-c", "release"] : []
        guard let described = Self.run(swift + ["package", "--package-path", dir, "describe", "--type", "json"]),
              let products = Self.executableProducts(describeJSON: Data(described.utf8)), !products.isEmpty,
              let bin = Self.run(swift + ["build", "--package-path", dir, "--show-bin-path"] + release)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !bin.isEmpty else { return nil }
        let name = products.first { $0 == request.scheme } ?? products[0]
        return (bin as NSString).appendingPathComponent(name)
    }

    /// The executable products' names in `swift package describe --type
    /// json` output, in manifest order.
    public static func executableProducts(describeJSON data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = root["products"] as? [[String: Any]] else { return nil }
        return products.compactMap { p in
            guard let name = p["name"] as? String, let type = p["type"] as? [String: Any], type.keys.contains("executable") else { return nil }
            return name
        }
    }

    /// Runs a command and returns its standard output (nil when it fails).
    static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// A build that fails at once with one log line and one issue.
    static func failed(issue message: String) -> BuildOperation {
        let (stream, continuation) = AsyncStream<BuildEvent>.makeStream()
        continuation.yield(.output(message))
        let issue = Diagnostic(severity: .error, message: message, location: nil)
        continuation.yield(.finished(BuildResult(status: .failed, exitCode: -1, issues: [issue])))
        continuation.finish()
        return BuildOperation(events: stream, cancel: {})
    }

    /// A build that fails at once with one log line.
    static func failed(_ message: String) -> BuildOperation {
        let (stream, continuation) = AsyncStream<BuildEvent>.makeStream()
        continuation.yield(.output(message))
        continuation.yield(.finished(BuildResult(status: .failed, exitCode: -1, issues: [])))
        continuation.finish()
        return BuildOperation(events: stream, cancel: {})
    }
}

/// Runs one SwiftPM command and reports its lines, progress, activity and
/// issues as build events, like the core's `ProcessBuild`, with two
/// differences SwiftPM's output needs: terminal colour sequences are
/// removed (the compiler colours its diagnostics even into a pipe), and the
/// summary errors that only repeat a failure ("Build failed", "<Step> …
/// failed with a nonzero exit code") are issues only when nothing else
/// failed.
enum SwiftPMRun {
    static func start(_ args: [String], currentDirectory: String) -> BuildOperation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let cancelled = CancelFlag()
        let (stream, continuation) = AsyncStream<BuildEvent>.makeStream()
        let thread = Thread {
            var lines = LineBuffer()
            var parser = DiagnosticParser()
            var counter = LogTaskCounter()
            var summaries: [Diagnostic] = []
            var issues: [Diagnostic] = []
            func report(_ ds: [Diagnostic]) {
                for d in ds {
                    if isSummary(d) { summaries.append(d); continue }
                    issues.append(d)
                    continuation.yield(.issue(d))
                }
            }
            func handle(_ raw: String) {
                let line = stripANSI(raw)
                continuation.yield(.output(line))
                if let p = counter.feed(line) { continuation.yield(.progress(done: p.done, total: p.total)) }
                if let a = PackageBuildEngine.activity(for: line) { continuation.yield(.activity(a)) }
                report(parser.feed(line))
            }
            do {
                try process.run()
            } catch {
                continuation.yield(.output("ycode: cannot run \(args[0]): \(error)"))
                continuation.yield(.finished(BuildResult(status: .failed, exitCode: -1, issues: [])))
                continuation.finish()
                return
            }
            let reader = pipe.fileHandleForReading
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                lines.append(data).forEach(handle)
            }
            if let last = lines.flush() { handle(last) }
            report(parser.finish())
            process.waitUntilExit()
            if !issues.contains(where: { $0.severity == .error }) {
                for d in summaries {
                    issues.append(d)
                    continuation.yield(.issue(d))
                }
            }
            let code = process.terminationStatus
            let status: BuildStatus = cancelled.isSet ? .cancelled : (code == 0 ? .succeeded : .failed)
            continuation.yield(.finished(BuildResult(status: status, exitCode: code, issues: issues)))
            continuation.finish()
        }
        thread.start()
        return BuildOperation(events: stream) {
            cancelled.set()
            if process.isRunning { process.interrupt() }
        }
    }

    /// A location-less error that only says a step or the build failed.
    static func isSummary(_ d: Diagnostic) -> Bool {
        guard d.severity == .error, d.location == nil else { return false }
        // ("error: fatalError" is how `swift test` ends after a failed build.)
        return d.message == "Build failed" || d.message.lowercased() == "fatalerror" || d.message.hasSuffix("failed with a nonzero exit code")
            || d.message.contains("failed with a nonzero exit code. Command line:")
    }

    /// The line without ANSI escape sequences (CSI … final byte).
    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = ""
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            guard c == "\u{1B}" else { out.unicodeScalars.append(c); continue }
            guard let next = it.next() else { break }
            guard next == "[" else { continue }
            while let b = it.next(), !(0x40...0x7E).contains(b.value) {}
        }
        return out
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}

/// What the Linux shell needs from the machine, and what it says without it.
public enum ShellToolchain {
    public static let noSwift = "Ycode could not find a Swift toolchain. Install Swift 6 or later (swift.org/install), make sure `swift` is on your PATH, then build again."
    public static let noBuildTool = "Ycode could not find its build tool, ycodebuild. It ships with Ycode; if you built Ycode from source, build the ycodebuild product too."

    public static let noAppleSDK = "This project is for Apple platforms, and My Computer cannot build it here: that takes the platform's SDK, which Ycode does not include. "
        + "Swift packages build and run on this computer. Building for a Ycode simulator host is experimental and needs your own SDK; see the README."

    /// The program's path on `PATH`.
    public static func locate(_ tool: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for dir in (environment["PATH"] ?? "").split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(dir)/\(tool)") {
            return "\(dir)/\(tool)"
        }
        return nil
    }
}

/// Projects and workspaces on Linux: the host is no destination for them
/// (their targets are Apple platforms), so a build for it says what it takes
/// instead of the build tool's "no such destination".
struct LinuxProjectEngine: BuildEngine {
    var inner: BuildEngine
    var name: String { inner.name }
    func start(_ request: BuildRequest) -> BuildOperation {
        guard request.destination == ShellBuildSetup.hostDestination.specifier, request.action != .clean else { return inner.start(request) }
        return PackageBuildEngine.failed(issue: ShellToolchain.noAppleSDK)
    }
    func executablePath(for request: BuildRequest) -> String? {
        request.destination == ShellBuildSetup.hostDestination.specifier ? nil : inner.executablePath(for: request)
    }
}

/// An engine for a tool that is not there: every build fails, saying so.
struct MissingToolEngine: BuildEngine {
    var name: String { "missing" }
    var message: String
    func start(_ request: BuildRequest) -> BuildOperation { PackageBuildEngine.failed(issue: message) }
    func executablePath(for request: BuildRequest) -> String? { nil }
}

/// The build engine and destinations the shell uses on this host.
public enum ShellBuildSetup {
    /// The host as a run destination. On Linux: "My Computer"
    /// (`platform=Linux`, a Ycode-own specifier SwiftPM does not need); on
    /// macOS the core's My Mac.
    public static var hostDestination: Destination {
        #if os(Linux)
        Destination(name: "My Computer", specifier: "platform=Linux", platform: "Linux", kind: .mac)
        #else
        .myMac
        #endif
    }

    /// The destination pop-up's groups on this host.
    public static func destinationGroups(for model: WorkspaceModel) -> [DestinationGroup] {
        #if os(Linux)
        [DestinationGroup(title: "My Computer", destinations: [hostDestination])]
        #else
        model.destinationGroups
        #endif
    }

    /// On Linux: SwiftPM for packages and `ycodebuild` (found as the core's
    /// test runner finds it) for projects and workspaces;
    /// `YCODE_IDE_ENGINE=ycodebuild` sends packages to `ycodebuild` too. On
    /// macOS: the engine chosen in Settings, as in the AppKit shell.
    public static func engine(environment: [String: String] = ProcessInfo.processInfo.environment) -> BuildEngine {
        #if os(Linux)
        let ycodebuild: BuildEngine = TestRunnerSelection.locateYcodebuild(environment: environment).map { LinuxProjectEngine(inner: XcodebuildEngine(command: [$0])) }
            ?? MissingToolEngine(message: ShellToolchain.noBuildTool)
        if environment["YCODE_IDE_ENGINE"] == "ycodebuild" { return ycodebuild }
        return FallbackEngine(primary: PackageBuildEngine(), fallback: ycodebuild) { r in
            if case .package = r.container { return true }
            return false
        }
        #else
        _ = environment
        return BuildSystemPreference.current().makeEngine()
        #endif
    }
}
