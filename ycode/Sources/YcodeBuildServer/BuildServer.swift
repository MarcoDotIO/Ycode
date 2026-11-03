import Foundation
import YcodeDebug

/// A Build Server Protocol server over a byte channel (JSON-RPC 2.0 with
/// `Content-Length` framing), answering the requests sourcekit-lsp sends
/// to an external build server. See `specs/ide/language.md` §Build server.
public final class BuildServer: @unchecked Sendable {
    public static let version = "0.1"
    public static let bspVersion = "2.2.0"

    public let model: IndexModel
    public let preparer: ModulePreparer
    private let send: @Sendable (Data) -> Void
    private let log: @Sendable (String) -> Void
    /// State requests run here, in order.
    private let queue = DispatchQueue(label: "ycode.bsp.state")
    /// Preparation runs here so that it does not hold up other requests.
    private let prepareQueue = DispatchQueue(label: "ycode.bsp.prepare")
    private var decoder = DAPFraming.Decoder()
    private let inputLock = NSLock()
    private var initialized = false
    private var timer: DispatchSourceTimer?
    /// Set by `build/exit`.
    public private(set) var exited = false
    public var onExit: (@Sendable () -> Void)?

    public init(model: IndexModel, preparer: ModulePreparer? = nil, send: @escaping @Sendable (Data) -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.model = model
        self.preparer = preparer ?? ModulePreparer(model: model, log: log)
        self.send = send
        self.log = log
    }

    /// Feeds incoming bytes; complete messages are handled.
    public func receive(_ data: Data) {
        inputLock.lock()
        let bodies = decoder.append(data)
        inputLock.unlock()
        for body in bodies {
            guard let message = try? JSON.decode(body) else { continue }
            handle(message)
        }
    }

