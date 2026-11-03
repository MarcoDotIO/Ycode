import Foundation
import YcodeAssistant
import YcodeBuild
import YcodeIDECore

extension YcodeMCPHost {
    var buildTools: [MCPTool] {
        let schemeArgs: [String: AnyJSON] = [
            "workspace": Schema.workspace,
            "scheme": Schema.string("The scheme (default: the selected one; see workspace_describe)."),
            "destination": Schema.string("A run destination's name or id (default: the selected one)."),
        ]
        let buildOutput = Schema.output(["status": Schema.str, "errors": Schema.int, "warnings": Schema.int, "issues": Schema.anyArray,
                                         "seconds": Schema.int, "logTail": Schema.anyArray])
        return [
            tool("build", "Build",
                 "Builds the scheme for the destination (Product ▸ Build) and returns the issues. Reports progress while it runs. Every issue is collected (the build does not stop at the first error).",
                 input: Schema.object(schemeArgs), output: buildOutput,
                 annotations: MCPToolAnnotations(readOnly: false, idempotent: true)) { h, call in
                try await h.build(call, action: .build)
            },
            tool("test", "Test",
                 "Builds and runs the tests (Product ▸ Test): all of them, the ones named, or a test plan's. Returns each test's outcome and the failures.",
                 input: Schema.object(schemeArgs.merging([
                     "tests": Schema.array(Schema.str, "Tests to run: identifiers \"Suite/name\" (or a bare function name for a free @Test). Default: all."),
                     "plan": Schema.string("A test plan of the scheme (projects only)."),
                 ]) { a, _ in a }),
                 output: Schema.output(["status": Schema.str, "passed": Schema.int, "failed": Schema.int, "skipped": Schema.int,
                                        "tests": Schema.anyArray, "issues": Schema.anyArray, "logTail": Schema.anyArray]),
                 annotations: MCPToolAnnotations(readOnly: false, idempotent: true)) { h, call in
                try await h.test(call)
            },
            tool("clean", "Clean",
                 "Removes the scheme's build products (Product ▸ Clean Build Folder).",
                 input: Schema.object(schemeArgs), output: buildOutput,
                 annotations: MCPToolAnnotations(readOnly: false, destructive: true, idempotent: true)) { h, call in
                try await h.build(call, action: .clean)
            },
            tool("build_log", "Build log",
                 "The last build's or test run's log lines.",
                 input: Schema.object(["workspace": Schema.workspace, "tail": Schema.integer("Only the last N lines (default 200).", minimum: 1)]),
                 output: Schema.output(["lines": Schema.anyArray, "lineCount": Schema.int])) { h, call in
                let s = try h.session(for: call)
                let tail = call.int("tail") ?? 200
                let lines = Array(s.buildLog.suffix(tail))
                return MCPToolResult(content: [.textBlock(lines.isEmpty ? "The log is empty: nothing was built yet." : lines.joined(separator: "\n"))],
                                     structured: ["lines": .strings(lines), "lineCount": .int(s.buildLog.count)])
            },
        ]
    }

    /// Runs `body` with the session's activity reported to `progress`.
    func reportingActivity<T>(_ progress: MCPProgress, _ body: () async -> T) async -> T {
        let previous = activityProgress
        activityProgress = progress.isRequested ? progress : nil
        activityCount = 0
        defer { activityProgress = previous }
        return await body()
    }

