import AppKit
import YcodeAssistant

extension Preferences {
    /// Settings ▸ Coding Assistant (no secrets; see `CodingAssistantServices`).
    public var codingAssistant: AssistantSettings {
        get {
            guard let d = defaults.data(forKey: "Ycode.codingAssistant"),
                  let s = try? JSONDecoder().decode(AssistantSettings.self, from: d) else { return AssistantSettings() }
            return s
        }
        set { set("codingAssistant", try? JSONEncoder().encode(newValue)) }
    }
}

/// The app-wide parts of the coding assistant: where secrets are kept, the
/// OpenAI account, and how providers are made. Tests replace them.
@MainActor
public final class CodingAssistantServices {
    public static var shared = CodingAssistantServices()

    /// Secrets: the login keychain (never user defaults or files in the
    /// workspace). Tests and test processes use memory.
    public var store: SecretStore
    public let account: OpenAIAccount
    /// Replaces the real providers (tests).
    public var providerOverride: ((ProviderKind) -> AssistantProvider?)?
    /// Replaces the tool search (tests).
    public var locator = CLIToolLocator()
    /// The settings new assistants use (nil: `Preferences.shared`; tests
    /// set their own instead of replacing the shared one).
    public var preferences: Preferences?

    public init(store: SecretStore? = nil, openURL: (@Sendable (URL) -> Bool)? = nil) {
        let s = store ?? (WorkspaceWindowController.isTestProcess ? MemorySecretStore() : defaultSecretStore())
        self.store = s
        let open: @Sendable (URL) -> Bool = openURL ?? { url in
            // The system browser (RFC 8252: no embedded web view).
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return true
        }
        account = OpenAIAccount(store: s, verifier: JWKSSignatureVerifier(), openURL: open)
    }

    public func backends(_ prefs: Preferences = .shared) -> AssistantBackends {
        AssistantBackends(settings: prefs.codingAssistant, store: store, account: account, locator: locator)
    }

    public func provider(_ kind: ProviderKind, prefs: Preferences = .shared) -> AssistantProvider {
        providerOverride?(kind) ?? backends(prefs).provider(kind)
    }

    /// Every back end's state (off the main thread: the checks touch the
    /// network and the file system).
    public func survey(prefs: Preferences = .shared) async -> [ProviderKind: ProviderAvailability] {
        let kinds = ProviderKind.allCases
        let providers = kinds.map { provider($0, prefs: prefs) }
        return await withTaskGroup(of: (ProviderKind, ProviderAvailability).self) { group in
            for (k, p) in zip(kinds, providers) { group.addTask { (k, await p.availability()) } }
            var out: [ProviderKind: ProviderAvailability] = [:]
            for await (k, a) in group { out[k] = a }
            return out
        }
    }
}
