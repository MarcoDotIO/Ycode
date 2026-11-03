import AppKit
import YcodeAssistant
import YcodeCompletion
import YcodeIDECore

/// Settings ▸ Editing ▸ Completion ▸ Predictive Code Completion
/// (specs/ide/predictive-completion.md §5): backend, address, model, Test,
/// an explicit model download for Ollama, timing and sampling.
extension TextEditingSettingsPane {
    var predictive: PredictiveCompletionSettings { prefs.predictiveCompletion }

    /// Changes the settings and saves them (open editors follow).
    public func updatePrediction(_ f: (inout PredictiveCompletionSettings) -> Void) {
        var s = prefs.predictiveCompletion
        f(&s)
        prefs.predictiveCompletion = s
    }

    /// The address shown when none is set.
    var predictionDefaultAddress: String { predictive.effectiveAddress(assistantOllamaURL: prefs.sharedOllamaURL) }

    func buildPredictionRows() {
        let s = predictive
        heading("Predictive Code Completion")
        note(s.enabled ? "On (Settings ▸ Editing ▸ Predictive code completion)." : "Off: turn on Predictive code completion on the Editing page.")
        row("Backend:", popUp(PredictiveCompletionSettings.Backend.allCases.map(\.displayName), selected: s.backend.displayName) { [weak self] t in
            guard let b = PredictiveCompletionSettings.Backend.allCases.first(where: { $0.displayName == t }) else { return }
            self?.updatePrediction { s in
                if s.backend != b { s.address = nil; s.model = "" }
                s.backend = b
            }
            self?.predictionProbe = nil
            self?.predictionMessage = ""
            self?.rebuild()
        })
        let address = ClosureField(string: s.address ?? "")
        address.placeholderString = predictionDefaultAddress
        address.widthAnchor.constraint(equalToConstant: 280).isActive = true
        address.onCommit = { [weak self] f in
            let v = f.stringValue.trimmingCharacters(in: .whitespaces)
            self?.updatePrediction { $0.address = v.isEmpty ? nil : v }
        }
        row("Address:", address)
        if s.backend == .ollama && s.address == nil {
            note("Uses the Ollama address of Settings ▸ Coding Assistant.")
        }
        // The model: Automatic, then what the last Test found.
        let automatic = "Automatic"
        var models = [automatic] + (predictionProbe?.fimModels ?? [])
        if !s.model.isEmpty && !models.contains(s.model) { models.append(s.model) }
        row("Model:", popUp(models, selected: s.model.isEmpty ? automatic : s.model) { [weak self] t in
            self?.updatePrediction { $0.model = t == automatic ? "" : t }
        })
        let test = ClosureButton(title: "Test", target: nil, action: nil)
        test.bezelStyle = .rounded
        test.onChange = { [weak self] _ in self?.testPrediction() }
        row("", test)
        if !predictionMessage.isEmpty {
            let m = NSTextField(wrappingLabelWithString: predictionMessage)
            m.preferredMaxLayoutWidth = 420
            m.font = .systemFont(ofSize: 11)
            row("", m)
        }
        if s.backend == .ollama {
            if predictionProbe?.reachable == false {
                let get = ClosureButton(title: "Get Ollama…", target: nil, action: nil)
                get.bezelStyle = .rounded
                get.onChange = { _ in if let u = URL(string: OllamaProvider.downloadURL) { NSWorkspace.shared.open(u) } }
                row("", get)
            }
            // Downloads only on request; the name comes from the user.
            let name = ClosureField(string: "")
            name.placeholderString = "model:tag from ollama.com/search"
            name.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let pull = ClosureButton(title: "Download", target: nil, action: nil)
            pull.bezelStyle = .rounded
            pull.onChange = { [weak self, weak name] _ in
                guard let n = name?.stringValue.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return }
                self?.pullModel(n)
            }
            let box = NSStackView(views: [name, pull])
            row("Download a model:", box)
        }
        row("Wait after typing (ms):", number(s.debounceMilliseconds) { [weak self] n in self?.updatePrediction { $0.debounceMilliseconds = max(0, min(5000, n)) } })
        row("Most tokens:", number(s.maxTokens) { [weak self] n in self?.updatePrediction { $0.maxTokens = max(8, min(2048, n)) } })
        let temp = ClosureField(string: s.temperature.map { String($0) } ?? "")
        temp.placeholderString = "server default"
        temp.widthAnchor.constraint(equalToConstant: 110).isActive = true
        temp.onCommit = { [weak self] f in self?.updatePrediction { $0.temperature = Double(f.stringValue.trimmingCharacters(in: .whitespaces)) } }
        row("Temperature:", temp)
        if s.backend == .openAICompatible {
            row("Prompt format:", popUp(FIMFormat.allCases.map(\.displayName), selected: s.fimFormat.displayName) { [weak self] t in
                self?.updatePrediction { $0.fimFormat = FIMFormat.allCases.first { $0.displayName == t } ?? .auto }
            })
        }
        note(Self.predictionPrivacyNote)
    }

    static let predictionPrivacyNote = """
    Suggestions come from a model you run. Ycode sends the code around the insertion point (and short parts of other open files) to the address above, nothing else, and only while the switch is on. With the default address this stays on this Mac. Tab accepts what is shown, Option-Tab all of it, Control-Tab the next word; Escape dismisses; hold Option to see every line.
    """

    /// Test: asks the backend whether it answers and which models it has.
    public func testPrediction(_ done: (() -> Void)? = nil) {
        let backend = predictive.makeBackend(assistantOllamaURL: prefs.sharedOllamaURL)
        predictionMessage = "Checking \(backend.address)…"
        rebuild()
        predictionTask?.cancel()
        predictionTask = Task { [weak self] in
            let p = await backend.probe()
            guard let self, !Task.isCancelled else { return }
            self.predictionProbe = p
            self.predictionMessage = p.message
            self.rebuild()
            done?()
        }
    }

    /// Download: `ollama pull` through the API, with progress in the message.
    public func pullModel(_ name: String) {
        let provider = OllamaProvider(baseURL: predictionDefaultAddress)
        predictionTask?.cancel()
        predictionMessage = "Downloading \(name)…"
        rebuild()
        predictionTask = Task { [weak self] in
            do {
                for try await p in provider.pull(model: name) {
                    guard let self else { return }
                    let pct = p.fraction.map { String(format: " %.0f%%", $0 * 100) } ?? ""
                    self.predictionMessage = "\(name): \(p.status)\(pct)"
                    self.rebuild()
                }
                self?.predictionMessage = "\(name) is installed."
            } catch {
                self?.predictionMessage = "Download failed: \(error.localizedDescription)"
            }
            self?.rebuild()
        }
    }
}
