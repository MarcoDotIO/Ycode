import Foundation
import YcodeProject
import YcodeWorkspace
import YcodeSubprocess

/// Builds with swift-build (open source) from a PIF that Ycode generates,
/// through the `ycode-swb` helper when it is available (it signs with
/// Ycode's provisioning answers, entitlements included; see
/// `specs/ide/signing.md`), else through swift-build's `swbuild`
/// command-line client, which signs ad hoc without entitlements. See
/// `specs/ide/build-pif.md`. Supports what `PIFGenerator` supports:
/// projects whose targets are command-line tools or static libraries.
/// Supplies the PIF for project and workspace containers, replacing the
/// built-in `PIFGenerator` (e.g. `YcodeXcodebuild.XcodePIFSource`, which uses
/// the reference tool's GUID scheme). Packages always use SwiftPM's PIF.
public protocol PIFSource: Sendable {
    /// The PIF JSON and the names of the targets it describes.
    func pif(for request: BuildRequest) throws -> (data: Data, targets: [String])
    /// The PIF with warnings about the project per target name (for
    /// example a target whose synchronized folders hold no source). The
    /// engine reports the built target's warnings before it builds.
    func pifWithWarnings(for request: BuildRequest) throws -> (data: Data, targets: [String], warnings: [String: [String]])
}

extension PIFSource {
    public func pifWithWarnings(for request: BuildRequest) throws -> (data: Data, targets: [String], warnings: [String: [String]]) {
        let (data, targets) = try pif(for: request)
        return (data, targets, [:])
    }
}

public struct SwiftBuildEngine: BuildEngine {
    public var name: String { "swift-build" }
    /// Path of the `swbuild` executable.
    public var swbuild: String
    /// Where project/workspace PIF comes from; nil = `PIFGenerator`.
    public var pifSource: (any PIFSource)?
    /// The `ycode-swb` helper; nil builds through `swbuild`.
    public var helper: String?

    /// `helper` defaults to the `ycode-swb` found by `locateHelper`.
    public init(swbuild: String, helper: String?? = nil) {
        self.swbuild = swbuild
        self.helper = helper ?? Self.locateHelper(swbuild: swbuild)
    }

