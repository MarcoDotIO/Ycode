import Foundation

/// Result bundles (`-resultBundlePath`, and the default bundle of test
/// runs): what is recorded and when it is written.
/// See `specs/xcodebuild/result-bundle.md`.
final class ResultBundleSession {
    /// One scheme action (or legacy build) as recorded in the bundle.
    struct Action {
        var commandName: String
        var taskName: String
        var title: String?
        var started: Date
        var ended: Date
        var build: BuildActions.BuildOutcome?
        var buildRequested = true
        var tests: TestActions.Outcome?
        var testPlanName: String?
        var testRequested = false
    }

    let path: String
    let given: String
    /// The project or workspace path, its label (`Calc project`) and the
    /// project name the build log heading uses.
    let containerPath: String
    let containerLabel: String
    let projectName: String
    let schemeName: String?
    let runDestination: RunDestination?
    let sdk: SDKEntry?
    let uniqueID = UUID().uuidString
    var actions: [Action] = []
    var archivePath: String?
    /// Explicit (`-resultBundlePath`) or the default test bundle.
    let explicit: Bool
    /// A build without a scheme.
    var legacy = false
    /// "project" or "workspace" (log headings and titles).
    var containerWord = "project"

    init(path: String, given: String, explicit: Bool, containerPath: String, containerLabel: String, projectName: String,
         schemeName: String?, runDestination: RunDestination?, sdk: SDKEntry?) {
        self.path = path
        self.given = given
        self.explicit = explicit
        self.containerPath = containerPath
        self.containerLabel = containerLabel
        self.projectName = projectName
        self.schemeName = schemeName
        self.runDestination = runDestination
        self.sdk = sdk
    }

    /// The path as the reference tool prints it at the end (`/private`
    /// prefixes of existing paths removed).
    var displayPath: String { ResultBundleSession.standardized(path) }

    static func standardized(_ p: String) -> String { PathText.withoutPrivatePrefix(p) }

    /// `-resultBundlePath`, made absolute.
    static func requestedPath(_ inv: Invocation, cwd: String) -> (absolute: String, given: String)? {
        guard let p = inv.value("-resultBundlePath") else { return nil }
        let abs = p.hasPrefix("/") ? p : cwd + "/" + p
        return (URL(fileURLWithPath: abs).standardizedFileURL.path, p)
    }

    /// `<DerivedData folder>/Logs/Test/Test-<scheme>-<yyyy.MM.dd_HH-mm-ss-ZZZ>.xcresult`.
    static func defaultTestPath(arena: Arena, scheme: String, date: Date = Date()) -> String {
        let folder = URL(fileURLWithPath: arena.buildProductsPath).deletingLastPathComponent().deletingLastPathComponent().path
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy.MM.dd_HH-mm-ss-ZZZ"
        return folder + "/Logs/Test/Test-\(scheme)-\(f.string(from: date)).xcresult"
    }

    /// Writes the bundle with every action recorded so far (replacing an
    /// earlier write of this session).
    func write(console: Console) -> Bool {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        do {
            if fm.fileExists(atPath: path) { try fm.removeItem(at: url) }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let store = try XCResultStore(creating: url)
            let root = try ResultRecords(session: self, store: store).root()
            try store.finish(root: root)
            return true
        } catch {
            console.err("ycodebuild: warning: could not write the result bundle at \(path): \(error)")
            return false
        }
    }
}

/// Builds the object graph of a session (types and keys from
/// `xcresulttool formatDescription`; see `specs/xcodebuild/result-bundle.md` §4).
struct ResultRecords {
    let session: ResultBundleSession
    let store: XCResultStore

    typealias V = XCRValue
    static let issueSummary = XCRType("IssueSummary")
    static let testFailureIssueSummary = XCRType("TestFailureIssueSummary", "IssueSummary")
    static let groupType = XCRType("ActionTestSummaryGroup", "ActionTestSummaryIdentifiableObject", "ActionAbstractTestSummary")
    static let metadataType = XCRType("ActionTestMetadata", "ActionTestSummaryIdentifiableObject", "ActionAbstractTestSummary")
    static let summaryType = XCRType("ActionTestSummary", "ActionTestSummaryIdentifiableObject", "ActionAbstractTestSummary")

