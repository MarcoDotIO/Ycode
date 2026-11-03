import Foundation
import Testing
@testable import YcodeAssistant
@testable import YcodeCompletion

/// The context builder (predictive-completion.md §4.1).
@Suite struct ContextBuilderTests {
    @Test func cutsAtLineBoundariesAndKeepsTheCaretLine() {
        let text = (1...200).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let caret = (text as NSString).range(of: "let value100 = ").upperBound
        let limits = ContextLimits(prefixTokens: 100, suffixTokens: 30, relatedTokens: 0)
        let c = CompletionContext.make(text: text, caret: caret, path: "A.swift", limits: limits)
        #expect(c.linePrefix == "let value100 = ")
        #expect(c.lineSuffix == "100")
        #expect(c.prefix.hasSuffix("let value99 = 99\nlet value100 = "))
        #expect(c.prefix.hasPrefix("let value"))       // starts at a line start
        #expect(c.prefix.utf16.count <= 300 + 20)
        #expect(!c.prefixIsWholeFile)
        #expect(c.suffix.hasPrefix("100\nlet value101"))
        #expect(c.suffix.hasSuffix("\n"))               // ends at a line end
        #expect(c.suffix.utf16.count <= 90)
        #expect(c.language == "swift")
        #expect(c.isMidLine)
    }

    @Test func smallFilesGoWhole() {
        let c = CompletionContext.make(text: "func f() {\n    \n}\n", caret: 15, path: "x.py")
        #expect(c.prefix == "func f() {\n    ")
        #expect(c.suffix == "\n}\n")
        #expect(c.prefixIsWholeFile)
        #expect(c.language == "python")
        #expect(!c.isMidLine)
        #expect(c.suffixAfterLine == "}\n")
    }

    @Test func closersAreNotMidLine() {
        #expect(!CompletionContext(prefix: "print(", suffix: ")\n", path: "a").isMidLine)
        #expect(!CompletionContext(prefix: "x = [", suffix: "];", path: "a").isMidLine)
        #expect(CompletionContext(prefix: "let ", suffix: "x = 1", path: "a").isMidLine)
    }

    @Test func lineAndColumnToOffset() {
        let t = "ab\nçd€\n\nx"
        #expect(CompletionContext.offset(in: t, line: 1, column: 1) == 0)
        #expect(CompletionContext.offset(in: t, line: 2, column: 3) == 5)
        #expect(CompletionContext.offset(in: t, line: 2, column: 99) == 6)
        #expect(CompletionContext.offset(in: t, line: 4, column: 2) == 9)
        #expect(CompletionContext.offset(in: t, line: 5, column: 1) == nil)
    }

    @Test func relatedSnippetsShareNames() {
        let other = """
        struct Invoice {
            var lineItems: [LineItem]
            func totalAmount() -> Decimal { lineItems.reduce(0) { $0 + $1.price } }
        }
        """
        let unrelated = "enum Weather { case sunny, rainy }\n"
        let query = "let invoice = Invoice(lineItems: items)\nlet sum = invoice."
        let picked = RelatedSnippets.pick(query: query, files: [("Weather.swift", unrelated), ("Invoice.swift", other)])
        #expect(picked.map(\.path) == ["Invoice.swift"])
        // The related budget drops what does not fit.
        let c = CompletionContext.make(text: query, caret: query.utf16.count, path: "Main.swift", related: picked,
                                       limits: ContextLimits(relatedTokens: 10))
        #expect(c.related.isEmpty)
        let c2 = CompletionContext.make(text: query, caret: query.utf16.count, path: "Main.swift", related: picked)
        #expect(c2.related == picked)
    }
}

/// Post-processing (§4.3).
@Suite struct ShaperTests {
    let shaper = SuggestionShaper(maxLines: 6)

    func ctx(_ text: String) -> CompletionContext {
        let caret = (text as NSString).range(of: "|").location
        let t = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        return CompletionContext.make(text: t, caret: caret, path: "A.swift")
    }

