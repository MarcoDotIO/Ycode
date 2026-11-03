import Foundation

/// `ycode complete`: one predictive completion at a position of a file,
/// printed on standard output (predictive-completion.md §7). The settings
/// come from Ycode's user defaults (`Ycode.predictiveCompletion`); flags
/// override them. Works without the switch being on.
public enum CompleteCLI {
    public static let help = """
    usage: ycode complete --file <F> --line <L> --column <C> [options]

    Prints a predictive code completion for the position (1-based line and
    column, in characters) of the file. The suggestion is what the editor
    would show as ghost text after the caret.

      --backend ollama|llama-server|openai   default: the setting (Ollama)
      --address <URL>        the server (default: the setting; Ollama's is shared
                             with the coding assistant, else 127.0.0.1:11434)
      --model <ID>           default: the setting; for Ollama, the first installed
                             model that can fill in the middle
      --max-tokens <N>       --temperature <T>   --top-p <P>   --top-k <K>   --repeat-penalty <R>
      --fim auto|qwen|starcoder|codellama|deepseek|suffix-first|chat
                             the prompt format for an OpenAI-compatible server
      --related <file>       another file to take related snippets from (repeatable)
      --raw                  print the model's output before shaping instead
      --json                 print {suggestion, raw, model, firstTokenMs, totalMs, stoppedEarly}
      --timing               print the timings on standard error

    """

    public struct Options: Equatable {
        public var file = ""
        public var line = 0
        public var column = 0
        public var backend: PredictiveCompletionSettings.Backend?
        public var address: String?
        public var model: String?
        public var maxTokens: Int?
        public var temperature: Double?
        public var topP: Double?
        public var topK: Int?
        public var repeatPenalty: Double?
        public var fim: FIMFormat?
        public var related: [String] = []
        public var raw = false
        public var json = false
        public var timing = false
        public init() {}
    }

    public enum ParseError: Error, Equatable { case usage(String), help }