    func root() throws -> String {
        let metadata = try store.put(.obj(XCRType("ActionsInvocationMetadata"), [
            "creatingWorkspaceFilePath": .string(session.containerPath),
            "uniqueIdentifier": .string(session.uniqueID),
            "schemeIdentifier": session.schemeName.map { s in
                .obj(XCRType("EntityIdentifier"), [
                    "containerName": .string(session.containerLabel),
                    "entityName": .string(s), "entityType": .string("scheme"), "sharedState": .string("shared"),
                ])
            },
        ]))
        var records: [V] = []
        var all = Issues()
        for a in session.actions {
            let (record, issues) = try action(a)
            records.append(record)
            all.add(issues)
        }
        var fields: [String: V?] = [
            "actions": .array(records),
            "issues": all.value,
            "metadataRef": .reference(metadata, XCRType("ActionsInvocationMetadata")),
            "metrics": all.metrics,
        ]
        if let a = session.archivePath { fields["archive"] = .obj(XCRType("ArchiveInfo"), ["path": .string(ResultBundleSession.standardized(a))]) }
        return try store.put(.obj(XCRType("ActionsInvocationRecord"), fields))
    }

    /// Issues and counts of one result.
    struct Issues {
        var errors: [V] = []
        var warnings: [V] = []
        var testFailures: [V] = []
        var tests = 0, failed = 0, skipped = 0
        var coveredLines = 0, executableLines = 0

        mutating func add(_ o: Issues) {
            errors += o.errors; warnings += o.warnings; testFailures += o.testFailures
            tests += o.tests; failed += o.failed; skipped += o.skipped
            coveredLines += o.coveredLines; executableLines += o.executableLines
        }

        var value: V {
            .obj(XCRType("ResultIssueSummaries"), [
                "analyzerWarningSummaries": .array([]), "errorSummaries": .array(errors),
                "testFailureSummaries": .array(testFailures), "testWarningSummaries": .array([]), "warningSummaries": .array(warnings),
            ])
        }

        var metrics: V {
            .obj(XCRType("ResultMetrics"), [
                "analyzerWarningCount": .int(0), "errorCount": .int(errors.count), "testsCount": .int(tests),
                "testsFailedCount": .int(failed), "testsSkippedCount": .int(skipped), "warningCount": .int(warnings.count),
                "totalCoveragePercentage": executableLines > 0 ? .double(Double(coveredLines) / Double(executableLines)) : nil,
            ])
        }
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// `file://…#EndingColumnNumber=…&…&Timestamp=…`, zero-based numbers.
    static func documentLocation(file: String, line: Int?, column: Int?, timestamp: Bool) -> V {
        var url = URL(fileURLWithPath: file).absoluteString
        var parts: [String] = []
        if let l = line, l > 0 {
            if let c = column, c > 0 { parts.append("EndingColumnNumber=\(c - 1)") }
            parts.append("EndingLineNumber=\(l - 1)")
            if let c = column, c > 0 { parts.append("StartingColumnNumber=\(c - 1)") }
            parts.append("StartingLineNumber=\(l - 1)")
        }
        if timestamp { parts.append("Timestamp=" + String(format: "%.6f", Date().timeIntervalSinceReferenceDate)) }
        if !parts.isEmpty { url += "#" + parts.joined(separator: "&") }
        return .obj(XCRType("DocumentLocation"), ["concreteTypeName": .string("DVTTextDocumentLocation"), "url": .string(url)])
    }

    func buildIssues(_ b: BuildActions.BuildOutcome) -> Issues {
        var r = Issues()
        // The same issue from several targets is summarized once.
        var seen = Set<String>()
        for i in b.issues where seen.insert("\(i.kind)|\(i.message)|\(i.file ?? "")|\(i.line ?? 0)|\(i.column ?? 0)").inserted {
            let type = i.category ?? (i.kind == "error" ? "Error" : "Warning")
            let summary: V = .obj(Self.issueSummary, [
                "issueType": .string(type),
                "message": .string(Self.capitalizedFirst(i.message)),
                "documentLocationInCreatingWorkspace": i.file.map { Self.documentLocation(file: $0, line: i.line, column: i.column, timestamp: true) },
            ])
            if i.kind == "error" { r.errors.append(summary) } else { r.warnings.append(summary) }
        }
        return r
    }

