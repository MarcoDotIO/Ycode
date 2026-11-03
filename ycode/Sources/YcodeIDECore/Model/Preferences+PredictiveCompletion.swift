import Foundation
import YcodeCompletion

extension Preferences {
    /// Predictive code completion (Settings ▸ Editing; specs/ide/predictive-completion.md §5):
    /// the JSON value `Ycode.predictiveCompletion` that both IDEs, `ycode
    /// complete` and the onboarding share.
    public var predictiveCompletion: PredictiveCompletionSettings {
        get { PredictiveCompletionSettings.load(from: defaults) }
        set {
            newValue.save(to: defaults)
            changed()
        }
    }

    /// The coding assistant's Ollama address, which predictive completion
    /// uses when it names none of its own.
    public var sharedOllamaURL: String { codingAssistant.ollamaURL }
}