    /// `YCODE_SWB`, else `ycode-swb` next to `swbuild` (both are products of
    /// `Tools/ycode-swb`), else `ycode-swb` on PATH.
    public static func locateHelper(swbuild: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        if let p = environment["YCODE_SWB"], fm.isExecutableFile(atPath: p) { return p }
        if let swbuild {
            let sibling = URL(fileURLWithPath: swbuild).deletingLastPathComponent().appendingPathComponent("ycode-swb").path
            if fm.isExecutableFile(atPath: sibling) { return sibling }
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where fm.isExecutableFile(atPath: "\(dir)/ycode-swb") {
            return "\(dir)/ycode-swb"
        }
        return nil
    }

    /// `YCODE_SWBUILD`, else `swbuild` next to the `ycode-swb` helper
    /// (`YCODE_SWB`; both built from the pinned swift-build of
    /// `Tools/ycode-swb`), else `swbuild` on PATH.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let p = environment["YCODE_SWBUILD"], FileManager.default.isExecutableFile(atPath: p) { return p }
        if let helper = environment["YCODE_SWB"] {
            let sibling = URL(fileURLWithPath: helper).deletingLastPathComponent().appendingPathComponent("swbuild").path
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let c = "\(dir)/swbuild"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    /// Settings every `swbuild` request carries.
    /// - The SDK stat cache is off: its tool is not in every toolchain.
    /// - Sign to Run Locally: identity `-` (ad-hoc), with no entitlements
    ///   written into the signature. `swbuild`'s provisioning stub would
    ///   otherwise add an `application-identifier` entitlement, which macOS
    ///   refuses to run without a provisioning profile.
    public static let baseOverrides: [(String, String)] = [
        ("SDK_STAT_CACHE_ENABLE", "NO"), ("CODE_SIGN_IDENTITY", "-"),
        ("ENTITLEMENTS_DESTINATION", ""), ("ENTITLEMENTS_REQUIRED", "NO"),
    ]

    /// Settings every `ycode-swb` request carries: the project's own
    /// signing settings apply (the helper answers provisioning).
    public static let helperOverrides: [(String, String)] = [("SDK_STAT_CACHE_ENABLE", "NO")]

    /// The host architecture (`arm64` or `x86_64`).
    public static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The run destination for a request's destination specifier. My Mac
    /// builds the host architecture; generic (Any Mac) sends none and builds
    /// all. A simulator (`platform=iOS Simulator`, `generic/platform=visionOS
    /// Simulator`, …) is a run destination of that simulator's SDK: swift-build
    /// then builds the targets that support the platform with its SDK, even
    /// when a project's `SDKROOT` names the device SDK (visionos.md §10.21),
    /// while host tools (macro implementations, plug-in tools) still build for
    /// the Mac, which an `SDKROOT` override would not allow
    /// (`build-pif.md` §Package products). A generic simulator destination
    /// builds every architecture.
    static func runDestination(for destination: String?) -> JSONValue? {
        if let sdk = simulatorSDK(for: destination) {
            return .object([
                "platform": .string(sdk), "sdk": .string(sdk),
                "targetArchitecture": .string(hostArchitecture),
                "supportedArchitectures": ["arm64", "x86_64"],
                "disableOnlyActiveArch": .bool(destination?.hasPrefix("generic/") == true),
            ])
        }
        let spec = destination ?? "platform=macOS"
        guard spec.contains("platform=macOS") else { return nil }
        if spec.hasPrefix("generic/") { return nil }
        return .object([
            "platform": "macosx", "sdk": "macosx", "sdkVariant": "macos",
            "targetArchitecture": .string(hostArchitecture),
            "supportedArchitectures": ["arm64", "x86_64"],
            "disableOnlyActiveArch": .bool(false),
        ])
    }

    /// The SDK of a simulator destination (`platform=visionOS Simulator`,
    /// `generic/platform=iOS Simulator`, …); nil for other destinations.
    static func simulatorSDK(for destination: String?) -> String? {
        guard let d = destination, let r = d.range(of: "platform=") else { return nil }
        let platform = d[r.upperBound...].prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
        switch platform {
        case "iOS Simulator": return "iphonesimulator"
        case "visionOS Simulator", "xrOS Simulator": return "xrsimulator"
        case "tvOS Simulator": return "appletvsimulator"
        case "watchOS Simulator": return "watchsimulator"
        default: return nil
        }
    }

    /// Files the engine writes for one request, and the tool's arguments.
    public struct Invocation: Equatable {
        public var pif: Data
        public var parameters: Data
        public var arguments: [String]
        public var derivedData: URL
        /// The `ycode-swb build` request (helper builds only), written next
        /// to the parameters as `build.json`.
        public var helperRequest: Data?
        /// Warnings about the built target the PIF source found.
        public var warnings: [String] = []
    }

    /// Prepares PIF, build parameters and arguments for a request.
    public static func invocation(for request: BuildRequest, pifPath: URL, parametersPath: URL) throws -> Invocation {
        try invocation(for: request, pifPath: pifPath, parametersPath: parametersPath, source: nil)
    }

    /// The `ycode-swb build` request file's path for a parameters path.
    static func helperRequestPath(_ parametersPath: URL) -> URL {
        parametersPath.deletingLastPathComponent().appendingPathComponent("build.json")
    }

    public static func invocation(for request: BuildRequest, pifPath: URL, parametersPath: URL, source: (any PIFSource)?,
                                  helper: Bool = false) throws -> Invocation {
        let pifData: Data
        let target: String
        let baseDir: URL
        var warnings: [String] = []
        switch request.container {
        case .project(let path) where source != nil, .workspace(let path) where source != nil:
            let (data, targets, found) = try source!.pifWithWarnings(for: request)
            target = targets.first { $0 == request.scheme } ?? targets.first ?? ""
            pifData = data
            warnings = request.action == .clean ? [] : found[target] ?? []
            baseDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        case .project(let path):
            let url = URL(fileURLWithPath: path)
            let pif = try PIFGenerator(proj: try PBXProj(contentsOf: url), xcodeprojURL: url).pif()
            let targets = (pif.arrayValue ?? []).filter { $0["type"] == "target" }.compactMap { $0["contents"]?["name"]?.stringValue }
            target = targets.first { $0 == request.scheme } ?? targets.first ?? ""
            pifData = try pif.serialized()
            baseDir = url.deletingLastPathComponent()
        case .package(let dir):
            // SwiftPM (open source) generates the PIF of a package graph,
            // local dependencies included.
            pifData = try packagePIF(directory: URL(fileURLWithPath: dir))
            target = packageTarget(pif: pifData, scheme: request.scheme)
            baseDir = URL(fileURLWithPath: dir)
        case .workspace(let path):
            let url = URL(fileURLWithPath: path)
            let projects = try workspaceProjects(url)
            let pif = try PIFGenerator.workspacePIF(projects: projects, workspaceURL: url)
            let targets = (pif.arrayValue ?? []).filter { $0["type"] == "target" }.compactMap { $0["contents"]?["name"]?.stringValue }
            target = targets.first { $0 == request.scheme } ?? targets.first ?? ""
            pifData = try pif.serialized()
            baseDir = url.deletingLastPathComponent()
        }
        let derived = URL(fileURLWithPath: request.derivedDataPath
            ?? baseDir.appendingPathComponent(".ycode-build").path)
        let configuration = request.configuration ?? "Debug"
        var table: [String: JSONValue] = [:]
        // YCODE_ASSET_COMPILER=ycode: swift-build runs `ycode assets compile` for actool.
        let assets = AssetCompilerHook.overrides(settings: request.settings, directory: derived.appendingPathComponent("YcodeAssetCompiler"))
            + StringsCompilerHook.overrides(settings: request.settings)
        for (k, v) in (helper ? helperOverrides : baseOverrides) + request.settings + assets { table[k] = .string(v) }
        var paramObject: [String: JSONValue] = [
            "configurationName": .string(configuration),
            "overrides": .object(["commandLine": .object(["table": .object(table)])]),
        ]
        if let dest = runDestination(for: request.destination) {
            paramObject["activeRunDestination"] = dest
            paramObject["activeArchitecture"] = .string(hostArchitecture)
        }
        if helper {
            // The build locations `swbuild --derivedDataPath` sets, so the
            // products land where they always have.
            let d = derived.path
            paramObject["action"] = "build"
            paramObject["arenaInfo"] = .object([
                "derivedDataPath": .string(d), "buildProductsPath": .string(d + "/Products"),
                "buildIntermediatesPath": .string(d + "/Intermediates.noindex"), "pchPath": .string(d),
                "indexPCHPath": .string(d), "indexDataStoreFolderPath": .string(d), "indexEnableDataStore": .bool(false),
            ])
        }
        let params: JSONValue = .object(paramObject)
        if helper {
            // The request `swbuild build` makes, with Ycode's signing answers.
            let file: JSONValue = .object([
                "pif": .string(pifPath.path), "parameters": params, "targetNames": .array([.string(target)]),
                "parallel": .bool(true), "implicitDependencies": .bool(false), "hideShellScriptEnvironment": .bool(true),
                "command": .string(request.action == .clean ? "cleanBuildFolder" : "build"), "locationStyle": "regular",
                "debuggable": .bool(true),
            ])
            let requestPath = helperRequestPath(parametersPath)
            return Invocation(pif: pifData, parameters: try params.serialized(pretty: false), arguments: ["build", requestPath.path],
                              derivedData: derived, helperRequest: try file.serialized(pretty: false), warnings: warnings)
        }
        let action = request.action == .clean ? "clean" : "build"
        let args = [action, pifPath.path, "--target", target, "--buildParametersFile", parametersPath.path,
                    "--derivedDataPath", derived.path]
        return Invocation(pif: pifData, parameters: try params.serialized(pretty: false), arguments: args, derivedData: derived,
                          warnings: warnings)
    }

    /// The `.xcodeproj` files a workspace lists (`contents.xcworkspacedata`
    /// `FileRef` locations relative to the workspace's folder).
    static func workspaceProjects(_ url: URL) throws -> [(PBXProj, URL)] {
        let paths = try Workspace(contentsOf: url.path).projectPaths
        guard !paths.isEmpty else { throw PIFGenerator.GenerationError.unsupported("a workspace without projects") }
        return try paths.map { p in
            let u = URL(fileURLWithPath: p)
            return (try PBXProj(contentsOf: u), u)
        }
    }

    /// Whether this engine can build the request's container: packages,
    /// and projects or workspaces whose targets the PIF generator supports.
    public static func supports(_ request: BuildRequest) -> Bool {
        switch request.container {
        case .package: return true
        case .workspace(let path):
            let url = URL(fileURLWithPath: path)
            guard let projects = try? workspaceProjects(url) else { return false }
            return (try? PIFGenerator.workspacePIF(projects: projects, workspaceURL: url)) != nil
        case .project(let path):
            let url = URL(fileURLWithPath: path)
            guard let proj = try? PBXProj(contentsOf: url) else { return false }
            return (try? PIFGenerator(proj: proj, xcodeprojURL: url).pif()) != nil
        }
    }

    /// `swift package dump-pif` in `directory`.
    public static func packagePIF(directory: URL, swift: String = "/usr/bin/env") throws -> Data {
        MainThreadGuard.blockingCall("swift package dump-pif")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: swift)
        p.arguments = (swift.hasSuffix("env") ? ["swift"] : []) + ["package", "dump-pif"]
        p.currentDirectoryURL = directory
        let out = try SpawnPipe(childReads: false), err = try SpawnPipe(childReads: false)
        p.standardOutput = out.childEnd
        p.standardError = err.childEnd
        try p.runWithSignalsUnblocked(closingChildEndsOf: out, err)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw PIFGenerator.GenerationError.unsupported("swift package dump-pif failed: \(String(decoding: errors, as: UTF8.self))")
        }
        return data
    }