    func actionResult(name: String, status: String, issues: Issues, log: String?, tests: String?,
                      coverage: (report: String, archive: String)? = nil, diagnostics: String? = nil) -> V {
        .obj(XCRType("ActionResult"), [
            "coverage": .obj(XCRType("CodeCoverageInfo"), [
                "hasCoverageData": .bool(coverage != nil),
                "reportRef": coverage.map { .reference($0.report) },
                "archiveRef": coverage.map { .reference($0.archive) },
            ]),
            "diagnosticsRef": diagnostics.map { .reference($0) },
            "issues": issues.value,
            "logRef": log.map { .reference($0, XCRType("ActivityLogSection")) },
            "metrics": issues.metrics,
            "resultName": .string(name),
            "status": .string(status),
            "testsRef": tests.map { .reference($0, XCRType("ActionTestPlanRunSummaries")) },
        ])
    }

    func action(_ a: ResultBundleSession.Action) throws -> (V, Issues) {
        var buildIssues = Issues()
        var buildLog: String?
        var buildStatus = "notRequested"
        if let b = a.build {
            buildIssues = self.buildIssues(b)
            buildLog = try store.put(buildLogSection(b, title: a.title))
            buildStatus = b.ok ? "succeeded" : "failed"
        }
        var testIssues = Issues()
        var testsRef: String?
        var actionLog: String?
        var actionStatus = "notRequested"
        var coverageRefs: (report: String, archive: String)?
        var diagnosticsRef: String?
        if let t = a.tests {
            if let c = t.coverage, let report = Coverage.reportArchive(c) {
                let files = try Coverage.archiveFiles(c).map { (name: $0.name, isDirectory: false, id: try store.putFile($0.bytes)) }
                coverageRefs = (try store.putFile(report), try store.putDirectory(files))
            }
            diagnosticsRef = try diagnostics(t)
            (testsRef, testIssues) = try testSummaries(t)
            actionStatus = t.succeeded ? "succeeded" : "failed"
            let targets: [V] = t.targets.map { run in
                .obj(XCRType("ActivityLogSection"), [
                    "attachments": .array([]), "domainType": .string("com.apple.dt.unit.cocoaUnitTest"),
                    "duration": .double(run.results.reduce(0) { $0 + $1.duration }), "messages": .array([]),
                    "result": .string("succeeded"), "subsections": .array([]), "title": .string("Test target \(run.target.blueprintName)"),
                ])
            }
            actionLog = try store.put(.obj(XCRType("ActivityLogSection"), [
                "attachments": .array([]), "domainType": .string("com.apple.dt.unit.cocoaUnitTest"),
                "duration": .double(t.endedAt.timeIntervalSince(t.startedAt)), "messages": .array([]),
                "result": .string("succeeded"), "startTime": .date(t.startedAt), "subsections": .array(targets),
                "title": .string("Test \(session.schemeName ?? session.projectName)"),
            ]))
        } else if a.testRequested {
            actionStatus = "failed"
        } else if a.commandName == "Archive", let b = a.build {
            actionStatus = b.ok ? "succeeded" : "failed"
        }
        let record: V = .obj(XCRType("ActionRecord"), [
            "actionResult": actionResult(name: "action", status: actionStatus, issues: testIssues, log: actionLog, tests: testsRef,
                                         coverage: coverageRefs, diagnostics: diagnosticsRef),
            "buildResult": actionResult(name: "build", status: buildStatus, issues: buildIssues, log: buildLog, tests: nil),
            "endedTime": .date(a.ended),
            "runDestination": runDestination(),
            "schemeCommandName": .string(a.commandName),
            "schemeTaskName": .string(a.taskName),
            "startedTime": .date(a.started),
            "testPlanName": a.testPlanName.map { .string($0) },
            "title": a.title.map { .string($0) },
        ])
        var both = buildIssues
        both.add(testIssues)
        if let c = a.tests?.coverage {
            both.coveredLines += c.coveredLines
            both.executableLines += c.executableLines
        }
        return (record, both)
    }

