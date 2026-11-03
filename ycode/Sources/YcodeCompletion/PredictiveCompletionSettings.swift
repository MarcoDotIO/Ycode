import Foundation
import YcodeAssistant

/// Predictive code completion's settings (specs/ide/predictive-completion.md
/// §5): the one model both IDEs, `ycode complete`, the MCP tool and the
/// onboarding read and write. Stored as JSON under the user default
/// `Ycode.predictiveCompletion`. No secrets.
public struct PredictiveCompletionSettings: Codable, Sendable, Equatable {
    /// Where suggestions come from. Ollama is the default (owner decision O3).
    public enum Backend: String, Codable, Sendable, CaseIterable {
        /// Ollama's `/api/generate` with `suffix` (the model's own FIM template).
        case ollama
        /// llama.cpp's `llama-server` `/infill` (advanced).
        case llamaServer
        /// An OpenAI-compatible server: `/v1/completions` with a FIM prompt,
        /// or `/v1/chat/completions` (advanced).
        case openAICompatible

        public var displayName: String {
            switch self {
            case .ollama: "Ollama"
            case .llamaServer: "llama.cpp server"
            case .openAICompatible: "OpenAI-compatible server"
            }
        }

        /// The address used when none is set.
        public var defaultAddress: String {
            switch self {
            case .ollama: OllamaProvider.defaultBaseURL
            case .llamaServer, .openAICompatible: ChatCompletionsProvider.defaultBaseURL
            }
        }
    }

    /// The user default that holds these settings (JSON data).
    public static let defaultsKey = "Ycode.predictiveCompletion"
    /// The coding assistant's settings key (its Ollama address is shared).
    public static let assistantDefaultsKey = "Ycode.codingAssistant"

    /// Settings ▸ Editing ▸ "Predictive code completion". Off until the user
    /// (or the onboarding) turns it on: Ycode bundles no model.
    public var enabled = false
    public var backend: Backend = .ollama
    /// The server's address; nil = the default: for Ollama the coding
    /// assistant's Ollama address (shared), else `backend.defaultAddress`.
    public var address: String?
    /// The model ID; "" = for Ollama the first installed model that can fill
    /// in the middle (capability `insert`), else the server's own model.
    public var model = ""
    /// The most tokens one suggestion may have.
    public var maxTokens = 128
    /// How long typing must pause before a request (milliseconds).
    public var debounceMilliseconds = 250
    /// Sampling; nil = the server's default.
    public var temperature: Double? = 0.2
    public var topP: Double?
    public var topK: Int?
    /// `repeat_penalty` (Ollama, llama-server); nil = the server's default.
    public var repeatPenalty: Double?
    /// The context budget in tokens around the caret.
    public var prefixTokens = 1536
    public var suffixTokens = 512
    /// Snippets of other open files that share names with the code around
    /// the caret (the budget is separate; 0 turns them off).
    public var relatedTokens = 512
    /// The FIM prompt format for `/v1/completions` (OpenAI-compatible only).
    public var fimFormat: FIMFormat = .auto
    /// The suggestion's most lines.
    public var maxLines = 12

    public init() {}

    public init(from decoder: Decoder) throws {
        // Missing keys keep their defaults (settings saved by older builds or written by the onboarding).
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PredictiveCompletionSettings()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        backend = (try? c.decode(Backend.self, forKey: .backend)) ?? d.backend
        address = try? c.decodeIfPresent(String.self, forKey: .address)
        model = (try? c.decode(String.self, forKey: .model)) ?? d.model
        maxTokens = (try? c.decode(Int.self, forKey: .maxTokens)) ?? d.maxTokens
        debounceMilliseconds = (try? c.decode(Int.self, forKey: .debounceMilliseconds)) ?? d.debounceMilliseconds
        // A stored null means "the server's default"; a missing key keeps Ycode's.
        if c.contains(.temperature) {
            temperature = (try? c.decodeIfPresent(Double.self, forKey: .temperature)).flatMap { $0 }
        } else {
            temperature = d.temperature
        }
        topP = try? c.decodeIfPresent(Double.self, forKey: .topP)
        topK = try? c.decodeIfPresent(Int.self, forKey: .topK)
        repeatPenalty = try? c.decodeIfPresent(Double.self, forKey: .repeatPenalty)
        prefixTokens = (try? c.decode(Int.self, forKey: .prefixTokens)) ?? d.prefixTokens
        suffixTokens = (try? c.decode(Int.self, forKey: .suffixTokens)) ?? d.suffixTokens
        relatedTokens = (try? c.decode(Int.self, forKey: .relatedTokens)) ?? d.relatedTokens
        fimFormat = (try? c.decode(FIMFormat.self, forKey: .fimFormat)) ?? d.fimFormat
        maxLines = (try? c.decode(Int.self, forKey: .maxLines)) ?? d.maxLines
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(backend, forKey: .backend)
        try c.encodeIfPresent(address, forKey: .address)
        try c.encode(model, forKey: .model)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(debounceMilliseconds, forKey: .debounceMilliseconds)
        try c.encode(temperature, forKey: .temperature) // null = the server's default
        try c.encodeIfPresent(topP, forKey: .topP)
        try c.encodeIfPresent(topK, forKey: .topK)
        try c.encodeIfPresent(repeatPenalty, forKey: .repeatPenalty)
        try c.encode(prefixTokens, forKey: .prefixTokens)
        try c.encode(suffixTokens, forKey: .suffixTokens)
        try c.encode(relatedTokens, forKey: .relatedTokens)
        try c.encode(fimFormat, forKey: .fimFormat)
        try c.encode(maxLines, forKey: .maxLines)
    }

