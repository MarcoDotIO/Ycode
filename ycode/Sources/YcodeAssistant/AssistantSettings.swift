import Foundation

/// The assistant's settings (no secrets: those are in a `SecretStore`).
public struct AssistantSettings: Codable, Sendable, Equatable {
    public enum OpenAIAuth: String, Codable, Sendable, CaseIterable { case chatGPT, apiKey }

    public var provider: ProviderKind = .ollama
    public var ollamaURL = OllamaProvider.defaultBaseURL
    public var llamaCppURL = ChatCompletionsProvider.defaultBaseURL
    public var openAIURL = OpenAIProvider.defaultBaseURL
    public var openAIAuth: OpenAIAuth = .chatGPT
    /// The chosen model per provider (raw value → model ID; "" = the
    /// tool's default).
    public var models: [String: String] = [:]
    /// A path per agent tool that replaces the search (raw value → path).
    public var toolPaths: [String: String] = [:]
    /// The most tokens a request may use, whatever the model allows.
    public var contextLimit = 32_768
    public var context = ContextOptions()
    /// The ChatGPT plan notice was shown (the first sign-in disclosure).
    public var shownPlanNotice = false

    public init() {}

    public func model(for p: ProviderKind) -> String? { models[p.rawValue] }
    public mutating func setModel(_ m: String?, for p: ProviderKind) { models[p.rawValue] = m }

    public init(from decoder: Decoder) throws {
        // Missing keys keep their defaults (settings saved by older builds).
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AssistantSettings()
        provider = (try? c.decode(ProviderKind.self, forKey: .provider)) ?? d.provider
        ollamaURL = (try? c.decode(String.self, forKey: .ollamaURL)) ?? d.ollamaURL
        llamaCppURL = (try? c.decode(String.self, forKey: .llamaCppURL)) ?? d.llamaCppURL
        openAIURL = (try? c.decode(String.self, forKey: .openAIURL)) ?? d.openAIURL
        openAIAuth = (try? c.decode(OpenAIAuth.self, forKey: .openAIAuth)) ?? d.openAIAuth
        models = (try? c.decode([String: String].self, forKey: .models)) ?? [:]
        toolPaths = (try? c.decode([String: String].self, forKey: .toolPaths)) ?? [:]
        contextLimit = (try? c.decode(Int.self, forKey: .contextLimit)) ?? d.contextLimit
        context = (try? c.decode(ContextOptions.self, forKey: .context)) ?? d.context
        shownPlanNotice = (try? c.decode(Bool.self, forKey: .shownPlanNotice)) ?? false
    }
}

/// Makes providers from settings and finds which back ends can be used.
public struct AssistantBackends: Sendable {
    public var settings: AssistantSettings
    public var store: SecretStore
    public var account: OpenAIAccount?
    public var locator: CLIToolLocator

    public init(settings: AssistantSettings, store: SecretStore, account: OpenAIAccount?, locator: CLIToolLocator = CLIToolLocator()) {
        self.settings = settings
        self.store = store
        self.account = account
        self.locator = locator
    }

    public func provider(_ kind: ProviderKind) -> AssistantProvider {
        switch kind {
        case .ollama:
            return OllamaProvider(baseURL: settings.ollamaURL)
        case .llamaCpp:
            return ChatCompletionsProvider(baseURL: settings.llamaCppURL, apiKey: store.readString(SecretAccount.llamaCppKey))
        case .openAI:
            let credential: OpenAIProvider.Credential
            switch settings.openAIAuth {
            case .apiKey: credential = store.readString(SecretAccount.openAIKey).map { .apiKey($0) } ?? .none
            case .chatGPT: credential = account.map { .account($0) } ?? .none
            }
            return OpenAIProvider(baseURL: settings.openAIURL, credential: credential)
        case .claudeCode, .codex, .antigravity:
            let agent = kind.cliAgent!
            return CLIAgentProvider(agent: agent, executable: locator.find(agent.executableName, override: settings.toolPaths[kind.rawValue]))
        }
    }

    /// Every back end's availability, checked concurrently.
    public func survey() async -> [ProviderKind: ProviderAvailability] {
        await withTaskGroup(of: (ProviderKind, ProviderAvailability).self) { group in
            for k in ProviderKind.allCases {
                let p = provider(k)
                group.addTask { (k, await p.availability()) }
            }
            var out: [ProviderKind: ProviderAvailability] = [:]
            for await (k, a) in group { out[k] = a }
            return out
        }
    }

    /// The empty state when nothing can be used.
    public static let noBackendText = """
    The coding assistant needs a model. Use one of these:
    • Ollama: install it from ollama.com, then run `ollama pull qwen2.5-coder` in Terminal.
    • llama.cpp: run `llama-server -m <model>.gguf`.
    • OpenAI: sign in with ChatGPT, or enter an API key, in Settings ▸ Coding Assistant.
    • Claude Code, Codex or the Antigravity CLI: install one and sign in to it once in Terminal.
    """
}