    /// The test run's diagnostics: per test bundle
    /// `<target>-<UUID>-Configuration-Test Scheme Action-Iteration-1/<target>-<UUID>/StandardOutputAndStandardError.txt`
    /// with the runner's console output.
    func diagnostics(_ t: TestActions.Outcome) throws -> String? {
        guard !t.targets.isEmpty else { return nil }
        var top: [(name: String, isDirectory: Bool, id: String)] = []
        for run in t.targets {
            let name = run.target.blueprintName
            let output = try store.putFile(Array(run.output.utf8))
            let session = try store.putDirectory([("StandardOutputAndStandardError.txt", false, output)])
            let iteration = try store.putDirectory([("\(name)-\(UUID().uuidString)", true, session)])
            top.append(("\(name)-\(UUID().uuidString)-Configuration-Test Scheme Action-Iteration-1", true, iteration))
        }
        return try store.putDirectory(top)
    }

    // MARK: Build log

    func buildLogSection(_ b: BuildActions.BuildOutcome, title: String?) -> V {
        let projectName = session.projectName
        let heading = session.schemeName.map { "Building \(session.containerWord) \(projectName) with scheme \($0)" } ?? "Building project \(projectName)"
        func message(_ i: BuildLog.Issue) -> V {
            .obj(XCRType("ActivityLogMessage"), [
                "annotations": .array([]),
                "category": .string(i.category ?? (i.kind == "error" ? "Error" : "Warning")),
                "location": i.file.map { Self.documentLocation(file: $0, line: i.line, column: i.column, timestamp: false) },
                "shortTitle": .string(Self.capitalizedFirst(i.message)),
                "title": .string(Self.capitalizedFirst(i.message)),
                "type": .string(i.kind),
            ])
        }
        let sections: [V] = b.tasks.map { t in
            .obj(XCRType("ActivityLogCommandInvocationSection", "ActivityLogSection"), [
                "attachments": .array([]),
                "commandDetails": .string(t.details),
                "domainType": .string("com.apple.dt.IDE.BuildLogSection"),
                "duration": .double(t.duration),
                "emittedOutput": .string(t.output),
                "exitCode": .int(t.succeeded ? 0 : 1),
                "messages": .array(b.issues.filter { $0.taskID == t.id }.map(message)),
                "result": .string(t.succeeded ? "succeeded" : "failed"),
                "startTime": .date(t.started),
                "subsections": .array([]),
                "title": .string(t.title),
            ])
        }
        return .obj(XCRType("ActivityLogSection"), [
            "attachments": .array([]),
            "domainType": .string("Xcode.IDEActivityLogDomainType.BuildLog"),
            "duration": .double(b.ended.timeIntervalSince(b.started)),
            "messages": .array(b.issues.filter { $0.taskID == nil }.map(message)),
            "result": .string(b.ok ? "succeeded" : "failed"),
            "startTime": .date(b.started),
            "subsections": .array(sections),
            "title": .string(heading),
        ])
    }

    // MARK: Tests