    enum CodingKeys: String, CodingKey {
        case enabled, backend, address, model, maxTokens, debounceMilliseconds, temperature, topP, topK, repeatPenalty
        case prefixTokens, suffixTokens, relatedTokens, fimFormat, maxLines
    }

    /// The address requests go to. `assistantOllamaURL` is the coding
    /// assistant's Ollama address (used when `address` is nil).
    public func effectiveAddress(assistantOllamaURL: String? = nil) -> String {
        if let a = address?.trimmingCharacters(in: .whitespaces), !a.isEmpty { return a }
        if backend == .ollama, let s = assistantOllamaURL, !s.isEmpty { return s }
        return backend.defaultAddress
    }

    /// The context limits these settings give.
    public var limits: ContextLimits {
        ContextLimits(prefixTokens: max(64, prefixTokens), suffixTokens: max(0, suffixTokens), relatedTokens: max(0, relatedTokens))
    }

    // MARK: Storage

    /// Reads the settings (defaults when absent or unreadable).
    public static func load(from defaults: UserDefaults) -> PredictiveCompletionSettings {
        guard let d = defaults.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(Self.self, from: d) else { return Self() }
        return s
    }

    /// Writes the settings (sorted keys, so the stored value is stable).
    public func save(to defaults: UserDefaults) {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        defaults.set(try? e.encode(self), forKey: Self.defaultsKey)
    }

    /// The coding assistant's Ollama address from `defaults` (nil when the
    /// assistant has no settings yet).
    public static func assistantOllamaURL(in defaults: UserDefaults) -> String? {
        guard let d = defaults.data(forKey: assistantDefaultsKey), let s = try? JSONDecoder().decode(AssistantSettings.self, from: d) else { return nil }
        return s.ollamaURL
    }

    /// The coding assistant's chosen Ollama model (nil: none chosen).
    public static func assistantOllamaModel(in defaults: UserDefaults) -> String? {
        guard let d = defaults.data(forKey: assistantDefaultsKey), let s = try? JSONDecoder().decode(AssistantSettings.self, from: d),
              let m = s.model(for: .ollama), !m.isEmpty else { return nil }
        return m
    }

    // MARK: Xcode preference import

    /// The reference's preference keys (domain `com.apple.dt.Xcode`;
    /// specs/simulator/runtime-downloads.md §7.1, branch obs-runtime).
    public static let xcodeEditorSwitchKey = "DVTTextEnablePredictiveCompletion"
    public static let xcodeOnDeviceModelKey = "DVTEnableOnDeviceCodePredictions"

    /// Maps imported Xcode preferences onto the switch (runtime-downloads.md
    /// §7.4): on when every key present is true, off when one present key is
    /// false; with neither key nothing changes. The backend, address and
    /// model are Ycode's own and are never imported (the reference's model
    /// cannot be used). Returns whether `enabled` changed.
    @discardableResult
    public mutating func importXcodePreferences(_ values: [String: Any]) -> Bool {
        let flags = [Self.xcodeEditorSwitchKey, Self.xcodeOnDeviceModelKey].compactMap { values[$0].flatMap(Self.bool) }
        guard !flags.isEmpty else { return false }
        let on = flags.allSatisfy { $0 }
        defer { enabled = on }
        return enabled != on
    }

    static func bool(_ v: Any) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let i = v as? Int { return i != 0 }
        if let s = v as? String { return ["1", "yes", "true", "on"].contains(s.lowercased()) ? true : (["0", "no", "false", "off"].contains(s.lowercased()) ? false : nil) }
        return nil
    }
}
