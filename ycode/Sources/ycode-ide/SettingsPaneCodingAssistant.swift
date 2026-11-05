import Foundation
import SwiftUI
import YcodeAssistant
import YcodeIDECore
import YcodeIDEShell

/// Settings ▸ Coding Assistant (coding-assistant.md §6), the macOS pane's
/// sections and rows: the provider, the local model servers, OpenAI, the
/// agent tools, an ACP agent, agent mode, the context, the output limits
/// and the privacy note. Settings are the shared `AssistantSettings` (user
/// defaults); keys go to the secret store (§7: on Linux one 0600 file per
/// key under `~/.config/ycode/secrets`), and the pane never shows a saved
/// key, only that one is saved.
struct CodingAssistantSettingsPane: View {
    /// Bumped when a key is saved or removed (the store is not observed).
    @State private var secretsRevision = 0
    @State private var message = ""
    @State private var accountStatus: OpenAIAccount.Status?

    var services: CodingAssistantServices { CodingAssistantServices.shared }
    var prefs: Preferences { services.preferences ?? .shared }

    /// A binding to one assistant setting; setting it posts
    /// `Preferences.didChange`, so open panes check their back ends again.
    func value<T>(_ key: WritableKeyPath<AssistantSettings, T>) -> Binding<T> {
        let prefs = prefs
        return Binding(get: { prefs.codingAssistant[keyPath: key] }, set: { v in
            var s = prefs.codingAssistant
            s[keyPath: key] = v
            prefs.codingAssistant = s
        })
    }

    static let openAIAuthTitles: [AssistantSettings.OpenAIAuth: String] = [.chatGPT: "Sign in with ChatGPT", .apiKey: "API key"]