    func testSummaries(_ outcome: TestActions.Outcome) throws -> (String, Issues) {
        var issues = Issues()
        var testables: [V] = []
        for run in outcome.targets {
            let t = run.target
            let base = "test://com.apple.xcode/\(t.projectName)/\(t.blueprintName)"
            func url(_ s: String, query: String? = nil) -> String {
                base + "/" + (s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s) + (query.map { "?" + $0 } ?? "")
            }
            func metadata(_ r: TestCaseResult) throws -> V {
                let ident = r.identifier
                let urlTail = r.library == .xctest ? (r.suite.isEmpty ? r.name : r.suite + "/" + r.name) : ident
                // A test case of a parameterized test: `?args=<SHA-256 of the value>`.
                let query = r.arguments.isEmpty ? nil : "args=" + SHA256.hex(Array(r.arguments.map(\.value).joined(separator: ", ").utf8))
                let arguments: [V] = r.arguments.map { a in
                    .obj(XCRType("TestArgument"), [
                        "description": .string(""),
                        "parameter": .obj(XCRType("TestParameter"), ["label": .string(a.label)]),
                        "value": .obj(XCRType("TestValue"), ["debugDescription": .string(a.value), "description": .string(a.value), "isCollection": .bool(false)]),
                    ])
                }
                let failures: [V] = r.status == .failed ? r.issues.map { i in
                    .obj(XCRType("ActionTestFailureSummary"), [
                        "attachments": .array([]), "fileName": .string(i.file ?? ""), "isPerformanceFailure": .bool(false),
                        "isTopLevelFailure": .bool(true), "issueType": .string("Assertion Failure"), "lineNumber": .int(i.line ?? 0),
                        "message": .string(i.message), "uuid": .string(UUID().uuidString),
                        "sourceCodeContext": i.file.map { f in
                            .obj(XCRType("SourceCodeContext"), [
                                "callStack": .array([]),
                                "location": .obj(XCRType("SourceCodeLocation"), ["filePath": .string(f), "lineNumber": .int(i.line ?? 0)]),
                            ])
                        },
                    ])
                } : []
                let skip: V? = r.status == .skipped ? .obj(XCRType("ActionTestNoticeSummary"), [
                    "fileName": .string(r.skipFile ?? ""), "lineNumber": .int(r.skipLine ?? 0),
                    "message": r.skipMessage.map { .string(r.library == .xctest ? "Test skipped - " + $0 : $0) } ?? .string("Test skipped"),
                ]) : nil
                let summary = try store.put(.obj(Self.summaryType, [
                    "activitySummaries": .array([]), "arguments": .array(arguments), "documentation": .array([]),
                    "duration": .double(r.duration), "expectedFailures": .array([]), "failureSummaries": .array(failures),
                    "identifier": .string(ident), "identifierURL": .string(url(urlTail, query: query)), "name": .string(displayName(r)),
                    "performanceMetrics": .array([]), "skipNoticeSummary": skip, "tags": .array([]),
                    "testStatus": .string(r.status.rawValue), "trackedIssues": .array([]), "warningSummaries": .array([]),
                ]))
                issues.tests += 1
                if r.status == .failed {
                    issues.failed += 1
                    for i in r.issues {
                        issues.testFailures.append(.obj(Self.testFailureIssueSummary, [
                            "documentLocationInCreatingWorkspace": i.file.map { Self.documentLocation(file: $0, line: i.line, column: nil, timestamp: false) },
                            "issueType": .string("Uncategorized"), "message": .string(i.message), "testCaseName": .string(r.failingName),
                        ]))
                    }
                }
                if r.status == .skipped { issues.skipped += 1 }
                return .obj(Self.metadataType, [
                    "activitySummariesCount": .int(0), "duration": .double(r.duration), "failureSummariesCount": .int(failures.count),
                    "identifier": .string(ident), "identifierURL": .string(url(urlTail, query: query)), "name": .string(displayName(r)),
                    "performanceMetricsCount": .int(0), "summaryRef": .reference(summary, Self.summaryType),
                    "testStatus": .string(r.status.rawValue),
                ])
            }
            func group(_ name: String, identifier: String, children: [V], duration: Double) -> V {
                .obj(Self.groupType, [
                    "activitySummaries": .array([]), "documentation": .array([]), "duration": .double(duration),
                    "expectedFailures": .array([]), "failureSummaries": .array([]), "identifier": .string(identifier),
                    "identifierURL": .string(url(identifier)), "name": .string(name), "subtests": .array(children),
                    "tags": .array([]), "trackedIssues": .array([]), "warningSummaries": .array([]),
                ])
            }
            var top: [V] = []
            // XCTest: All tests > <bundle>.xctest > classes > methods.
            let xc = run.results.filter { $0.library == .xctest }
            if !xc.isEmpty {
                var classes: [V] = []
                for cls in xc.map(\.suite).uniqued() {
                    let members = xc.filter { $0.suite == cls }
                    classes.append(group(cls, identifier: cls, children: try members.map(metadata), duration: members.reduce(0) { $0 + $1.duration }))
                }
                let total = xc.reduce(0) { $0 + $1.duration }
                let bundle = group(t.blueprintName + ".xctest", identifier: t.blueprintName + ".xctest", children: classes, duration: total)
                let rootName = run.selected ? "Selected tests" : "All tests"
                top.append(group(rootName, identifier: rootName, children: [bundle], duration: total))
            }
            // swift-testing: suites (nested by path), then free functions.
            let sw = run.results.filter { $0.library == .swiftTesting }
            // Suites in the order their first function started running.
            func first(_ suite: String) -> Int { sw.filter { $0.suite == suite }.map { run.starts[$0.name] ?? Int.max }.min() ?? Int.max }
            let suites = sw.map(\.suite).filter { !$0.isEmpty }.uniqued().enumerated()
                .sorted { (first($0.element), $0.offset) < (first($1.element), $1.offset) }.map(\.element)
            for suite in suites {
                let members = sw.filter { $0.suite == suite }
                top.append(group(suite.components(separatedBy: "/").last ?? suite, identifier: suite, children: try members.map(metadata),
                                 duration: members.reduce(0) { $0 + $1.duration }))
            }
            top += try sw.filter { $0.suite.isEmpty }.map(metadata)
            testables.append(.obj(XCRType("ActionTestableSummary", "ActionAbstractTestSummary"), [
                "diagnosticsDirectoryName": .string(""), "failureSummaries": .array([]), "identifierURL": .string(base),
                "name": .string(t.blueprintName), "projectRelativePath": .string(t.projectRelativePath),
                "targetName": .string(t.blueprintName), "testKind": .string("xctest-tool hosted"),
                "testLanguage": .string(""), "testRegion": .string(""), "tests": .array(top),
            ]))
        }
        let plan: V = .obj(XCRType("ActionTestPlanRunSummaries"), [
            "summaries": .array([.obj(XCRType("ActionTestPlanRunSummary", "ActionAbstractTestSummary"), [
                "name": .string("Test Scheme Action"), "testableSummaries": .array(testables),
            ])]),
        ])
        return (try store.put(plan), issues)
    }

