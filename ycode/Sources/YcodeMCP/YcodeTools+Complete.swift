import Foundation
import YcodeAssistant
import YcodeCompletion

/// `complete`: one predictive code completion (specs/ide/predictive-completion.md §7),
/// from the backend in Ycode's settings (`Ycode.predictiveCompletion`).
extension YcodeMCPHost {
    var completionTools: [MCPTool] {
        [
            tool("complete", "Predict code",
                 "The code Ycode's predictive completion suggests at a position of a file (what the editor shows as grey text after the caret), from the local model server in Ycode's settings (Ollama by default). Line and column are 1-based.",
                 input: Schema.object(["workspace": Schema.workspace, "path": Schema.string("A file, relative to the workspace folder."),
                                       "line": Schema.integer("1-based line.", minimum: 1), "column": Schema.integer("1-based column (characters).", minimum: 1),
                                       "maxTokens": Schema.integer("The most tokens to generate (default: the setting).", minimum: 1)],
                                      required: ["path", "line", "column"]),
                 output: Schema.output(["suggestion": Schema.str, "backend": Schema.str, "model": Schema.str, "totalMs": Schema.int])) { h, call in
                try await h.complete(call)
            },
        ]
    }

    func complete(_ call: MCPToolCall) async throws -> MCPToolResult {
        let s = try session(for: call)
        let url = try resolve(try call.require("path"), in: s)
        guard let text = text(of: url) else { throw MCPToolError("cannot read \(relative(url.path, in: s))") }
        guard let line = call.int("line"), let column = call.int("column"),
              let caret = CompletionContext.offset(in: text, line: line, column: column) else { throw MCPToolError("no such position in the file") }
        var settings = PredictiveCompletionSettings.load(from: .standard)
        if let n = call.int("maxTokens") { settings.maxTokens = n }
        let context = CompletionContext.make(text: text, caret: caret, path: relative(url.path, in: s), limits: settings.limits)
        let backend = settings.makeBackend(assistantOllamaURL: PredictiveCompletionSettings.assistantOllamaURL(in: .standard))
        do {
            let r = try await PredictionClient(backend: backend, shaper: SuggestionShaper(maxLines: settings.maxLines))
                .complete(PredictionRequest(context: context, settings: settings))
            return .structured(["suggestion": .string(r.text), "backend": .string(settings.backend.rawValue), "model": .string(r.model ?? ""),
                                "totalMs": .int(Int(r.totalMilliseconds))],
                               summary: r.text.isEmpty ? "No suggestion." : r.text)
        } catch let e as PredictionError {
            throw MCPToolError([e.errorDescription, e.hint].compactMap { $0 }.joined(separator: " "))
        }
    }
}
