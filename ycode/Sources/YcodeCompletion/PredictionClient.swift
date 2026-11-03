import Foundation

/// A finished suggestion with its timings.
public struct PredictionResult: Sendable, Equatable {
    /// The shaped suggestion ("" when nothing should be shown).
    public var text: String
    /// The model's output as received (up to where the request stopped).
    public var raw: String
    public var model: String?
    /// From sending the request to the first output text (milliseconds).
    public var firstTokenMilliseconds: Double?
    /// From sending the request to the suggestion (milliseconds).
    public var totalMilliseconds: Double
    /// The request was stopped once the suggestion reached a boundary.
    public var stoppedEarly: Bool
}

/// Sends one request and shapes the streamed output; stops the request as
/// soon as the suggestion reached a boundary (predictive-completion.md §4.3).
public struct PredictionClient: Sendable {
    public var backend: PredictionBackend
    public var shaper: SuggestionShaper

    public init(backend: PredictionBackend, shaper: SuggestionShaper = SuggestionShaper()) {
        self.backend = backend
        self.shaper = shaper
    }

    /// The suggestion for `request`. `onUpdate` sees the shaped text as it
    /// grows (on the caller's actor). Throws `PredictionError`, or
    /// `CancellationError` when the calling task is cancelled.
    public func complete(_ request: PredictionRequest, isolation: isolated (any Actor)? = #isolation,
                         onUpdate: ((String) -> Void)? = nil) async throws -> PredictionResult {
        let clock = ContinuousClock()
        let start = clock.now
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        var raw = ""
        var model: String?
        var chat = false
        var first: Double?
        var shown = ""
        var early = false
        for try await e in backend.stream(request) {
            switch e {
            case .model(let m): model = m
            case .chat: chat = true
            case .text(let t):
                if first == nil { first = ms(clock.now - start) }
                raw += t
                let r = shaper.shape(raw, context: request.context, final: false, fromChat: chat)
                if r.text != shown {
                    shown = r.text
                    onUpdate?(shown)
                }
                if r.complete {
                    early = true
                    break
                }
            }
            if early { break }
        }
        try Task.checkCancellation()
        let final = shaper.shape(raw, context: request.context, final: true, fromChat: chat)
        if final.text != shown { onUpdate?(final.text) }
        return PredictionResult(text: final.text, raw: raw, model: model ?? (request.model.isEmpty ? nil : request.model),
                                firstTokenMilliseconds: first, totalMilliseconds: ms(clock.now - start), stoppedEarly: early)
    }
}