    func displayName(_ r: TestCaseResult) -> String { r.library == .xctest ? r.name + "()" : r.name }

    // MARK: Destination

    func runDestination() -> V {
        // Builds without a scheme have no run destination: every field empty.
        if session.legacy {
            let device: V = .obj(XCRType("ActionDeviceRecord"), [
                "cpuKind": .string(""), "identifier": .string(""), "isConcreteDevice": .bool(false), "isWireless": .bool(false),
                "modelCode": .string(""), "modelName": .string(""), "modelUTI": .string(""), "name": .string(""),
                "nativeArchitecture": .string(""), "operatingSystemVersion": .string(""), "operatingSystemVersionWithBuildNumber": .string(""),
                "platformRecord": .obj(XCRType("ActionPlatformRecord"), ["identifier": .string(""), "userDescription": .string("")]),
            ])
            return .obj(XCRType("ActionRunDestinationRecord"), [
                "displayName": .string(""), "localComputerRecord": device, "targetArchitecture": .string(""), "targetDeviceRecord": device,
                "targetSDKRecord": .obj(XCRType("ActionSDKRecord"), ["identifier": .string(""), "isInternal": .bool(false), "name": .string(""),
                                                                    "operatingSystemVersion": .string("")]),
            ])
        }
        let host = HostRecord.current
        let device = host.deviceRecord
        var target = device
        var arch = session.runDestination?.targetArchitecture ?? host.architecture
        var name = "My Mac"
        // The generic destination of `archive` ("Any Mac").
        if session.runDestination?.disableOnlyActiveArch == true {
            name = "Any Mac"
            arch = "undefined_arch"
            target = .obj(XCRType("ActionDeviceRecord"), [
                "busSpeedInMHz": .int(0), "cpuCount": .int(0), "cpuKind": .string(""), "cpuSpeedInMHz": .int(0),
                "identifier": .string("dvtdevice-IDEOSXSupportCore.IDEMacPlaceholder-macosx:placeholder"),
                "isConcreteDevice": .bool(false), "isWireless": .bool(false), "logicalCPUCoresPerPackage": .int(0),
                "modelCode": .string("GenericmacOS"), "modelName": .string("GenericmacOS"), "modelUTI": .string("com.apple.device"),
                "name": .string(name), "nativeArchitecture": .string("undefined_arch"), "operatingSystemVersion": .string(""),
                "operatingSystemVersionWithBuildNumber": .string(""), "physicalCPUCoresPerPackage": .int(0),
                "platformRecord": .obj(XCRType("ActionPlatformRecord"), ["identifier": .string("com.apple.platform.macosx"), "userDescription": .string("macOS")]),
                "ramSizeInMegabytes": .int(0),
            ])
        }
        var sdkFields: [String: V?] = [:]
        if let sdk = session.sdk {
            sdkFields = ["identifier": .string(sdk.canonicalName), "isInternal": .bool(false), "name": .string(sdk.displayName),
                         "operatingSystemVersion": .string(sdk.version)]
        }
        return .obj(XCRType("ActionRunDestinationRecord"), [
            "displayName": .string(name),
            "localComputerRecord": device,
            "targetArchitecture": .string(arch),
            "targetDeviceRecord": target,
            "targetSDKRecord": .obj(XCRType("ActionSDKRecord"), sdkFields),
        ])
    }
}

/// The Mac's description for run-destination records.
struct HostRecord {
    var identifier: String
    var modelCode: String
    var modelName: String
    var cpuKind: String
    var logicalCores: Int
    var physicalCores: Int
    var ramMB: Int
    var osVersion: String
    var osBuild: String
    var architecture: String
    var nativeArchitecture: String

