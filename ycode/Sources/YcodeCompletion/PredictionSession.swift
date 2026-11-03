import Foundation

/// The editor side of predictive completion, without a toolkit
/// (predictive-completion.md §4.5): when to ask (debounced, after typing;
/// at once for Show Predictive Completion), cancelling, the suggestion
/// anchored at the caret, typing through it, dismissing it and accepting
/// it whole, by line or by word. The macOS editor drives it today; the
/// Linux editor (milestone L2) is meant to drive the same object.
@MainActor
public final class PredictionSession {
    /// A suggestion shown at a UTF-16 offset of the document.
    public struct Suggestion: Sendable, Equatable {
        public var anchor: Int
        public var text: String
        public init(anchor: Int, text: String) {
            self.anchor = anchor
            self.text = text
        }
    }

    public enum Status: Sendable, Equatable {
        case idle
        case requesting
        case ready(model: String?)
        /// The backend cannot be used; `hint` says what to do.
        case unavailable(message: String, hint: String?)
    }

    /// What the editor reports on each change.
    public struct Snapshot: Sendable {
        public var text: String
        public var caret: Int
        public var selectionLength: Int
        public var path: String
        public var language: String?
        /// The other open files, for related snippets.
        public var otherFiles: [(path: String, text: String)]
        public init(text: String, caret: Int, selectionLength: Int = 0, path: String, language: String? = nil,
                    otherFiles: [(path: String, text: String)] = []) {
            self.text = text
            self.caret = caret
            self.selectionLength = selectionLength
            self.path = path
            self.language = language
            self.otherFiles = otherFiles
        }
    }

    /// How much an accept takes.
    public enum AcceptUnit: Sendable { case all, shown, line, word }

    public var settings: PredictiveCompletionSettings {
        didSet { if oldValue != settings { cancel(); if !settings.enabled { dismiss() } } }
    }
    /// The coding assistant's Ollama address (shared when the settings
    /// name none).
    public var assistantOllamaURL: String?
    /// Makes the backend for a request (tests substitute stand-ins).
    public var makeBackend: (PredictiveCompletionSettings, String?) -> PredictionBackend = { s, shared in s.makeBackend(assistantOllamaURL: shared) }
    /// After "nothing answers", automatic requests wait this long (Show
    /// Predictive Completion always tries).
    public var unreachableBackoff: TimeInterval = 30

    public private(set) var suggestion: Suggestion?
    public private(set) var status: Status = .idle
    /// The last finished request's result (timings, model).
    public private(set) var lastResult: PredictionResult?
    /// Requests sent (tests and the spec's measurements).
    public private(set) var requestCount = 0

    public var onSuggestionChange: ((Suggestion?) -> Void)?
    public var onStatusChange: ((Status) -> Void)?

    private var cache = SuggestionCache()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var backoffUntil: Date?
    /// Text typed through the suggestion while its request still streams.
    private var typedAhead = ""

    public init(settings: PredictiveCompletionSettings = PredictiveCompletionSettings(), assistantOllamaURL: String? = nil) {
        self.settings = settings
        self.assistantOllamaURL = assistantOllamaURL
    }

    /// A request is waiting or streaming.
    public var isBusy: Bool { task != nil }

    // MARK: Events from the editor

    /// The text changed by replacing `removed` UTF-16 units at `location`
    /// with `inserted`. Typing the suggestion's next characters keeps the
    /// rest; anything else drops it and (debounced) asks again.
    public func textDidChange(_ s: Snapshot, location: Int, removed: Int, inserted: String) {
        if let sug = suggestion, removed == 0, location == sug.anchor, !inserted.isEmpty, sug.text.hasPrefix(inserted) {
            let rest = String(sug.text.dropFirst(inserted.count))
            // A request still streaming learns what was typed into it.
            if task != nil { typedAhead += inserted }
            set(rest.isEmpty ? nil : Suggestion(anchor: sug.anchor + inserted.utf16.count, text: rest))
            return
        }
        set(nil)
        guard settings.enabled, s.selectionLength == 0 else { return cancel() }
        if let until = backoffUntil, until > Date() { return }
        let c = context(s, related: false)
        guard !c.isMidLine else { return cancel() } // Ycode's choice: automatic suggestions only where the rest of the line is closers
        request(c, snapshot: s, anchor: s.caret, force: false)
    }

    /// The caret moved without an edit: a suggestion elsewhere goes away.
    public func selectionDidChange(caret: Int, length: Int) {
        if let sug = suggestion, caret != sug.anchor || length > 0 { dismiss() }
    }

    /// Show Predictive Completion: asks now, wherever the caret is.
    public func forceRequest(_ s: Snapshot) {
        guard s.selectionLength == 0 else { return }
        set(nil)
        backoffUntil = nil
        request(context(s, related: false), snapshot: s, anchor: s.caret, force: true)
    }

    /// Escape: hides the suggestion and stops a request.
    public func dismiss() {
        cancel()
        set(nil)
    }