    func build(_ call: MCPToolCall, action: BuildRequest.Action) async throws -> MCPToolResult {
        let s = try session(for: call)
        try applyScheme(call.string("scheme"), destination: call.string("destination"), to: s)
        delegate?.mcpHostSaveAll()
        let started = Date()
        let result = await reportingActivity(call.progress) { await s.build(action) }
        let root = Self.folder(of: s.model).path
        let status: String = switch result.status { case .succeeded: "succeeded"; case .failed: "failed"; case .cancelled: "cancelled" }
        let issues = result.issues.filter { $0.severity != .note || $0.location != nil }
        let verb = action == .clean ? "Clean" : "Build"
        var summary = "\(verb) \(status) (\(result.errorCount) errors, \(result.warningCount) warnings)."
        for d in issues.prefix(30) where d.severity == .error || d.severity == .warning {
            summary += "\n" + (Self.issueJSON(d, relativeTo: root)["path"]?.string.map { p in "\(p):\(d.location?.line ?? 0): " } ?? "") + "\(d.severity.rawValue): \(d.message)"
        }
        if result.status == .failed && result.errorCount == 0 { summary += "\nLast log lines:\n" + s.buildLog.suffix(15).joined(separator: "\n") }
        let v: AnyJSON = ["status": .string(status), "errors": .int(result.errorCount), "warnings": .int(result.warningCount),
                            "issues": .array(issues.prefix(300).map { Self.issueJSON($0, relativeTo: root) }),
                            "seconds": .int(Int(Date().timeIntervalSince(started).rounded())), "logTail": .strings(Array(s.buildLog.suffix(30)))]
        return MCPToolResult(content: [.textBlock(summary)], structured: v, isError: false)
    }

    func test(_ call: MCPToolCall) async throws -> MCPToolResult {
        let s = try session(for: call)
        try applyScheme(call.string("scheme"), destination: call.string("destination"), to: s)
        if let plan = call.string("plan") {
            guard s.testPlanNames.contains(plan) else {
                throw MCPToolError("the scheme has no test plan \"\(plan)\"\(s.testPlanNames.isEmpty ? "" : "; its plans: " + s.testPlanNames.joined(separator: ", "))")
            }
            s.activeTestPlan = plan
        }
        delegate?.mcpHostSaveAll()
        var only: [DiscoveredTest] = []
        if let names = call.strings("tests"), !names.isEmpty {
            s.discoverTests()
            await s.testsDiscovered()
            for n in names {
                let found = s.tests.filter { t in
                    t.identifier == n || s.runnerIdentifier(t) == n || t.name == n || (t.suite == n) || "\(t.suite ?? "")/\(t.name)()" == n
                }
                guard !found.isEmpty else {
                    let known = s.tests.prefix(40).map(\.identifier).joined(separator: ", ")
                    throw MCPToolError("no test \"\(n)\" was found in the sources\(known.isEmpty ? "" : "; tests: " + known)")
                }
                only += found
            }
        }
        let outcomes = await reportingActivity(call.progress) { await s.runTests(only: only) }
        let root = Self.folder(of: s.model).path
        let passed = outcomes.filter { $0.status == .passed }.count
        let failed = outcomes.filter { $0.status == .failed }.count
        let skipped = outcomes.filter { $0.status == .skipped }.count
        let lastReportOK = s.reports.first?.succeeded ?? (failed == 0)
        let status = failed > 0 || !lastReportOK ? "failed" : "succeeded"
        var summary = "Tests \(status): \(passed) passed, \(failed) failed, \(skipped) skipped."
        for o in outcomes where o.status == .failed {
            summary += "\n✗ \(o.suite.map { "\($0)/" } ?? "")\(o.name)"
            for f in o.failures.prefix(3) { summary += "\n    " + f.description }
        }
        if outcomes.isEmpty && status == "failed" {
            let issues = s.displayedIssues.prefix(20).map(\.description)
            summary += "\nNo test ran." + (issues.isEmpty ? "\nLast log lines:\n" + s.buildLog.suffix(20).joined(separator: "\n") : "\n" + issues.joined(separator: "\n"))
        }
        let tests: [AnyJSON] = outcomes.map { o in
            ["suite": .optional(o.suite), "name": .string(o.name), "status": .string(o.status.rawValue),
             "seconds": o.duration.map { .double($0) } ?? .null, "failures": .array(o.failures.map { Self.issueJSON($0, relativeTo: root) })]
        }
        return MCPToolResult(content: [.textBlock(summary)],
                             structured: ["status": .string(status), "passed": .int(passed), "failed": .int(failed), "skipped": .int(skipped),
                                          "tests": .array(tests), "issues": .array(s.displayedIssues.prefix(200).map { Self.issueJSON($0, relativeTo: root) }),
                                          "logTail": .strings(Array(s.buildLog.suffix(30)))])
    }
}