    static let current: HostRecord = {
        #if arch(arm64)
        let arch = "arm64", native = "arm64e"
        #else
        let arch = "x86_64", native = "x86_64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = os.patchVersion == 0 ? "\(os.majorVersion).\(os.minorVersion)" : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return HostRecord(identifier: Destinations.macProvisioningUDID() ?? "", modelCode: sysctl("hw.model") ?? "",
                          modelName: Destinations.macModelName() ?? "Mac", cpuKind: sysctl("machdep.cpu.brand_string") ?? "",
                          logicalCores: sysctlInt("hw.logicalcpu"), physicalCores: sysctlInt("hw.physicalcpu"),
                          ramMB: sysctlInt("hw.memsize") / (1024 * 1024), osVersion: version, osBuild: sysctl("kern.osversion") ?? "",
                          architecture: arch, nativeArchitecture: native)
    }()

    var deviceRecord: XCRValue {
        .obj(XCRType("ActionDeviceRecord"), [
            "busSpeedInMHz": .int(0), "cpuCount": .int(1), "cpuKind": .string(cpuKind), "cpuSpeedInMHz": .int(0),
            "identifier": .string(identifier), "isConcreteDevice": .bool(true), "isWireless": .bool(false),
            "logicalCPUCoresPerPackage": .int(logicalCores), "modelCode": .string(modelCode), "modelName": .string(modelName),
            "modelUTI": .string(""), "name": .string("My Mac"), "nativeArchitecture": .string(nativeArchitecture),
            "operatingSystemVersion": .string(osVersion), "operatingSystemVersionWithBuildNumber": .string("\(osVersion) (\(osBuild))"),
            "physicalCPUCoresPerPackage": .int(physicalCores),
            "platformRecord": .obj(XCRType("ActionPlatformRecord"), ["identifier": .string("com.apple.platform.macosx"), "userDescription": .string("macOS")]),
            "ramSizeInMegabytes": .int(ramMB),
        ])
    }

    static func sysctl(_ name: String) -> String? {
        #if os(macOS)
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    static func sysctlInt(_ name: String) -> Int {
        #if os(macOS)
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return 0 }
        return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
        #else
        return 0
        #endif
    }
}

