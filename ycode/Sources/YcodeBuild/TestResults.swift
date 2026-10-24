import Foundation
import YcodeSubprocess

/// The outcome of one test. See `specs/ide/testing.md`.
public struct TestOutcome: Equatable, Sendable {
    public enum Status: String, Sendable { case passed, failed, skipped }
    /// The test's class or suite, when the runner names it.
    public var suite: String?
    /// The test function, without `()` (e.g. `testAdd`, `addsNumbers`).
    public var name: String
    public var status: Status
    /// Failure messages with their locations.
    public var failures: [Diagnostic]
    /// Seconds the test ran, when the runner reports it.
    public var duration: TimeInterval?

    public init(suite: String?, name: String, status: Status, failures: [Diagnostic] = [], duration: TimeInterval? = nil) {
        self.duration = duration
        self.suite = suite
        self.name = name
        self.status = status
        self.failures = failures
    }
}

/// Reads test results from runner output: XCTest's `Test Case '…' passed`
/// lines (Darwin `-[Module.Class test]` and Linux `Class.test` forms) and
/// swift-testing's `✔ Test name() passed` / `✘ Test name() failed` lines.
public struct TestResultParser: Sendable {
    public private(set) var outcomes: [TestOutcome] = []
    private var pendingIssues: [String: [Diagnostic]] = [:]

    public init() {}

    @discardableResult
    public mutating func feed(_ line: String) -> TestOutcome? {
        if let o = Self.xctest(line) ?? swiftTesting(line) {
            var o = o
            o.failures += pendingIssues.removeValue(forKey: o.name) ?? []
            if let i = outcomes.firstIndex(where: { $0.name == o.name && $0.suite == o.suite }) { outcomes[i] = o } else { outcomes.append(o) }
            return o
        }
        // XCTest failure: `/path/F.swift:12: error: -[Mod.Class testX] : message`
        if let d = DiagnosticParser.parseLine(line), d.severity == .error,
           let open = d.message.range(of: "-["), let close = d.message.range(of: "] : ") {
            let inner = d.message[open.upperBound..<close.lowerBound]
            let name = inner.split(separator: " ").last.map(String.init) ?? ""
            var issue = d
            issue.message = String(d.message[close.upperBound...])
            pendingIssues[name, default: []].append(issue)
        }
        return nil
    }

    static func xctest(_ line: String) -> TestOutcome? {
        guard let start = line.range(of: "Test Case '") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.range(of: "' ") else { return nil }
        let id = String(rest[..<end.lowerBound])
        let verdict = rest[end.upperBound...]
        let status: TestOutcome.Status
        if verdict.hasPrefix("passed") { status = .passed }
        else if verdict.hasPrefix("failed") { status = .failed }
        else if verdict.hasPrefix("skipped") { status = .skipped }
        else { return nil }
        var suite: String?, name = id
        if id.hasPrefix("-["), id.hasSuffix("]") {
            let parts = id.dropFirst(2).dropLast().split(separator: " ")
            if parts.count == 2 {
                suite = parts[0].split(separator: ".").last.map(String.init)
                name = String(parts[1])
            }
        } else if let dot = id.lastIndex(of: ".") {
            suite = String(id[..<dot]).split(separator: ".").last.map(String.init)
            name = String(id[id.index(after: dot)...])
        }
        return TestOutcome(suite: suite, name: name, status: status, duration: seconds(in: verdict))
    }

    /// "passed (0.001 seconds)" or "passed after 0.001 seconds".
    static func seconds<S: StringProtocol>(in s: S) -> TimeInterval? {
        guard let r = s.range(of: " seconds") else { return nil }
        let head = s[..<r.lowerBound]
        let num = head.reversed().prefix { $0.isNumber || $0 == "." }
        return TimeInterval(String(num.reversed()))
    }