    /// The target to build in a package PIF: the product named like the
    /// scheme (`<name>-product`), else the scheme as a target, else all
    /// non-test targets.
    public static func packageTarget(pif: Data, scheme: String?) -> String {
        let list = (try? JSONSerialization.jsonObject(with: pif) as? [[String: Any]]) ?? []
        let names = Set(list.filter { $0["type"] as? String == "target" }
            .compactMap { ($0["contents"] as? [String: Any])?["name"] as? String })
        if let s = scheme {
            if names.contains("\(s)-product") { return "\(s)-product" }
            if names.contains(s) { return s }
        }
        return "AllExcludingTests"
    }

    /// The built executable: `<derived data>/Products/<configuration>/<product>`,
    /// inside `Contents/MacOS` for an application bundle.
    public func executablePath(for request: BuildRequest) -> String? {
        if case .package(let dir) = request.container {
            // Package executables land in Products/<config>/<product name>.
            guard let name = request.scheme else { return nil }
            let derived = request.derivedDataPath ?? URL(fileURLWithPath: dir).appendingPathComponent(".ycode-build").path
            return "\(derived)/Products/\(request.configuration ?? "Debug")/\(name)"
        }
        let candidates: [(PBXProj, String)]
        let baseDir: String
        switch request.container {
        case .project(let path):
            guard let proj = try? PBXProj(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            candidates = [(proj, path)]
            baseDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        case .workspace(let path):
            guard let list = try? Self.workspaceProjects(URL(fileURLWithPath: path)) else { return nil }
            candidates = list.map { ($0.0, $0.1.path) }
            baseDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        case .package:
            return nil
        }
        // The project whose target matches the scheme, else the first.
        let (proj, path) = candidates.first { c in c.0.targets.contains { $0.string("name") == request.scheme } } ?? candidates[0]
        _ = path
        let targets = proj.targets.filter { PIFGenerator.supportedProductTypes.contains($0.string("productType") ?? "") }
        guard let t = targets.first(where: { $0.string("name") == request.scheme }) ?? targets.first,
              ["com.apple.product-type.application", "com.apple.product-type.tool"].contains(t.string("productType") ?? ""),
              let product = t.string("productReference").flatMap({ proj[$0]?.string("path") }) else { return nil }
        let derived = request.derivedDataPath ?? baseDir + "/.ycode-build"
        let dir = "\(derived)/Products/\(request.configuration ?? "Debug")/\(product)"
        if product.hasSuffix(".app") { return "\(dir)/Contents/MacOS/\((product as NSString).deletingPathExtension)" }
        return dir
    }

    public func start(_ request: BuildRequest) -> BuildOperation {
        let (stream, continuation) = AsyncStream<BuildEvent>.makeStream()
        let process = Process()
        let cancelled = Flag()
        let tool = helper ?? swbuild
        let viaHelper = helper != nil
        let source = pifSource
        Thread {
            func fail(_ message: String) {
                continuation.yield(.output("ycode: \(message)"))
                continuation.yield(.issue(Diagnostic(severity: .error, message: message)))
                continuation.yield(.finished(BuildResult(status: .failed, exitCode: -1,
                                                         issues: [Diagnostic(severity: .error, message: message)])))
                continuation.finish()
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-swiftbuild-\(UUID().uuidString)")
            let inv: Invocation
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                inv = try Self.invocation(for: request, pifPath: work.appendingPathComponent("workspace.pif.json"),
                                          parametersPath: work.appendingPathComponent("parameters.json"), source: source, helper: viaHelper)
                try inv.pif.write(to: work.appendingPathComponent("workspace.pif.json"))
                try inv.parameters.write(to: work.appendingPathComponent("parameters.json"))
                try inv.helperRequest?.write(to: Self.helperRequestPath(work.appendingPathComponent("parameters.json")))
            } catch {
                return fail("\(error)")
            }
            defer { try? FileManager.default.removeItem(at: work) }
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = inv.arguments
            // YCODE_STRINGS_COMPILER=ycode: swift-build finds Ycode's `xcstringstool` first.
            process.environment = StringsCompilerHook.environment(settings: request.settings,
                                                                  directory: inv.derivedData.appendingPathComponent("YcodeStringsCompiler"))
            let pipe: SpawnPipe
            do { pipe = try SpawnPipe(childReads: false) } catch { return fail("cannot run \(tool): \(error)") }
            process.standardOutput = pipe.childEnd
            process.standardError = pipe.childEnd
            process.standardInput = FileHandle.nullDevice
            let projectWarnings = inv.warnings.map { Diagnostic(severity: .warning, message: $0) }
            for w in projectWarnings {
                continuation.yield(.output("warning: \(w.message)"))
                continuation.yield(.issue(w))
            }
            do { try process.runWithSignalsUnblocked(closingChildEndsOf: pipe) } catch { return fail("cannot run \(tool): \(error)") }
            if !viaHelper {
                continuation.yield(.output("ycode: the ycode-swb helper was not found (YCODE_SWB); signing to run locally without entitlements"))
            }

            var lines = LineBuffer()
            var reader = SwiftBuildMessageReader()
            func handle(_ line: String) {
                for e in reader.feed(line) { continuation.yield(e) }
            }
            let fh = pipe.fileHandleForReading
            while true {
                let d = fh.availableData
                if d.isEmpty { break }
                lines.append(d).forEach(handle)
            }
            if let last = lines.flush() { handle(last) }
            process.waitUntilExit()
            let code = process.terminationStatus
            let ok = code == 0 && reader.completed != false
            let status: BuildStatus = cancelled.value ? .cancelled : (ok ? .succeeded : .failed)
            continuation.yield(.finished(BuildResult(status: status, exitCode: code, issues: projectWarnings + reader.issues)))
            continuation.finish()
        }.start()
        return BuildOperation(events: stream) {
            cancelled.set()
            // As Control-C: swift-build and the compilers it started.
            if process.isRunning { ChildSignals.send(SIGINT, to: process.processIdentifier) }
        }
    }
}

/// Reads swbuild's message stream: each message is a decimal byte count on
/// its own line followed by one JSON object. Other lines pass through as
/// output.
public struct SwiftBuildMessageReader {
    public private(set) var issues: [Diagnostic] = []
    /// The `buildCompleted` result, once seen (true = ok).
    public private(set) var completed: Bool?
    /// Task counts for the activity view: tasks finished (completed or up
    /// to date) and tasks known (started or up to date, or the larger
    /// total of swift-build's own "Building n of m tasks" progress text).
    public private(set) var tasksDone = 0
    public private(set) var tasksPlanned = 0
    private var startedIDs = Set<Int>()
    public init() {}