    @Test func midLineKeepsTheFirstLine() {
        let r = shaper.shape("count + 1\nlet y = 2", context: ctx("let x = |value\n"))
        #expect(r.text == "count + 1")
        #expect(r.complete)
    }

    @Test func stopsWhenTheBlockEnds() {
        let c = ctx("func f() {\n    |\n}\n")
        let r = shaper.shape("let a = 1\n    return a\n}\n\nfunc g() {}", context: c)
        #expect(r.text == "let a = 1\n    return a")   // `}` is already after the caret
        let c2 = ctx("    if ok {|}\n")
        let r2 = shaper.shape("\n        run()\n    }\n    other()", context: c2)
        #expect(r2.text == "\n        run()\n    }")
    }

    @Test func stopsWhenTheStatementIsCompleteOrAtAFence() {
        // Measured with a 7B model at the end of a file (predictive-completion.md §8).
        let c = ctx("let evens = numbers.filter { |")
        #expect(shaper.shape("$0 % 2 == 0 }\nprint(evens)\n```\n\nIn this example", context: c).text == "$0 % 2 == 0 }")
        let c2 = ctx("    let user = try decoder.decode(|\n}\n")
        #expect(shaper.shape("User.self, from: data)\n    return user\n}", context: c2).text == "User.self, from: data)")
        #expect(shaper.shape("a()\n```\nprose", context: ctx("|")).text == "a()")
    }

    @Test func stopsAtTwoBlankLinesAndMaxLines() {
        let c = ctx("|")
        #expect(shaper.shape("a()\nb()\n\n\nc()", context: c).text == "a()\nb()")
        #expect(shaper.shape((1...10).map { "f\($0)()" }.joined(separator: "\n"), context: c).text.split(separator: "\n").count == 6)
    }

    @Test func trimsWhatTheRestOfTheLineHas() {
        #expect(shaper.shape("\"hello\")", context: ctx("print(|)\n")).text == "\"hello\"")
        #expect(shaper.shape("items[0]]", context: ctx("let a = [|]\n")).text == "items[0]")
    }

    @Test func rejectsRepeats() {
        #expect(shaper.shape("   \n  ", context: ctx("let a = |\n")).text == "")
        #expect(shaper.shape("return x", context: ctx("    |\n    return x\n}\n")).text == "")
        #expect(shaper.shape("doThing()\ndoThing()", context: ctx("    doThing()\n    |\n")).text == "")
    }

    @Test func streamingShowsLinesAndStopsEarly() {
        let c = ctx("let x = |foo\n")
        let partial = shaper.shape("bar", context: c, final: false)
        #expect(partial == .init(text: "bar", complete: false))
        let done = shaper.shape("bar()\nmore", context: c, final: false)
        #expect(done == .init(text: "bar()", complete: true))
    }

    @Test func chatRepliesLoseFences() {
        let c = ctx("let total = |\n")
        #expect(shaper.shape("```swift\nlet total = items.count\n```", context: c, fromChat: true).text == "items.count")
    }
}

/// The LRU cache (§4.4).
@Suite struct CacheTests {
    @Test func exactHitsTypingThroughAndEviction() {
        var cache = SuggestionCache(capacity: 2)
        let c1 = CompletionContext(prefix: "let a = ", suffix: "\n", path: "A")
        cache.insert("compute(1)", for: c1, source: "s")
        #expect(cache.lookup(c1, source: "s") == "compute(1)")
        #expect(cache.lookup(c1, source: "other") == nil)
        let typed = CompletionContext(prefix: "let a = comp", suffix: "\n", path: "A")
        #expect(cache.lookup(typed, source: "s") == "ute(1)")
        let diverged = CompletionContext(prefix: "let a = cx", suffix: "\n", path: "A")
        #expect(cache.lookup(diverged, source: "s") == nil)
        cache.insert("x", for: CompletionContext(prefix: "b", suffix: "", path: "A"), source: "s")
        cache.insert("y", for: CompletionContext(prefix: "c", suffix: "", path: "A"), source: "s")
        #expect(cache.count == 2)
        #expect(cache.lookup(c1, source: "s") == nil)
    }
}

