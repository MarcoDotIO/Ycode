import AppKit
import YcodeAssistant

/// Settings ▸ Coding Assistant (coding-assistant.md §6): the back end, the
/// local servers' addresses, the OpenAI sign-in or API key, the agent
/// tools, what context is sent, and a note on privacy. Secrets go to the
/// keychain only; this pane never shows a stored key or token.
@MainActor
public final class CodingAssistantSettingsPane: SettingsPane {
    public static let paneTitle = "Coding Assistant"
    let services: CodingAssistantServices
    /// The last sign-in or key message (tests).
    public private(set) var accountMessage = ""
    /// The running sign-in (tests await it).
    public private(set) var signInTask: Task<Void, Never>?

    public init(prefs: Preferences = .shared, services: CodingAssistantServices = .shared) {
        self.services = services
        super.init(Self.paneTitle, prefs: prefs)
    }

    var settings: AssistantSettings {
        get { prefs.codingAssistant }
        set { prefs.codingAssistant = newValue }
    }

    static let openAIAuthTitles: [AssistantSettings.OpenAIAuth: String] = [.chatGPT: "Sign in with ChatGPT", .apiKey: "API key"]

    override func build() {
        let s = settings
        heading("Model Provider")
        row("Use:", popUp(ProviderKind.allCases.map(\.displayName), selected: s.provider.displayName) { [weak self] title in
            guard let self, let k = ProviderKind.allCases.first(where: { $0.displayName == title }) else { return }
            settings.provider = k
        })
        note("Choose the model itself in the Coding Assistant pane's model menu.")

        heading("Local Models")
        row("Ollama address:", field(s.ollamaURL, width: 260) { [weak self] v in self?.settings.ollamaURL = v.isEmpty ? OllamaProvider.defaultBaseURL : v })
        note("Ollama's API (default \(OllamaProvider.defaultBaseURL)). To add a model, run `ollama pull \(OllamaProvider.suggestedModel)` in Terminal.")
        row("llama.cpp address:", field(s.llamaCppURL, width: 260) { [weak self] v in
            self?.settings.llamaCppURL = v.isEmpty ? ChatCompletionsProvider.defaultBaseURL : v
        })
        row("llama.cpp API key:", secretRow(SecretAccount.llamaCppKey, placeholder: "Only if llama-server uses --api-key"))

        heading("OpenAI")
        row("Sign-in method:", popUp(AssistantSettings.OpenAIAuth.allCases.map { Self.openAIAuthTitles[$0]! },
                                     selected: Self.openAIAuthTitles[s.openAIAuth]!) { [weak self] title in
            guard let self, let a = Self.openAIAuthTitles.first(where: { $0.value == title })?.key else { return }
            settings.openAIAuth = a
            rebuild()
        })
        if s.openAIAuth == .chatGPT {
            row("Account:", accountRow())
            note("Uses OpenAI's sign-in for open-source apps: your browser opens OpenAI's page, and eligible requests use your ChatGPT plan (Plus or Pro). Ycode registers itself with OpenAI on the first sign-in; there is no client ID to enter. Tokens are kept in the keychain. Manage usage in ChatGPT settings.")
        } else {
            row("API key:", secretRow(SecretAccount.openAIKey, placeholder: "sk-…"))
            note("Requests are billed to the API key's organization. The key is kept in the keychain.")
        }
        row("OpenAI address:", field(s.openAIURL, width: 260) { [weak self] v in self?.settings.openAIURL = v.isEmpty ? OpenAIProvider.defaultBaseURL : v })

        heading("Agent Tools")
        note("Ycode runs these tools read-only in the workspace folder and asks them for proposals; it never reads their sign-in or settings. Sign in to each tool once in Terminal.")
        for agent in CLIAgentKind.allCases {
            let kind = agent.providerKind
            let found = services.locator.find(agent.executableName, override: s.toolPaths[kind.rawValue])
            let status = NSTextField(labelWithString: found.map { "Found: \($0.path)" } ?? "Not found (`\(agent.executableName)`)")
            status.textColor = found == nil ? .secondaryLabelColor : .labelColor
            status.font = .systemFont(ofSize: 11)
            status.lineBreakMode = .byTruncatingMiddle
            row("\(agent.displayName):", status)
            row("\(agent.displayName) path:", field(s.toolPaths[kind.rawValue] ?? "", width: 260, placeholder: "Search PATH and the usual folders") { [weak self] v in
                guard let self else { return }
                var t = settings
                t.toolPaths[kind.rawValue] = v.isEmpty ? nil : v
                settings = t
                rebuild()
            })
            row("\(agent.displayName) model:", field(s.model(for: kind) ?? "", width: 160, placeholder: "The tool's default") { [weak self] v in
                guard let self else { return }
                var t = settings
                t.setModel(v.isEmpty ? nil : v, for: kind)
                settings = t
            })
        }

        heading("Context")
        row("Context limit (tokens):", number(s.contextLimit) { [weak self] n in self?.settings.contextLimit = max(1024, n) })
        row("", check("Send the current file", s.context.includeCurrentFile) { [weak self] on in self?.settings.context.includeCurrentFile = on })
        row("", check("Send the other open files", s.context.includeOpenFiles) { [weak self] on in self?.settings.context.includeOpenFiles = on })
        row("", check("Send the workspace's issues", s.context.includeIssues) { [weak self] on in self?.settings.context.includeIssues = on })

        heading("Privacy")
        note(Self.privacyText)
    }

