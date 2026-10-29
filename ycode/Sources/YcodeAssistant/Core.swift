import Foundation

// The coding assistant's platform-neutral core: providers behind one
// protocol, conversations, prompt building and change proposals.
// See specs/ide/coding-assistant.md.

/// The back ends Ycode can talk to (coding-assistant.md §3).
public enum ProviderKind: String, Codable, Sendable, CaseIterable, Hashable {
    case ollama, llamaCpp, openAI, claudeCode, codex, antigravity

    public var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .llamaCpp: "llama.cpp"
        case .openAI: "OpenAI"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    /// A local model server (Ollama, llama-server).
    public var isLocalServer: Bool { self == .ollama || self == .llamaCpp }
    /// An agent command-line tool Ycode runs as a subprocess.
    public var cliAgent: CLIAgentKind? {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .antigravity: .antigravity
        default: nil
        }
    }
}

public enum ChatRole: String, Codable, Sendable, Equatable {
    case system, user, assistant
}

public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: ChatRole
    public var content: String
    public init(_ role: ChatRole, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// A model a provider offers.
public struct ModelInfo: Codable, Sendable, Equatable, Hashable {
    /// The identifier sent to the provider.
    public var id: String
    /// The name shown in pickers.
    public var displayName: String
    /// The model's context window in tokens, when the provider reports it.
    public var contextWindow: Int?
    public init(id: String, displayName: String? = nil, contextWindow: Int? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.contextWindow = contextWindow
    }
}

/// One request: the instructions, the conversation so far (ending with the
/// new user message) and where an agent tool runs.
public struct ChatRequest: Sendable, Equatable {
    public var model: String?
    public var instructions: String
    public var messages: [ChatMessage]
    /// The context window the prompt was built for (Ollama's `num_ctx`).
    public var contextTokens: Int?
    /// The workspace folder (agent tools run there).
    public var workingDirectory: URL?
    public init(model: String?, instructions: String, messages: [ChatMessage], contextTokens: Int? = nil, workingDirectory: URL? = nil) {
        self.model = model
        self.instructions = instructions
        self.messages = messages
        self.contextTokens = contextTokens
        self.workingDirectory = workingDirectory
    }

    /// The whole request as one text: instructions, then each earlier turn,
    /// then the new message. For back ends that take a single prompt.
    public var flattenedPrompt: String {
        var s = instructions
        let earlier = messages.dropLast()
        if !earlier.isEmpty {
            s += "\n\n<conversation>\n"
            for m in earlier { s += "<\(m.role.rawValue)>\n\(m.content)\n</\(m.role.rawValue)>\n" }
            s += "</conversation>"
        }
        if let last = messages.last { s += "\n\n" + last.content }
        return s
    }
}

public struct TokenUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// What a response stream reports.
public enum ChatEvent: Sendable, Equatable {
    /// More response text.
    case text(String)
    /// What an agent tool is doing ("Reading Sources/App.swift").
    case activity(String)
    /// The response is complete.
    case finished(TokenUsage?)
}

/// Whether a provider can be used now, and if not, what the user can do.
public enum ProviderAvailability: Sendable, Equatable {
    case ready([ModelInfo])
    /// A local server is not reachable.
    case notRunning(hint: String)
    /// The server runs but has no models.
    case noModels(hint: String)
    /// The command-line tool was not found.
    case notInstalled(hint: String)
    /// No credentials are stored.
    case signedOut(hint: String)
    case failed(String)

    public var isReady: Bool { if case .ready = self { true } else { false } }
    public var models: [ModelInfo] { if case .ready(let m) = self { m } else { [] } }
    /// The text shown for an unusable provider.
    public var hint: String? {
        switch self {
        case .ready: nil
        case .notRunning(let h), .noModels(let h), .notInstalled(let h), .signedOut(let h): h
        case .failed(let m): m
        }
    }
}

/// Errors a provider reports, with text for the user.
public enum AssistantError: Error, Sendable, Equatable, LocalizedError {
    /// The server did not answer (connection refused, host unknown).
    case unreachable(service: String, url: String, hint: String)
    case http(status: Int, message: String)
    case modelNotFound(model: String, hint: String)
    case notSignedIn(hint: String)
    /// Signed in, but the grant lacks plan usage.
    case planUsageNotEnabled
    case usageLimit(String)
    case temporarilyUnavailable(String)
    case unsupported(String)
    /// The response stopped before completing (`response.incomplete`).
    case incomplete(String)
    case failed(String)
    /// An agent tool exited with an error.
    case tool(name: String, message: String)
    case malformed(String)
    case signIn(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let service, let url, _): "\(service) is not running at \(url)."
        case .http(let status, let message): message.isEmpty ? "The server answered with HTTP \(status)." : "HTTP \(status): \(message)"
        case .modelNotFound(let model, _): "The model “\(model)” is not available."
        case .notSignedIn: "You are not signed in."
        case .planUsageNotEnabled: "ChatGPT plan usage isn't enabled for this app."
        case .usageLimit(let m), .temporarilyUnavailable(let m), .unsupported(let m), .failed(let m), .malformed(let m), .signIn(let m): m
        case .incomplete(let reason): "The response stopped early (\(reason))."
        case .tool(let name, let message): "\(name) stopped: \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unreachable(_, _, let hint), .modelNotFound(_, let hint), .notSignedIn(let hint): hint
        case .planUsageNotEnabled: "Sign in again and allow plan usage, or choose API key in Settings ▸ Coding Assistant."
        case .usageLimit: "Check your usage in ChatGPT settings."
        case .temporarilyUnavailable: "Try again shortly."
        default: nil
        }
    }
}

/// A back end behind the coding assistant.
public protocol AssistantProvider: Sendable {
    var kind: ProviderKind { get }
    /// Whether it can answer now, with its models when it can.
    func availability() async -> ProviderAvailability
    /// The context window of `model`, when the provider reports it.
    func contextWindow(model: String) async -> Int?
    /// Streams the response. Cancelling the consuming task stops the
    /// request (closes the connection or interrupts the tool).
    func send(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

extension AssistantProvider {
    public func contextWindow(model: String) async -> Int? { nil }
}

/// Builds a stream from an async body that yields events; the body's task
/// is cancelled when the consumer stops.
func eventStream(_ body: @escaping @Sendable (AsyncThrowingStream<ChatEvent, Error>.Continuation) async throws -> Void)
    -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
