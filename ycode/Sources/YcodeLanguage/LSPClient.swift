import Foundation
import YcodeDebug
import YcodeSubprocess

/// Language Server Protocol client (JSON-RPC 2.0 over the same
/// `Content-Length` framing DAP uses). The first server is sourcekit-lsp.
/// See `specs/ide/language.md`.
public final class LSPClient: @unchecked Sendable {
    public struct ResponseError: Error, Equatable, CustomStringConvertible, Sendable {
        public var method: String
        public var code: Int
        public var message: String
        public var description: String { "\(method): \(message) (\(code))" }
    }

    /// A notification from the server (`textDocument/publishDiagnostics`,
    /// `window/logMessage`, …).
    public struct Notification: Equatable, Sendable {
        public var method: String
        public var params: JSON
    }

    public let notifications: AsyncStream<Notification>
    private let sink: AsyncStream<Notification>.Continuation
    private let transport: DAPTransport
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: (String, CheckedContinuation<JSON, Error>)] = [:]
    private var decoder = DAPFraming.Decoder()
    private var closed = false
    public private(set) var capabilities: JSON = [:]

    public init(transport: DAPTransport) throws {
        self.transport = transport
        (notifications, sink) = AsyncStream<Notification>.makeStream()
        try transport.start { [weak self] data in self?.receive(data) }
    }

    // MARK: JSON-RPC

    @discardableResult
    public func request(_ method: String, _ params: JSON? = nil) async throws -> JSON {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                c.resume(throwing: ResponseError(method: method, code: -32099, message: "server closed"))
                return
            }
            nextID += 1
            let id = nextID
            pending[id] = (method, c)
            lock.unlock()
            var msg: [String: JSON] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
            if let params { msg["params"] = params }
            transport.send(DAPFraming.frame(JSON.object(msg).encoded()))
        }
    }

    public func notify(_ method: String, _ params: JSON? = nil) {
        var msg: [String: JSON] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { msg["params"] = params }
        transport.send(DAPFraming.frame(JSON.object(msg).encoded()))
    }

    private func receive(_ data: Data?) {
        guard let data else { return shutDown() }
        lock.lock()
        let bodies = decoder.append(data)
        lock.unlock()
        for body in bodies {
            guard let msg = try? JSON.decode(body) else { continue }
            let method = msg["method"]?.string
            if let method, let id = msg["id"] {
                // A request from the server: answer so it does not wait.
                // Edits the server asks for are applied by the client's
                // owner, which listens for this method among notifications.
                let result: JSON
                switch method {
                case "workspace/configuration": result = .array((msg["params"]?["items"]?.array ?? []).map { _ in .null })
                case "workspace/applyEdit":
                    sink.yield(Notification(method: method, params: msg["params"] ?? .null))
                    result = ["applied": true]
                default: result = .null
                }
                transport.send(DAPFraming.frame(JSON.object(["jsonrpc": "2.0", "id": id, "result": result]).encoded()))
            } else if let method {
                sink.yield(Notification(method: method, params: msg["params"] ?? .null))
            } else if let id = msg["id"]?.int {
                lock.lock()
                let waiter = pending.removeValue(forKey: id)
                lock.unlock()
                guard let (method, c) = waiter else { continue }
                if let e = msg["error"] {
                    c.resume(throwing: ResponseError(method: method, code: e["code"]?.int ?? 0, message: e["message"]?.string ?? ""))
                } else {
                    c.resume(returning: msg["result"] ?? .null)
                }
            }
        }
    }

    private func shutDown() {
        lock.lock()
        closed = true
        let waiting = pending
        pending = [:]
        lock.unlock()
        for (_, (m, c)) in waiting { c.resume(throwing: ResponseError(method: m, code: -32099, message: "server closed")) }
        sink.finish()
    }

    public func close() { transport.close() }

    // MARK: Lifecycle

    @discardableResult
    public func initialize(root: URL) async throws -> JSON {
        let result = try await request("initialize", [
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(root.absoluteString),
            "workspaceFolders": [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]],
            "clientInfo": ["name": "Ycode"],
            "capabilities": [
                "textDocument": .object([
                    "synchronization": ["didSave": true],
                    "completion": ["completionItem": ["snippetSupport": true]],
                    "definition": ["linkSupport": false],
                    // codeActionsInline: sourcekit-lsp attaches fix-its to diagnostics.
                    "publishDiagnostics": ["relatedInformation": true, "codeActionsInline": true],
                ].merging(Self.refactoringCapabilities) { a, _ in a }),
                "workspace": ["configuration": true, "applyEdit": true, "workspaceEdit": ["documentChanges": true]],
            ],
        ])
        lock.withLock { capabilities = result["capabilities"] ?? [:] }
        notify("initialized", [:])
        return result
    }

    public func shutdown() async {
        _ = try? await request("shutdown")
        notify("exit")
        close()
    }

    // MARK: Documents

    public static func languageID(for url: URL) -> String {
        switch url.pathExtension {
        case "swift": "swift"
        case "m": "objective-c"
        case "mm": "objective-cpp"
        case "cpp", "cc", "cxx", "hpp": "cpp"
        default: "c"
        }
    }

    public func didOpen(_ url: URL, text: String, version: Int = 1) {
        notify("textDocument/didOpen", ["textDocument": [
            "uri": .string(url.absoluteString), "languageId": .string(Self.languageID(for: url)),
            "version": .number(Double(version)), "text": .string(text),
        ]])
    }

    /// Sends the whole new text (full synchronization).
    public func didChange(_ url: URL, text: String, version: Int) {
        notify("textDocument/didChange", [
            "textDocument": ["uri": .string(url.absoluteString), "version": .number(Double(version))],
            "contentChanges": [["text": .string(text)]],
        ])
    }

    public func didSave(_ url: URL) { notify("textDocument/didSave", ["textDocument": ["uri": .string(url.absoluteString)]]) }
    public func didClose(_ url: URL) { notify("textDocument/didClose", ["textDocument": ["uri": .string(url.absoluteString)]]) }

    static func position(_ url: URL, _ p: Position) -> JSON {
        ["textDocument": ["uri": .string(url.absoluteString)],
         "position": ["line": .number(Double(p.line)), "character": .number(Double(p.character))]]
    }

    public func completion(_ url: URL, at p: Position) async throws -> [CompletionItem] {
        let r = try await request("textDocument/completion", Self.position(url, p))
        return (r.array ?? r["items"]?.array ?? []).map(CompletionItem.init)
    }

    /// `textDocument/hover`: the documentation and declaration at a
    /// position, as plain or Markdown text (nil when there is none).
    public func hover(_ url: URL, at p: Position) async throws -> String? {
        let r = try await request("textDocument/hover", Self.position(url, p))
        return Self.hoverText(r["contents"])
    }

    /// Hover contents: MarkupContent, a MarkedString, or an array of them.
    static func hoverText(_ c: JSON?) -> String? {
        guard let c else { return nil }
        if let s = c.string { return s.isEmpty ? nil : s }
        if let v = c["value"]?.string { return v.isEmpty ? nil : v }
        if let a = c.array {
            let parts = a.compactMap { hoverText($0) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        return nil
    }

    public func definition(_ url: URL, at p: Position) async throws -> [Location] {
        let r = try await request("textDocument/definition", Self.position(url, p))
        let list = r.array ?? (r == .null ? [] : [r])
        return list.compactMap(Location.init)
    }
}

// MARK: Model

/// 0-based line and UTF-16 character offset.
public struct Position: Equatable, Sendable, Hashable {
    public var line: Int
    public var character: Int
    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
    init(_ j: JSON?) {
        line = j?["line"]?.int ?? 0
        character = j?["character"]?.int ?? 0
    }
}

public struct Location: Equatable, Sendable {
    public var url: URL
    public var start: Position
    public var end: Position
    init?(_ j: JSON) {
        // Location or LocationLink.
        guard let uri = (j["uri"] ?? j["targetUri"])?.string, let url = URL(string: uri) else { return nil }
        let range = j["range"] ?? j["targetSelectionRange"]
        self.url = url
        start = Position(range?["start"])
        end = Position(range?["end"])
    }
}

public struct CompletionItem: Equatable, Sendable {
    public var label: String
    public var insertText: String
    public var detail: String?
    /// Documentation text (plain or the value of MarkupContent).
    public var documentation: String?
    public var kind: Int?
    /// The range the edit replaces, when the server gives one.
    public var replaceStart: Position?
    /// `insertTextFormat` 2: `insertText` is an LSP snippet (`${1:x}` stops).
    public var isSnippet = false
    init(_ j: JSON) {
        isSnippet = j["insertTextFormat"]?.int == 2
        label = j["label"]?.string ?? ""
        let edit = j["textEdit"]
        insertText = edit?["newText"]?.string ?? j["insertText"]?.string ?? label
        replaceStart = (edit?["range"] ?? edit?["replace"]).map { Position($0["start"]) }
        detail = j["detail"]?.string
        documentation = j["documentation"]?.string ?? j["documentation"]?["value"]?.string
        kind = j["kind"]?.int
    }
    public init(label: String, insertText: String, detail: String? = nil, kind: Int? = nil) {
        self.label = label
        self.insertText = insertText
        self.detail = detail
        self.documentation = nil
        self.kind = kind
    }
}

public struct LSPDiagnostic: Equatable, Sendable {
    public var start: Position
    public var end: Position
    /// 1 error, 2 warning, 3 information, 4 hint.
    public var severity: Int
    public var message: String
    /// The diagnostic as sent (passed back in code-action requests).
    public var raw: JSON = .null
    /// Fix-its sent inline (`codeActions`, a sourcekit-lsp extension).
    public var fixIts: [CodeAction] = []
    public init(_ j: JSON) {
        raw = j
        fixIts = (j["codeActions"]?.array ?? []).compactMap(CodeAction.init)
        start = Position(j["range"]?["start"])
        end = Position(j["range"]?["end"])
        severity = j["severity"]?.int ?? 1
        message = j["message"]?.string ?? ""
    }

    /// Diagnostics of one `textDocument/publishDiagnostics` notification.
    public static func published(_ params: JSON) -> (url: URL, diagnostics: [LSPDiagnostic])? {
        guard let uri = params["uri"]?.string, let url = URL(string: uri) else { return nil }
        return (url, (params["diagnostics"]?.array ?? []).map(LSPDiagnostic.init))
    }
}

/// Finds sourcekit-lsp: `YCODE_SOURCEKIT_LSP`, `xcrun -f sourcekit-lsp`, PATH.
public enum SourceKitLSP {
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let explicit = environment["YCODE_SOURCEKIT_LSP"] { return explicit }
        #if os(macOS)
        MainThreadGuard.blockingCall("xcrun --find sourcekit-lsp")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-f", "sourcekit-lsp"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, !path.isEmpty { return path }
        }
        #endif
        for dir in (environment["PATH"] ?? "/usr/bin").split(separator: ":") {
            let c = "\(dir)/sourcekit-lsp"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }
}
