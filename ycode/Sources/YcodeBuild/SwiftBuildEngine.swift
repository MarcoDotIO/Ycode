import Foundation
import YcodeProject
import YcodeWorkspace
import YcodeSubprocess

/// Builds with swift-build (open source) from a PIF that Ycode generates,
/// by running its `swbuild` command-line client. See
/// `specs/ide/build-pif.md`. Supports what `PIFGenerator` supports:
/// projects whose targets are command-line tools or static libraries.
/// Supplies the PIF for project and workspace containers, replacing the
/// built-in `PIFGenerator` (e.g. `YcodeXcodebuild.XcodePIFSource`, which uses
/// the reference tool's GUID scheme). Packages always use SwiftPM's PIF.
public protocol PIFSource: Sendable {
    /// The PIF JSON and the names of the targets it describes.
    func pif(for request: BuildRequest) throws -> (data: Data, targets: [String])
}

public struct SwiftBuildEngine: BuildEngine {
    public var name: String { "swift-build" }
    /// Path of the `swbuild` executable.
    public var swbuild: String
    /// Where project/workspace PIF comes from; nil = `PIFGenerator`.
    public var pifSource: (any PIFSource)?

    public init(swbuild: String) { self.swbuild = swbuild }

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

    /// Settings every request carries.
    /// - The SDK stat cache is off: its tool is not in every toolchain.
    /// - Sign to Run Locally: identity `-` (ad-hoc), with no entitlements
    ///   written into the signature. `swbuild`'s provisioning stub would
    ///   otherwise add an `application-identifier` entitlement, which macOS
    ///   refuses to run without a provisioning profile.
    public static let baseOverrides: [(String, String)] = [
        ("SDK_STAT_CACHE_ENABLE", "NO"), ("CODE_SIGN_IDENTITY", "-"),
        ("ENTITLEMENTS_DESTINATION", ""), ("ENTITLEMENTS_REQUIRED", "NO"),
    ]

    /// The host architecture (`arm64` or `x86_64`).
    public static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The run destination for a request's destination specifier. Only the
    /// Mac is supported: My Mac builds the host architecture; generic
    /// (Any Mac) builds all.
    static func runDestination(for destination: String?) -> JSONValue? {
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

    /// Files the engine writes for one request, and the swbuild arguments.
    public struct Invocation: Equatable {
        public var pif: Data
        public var parameters: Data
        public var arguments: [String]
        public var derivedData: URL
    }

    /// Prepares PIF, build parameters and arguments for a request.
    public static func invocation(for request: BuildRequest, pifPath: URL, parametersPath: URL) throws -> Invocation {
        try invocation(for: request, pifPath: pifPath, parametersPath: parametersPath, source: nil)
    }

    public static func invocation(for request: BuildRequest, pifPath: URL, parametersPath: URL, source: (any PIFSource)?) throws -> Invocation {
        let pifData: Data
        let target: String
        let baseDir: URL
        switch request.container {
        case .project(let path) where source != nil, .workspace(let path) where source != nil:
            let (data, targets) = try source!.pif(for: request)
            target = targets.first { $0 == request.scheme } ?? targets.first ?? ""
            pifData = data
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
        let configuration = request.configuration ?? "Debug"
        var table: [String: JSONValue] = [:]
        for (k, v) in baseOverrides + request.settings { table[k] = .string(v) }
        var paramObject: [String: JSONValue] = [
            "configurationName": .string(configuration),
            "overrides": .object(["commandLine": .object(["table": .object(table)])]),
        ]
        if let dest = runDestination(for: request.destination) {
            paramObject["activeRunDestination"] = dest
            paramObject["activeArchitecture"] = .string(hostArchitecture)
        }
        let params: JSONValue = .object(paramObject)
        let derived = URL(fileURLWithPath: request.derivedDataPath
            ?? baseDir.appendingPathComponent(".ycode-build").path)
        let action = request.action == .clean ? "clean" : "build"
        let args = [action, pifPath.path, "--target", target, "--buildParametersFile", parametersPath.path,
                    "--derivedDataPath", derived.path]
        return Invocation(pif: pifData, parameters: try params.serialized(pretty: false), arguments: args, derivedData: derived)
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
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
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
        let tool = swbuild
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
                                          parametersPath: work.appendingPathComponent("parameters.json"), source: source)
                try inv.pif.write(to: work.appendingPathComponent("workspace.pif.json"))
                try inv.parameters.write(to: work.appendingPathComponent("parameters.json"))
            } catch {
                return fail("\(error)")
            }
            defer { try? FileManager.default.removeItem(at: work) }
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = inv.arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return fail("cannot run \(tool): \(error)") }

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
            continuation.yield(.finished(BuildResult(status: status, exitCode: code, issues: reader.issues)))
            continuation.finish()
        }.start()
        return BuildOperation(events: stream) {
            cancelled.set()
            if process.isRunning { process.interrupt() }
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
    public init() {}

    public mutating func feed(_ line: String) -> [BuildEvent] {
        if Int(line) != nil { return [] } // length prefix
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = msg["kind"] as? String else {
            return line.isEmpty ? [] : [.output(line)]
        }
        switch kind {
        case "taskStarted":
            return (msg["executionDescription"] as? String).map { [.activity($0)] } ?? []
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
