#if canImport(AppKit)
import AppKit
#endif
import Foundation
import YcodeSubprocess
import YcodeAssistant

/// The app-wide parts of the coding assistant: where secrets are kept, the
/// OpenAI account, and how providers are made. Tests replace them. Shared
/// by both IDEs (coding-assistant.md §7: the keychain on macOS, the 0600
/// files of `FileSecretStore` on Linux).
@MainActor
public final class CodingAssistantServices {
    public static var shared = CodingAssistantServices()

    /// Secrets: the login keychain on macOS, `~/.config/ycode/secrets` on
    /// Linux (never user defaults or files in the workspace). Test
    /// processes use memory.
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
        let s = store ?? (IDEProcess.isTestProcess ? MemorySecretStore() : defaultSecretStore())
        self.store = s
        #if canImport(Security)
        let verifier: IDTokenSignatureVerifier? = JWKSSignatureVerifier()
        #else
        // Linux: the ID token is accepted on the strength of the direct TLS
        // exchange (coding-assistant.md §3.3).
        let verifier: IDTokenSignatureVerifier? = nil
        #endif
        account = OpenAIAccount(store: s, verifier: verifier, openURL: openURL ?? Self.openInBrowser)
    }

    /// Opens a URL in the system browser (RFC 8252: no embedded web view).
    public static let openInBrowser: @Sendable (URL) -> Bool = { url in
        #if canImport(AppKit)
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        return true
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["xdg-open", url.absoluteString]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.runWithSignalsUnblocked() } catch { return false }
        return true
        #endif
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