extension ResultBundleSession {
    /// A session for a scheme or legacy run.
    static func make(plan: Plan, path: String, given: String, explicit: Bool, context ctx: XcodebuildContext) -> ResultBundleSession {
        let c = plan.container
        let sdkName = plan.overrides.last { $0.0 == "SDKROOT" }?.1 ?? "macosx"
        let sdk = SDKRegistry(developerDirectory: ctx.developerDirectory ?? "").lookup(sdkName, relativeTo: ctx.cwd)
        let s = ResultBundleSession(path: path, given: given, explicit: explicit, containerPath: c.url.path,
                                    containerLabel: "\(c.name) \(c.kind == .workspace ? "workspace" : "project")",
                                    projectName: c.mainProject?.name ?? c.name, schemeName: plan.scheme?.name,
                                    runDestination: plan.runDestination, sdk: sdk)
        s.legacy = plan.scheme == nil
        s.containerWord = c.kind == .workspace ? "workspace" : "project"
        return s
    }

    func announceIfExplicit(_ console: Console) { if explicit { announce(console) } }

    /// `Writing result bundle at path:` (printed also with `-quiet`).
    func announce(_ console: Console) {
        console.out("Writing result bundle at path:")
        console.out("\t" + given)
        console.out()
    }

    /// Records an action and rewrites the bundle; for explicit bundles of
    /// build actions, prints where (not quiet).
    func record(_ action: Action, quiet: Bool, console: Console, announceWritten: Bool = true) {
        actions.append(action)
        if write(console: console), explicit, announceWritten, !quiet {
            console.out()
            console.out("Result bundle written to path:")
            console.out("\t" + displayPath)
            console.out()
        }
    }

    /// What the bundle records for an action: command, task and title.
    static func names(_ action: BuildAction, scheme: String?, projectName: String, containerWord: String = "project") -> (command: String, task: String, title: String?) {
        guard let s = scheme else { return ("Run", "Build", nil) }
        let projectName = containerWord + " " + projectName
        switch action {
        case .test: return ("Test", "BuildAndAction", "Testing \(projectName) with scheme \(s)")
        case .testWithoutBuilding: return ("Test", "Action", "Testing \(projectName) with scheme \(s)")
        case .buildForTesting: return ("Test", "Build", "Build \"\(s)\"")
        case .archive: return ("Archive", "BuildAndAction", "Archiving \(projectName) with scheme \(s)")
        case .analyze: return ("Analyze", "Build", "Analyze \"\(s)\"")
        case .clean: return ("Run", "Build", "Clean \"\(s)\"")
        case .install: return ("Run", "Build", "Install \"\(s)\"")
        default: return ("Run", "Build", "Build \"\(s)\"")
        }
    }
}

extension XCTestRunFile {
    /// The bundle of a `-xctestrun` run: `-resultBundlePath`, else a
    /// default one in `Logs/Test` of the DerivedData folder that holds the
    /// file (`…/Build/Products/x.xctestrun`). Returns it with the plan name.
    static func resultBundleSession(_ inv: Invocation, file: Contents, xctestrun: String, started: Date,
                                    context ctx: XcodebuildContext) -> (ResultBundleSession, String?)? {
        let products = URL(fileURLWithPath: xctestrun).deletingLastPathComponent()
        let name = file.container ?? ""
        func make(_ path: String, _ given: String, explicit: Bool) -> ResultBundleSession {
            ResultBundleSession(path: path, given: given, explicit: explicit, containerPath: "", containerLabel: "\(name) project",
                                projectName: name, schemeName: file.scheme, runDestination: nil,
                                sdk: SDKRegistry(developerDirectory: ctx.developerDirectory ?? "").lookup("macosx", relativeTo: ctx.cwd))
        }
        if let (path, given) = ResultBundleSession.requestedPath(inv, cwd: ctx.cwd) { return (make(path, given, explicit: true), file.testPlan) }
        guard products.deletingLastPathComponent().lastPathComponent == "Build" else { return nil }
        let arena = Arena(derivedDataPath: "", buildProductsPath: products.path, buildIntermediatesPath: "")
        let p = ResultBundleSession.defaultTestPath(arena: arena, scheme: file.scheme ?? name, date: started)
        return (make(p, p, explicit: false), file.testPlan)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