/// Settings and the reference's preference keys (§5).
@Suite struct SettingsTests {
    @Test func defaultsRoundTripAndOlderValues() throws {
        let d = try #require(UserDefaults(suiteName: "ycode-predict-\(UUID().uuidString)"))
        var s = PredictiveCompletionSettings.load(from: d)
        #expect(s == PredictiveCompletionSettings())
        #expect(!s.enabled && s.backend == .ollama && s.model.isEmpty && s.temperature == 0.2)
        s.enabled = true
        s.model = "my-model"
        s.temperature = nil
        s.topK = 20
        s.save(to: d)
        let back = PredictiveCompletionSettings.load(from: d)
        #expect(back == s)
        #expect(back.temperature == nil)
        // Written by another component with only some keys.
        d.set(Data(#"{"enabled": true, "backend": "llamaServer"}"#.utf8), forKey: PredictiveCompletionSettings.defaultsKey)
        let partial = PredictiveCompletionSettings.load(from: d)
        #expect(partial.enabled && partial.backend == .llamaServer && partial.maxTokens == 128 && partial.temperature == 0.2)
    }

    @Test func sharesTheAssistantsOllamaAddress() throws {
        let d = try #require(UserDefaults(suiteName: "ycode-predict-\(UUID().uuidString)"))
        var a = AssistantSettings()
        a.ollamaURL = "http://127.0.0.1:22222"
        a.setModel("chat-model", for: .ollama)
        d.set(try JSONEncoder().encode(a), forKey: PredictiveCompletionSettings.assistantDefaultsKey)
        let shared = PredictiveCompletionSettings.assistantOllamaURL(in: d)
        #expect(shared == "http://127.0.0.1:22222")
        #expect(PredictiveCompletionSettings.assistantOllamaModel(in: d) == "chat-model")
        var s = PredictiveCompletionSettings()
        #expect(s.effectiveAddress(assistantOllamaURL: shared) == "http://127.0.0.1:22222")
        s.address = "http://10.0.0.2:11434"
        #expect(s.effectiveAddress(assistantOllamaURL: shared) == "http://10.0.0.2:11434")
        s.address = nil
        s.backend = .llamaServer
        #expect(s.effectiveAddress(assistantOllamaURL: shared) == "http://127.0.0.1:9931")
    }

    @Test func importsXcodePreferences() {
        var s = PredictiveCompletionSettings()
        var changed = s.importXcodePreferences([:])
        #expect(!changed)
        changed = s.importXcodePreferences(["DVTTextEnablePredictiveCompletion": true])
        #expect(changed && s.enabled)
        changed = s.importXcodePreferences(["DVTTextEnablePredictiveCompletion": true, "DVTEnableOnDeviceCodePredictions": NSNumber(value: false)])
        #expect(changed && !s.enabled)
        changed = s.importXcodePreferences(["DVTEnableOnDeviceCodePredictions": "YES"])
        #expect(changed && s.enabled)
        #expect(s.backend == .ollama && s.address == nil) // never imported
    }
}

/// FIM prompt formats (§6.3).
@Suite struct FIMFormatTests {
    @Test func formatsAndDetection() {
        let c = CompletionContext(prefix: "a(", suffix: ")", path: "Main.swift", related: [RelatedSnippet(path: "B.swift", text: "func b() {}")])
        #expect(FIMFormat.qwen.prompt(c) == "<|repo_name|>workspace\n<|file_sep|>B.swift\nfunc b() {}\n<|file_sep|>Main.swift\n<|fim_prefix|>a(<|fim_suffix|>)<|fim_middle|>")
        #expect(FIMFormat.codeLlama.prompt(c) == "<PRE> a( <SUF>) <MID>")
        #expect(FIMFormat.suffixFirst.prompt(c) == "[SUFFIX])[PREFIX]a(")
        #expect(FIMFormat.chat.prompt(c) == nil)
        #expect(FIMFormat.detect(model: "Qwen2.5-Coder-1.5B-Q8_0.gguf") == .qwen)
        #expect(FIMFormat.detect(model: "starcoder2:3b") == .starCoder)
        #expect(FIMFormat.detect(model: "my-chat-model") == .chat)
        #expect(FIMFormat.auto.resolved(model: "deepseek-coder") == .deepSeek)
    }
}

/// Each adapter against the stand-in server (§6).
@Suite(.serialized) struct BackendTests {
    let context = CompletionContext(prefix: "func add(_ a: Int, _ b: Int) -> Int {\n    ", suffix: "\n}\n", path: "Math.swift", language: "swift",
                                    related: [RelatedSnippet(path: "Other.swift", text: "let k = 1")])

    func run(_ b: PredictionBackend, model: String = "", fim: FIMFormat = .auto) async throws -> PredictionResult {
        try await PredictionClient(backend: b).complete(PredictionRequest(context: context, model: model, maxTokens: 64, temperature: 0.1, topP: 0.9, topK: 30,
                                                                          repeatPenalty: 1.05, fimFormat: fim))
    }

    @Test func ollamaGenerateWithSuffix() async throws {
        let s = try StandInServer { _, suffix in suffix.hasPrefix("\n}") ? "return a + b\n}\n" : "wrong" }
        let r = try await run(OllamaFIMBackend(address: s.baseURL))
        #expect(r.text == "return a + b")
        #expect(r.model == "stand-in-coder")
        #expect(r.firstTokenMilliseconds != nil)
        let body = try #require(s.generationRequests.first?.body)
        #expect(body["model"] as? String == "stand-in-coder")
        #expect(body["suffix"] as? String == "\n}\n")
        #expect((body["prompt"] as? String)?.hasPrefix("// From Other.swift:\n// let k = 1\n\nfunc add") == true)
        #expect(body["stream"] as? Bool == true)
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["num_predict"] as? Int == 64 && options["top_k"] as? Int == 30)
        #expect((options["temperature"] as? Double) == 0.1 && (options["top_p"] as? Double) == 0.9)
        #expect((options["repeat_penalty"] as? Double) == 1.05)
        let probe = await OllamaFIMBackend(address: s.baseURL).probe()
        #expect(probe.reachable && probe.fimModels == ["stand-in-coder"])
    }

    @Test func llamaServerInfill() async throws {
        let s = try StandInServer { prefix, _ in prefix.hasSuffix("    ") ? "return a + b" : "?" }
        let r = try await run(LlamaServerInfillBackend(address: s.baseURL))
        #expect(r.text == "return a + b")
        let body = try #require(s.generationRequests.first?.body)
        #expect(body["input_suffix"] as? String == "\n}\n")
        #expect((body["input_extra"] as? [[String: String]]) == [["filename": "Other.swift", "text": "let k = 1"]])
        #expect(body["n_predict"] as? Int == 64 && body["cache_prompt"] as? Bool == true)
        #expect(body["repeat_penalty"] as? Double == 1.05)
        #expect(await LlamaServerInfillBackend(address: s.baseURL).probe().models == ["stand-in-coder"])
    }

    @Test func openAICompatibleFIMAndChat() async throws {
        let s = try StandInServer { prompt, _ in
            prompt.contains("<|fim_middle|>") ? "return a + b" : (prompt.contains("<CURSOR>") ? "```swift\nreturn a &+ b\n```" : "?")
        }
        let fim = try await run(OpenAICompatibleBackend(address: s.baseURL + "/v1"), model: "qwen2.5-coder-7b")
        #expect(fim.text == "return a + b")
        let body = try #require(s.generationRequests.first?.body)
        #expect((body["stop"] as? [String])?.first == "<|endoftext|>")
        #expect((body["stream_options"] as? [String: Bool]) == ["include_usage": true])
        let chat = try await run(OpenAICompatibleBackend(address: s.baseURL), model: "some-chat-model")
        #expect(chat.text == "return a &+ b")
        #expect(s.generationRequests.last?.path == "/v1/chat/completions")
    }

    @Test func unreachableAndNoModel() async throws {
        let closed = try LoopbackServer { _ in .text("") }
        let url = closed.baseURL
        closed.stop()
        await #expect(throws: PredictionError.unreachable(backend: .ollama, address: url)) { try await run(OllamaFIMBackend(address: url)) }
        await #expect(throws: PredictionError.unreachable(backend: .llamaServer, address: url)) { try await run(LlamaServerInfillBackend(address: url)) }
        #expect(PredictionError.unreachable(backend: .ollama, address: url).hint?.contains("ollama.com/download") == true)
        let noFIM = try LoopbackServer { req in
            req.path == "/api/tags" ? .json(["models": [["name": "chat-only"]]]) : .json(["capabilities": ["completion"]])
        }
        await #expect(throws: PredictionError.noModel("None of Ollama's models can fill in the middle.")) { try await run(OllamaFIMBackend(address: noFIM.baseURL)) }
    }
}

/// The editor session (§4.5): debounce, typing through, accepting, dismissing.
@MainActor @Suite(.serialized) struct SessionTests {
    func waitFor(_ cond: () -> Bool, timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func session(_ server: StandInServer, debounce: Int = 0) -> PredictionSession {
        var s = PredictiveCompletionSettings()
        s.enabled = true
        s.address = server.baseURL
        s.debounceMilliseconds = debounce
        return PredictionSession(settings: s)
    }

    @Test func typingThroughAcceptingAndDismissing() async throws {
        let server = try StandInServer { _, _ in "items.reduce(0, +)\nprint(total)" }
        let p = session(server)
        var text = "let total = "
        p.textDidChange(.init(text: text, caret: 12, path: "A.swift"), location: 11, removed: 0, inserted: " ")
        await waitFor { p.suggestion?.text == "items.reduce(0, +)\nprint(total)" }
        #expect(p.suggestion == .init(anchor: 12, text: "items.reduce(0, +)\nprint(total)"))
        #expect(p.acceptText(.shown) == "items.reduce(0, +)")
        #expect(p.acceptText(.word) == "items")
        // Typing what it suggests keeps the rest; no new request.
        let before = p.requestCount
        text += "ite"
        p.textDidChange(.init(text: text, caret: 15, path: "A.swift"), location: 12, removed: 0, inserted: "ite")
        #expect(p.suggestion == .init(anchor: 15, text: "ms.reduce(0, +)\nprint(total)"))
        #expect(p.requestCount == before)
        // Moving the caret away dismisses; Escape dismisses.
        p.selectionDidChange(caret: 3, length: 0)
        #expect(p.suggestion == nil)
        p.forceRequest(.init(text: text, caret: 15, path: "A.swift"))
        await waitFor { p.suggestion != nil }
        p.dismiss()
        #expect(p.suggestion == nil)
        // Typing something else drops it.
        p.forceRequest(.init(text: text, caret: 15, path: "A.swift"))
        await waitFor { p.suggestion != nil }
        p.textDidChange(.init(text: text + "x", caret: 16, path: "A.swift"), location: 15, removed: 0, inserted: "x")
        #expect(p.suggestion == nil)
    }

    @Test func typingAheadOfAStreamingRequest() async throws {
        let server = try StandInServer(chunk: 3, delay: 0.04) { _, _ in "abcdefghij" }
        let p = session(server)
        p.textDidChange(.init(text: "x = ", caret: 4, path: "A.swift"), location: 3, removed: 0, inserted: " ")
        await waitFor { p.suggestion?.text == "abc" }
        p.textDidChange(.init(text: "x = ab", caret: 6, path: "A.swift"), location: 4, removed: 0, inserted: "ab")
        #expect(p.suggestion == .init(anchor: 6, text: "c"))
        await waitFor { !p.isBusy }
        #expect(p.suggestion == .init(anchor: 6, text: "cdefghij"))
        #expect(server.generationRequests.count == 1)
    }

    @Test func debounceSendsOneRequestAndMidLineWaits() async throws {
        let server = try StandInServer { _, _ in "42" }
        let p = session(server, debounce: 80)
        for (i, ch) in "let x = ".enumerated() {
            let t = String("let x = ".prefix(i + 1))
            p.textDidChange(.init(text: t, caret: i + 1, path: "A.swift"), location: i, removed: 0, inserted: String(ch))
        }
        await waitFor { p.suggestion != nil }
        #expect(p.suggestion?.text == "42")
        #expect(server.generationRequests.count == 1)
        // In the middle of a line, only the command asks.
        p.textDidChange(.init(text: "let y = z", caret: 8, path: "A.swift"), location: 7, removed: 0, inserted: " ")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(server.generationRequests.count == 1)
        p.forceRequest(.init(text: "let y = z", caret: 8, path: "A.swift"))
        await waitFor { server.generationRequests.count == 2 }
    }

    @Test func unreachableIsQuietAndBacksOff() async throws {
        let closed = try LoopbackServer { _ in .text("") }
        let url = closed.baseURL
        closed.stop()
        var s = PredictiveCompletionSettings()
        s.enabled = true
        s.address = url
        s.debounceMilliseconds = 0
        let p = PredictionSession(settings: s)
        var statuses: [PredictionSession.Status] = []
        p.onStatusChange = { statuses.append($0) }
        p.textDidChange(.init(text: "a", caret: 1, path: "A.swift"), location: 0, removed: 0, inserted: "a")
        await waitFor { if case .unavailable = p.status { true } else { false } }
        guard case .unavailable(let m, let hint) = p.status else { Issue.record("expected unavailable"); return }
        #expect(m.contains("not running"))
        #expect(hint?.contains("ollama.com/download") == true)
        let n = p.requestCount
        p.textDidChange(.init(text: "ab", caret: 2, path: "A.swift"), location: 1, removed: 0, inserted: "b")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(p.requestCount == n) // backing off
        #expect(statuses.first == .requesting)
    }

    @Test func offSendsNothing() async throws {
        let server = try StandInServer { _, _ in "x" }
        let p = session(server)
        p.settings.enabled = false
        p.textDidChange(.init(text: "a", caret: 1, path: "A.swift"), location: 0, removed: 0, inserted: "a")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(server.generationRequests.isEmpty && p.suggestion == nil)
    }

    @Test func acceptUnits() {
        #expect(PredictionSession.collapsed("\n    return 1\n}") == "\n    return 1")
        #expect(PredictionSession.nextWord("  foo.bar") == "  foo")
        #expect(PredictionSession.nextWord(".bar") == ".")
        #expect(PredictionSession.nextWord("\n    x = 1") == "\n    x")
    }
}

/// `ycode complete` (§7).
@Suite(.serialized) struct CompleteCLITests {
    @Test func parsesFlags() throws {
        let o = try CompleteCLI.parse(["--file", "a.swift", "--line", "3", "--column", "5", "--backend", "llama-server", "--top-k", "10", "--fim", "qwen", "--json"])
        #expect(o.file == "a.swift" && o.line == 3 && o.column == 5 && o.backend == .llamaServer && o.topK == 10 && o.fim == .qwen && o.json)
        #expect(throws: CompleteCLI.ParseError.usage("--file, --line and --column are required")) { try CompleteCLI.parse(["--file", "a"]) }
        #expect(throws: CompleteCLI.ParseError.usage("unknown backend “x”")) { try CompleteCLI.parse(["--backend", "x"]) }
        var base = PredictiveCompletionSettings()
        base.address = "http://h:1"
        let s = CompleteCLI.settings(o, base: base)
        #expect(s.backend == .llamaServer && s.address == nil && s.topK == 10)
    }

    @Test func runsAgainstTheStandIn() async throws {
        let server = try StandInServer { _, _ in "a + b\n}" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Sum.swift")
        try "func sum(a: Int, b: Int) -> Int {\n    return \n}\n".write(to: file, atomically: true, encoding: .utf8)
        let d = try #require(UserDefaults(suiteName: "ycode-complete-\(UUID().uuidString)"))
        let code = await CompleteCLI.run(["--file", file.path, "--line", "2", "--column", "12", "--address", server.baseURL], defaults: d)
        #expect(code == 0)
        let body = try #require(server.generationRequests.first?.body)
        #expect(body["prompt"] as? String == "func sum(a: Int, b: Int) -> Int {\n    return ")
    }
}