    /// The text to insert for an accept (the editor inserts it at the
    /// anchor; that edit types through the suggestion). Nil: nothing shown.
    public func acceptText(_ unit: AcceptUnit) -> String? {
        guard let s = suggestion, !s.text.isEmpty else { return nil }
        switch unit {
        case .all: return s.text
        case .shown: return Self.collapsed(s.text)
        case .line: return Self.firstLine(s.text)
        case .word: return Self.nextWord(s.text)
        }
    }

    /// What the collapsed suggestion shows: through the end of its first
    /// line with text (a suggestion that starts with a line break shows the
    /// next line too).
    public static func collapsed(_ text: String) -> String {
        firstLine(text)
    }

    static func firstLine(_ text: String) -> String {
        var out = ""
        var sawText = false
        for ch in text {
            if ch == "\n" {
                if sawText { break }
                out.append(ch)
                continue
            }
            if ch != " " && ch != "\t" { sawText = true }
            out.append(ch)
        }
        return out
    }

    /// The next segment: line breaks and spaces, then one run of word
    /// characters or of other characters.
    static func nextWord(_ text: String) -> String {
        var out = ""
        var it = text.makeIterator()
        var pending: Character?
        while let ch = it.next() {
            if ch == " " || ch == "\t" || ch == "\n" { out.append(ch) } else { pending = ch; break }
        }
        guard let first = pending else { return out }
        out.append(first)
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        let wordRun = isWord(first)
        while let ch = it.next() {
            if ch == " " || ch == "\t" || ch == "\n" || isWord(ch) != wordRun { break }
            out.append(ch)
        }
        return out
    }

    // MARK: Requests

    /// The context for a snapshot under the current limits; related
    /// snippets only with `related` (they are picked after the debounce,
    /// not on every keystroke).
    public func context(_ s: Snapshot, related includeRelated: Bool = true) -> CompletionContext {
        let limits = settings.limits
        var related: [RelatedSnippet] = []
        if includeRelated, limits.relatedTokens > 0, !s.otherFiles.isEmpty {
            let ns = s.text as NSString
            let before = ns.substring(to: max(0, min(s.caret, ns.length)))
            related = RelatedSnippets.pick(query: before, files: s.otherFiles, limit: limits.maxRelated)
        }
        return CompletionContext.make(text: s.text, caret: s.caret, path: s.path, language: s.language, related: related, limits: limits)
    }

    var source: String {
        let a = settings.effectiveAddress(assistantOllamaURL: assistantOllamaURL)
        return "\(settings.backend.rawValue) \(a) \(settings.model)"
    }

    /// Asks for `c` (the cache key has no related snippets); `snapshot`
    /// supplies them once the debounce is over.
    func request(_ c: CompletionContext, snapshot: Snapshot? = nil, anchor: Int, force: Bool) {
        cancel()
        generation += 1
        let g = generation
        if let hit = cache.lookup(c, source: source) {
            set(Suggestion(anchor: anchor, text: hit))
            return
        }
        let settings = self.settings
        let backend = makeBackend(settings, assistantOllamaURL)
        let delay = force ? 0 : max(0, settings.debounceMilliseconds)
        let source = self.source
        typedAhead = ""
        task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            let full = snapshot.map { self.context($0) } ?? c
            self.requestCount += 1
            self.setStatus(.requesting)
            let client = PredictionClient(backend: backend, shaper: SuggestionShaper(maxLines: settings.maxLines))
            do {
                let r = try await client.complete(PredictionRequest(context: full, settings: settings)) { [weak self] partial in
                    guard let self, g == self.generation else { return }
                    self.set(self.adjusted(partial, anchor: anchor))
                }
                guard g == self.generation else { return }
                self.task = nil
                self.lastResult = r
                self.backoffUntil = nil
                self.cache.insert(r.text, for: c, source: source)
                self.set(self.adjusted(r.text, anchor: anchor))
                self.typedAhead = ""
                self.setStatus(.ready(model: r.model))
            } catch {
                guard g == self.generation, !(error is CancellationError) else { return }
                self.task = nil
                self.set(nil)
                let p = error as? PredictionError
                if p?.isUnreachable == true { self.backoffUntil = Date().addingTimeInterval(self.unreachableBackoff) }
                self.setStatus(.unavailable(message: p?.errorDescription ?? error.localizedDescription, hint: p?.hint))
            }
        }
    }

    /// `text` (suggested at `anchor`) after what was typed into it meanwhile.
    func adjusted(_ text: String, anchor: Int) -> Suggestion? {
        guard text.hasPrefix(typedAhead) else { return nil }
        let rest = String(text.dropFirst(typedAhead.count))
        return rest.isEmpty ? nil : Suggestion(anchor: anchor + typedAhead.utf16.count, text: rest)
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
    }

    private func set(_ s: Suggestion?) {
        guard s != suggestion else { return }
        suggestion = s
        onSuggestionChange?(s)
    }

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        onStatusChange?(s)
    }
}