    /// Checks the watched files every `interval` seconds and reports
    /// changed targets (`buildTarget/didChange`).
    public func startWatching(interval: TimeInterval = 2) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.reloadAndNotify() }
        t.resume()
        timer = t
    }

    public func stopWatching() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Dispatch

    func handle(_ message: JSON) {
        guard let method = message["method"]?.string else { return } // responses to us: none expected
        let params = message["params"] ?? .null
        guard let id = message["id"] else { return notification(method, params) }
        switch method {
        case "buildTarget/prepare":
            prepareQueue.async { [self] in
                let ids = (params["targets"]?.array ?? []).compactMap { $0["uri"]?.string }
                let steps = preparer.prepare(ids)
                for s in steps where s.ran && !s.succeeded {
                    notify("build/logMessage", ["type": 2, "message": .string("Preparing \(s.target) failed:\n\(s.output)")])
                }
                reply(id, .null)
            }
        default:
            queue.async { [self] in
                do { reply(id, try request(method, params)) } catch let e as RequestError {
                    replyError(id, code: e.code, message: e.message)
                } catch {
                    replyError(id, code: -32603, message: "\(error)")
                }
            }
        }
    }

    struct RequestError: Error {
        var code: Int
        var message: String
    }

    func request(_ method: String, _ params: JSON) throws -> JSON {
        switch method {
        case "build/initialize": return initializeResult()
        case "workspace/buildTargets": return ["targets": .array(model.graph.targets.map(targetJSON))]
        case "buildTarget/sources":
            let ids = (params["targets"]?.array ?? []).compactMap { $0["uri"]?.string }
            let graph = model.graph
            return ["items": .array(ids.compactMap { graph.target(id: $0) }.map(sourcesJSON))]
        case "textDocument/sourceKitOptions":
            guard let uri = params["textDocument"]?["uri"]?.string, let path = Self.path(uri) else { return .null }
            let language = params["language"]?.string.flatMap(SourceLanguage.init(rawValue:))
            guard let r = model.arguments(for: path, targetID: params["target"]?["uri"]?.string, language: language) else { return .null }
            return ["compilerArguments": .array(r.arguments.map(JSON.string)), "workingDirectory": .string(r.workingDirectory)]
        case "workspace/waitForBuildSystemUpdates":
            reloadAndNotify()
            return .null
        case "build/shutdown":
            stopWatching()
            return .null
        default:
            throw RequestError(code: -32601, message: "method not found: \(method)")
        }
    }

    func notification(_ method: String, _ params: JSON) {
        switch method {
        case "build/initialized":
            queue.async { self.initialized = true }
        case "workspace/didChangeWatchedFiles":
            queue.async { self.reloadAndNotify() }
        case "build/exit":
            stopWatching()
            exited = true
            onExit?()
        default:
            break // $/cancelRequest and others
        }
    }

    /// Must run on `queue`.
    private func reloadAndNotify() {
        let changed = model.reloadIfChanged()
        guard !changed.isEmpty else { return }
        log("Build targets changed: \(changed.count)")
        if initialized {
            notify("buildTarget/didChange", ["changes": .array(changed.map { ["target": ["uri": .string($0)], "kind": 2] })])
        }
    }

    // MARK: Results

    func initializeResult() -> JSON {
        let ctx = model.context
        let watchers: [JSON] = ["**/*.pbxproj", "**/*.xcconfig", "**/contents.xcworkspacedata", "**/*.xcscheme"].map { ["globPattern": .string($0)] }
        return [
            "displayName": "Ycode",
            "version": .string(Self.version),
            "bspVersion": .string(Self.bspVersion),
            "capabilities": [
                "languageIds": .array(SourceLanguage.allCases.map { .string($0.rawValue) }),
                "buildTargetChangedProvider": true,
            ],
            "dataKind": "sourceKit",
            "data": [
                "indexDatabasePath": .string(ctx.indexDatabasePath),
                "indexStorePath": .string(ctx.indexStorePath),
                "prepareProvider": true,
                "sourceKitOptionsProvider": true,
                "watchers": .array(watchers),
            ],
        ]
    }

    func targetJSON(_ t: BuildGraph.Target) -> JSON {
        let tag = t.isTest ? "test" : t.isApplication ? "application" : "library"
        return [
            "id": ["uri": .string(t.id)],
            "displayName": .string(t.name),
            "baseDirectory": .string(URL(fileURLWithPath: model.graph.project(of: t).directory.path, isDirectory: true).absoluteString),
            "tags": [.string(tag)],
            "languageIds": .array(t.languages.map { .string($0.rawValue) }),
            "dependencies": .array(t.dependencies.map { ["uri": .string($0)] }),
            "capabilities": ["canCompile": true],
            "dataKind": "sourceKit",
            "data": [:],
        ]
    }

    func sourcesJSON(_ t: BuildGraph.Target) -> JSON {
        var items: [JSON] = t.sources.map { s in
            ["uri": .string(URL(fileURLWithPath: s.path).absoluteString), "kind": 1, "generated": false, "dataKind": "sourceKit",
             "data": ["language": .string(s.language.rawValue), "kind": "source"]]
        }
        let headerLanguage: SourceLanguage = t.sources.contains { $0.language == .objectiveCpp } ? .objectiveCpp
            : t.sources.contains { $0.language == .cpp } ? .cpp
            : t.sources.contains { $0.language == .objectiveC } || t.hasSwift ? .objectiveC : .c
        items += t.headers.map { h in
            ["uri": .string(URL(fileURLWithPath: h.path).absoluteString), "kind": 1, "generated": false, "dataKind": "sourceKit",
             "data": ["language": .string(headerLanguage.rawValue), "kind": "header"]]
        }
        return ["target": ["uri": .string(t.id)], "sources": .array(items)]
    }

    // MARK: Output

    func reply(_ id: JSON, _ result: JSON) {
        send(DAPFraming.frame(JSON.object(["jsonrpc": "2.0", "id": id, "result": result]).encoded()))
    }

    func replyError(_ id: JSON, code: Int, message: String) {
        send(DAPFraming.frame(JSON.object(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]).encoded()))
    }

    func notify(_ method: String, _ params: JSON) {
        send(DAPFraming.frame(JSON.object(["jsonrpc": "2.0", "method": .string(method), "params": params]).encoded()))
    }

    /// The file path of a `file:` URI.
    static func path(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }
}