    static let privacyText = """
    What is sent: your message, the attached file or selection, and, as allowed above, the current file (or the part of it \
    that fits), the other open files and the issue list, plus the earlier messages of the conversation. With Ollama or \
    llama.cpp this stays on the address you set (this Mac by default). With OpenAI it goes to OpenAI. With an agent tool \
    it goes to that tool, which may also read files in the workspace folder and sends what it reads to its own service. \
    Conversations are saved in Ycode's folder in Application Support, not in the workspace. Changes are only applied when \
    you accept them.
    """

    // MARK: Rows

    func field(_ value: String, width: CGFloat, placeholder: String = "", _ action: @escaping (String) -> Void) -> NSTextField {
        let f = ClosureField(string: value)
        f.placeholderString = placeholder
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        f.onCommit = { action($0.stringValue.trimmingCharacters(in: .whitespaces)) }
        return f
    }

    /// A key field that writes to the secret store; it shows only whether
    /// a key is saved, never the key.
    func secretRow(_ account: String, placeholder: String) -> NSView {
        let saved = try? services.store.read(account)
        let f = NSSecureTextField()
        f.placeholderString = saved == nil ? placeholder : "Saved in the keychain"
        f.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let save = ClosureButton(title: "Save", target: nil, action: nil)
        save.bezelStyle = .rounded
        save.onChange = { [weak self, weak f] _ in
            guard let self, let key = f?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
            do {
                try services.store.write(Data(key.utf8), for: account)
                accountMessage = "Key saved."
            } catch {
                accountMessage = error.localizedDescription
            }
            settingsChangedExternally()
            rebuild()
        }
        let remove = ClosureButton(title: "Remove", target: nil, action: nil)
        remove.bezelStyle = .rounded
        remove.isEnabled = saved != nil
        remove.onChange = { [weak self] _ in
            guard let self else { return }
            try? services.store.delete(account)
            accountMessage = "Key removed."
            settingsChangedExternally()
            rebuild()
        }
        let stack = NSStackView(views: [f, save, remove])
        stack.spacing = 6
        return stack
    }

    /// Saved keys and tokens are not settings; nudge observers to check
    /// the back ends again.
    func settingsChangedExternally() {
        NotificationCenter.default.post(name: Self.credentialsDidChange, object: nil)
    }

    public static let credentialsDidChange = Notification.Name("YcodeCodingAssistantCredentialsDidChange")

    func accountRow() -> NSView {
        let status = NSTextField(labelWithString: "Checking…")
        status.font = .systemFont(ofSize: 11)
        let button = ClosureButton(title: "Continue with ChatGPT", target: nil, action: nil)
        button.bezelStyle = .rounded
        let message = NSTextField(labelWithString: accountMessage)
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        let account = services.account
        Task { [weak status, weak button] in
            let st = await account.status
            guard let status, let button else { return }
            switch st {
            case .signedOut:
                status.stringValue = "Not signed in"
                button.title = "Continue with ChatGPT"
            case .signedIn(let email, let plan):
                status.stringValue = "Signed in" + (email.map { " as \($0)" } ?? "") + (plan ? "" : " (plan usage not allowed)")
                button.title = "Sign Out"
            }
        }
        button.onChange = { [weak self] b in
            guard let self else { return }
            if b.title == "Sign Out" { signOut() } else { signIn() }
        }
        let stack = NSStackView(views: [status, button, message])
        stack.spacing = 8
        return stack
    }

    /// Opens the browser for OpenAI's sign-in and waits for it.
    public func signIn() {
        accountMessage = "Continue in your browser…"
        rebuild()
        let account = services.account
        signInTask = Task { [weak self] in
            do {
                let t = try await account.signIn()
                guard let self else { return }
                accountMessage = t.hasPlanUsage ? "Signed in." : "Signed in, but plan usage was not allowed. Sign in again and allow it, or use an API key."
                if t.hasPlanUsage && !settings.shownPlanNotice {
                    settings.shownPlanNotice = true
                    showPlanNotice()
                }
            } catch {
                self?.accountMessage = CodingAssistantModel.describe(error)
            }
            self?.settingsChangedExternally()
            self?.rebuild()
        }
    }

    public func signOut() {
        let account = services.account
        signInTask = Task { [weak self] in
            let revoked = await account.signOut()
            self?.accountMessage = revoked ? "Signed out." : "Signed out on this Mac. Ycode could not confirm the revocation; disconnect Ycode in ChatGPT settings."
            self?.settingsChangedExternally()
            self?.rebuild()
        }
    }

    /// The first sign-in's notice that requests use the ChatGPT plan.
    func showPlanNotice() {
        guard let w = view.window, w.isVisible else { return }
        let a = NSAlert()
        a.messageText = "You're using your ChatGPT plan"
        a.informativeText = "Eligible requests from Ycode's coding assistant use your ChatGPT plan. You can manage usage in ChatGPT settings."
        a.addButton(withTitle: "Got it")
        a.beginSheetModal(for: w)
    }
}
