import Foundation
import Testing
@testable import YcodeAssistant

/// Output limit, sampling, cut-off replies and streamed usage
/// (coding-assistant.md §3.5), against stand-in servers with recorded reply
/// shapes. No network.
@Suite struct GenerationOptionsTests {
    let options = GenerationOptions(maxOutputTokens: 512, temperature: 0.3, topP: 0.9, topK: 40, repeatPenalty: 1.1)

    func request(_ g: GenerationOptions) -> ChatRequest {
        ChatRequest(model: "m", instructions: "i", messages: [ChatMessage(.user, "q")], generation: g)
    }

    @Test func settingsDefaultAndOlderSaves() throws {
        #expect(AssistantSettings().generation == GenerationOptions(maxOutputTokens: 4096))
        // Saved before the field existed: the default applies.
        let old = try JSONDecoder().decode(AssistantSettings.self, from: Data(#"{"provider":"ollama"}"#.utf8))
        #expect(old.generation.maxOutputTokens == 4096)
        var s = AssistantSettings()
        s.generation = options
        let back = try JSONDecoder().decode(AssistantSettings.self, from: JSONEncoder().encode(s))
        #expect(back.generation == options)
    }

    @Test func llamaServerBodyCarriesLimitsOnlyWhenSet() {
        let b = ChatCompletionsProvider.chatBody(request(options))
        #expect(b["max_tokens"] as? Int == 512 && b["top_k"] as? Int == 40)
        #expect(b["temperature"] as? Double == 0.3 && b["top_p"] as? Double == 0.9 && b["repeat_penalty"] as? Double == 1.1)
        #expect((b["stream_options"] as? [String: Bool]) == ["include_usage": true])
        let bare = ChatCompletionsProvider.chatBody(request(GenerationOptions()))
        for k in ["max_tokens", "temperature", "top_p", "top_k", "repeat_penalty"] { #expect(bare[k] == nil, "\(k)") }
    }

    @Test func ollamaBodyMapsNumPredict() {
        let o = OllamaProvider.chatBody(request(options))["options"] as? [String: Any]
        #expect(o?["num_predict"] as? Int == 512 && o?["top_k"] as? Int == 40 && o?["repeat_penalty"] as? Double == 1.1)
        #expect(OllamaProvider.chatBody(request(GenerationOptions()))["options"] == nil)
    }

    @Test func openAIBodyTakesWhatTheResponsesAPIHas() {
        let b = OpenAIProvider.responsesBody(request(options))
        #expect(b["max_output_tokens"] as? Int == 512 && b["temperature"] as? Double == 0.3 && b["top_p"] as? Double == 0.9)
        #expect(b["top_k"] == nil && b["repeat_penalty"] == nil)
    }

    /// llama-server: `finish_reason: "length"`, then the usage chunk
    /// `stream_options.include_usage` adds (`choices: []`), then `[DONE]`.
    @Test func llamaServerCutOffAndUsage() async throws {
        let server = try LoopbackServer { _ in
            .init(contentType: "text/event-stream", chunks: sse([
                ["choices": [["index": 0, "delta": ["content": "loop loop"], "finish_reason": NSNull()]]],
                ["choices": [["index": 0, "delta": ["content": " loop"], "finish_reason": "length"]]],
                ["choices": [] as [Any], "usage": ["prompt_tokens": 20, "completion_tokens": 512]],
                "[DONE]",
            ]))
        }
        let r = try await collect(ChatCompletionsProvider(baseURL: server.baseURL).send(request(options)))
        #expect(r.text == "loop loop loop")
        #expect(Array(r.events.suffix(2)) == [.truncated, .finished(TokenUsage(inputTokens: 20, outputTokens: 512))])
        #expect(try ChatCompletionsProvider.parseChunk(#"{"choices":[{"delta":{"content":"a"},"finish_reason":"stop"}]}"#) == [.text("a")])
    }

    @Test func ollamaCutOff() async throws {
        let server = try LoopbackServer { _ in
            .init(contentType: "application/x-ndjson", chunks: ndjson([
                ["message": ["role": "assistant", "content": "abc"], "done": false],
                ["message": ["role": "assistant", "content": ""], "done": true, "done_reason": "length", "prompt_eval_count": 5, "eval_count": 512],
            ]))
        }
        let r = try await collect(OllamaProvider(baseURL: server.baseURL).send(request(options)))
        #expect(Array(r.events.suffix(2)) == [.truncated, .finished(TokenUsage(inputTokens: 5, outputTokens: 512))])
    }

    @Test func openAIIncompleteAtTheLimitIsACutOff() throws {
        let e = try OpenAIProvider.parseEvent(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":3,"output_tokens":512}}}"#, plan: false)
        #expect(e == [.truncated, .finished(TokenUsage(inputTokens: 3, outputTokens: 512))])
        #expect(throws: AssistantError.incomplete("content_filter")) {
            try OpenAIProvider.parseEvent(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}"#, plan: false)
        }
    }

    @Test func olderConversationsDecode() throws {
        let m = ConversationMessage(role: .assistant, text: "x")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
        json["isCutOff"] = nil
        let back = try JSONDecoder().decode(ConversationMessage.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.isCutOff == nil)
    }
}