    /// "Building 3 of 10 tasks" → 10 (swift-build's progress text).
    static func plannedTotal(inProgressText text: String) -> Int? {
        let words = text.split(separator: " ")
        guard let i = words.firstIndex(of: "of"), i + 1 < words.count, words.last == "tasks" else { return nil }
        return Int(words[i + 1])
    }

    private var progress: BuildEvent { .progress(done: tasksDone, total: max(tasksPlanned, tasksDone)) }

    public mutating func feed(_ line: String) -> [BuildEvent] {
        if Int(line) != nil { return [] } // length prefix
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = msg["kind"] as? String else {
            return line.isEmpty ? [] : [.output(line)]
        }
        switch kind {
        case "planningOperationStarted":
            return [.planning]
        case "taskStarted":
            if let id = msg["id"] as? Int { startedIDs.insert(id) }
            tasksPlanned += 1
            return [progress] + ((msg["executionDescription"] as? String).map { [.activity($0)] } ?? [])
        case "taskComplete":
            if let id = msg["id"] as? Int, startedIDs.remove(id) == nil { return [] }
            tasksDone += 1
            return [progress]
        case "taskUpToDate":
            tasksDone += 1
            tasksPlanned += 1
            return [progress]
        case "didUpdateProgress":
            guard let total = (msg["message"] as? String).flatMap(Self.plannedTotal(inProgressText:)), total > tasksPlanned else { return [] }
            tasksPlanned = total
            return [progress]
        case "output":
            guard let b64 = msg["data"] as? String, let d = Data(base64Encoded: b64) else { return [] }
            return String(decoding: d, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast(String(decoding: d, as: UTF8.self).hasSuffix("\n") ? 1 : 0).map { .output(String($0)) }
        case "error", "warning", "note", "remark":
            let d = Self.diagnostic(msg)
            // One compile per architecture repeats the same issue; keep the first.
            guard !issues.contains(d) else { return [] }
            issues.append(d)
            return [.issue(d)]
        case "buildCompleted":
            completed = (msg["result"] as? String) == "ok"
            return [.output("** BUILD \(completed == true ? "SUCCEEDED" : "FAILED") **")]
        default:
            return []
        }
    }

    static func diagnostic(_ m: [String: Any]) -> Diagnostic {
        let severity = Diagnostic.Severity(rawValue: m["kind"] as? String ?? "") ?? .error
        var location: Diagnostic.Location?
        if let loc = m["location"] as? [String: Any], let path = loc["path"] as? String {
            location = .init(file: path, line: loc["line"] as? Int ?? 0, column: loc["column"] as? Int ?? 0)
        }
        let fixIts: [Diagnostic.FixIt] = (m["fixIts"] as? [[String: Any]] ?? []).compactMap { f in
            guard let r = f["sourceRange"] as? [String: Any], let path = r["path"] as? String else { return nil }
            return .init(file: path,
                         start: .init(file: path, line: r["startLine"] as? Int ?? 0, column: r["startColumn"] as? Int ?? 0),
                         end: .init(file: path, line: r["endLine"] as? Int ?? 0, column: r["endColumn"] as? Int ?? 0),
                         replacement: f["textToInsert"] as? String ?? "")
        }
        let notes = (m["childDiagnostics"] as? [[String: Any]] ?? []).map(diagnostic)
        return Diagnostic(severity: severity, message: m["message"] as? String ?? "", location: location, notes: notes, fixIts: fixIts)
    }
}