    mutating func swiftTesting(_ line: String) -> TestOutcome? {
        // ✔ Test addsNumbers() passed after 0.001 seconds.
        // ✘ Test addsNumbers() recorded an issue at File.swift:3:5: Expectation failed: …
        // ✘ Test addsNumbers() failed after 0.002 seconds with 1 issue.
        for (mark, status) in [("✔ Test ", TestOutcome.Status.passed), ("✘ Test ", .failed), ("➜ Test ", .skipped)] {
            guard let r = line.range(of: mark) else { continue }
            let rest = line[r.upperBound...]
            guard let paren = rest.range(of: "(") else { return nil }
            let name = String(rest[..<paren.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let issue = rest.range(of: " recorded an issue at ") {
                let tail = String(rest[issue.upperBound...])
                if let d = DiagnosticParser.parseLine(tail.replacingOccurrences(of: ": ", with: ": error: ", options: [], range: tail.range(of: ": "))) {
                    pendingIssues[name, default: []].append(d)
                }
                return nil
            }
            if rest.contains(" skipped") { return TestOutcome(suite: nil, name: name, status: .skipped) }
            guard rest.contains(" passed") || rest.contains(" failed") else { return nil }
            return TestOutcome(suite: nil, name: name, status: status, duration: Self.seconds(in: rest))
        }
        return nil
    }

    public static func parse(_ text: String) -> [TestOutcome] {
        var p = TestResultParser()
        text.split(separator: "\n", omittingEmptySubsequences: false).forEach { p.feed(String($0)) }
        return p.outcomes
    }
}

/// Runs a container's tests and reports output lines and outcomes.
/// Packages use SwiftPM (`swift test`); projects and workspaces use
/// `xcodebuild test`. See `specs/ide/testing.md`.
public struct TestRunner: Sendable {
    public var xcodebuild: [String] = ["/usr/bin/xcrun", "xcodebuild"]
    public var swift: [String] = ["/usr/bin/env", "swift"]
    /// Gather code coverage (the scheme's test action enables it):
    /// `swift test --enable-code-coverage`, or `-enableCodeCoverage YES`.
    public var coverage = false
    /// With `coverage`, where ycodebuild writes its coverage summary (it
    /// reads the path from `YCODE_COVERAGE_SUMMARY`; other xcodebuild
    /// tools ignore the variable and write nothing).
    public var coverageSummaryPath: String?
    public init() {}

    /// The test plan to run (`-testPlan`, projects and workspaces); nil =
    /// the scheme's default plan.
    public var testPlan: String?

    /// The command for a request; `only` narrows to `Suite/test` identifiers.
    /// The request's action picks the step (Product ▸ Build For ▸ Testing,
    /// Perform Action ▸ Test Without Building, `reference-ui-5.md` §2.9):
    /// `build-for-testing` builds the tests only, `test-without-building`
    /// runs tests an earlier `build-for-testing` built; any other action
    /// builds and runs them (`test`). Packages map these to `swift build
    /// --build-tests`, `swift test --skip-build` and `swift test`.
    public func command(for request: BuildRequest, only: [String] = []) -> (args: [String], cwd: String?) {
        let action: BuildRequest.Action = [.buildForTesting, .testWithoutBuilding].contains(request.action) ? request.action : .test
        switch request.container {
        case .package(let dir):
            if action == .buildForTesting {
                return (swift + ["build", "--build-tests"] + (request.configuration == "Release" ? ["-c", "release"] : []), dir)
            }
            var a = swift + ["test"]
            if action == .testWithoutBuilding { a.append("--skip-build") }
            if request.configuration == "Release" { a += ["-c", "release"] }
            if coverage && action == .test { a.append("--enable-code-coverage") }
            for o in only { a += ["--filter", o.replacingOccurrences(of: "/", with: ".")] }
            return (a, dir)
        default:
            var r = request
            r.action = action
            var a = xcodebuild + (coverage && action != .buildForTesting ? ["-enableCodeCoverage", "YES"] : []) + XcodebuildEngine.arguments(for: r)
            // Options go before the action word and the setting overrides.
            let optionsEnd = a.count - 1 - r.settings.count
            var options: [String] = []
            if let testPlan, !testPlan.isEmpty { options += ["-testPlan", testPlan] }
            if action != .buildForTesting { options += only.map { "-only-testing:\($0)" } }
            a.insert(contentsOf: options, at: optionsEnd)
            return (a, nil)
        }
    }

    /// Product ▸ Build For ▸ Testing: the `build-for-testing` step as a
    /// build operation (log lines, progress and diagnostics), run with the
    /// same tool that runs the tests, so Test Without Building finds its
    /// products.
    public func buildForTesting(_ request: BuildRequest) -> BuildOperation {
        var r = request
        r.action = .buildForTesting
        let (args, cwd) = command(for: r)
        return ProcessBuild.start(args, currentDirectory: cwd, activity: XcodebuildEngine.activity(for:))
    }

    /// Runs and streams; finishes with all outcomes.
    public func run(_ request: BuildRequest, only: [String] = [],
                    onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> (exitCode: Int32, outcomes: [TestOutcome]) {
        let (args, cwd) = command(for: request, only: only)
        return await withCheckedContinuation { c in
            Thread {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: args[0])
                p.arguments = Array(args.dropFirst())
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                if coverage, let out = coverageSummaryPath {
                    var env = ProcessInfo.processInfo.environment
                    env["YCODE_COVERAGE_SUMMARY"] = out
                    p.environment = env
                }
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                var parser = TestResultParser()
                var lines = LineBuffer()
                do { try p.run() } catch {
                    onLine("ycode: cannot run tests: \(error)")
                    return c.resume(returning: (-1, []))
                }
                let fh = pipe.fileHandleForReading
                while true {
                    let d = fh.availableData
                    if d.isEmpty { break }
                    for l in lines.append(d) { onLine(l); parser.feed(l) }
                }
                if let l = lines.flush() { onLine(l); parser.feed(l) }
                p.waitUntilExit()
                c.resume(returning: (p.terminationStatus, parser.outcomes))
            }.start()
        }
    }

    /// The llvm-cov export JSON of a package's last coverage run
    /// (`swift test --show-codecov-path`), nil when there is none.
    public func packageCoverageJSON(packageDirectory dir: String) -> Data? {
        MainThreadGuard.blockingCall("swift test --show-codecov-path")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: swift[0])
        p.arguments = Array(swift.dropFirst()) + ["test", "--show-codecov-path"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !path.isEmpty else { return nil }
        return FileManager.default.contents(atPath: path)
    }
}