    public static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw ParseError.usage("\(flag) needs a value") }
            return args[i]
        }
        func int(_ flag: String) throws -> Int {
            guard let n = Int(try value(flag)) else { throw ParseError.usage("\(flag) needs a number") }
            return n
        }
        func double(_ flag: String) throws -> Double {
            guard let n = Double(try value(flag)) else { throw ParseError.usage("\(flag) needs a number") }
            return n
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--file": o.file = try value(a)
            case "--line": o.line = try int(a)
            case "--column": o.column = try int(a)
            case "--backend":
                switch try value(a) {
                case "ollama": o.backend = .ollama
                case "llama-server", "llama", "llamacpp", "llama.cpp": o.backend = .llamaServer
                case "openai", "openai-compatible": o.backend = .openAICompatible
                case let b: throw ParseError.usage("unknown backend “\(b)”")
                }
            case "--address": o.address = try value(a)
            case "--model": o.model = try value(a)
            case "--max-tokens": o.maxTokens = try int(a)
            case "--temperature": o.temperature = try double(a)
            case "--top-p": o.topP = try double(a)
            case "--top-k": o.topK = try int(a)
            case "--repeat-penalty": o.repeatPenalty = try double(a)
            case "--fim":
                let v = try value(a)
                let map: [String: FIMFormat] = ["auto": .auto, "qwen": .qwen, "starcoder": .starCoder, "codellama": .codeLlama,
                                                "deepseek": .deepSeek, "suffix-first": .suffixFirst, "chat": .chat]
                guard let f = map[v] else { throw ParseError.usage("unknown FIM format “\(v)”") }
                o.fim = f
            case "--related": o.related.append(try value(a))
            case "--raw": o.raw = true
            case "--json": o.json = true
            case "--timing": o.timing = true
            case "-h", "--help": throw ParseError.help
            default: throw ParseError.usage("unknown option \(a)")
            }
            i += 1
        }
        guard !o.file.isEmpty, o.line >= 1, o.column >= 1 else { throw ParseError.usage("--file, --line and --column are required") }
        return o
    }

    /// The settings after the flags.
    public static func settings(_ o: Options, base: PredictiveCompletionSettings) -> PredictiveCompletionSettings {
        var s = base
        if let b = o.backend, b != s.backend {
            s.backend = b
            s.address = nil
        }
        if let a = o.address { s.address = a }
        if let m = o.model { s.model = m }
        if let n = o.maxTokens { s.maxTokens = n }
        if let t = o.temperature { s.temperature = t }
        if let p = o.topP { s.topP = p }
        if let k = o.topK { s.topK = k }
        if let r = o.repeatPenalty { s.repeatPenalty = r }
        if let f = o.fim { s.fimFormat = f }
        return s
    }

    /// Runs one completion; returns the exit status.
    public static func run(_ args: [String], defaults: UserDefaults = .standard) async -> Int32 {
        let o: Options
        do { o = try parse(args) } catch ParseError.help {
            print(help, terminator: "")
            return 0
        } catch {
            if case ParseError.usage(let m) = error { FileHandle.standardError.write(Data("ycode complete: \(m)\n".utf8)) }
            FileHandle.standardError.write(Data(help.utf8))
            return 64
        }
        guard let text = try? String(contentsOfFile: o.file, encoding: .utf8) else {
            FileHandle.standardError.write(Data("ycode complete: cannot read \(o.file)\n".utf8))
            return 66
        }
        guard let caret = CompletionContext.offset(in: text, line: o.line, column: o.column) else {
            FileHandle.standardError.write(Data("ycode complete: the file has no line \(o.line)\n".utf8))
            return 65
        }
        let s = settings(o, base: PredictiveCompletionSettings.load(from: defaults))
        let others = o.related.compactMap { p in (try? String(contentsOfFile: p, encoding: .utf8)).map { (path: (p as NSString).lastPathComponent, text: $0) } }
        let before = (text as NSString).substring(to: caret)
        let related = s.relatedTokens > 0 ? RelatedSnippets.pick(query: before, files: others, limit: s.limits.maxRelated) : []
        let context = CompletionContext.make(text: text, caret: caret, path: (o.file as NSString).lastPathComponent, related: related, limits: s.limits)
        let backend = s.makeBackend(assistantOllamaURL: PredictiveCompletionSettings.assistantOllamaURL(in: defaults))
        do {
            let r = try await PredictionClient(backend: backend, shaper: SuggestionShaper(maxLines: s.maxLines))
                .complete(PredictionRequest(context: context, settings: s))
            if o.json {
                var obj: [String: Any] = ["suggestion": r.text, "raw": r.raw, "totalMs": r.totalMilliseconds, "stoppedEarly": r.stoppedEarly,
                                          "backend": s.backend.rawValue, "address": backend.address]
                if let m = r.model { obj["model"] = m }
                if let f = r.firstTokenMilliseconds { obj["firstTokenMs"] = f }
                let d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
                print(String(decoding: d, as: UTF8.self))
            } else {
                print(o.raw ? r.raw : r.text)
            }
            if o.timing {
                let first = r.firstTokenMilliseconds.map { String(format: "%.0f ms", $0) } ?? "–"
                FileHandle.standardError.write(Data(String(format: "model %@ · first token %@ · total %.0f ms%@\n", r.model ?? "?", first,
                                                           r.totalMilliseconds, r.stoppedEarly ? " (stopped at a boundary)" : "").utf8))
            }
            return r.text.isEmpty && !o.raw ? 1 : 0
        } catch {
            let p = error as? PredictionError
            FileHandle.standardError.write(Data("ycode complete: \(p?.errorDescription ?? error.localizedDescription)\n".utf8))
            if let h = p?.hint { FileHandle.standardError.write(Data("\(h)\n".utf8)) }
            return 69
        }
    }

    /// `run` for a synchronous `main`.
    public static func runBlocking(_ args: [String]) -> Int32 {
        let box = ExitBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await run(args)
            done.signal()
        }
        done.wait()
        return box.value
    }

    final class ExitBox: @unchecked Sendable { var value: Int32 = 0 }
}