    var body: some View {
        let _ = ShellPreferences.shared.revision
        let _ = secretsRevision
        let s = prefs.codingAssistant
        SettingsForm {
            Section {
                Picker("Use", selection: value(\.provider)) {
                    ForEach(ProviderKind.allCases, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
                }
                .shellTarget("settings assistant provider")
            } header: {
                Text("Model Provider")
            } footer: {
                FootNote(text: "Choose the model itself in the Coding Assistant pane's model menu.")
            }
            Section {
                CommitField(title: "Ollama address", value: s.ollamaURL, placeholder: OllamaProvider.defaultBaseURL, target: "settings assistant ollama") {
                    value(\.ollamaURL).wrappedValue = $0.isEmpty ? OllamaProvider.defaultBaseURL : $0
                }
                CommitField(title: "llama.cpp address", value: s.llamaCppURL, placeholder: ChatCompletionsProvider.defaultBaseURL,
                            target: "settings assistant llamacpp") {
                    value(\.llamaCppURL).wrappedValue = $0.isEmpty ? ChatCompletionsProvider.defaultBaseURL : $0
                }
                SecretRow(title: "llama.cpp API key", account: SecretAccount.llamaCppKey, placeholder: "Only if llama-server uses --api-key",
                          target: "settings assistant llamacpp key", saved: changed)
            } header: {
                Text("Local Models")
            } footer: {
                FootNote(text: "Ollama's API (default \(OllamaProvider.defaultBaseURL); to add a model, run `ollama pull \(OllamaProvider.suggestedModel)`) and any server with /v1/models and /v1/chat/completions, such as llama-server. Press Return to apply an address.")
            }
            Section {
                Picker("Sign-in method", selection: value(\.openAIAuth)) {
                    ForEach(AssistantSettings.OpenAIAuth.allCases, id: \.self) { Text(verbatim: Self.openAIAuthTitles[$0] ?? $0.rawValue).tag($0) }
                }
                .shellTarget("settings assistant openai auth")
                if s.openAIAuth == .chatGPT {
                    LabeledContent("Account") {
                        HStack(spacing: 8) {
                            Text(verbatim: accountText).font(ShellFonts.small)
                            Button(isSignedIn ? "Sign Out" : "Continue with ChatGPT") { isSignedIn ? signOut() : signIn() }
                                .buttonStyle(.bordered)
                                .shellTarget("settings assistant chatgpt")
                        }
                    }
                } else {
                    SecretRow(title: "API key", account: SecretAccount.openAIKey, placeholder: "sk-…", target: "settings assistant openai key", saved: changed)
                }
                CommitField(title: "OpenAI address", value: s.openAIURL, placeholder: OpenAIProvider.defaultBaseURL, target: "settings assistant openai url") {
                    value(\.openAIURL).wrappedValue = $0.isEmpty ? OpenAIProvider.defaultBaseURL : $0
                }
            } header: {
                Text("OpenAI")
            } footer: {
                FootNote(text: s.openAIAuth == .chatGPT
                    ? "Uses OpenAI's sign-in for open-source apps: your browser opens OpenAI's page, and eligible requests use your ChatGPT plan. Tokens are kept in Ycode's secrets folder, readable only by you."
                    : "Requests are billed to the API key's organization. The key is kept in Ycode's secrets folder (~/.config/ycode/secrets), readable only by you.")
            }
            Section {
                ForEach(CLIAgentKind.allCases, id: \.self) { agent in
                    let kind = agent.providerKind
                    LabeledContent(agent.displayName) {
                        PathText(path: services.locator.find(agent.executableName, override: s.toolPaths[kind.rawValue])?.path)
                    }
                    CommitField(title: "\(agent.displayName) path", value: s.toolPaths[kind.rawValue] ?? "", placeholder: "Search PATH and the usual folders",
                                target: "settings assistant path \(agent.executableName)") { v in
                        var t = prefs.codingAssistant
                        t.toolPaths[kind.rawValue] = v.isEmpty ? nil : v
                        prefs.codingAssistant = t
                    }
                    CommitField(title: "\(agent.displayName) model", value: s.model(for: kind) ?? "", placeholder: "The tool's default",
                                target: "settings assistant model \(agent.executableName)") { v in
                        var t = prefs.codingAssistant
                        t.setModel(v.isEmpty ? nil : v, for: kind)
                        prefs.codingAssistant = t
                    }
                }
            } header: {
                Text("Agent Tools")
            } footer: {
                FootNote(text: "Ycode runs these tools in the workspace folder with their own editing turned off; they answer with proposals you review. Ycode never reads their sign-in or settings. Sign in to each tool once in a terminal.")
            }
            Section {
                CommitField(title: "Command", value: s.acpCommand, placeholder: "<agent> <arguments for its ACP mode>", target: "settings assistant acp") {
                    value(\.acpCommand).wrappedValue = $0
                }
                LabeledContent("Found") {
                    let acp = ACPAgentProvider(command: s.acpCommand, locator: services.locator)
                    if s.acpCommand.isEmpty { Text(verbatim: "Not set").font(ShellFonts.small) } else { PathText(path: acp.executable?.path) }
                }
            } header: {
                Text("ACP Agent")
            } footer: {
                FootNote(text: "An agent that speaks the Agent Client Protocol, started with this command line in the workspace folder. Its file writes are proposals you review.")
            }
            Section {
                CheckRow(title: "Let agents use Ycode's tools and change files", isOn: value(\.agentMode), target: "settings assistant agent mode")
            } header: {
                Text("Agent Mode")
            } footer: {
                FootNote(text: "The macOS IDE attaches its MCP server to agents in this mode. In the Linux IDE agents run read-only and propose changes; to give an agent you run yourself Ycode's tools, add `ycode mcp` to it (claude mcp add ycode -- ycode mcp).")
            }
            Section {
                CommitField(title: "Context limit (tokens)", value: String(s.contextLimit), placeholder: "32768", target: "settings assistant context limit") {
                    if let n = Int($0) { value(\.contextLimit).wrappedValue = max(1024, n) }
                }
                CheckRow(title: "Send the current file", isOn: value(\.context.includeCurrentFile), target: "settings assistant send file")
                CheckRow(title: "Send the other open files", isOn: value(\.context.includeOpenFiles), target: "settings assistant send open files")
                CheckRow(title: "Send the workspace's issues", isOn: value(\.context.includeIssues), target: "settings assistant send issues")
            } header: {
                Text("Context")
            }
            Section {
                CommitField(title: "Most output tokens", value: s.generation.maxOutputTokens.map(String.init) ?? "", placeholder: "no limit",
                            target: "settings assistant max tokens") { v in value(\.generation.maxOutputTokens).wrappedValue = Int(v).flatMap { $0 > 0 ? $0 : nil } }
                CommitField(title: "Temperature", value: s.generation.temperature.map { String($0) } ?? "", placeholder: "server default",
                            target: "settings assistant temperature") { v in value(\.generation.temperature).wrappedValue = Double(v) }
                CommitField(title: "Top P", value: s.generation.topP.map { String($0) } ?? "", placeholder: "server default",
                            target: "settings assistant top p") { v in value(\.generation.topP).wrappedValue = Double(v) }
                CommitField(title: "Top K", value: s.generation.topK.map(String.init) ?? "", placeholder: "server default",
                            target: "settings assistant top k") { v in value(\.generation.topK).wrappedValue = Int(v) }
                CommitField(title: "Repeat penalty", value: s.generation.repeatPenalty.map { String($0) } ?? "", placeholder: "server default",
                            target: "settings assistant repeat penalty") { v in value(\.generation.repeatPenalty).wrappedValue = Double(v) }
            } header: {
                Text("Output")
            } footer: {
                FootNote(text: "Empty fields are not sent: the server's own value applies. Top K and the repeat penalty are for Ollama and llama.cpp only.")
            }
            Section {
                Text(verbatim: Self.privacyText).font(ShellFonts.small).fixedSize(horizontal: false, vertical: true)
                if !message.isEmpty { Text(verbatim: message).font(ShellFonts.small).shellTarget("settings assistant message") }
            } header: {
                Text("Privacy")
            }
        }
        .task(id: secretsRevision) { accountStatus = await services.account.status }
        .shellTarget("settings assistant")
    }

    static let privacyText = """
    What is sent: your message, the attached file or selection, and, as allowed above, the current file (or the part of it \
    that fits), the other open files and the issue list, plus the earlier messages of the conversation. With Ollama or \
    llama.cpp this stays on the address you set (this computer by default). With OpenAI it goes to OpenAI. With an agent \
    tool it goes to that tool, which may also read files in the workspace folder and sends what it reads to its own \
    service. Conversations are saved in Ycode's data folder (~/.local/share/Ycode), not in the workspace. Changes are \
    only applied when you accept them.
    """

    var isSignedIn: Bool { if case .signedIn? = accountStatus { true } else { false } }

    var accountText: String {
        switch accountStatus {
        case nil: "Checking…"
        case .signedOut?: "Not signed in"
        case .signedIn(let email, let plan)?: "Signed in" + (email.map { " as \($0)" } ?? "") + (plan ? "" : " (plan usage not allowed)")
        }
    }

    /// A key was saved or removed, or the sign-in changed.
    func changed(_ note: String) {
        message = note
        secretsRevision &+= 1
        NotificationCenter.default.post(name: ShellAssistantModel.credentialsDidChange, object: nil)
    }

    func signIn() {
        message = "Continue in your browser…"
        let account = services.account
        Task {
            do {
                let t = try await account.signIn()
                changed(t.hasPlanUsage ? "Signed in." : "Signed in, but plan usage was not allowed. Sign in again and allow it, or use an API key.")
            } catch {
                changed(CodingAssistantModel.describe(error))
            }
        }
    }

    func signOut() {
        let account = services.account
        Task {
            let revoked = await account.signOut()
            changed(revoked ? "Signed out." : "Signed out on this computer. Ycode could not confirm the revocation; disconnect Ycode in ChatGPT settings.")
        }
    }
}

/// A text field that applies its value on Return (an address applied at
/// every keystroke would check the back ends at every keystroke).
struct CommitField: View {
    var title: String
    var value: String
    var placeholder: String
    var target: String
    var commit: (String) -> Void
    @State private var text: String?

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: Binding(get: { text ?? value }, set: { text = $0 }), prompt: Text(verbatim: placeholder))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 300)
                .onSubmit {
                    commit((text ?? value).trimmingCharacters(in: .whitespaces))
                    text = nil
                }
                .shellTarget(target)
        }
    }
}

/// A key: a secure field with Save and Remove. The saved key is never
/// shown; the field's placeholder says one is saved.
struct SecretRow: View {
    var title: String
    var account: String
    var placeholder: String
    var target: String
    var saved: (String) -> Void
    @State private var text = ""

    var body: some View {
        let store = CodingAssistantServices.shared.store
        let isSaved = store.readString(account) != nil
        LabeledContent(title) {
            HStack(spacing: 6) {
                SecureField(title, text: $text, prompt: Text(verbatim: isSaved ? "Saved (hidden)" : placeholder))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220)
                    .onSubmit { save(store) }
                    .shellTarget(target)
                Button("Save") { save(store) }.buttonStyle(.bordered).disabled(text.isEmpty).shellTarget(target + " save")
                Button("Remove") {
                    do { try store.delete(account); saved("Key removed.") } catch { saved(error.localizedDescription) }
                }
                .buttonStyle(.bordered)
                .disabled(!isSaved)
                .shellTarget(target + " remove")
            }
        }
    }

    func save(_ store: SecretStore) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        text = ""
        do {
            try store.write(Data(key.utf8), for: account)
            saved("Key saved.")
        } catch {
            saved(error.localizedDescription)
        }
    }
}
