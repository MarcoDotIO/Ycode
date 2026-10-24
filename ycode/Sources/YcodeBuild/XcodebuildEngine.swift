import Foundation

/// Builds by running `xcodebuild` as a subprocess and reading its log.
/// This is the interim engine; see `specs/ide/build.md` §Engines.
public struct XcodebuildEngine: BuildEngine {
    public var name: String { "xcodebuild" }
    /// The tool and any leading arguments. Tests replace it with a script.
    public var command: [String]
    public var environment: [String: String]?
    /// Where `buildSettings(for:)` gets settings; nil = `xcodebuild -showBuildSettings`.
    public var settingsSource: (any BuildSettingsSource)?

    public init(command: [String] = ["/usr/bin/xcrun", "xcodebuild"], environment: [String: String]? = nil) {
        self.command = command
        self.environment = environment
    }

    /// The command-line arguments for a request (without the tool itself).
    public static func arguments(for r: BuildRequest) -> [String] {
        var args: [String] = []
        switch r.container {
        case .project(let p): args += ["-project", p]
        case .workspace(let p): args += ["-workspace", p]
        case .package: break // xcodebuild finds Package.swift in its working directory
        }
        if let s = r.scheme { args += ["-scheme", s] }
        if let c = r.configuration { args += ["-configuration", c] }
        if let d = r.destination { args += ["-destination", d] }
        if let dd = r.derivedDataPath { args += ["-derivedDataPath", dd] }
        args.append(r.action.rawValue)
        args += r.settings.map { "\($0)=\($1)" }
        return args
    }

    /// Short progress text for a log line, or nil. The build log names each
    /// step with a leading verb (`CompileSwift`, `Ld`, …).
    public static func activity(for line: String) -> String? {
        let verbs: [(String, String)] = [
            ("CompileSwift", "Compiling"), ("SwiftCompile", "Compiling"), ("CompileC", "Compiling"),
            ("Ld ", "Linking"), ("CodeSign", "Signing"), ("CompileAssetCatalog", "Compiling assets"),
            ("ProcessInfoPlistFile", "Processing Info.plist"), ("PhaseScriptExecution", "Running script"),
            ("Resolve Package Graph", "Resolving packages"), ("ComputePackagePrebuildTargetDependencyGraph", "Preparing"),
        ]
        for (verb, label) in verbs where line.hasPrefix(verb) {
            let file = line.split(separator: " ").last { $0.contains("/") }.map { URL(fileURLWithPath: String($0)).lastPathComponent }
            return file.map { "\(label) \($0)" } ?? label
        }
        return nil
    }

    public func start(_ request: BuildRequest) -> BuildOperation {
        var cwd: String?
        if case .package(let dir) = request.container { cwd = dir }
        return ProcessBuild.start(command + Self.arguments(for: request), currentDirectory: cwd, environment: environment,
                                  activity: Self.activity(for:))
    }
}

/// Runs one build-tool process (stdout and stderr merged, stdin closed)
/// and reports its lines, progress text and diagnostics as build events
/// (`specs/ide/build.md` §Engines). Exit status 0 means success; cancel
/// sends SIGINT and the result is `cancelled`.
public enum ProcessBuild {
    public static func start(_ args: [String], currentDirectory: String? = nil, environment: [String: String]? = nil,
                             activity: @escaping @Sendable (String) -> String? = { _ in nil }) -> BuildOperation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let cancelled = Flag()

        let (stream, continuation) = AsyncStream<BuildEvent>.makeStream()
        let thread = Thread {
            var lines = LineBuffer()
            var parser = DiagnosticParser()
            func handle(_ line: String) {
                continuation.yield(.output(line))
                if let a = activity(line) { continuation.yield(.activity(a)) }
                for d in parser.feed(line) { continuation.yield(.issue(d)) }
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
            for d in parser.finish() { continuation.yield(.issue(d)) }
            process.waitUntilExit()
            let code = process.terminationStatus
            let status: BuildStatus = cancelled.value ? .cancelled : (code == 0 ? .succeeded : .failed)
            continuation.yield(.finished(BuildResult(status: status, exitCode: code, issues: parser.finished)))
            continuation.finish()
        }
        thread.start()
        return BuildOperation(events: stream) {
            cancelled.set()
            if process.isRunning { process.interrupt() }
        }
    }
}

/// A thread-safe boolean that only goes from false to true.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    func set() { lock.lock(); raised = true; lock.unlock() }
}
