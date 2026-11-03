import Foundation

/// A small least-recently-used cache of suggestions by the text around the
/// caret (predictive-completion.md §4.4). Besides exact hits, a prefix that
/// extends a cached one by text the cached suggestion starts with returns
/// the rest of that suggestion (typing through, then deleting back, then
/// typing again costs no request).
public struct SuggestionCache: Sendable {
    public struct Key: Hashable, Sendable {
        public var prefixTail: String
        public var suffixHead: String
        /// Backend, address and model: suggestions do not cross servers.
        public var source: String
    }

    public let capacity: Int
    /// The characters of each side that make up a key.
    public let prefixWindow: Int
    public let suffixWindow: Int
    private var entries: [Key: String] = [:]
    private var order: [Key] = []

    public init(capacity: Int = 32, prefixWindow: Int = 512, suffixWindow: Int = 256) {
        self.capacity = max(1, capacity)
        self.prefixWindow = prefixWindow
        self.suffixWindow = suffixWindow
    }

    public var count: Int { entries.count }

    public func key(_ c: CompletionContext, source: String) -> Key {
        Key(prefixTail: String(c.prefix.suffix(prefixWindow)), suffixHead: String(c.suffix.prefix(suffixWindow)), source: source)
    }

    public mutating func insert(_ suggestion: String, for c: CompletionContext, source: String) {
        guard !suggestion.isEmpty else { return }
        let k = key(c, source: source)
        entries[k] = suggestion
        touch(k)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }

    /// The suggestion for `c`: an exact hit, or the rest of a cached
    /// suggestion the newer prefix has typed into.
    public mutating func lookup(_ c: CompletionContext, source: String) -> String? {
        let k = key(c, source: source)
        if let s = entries[k] {
            touch(k)
            return s
        }
        let head = String(c.suffix.prefix(suffixWindow))
        for e in order.reversed() where e.source == source && e.suffixHead == head {
            guard let s = entries[e] else { continue }
            let maxTyped = min(s.count - 1, 128)
            guard maxTyped >= 1 else { continue }
            for n in 1...maxTyped {
                let typed = String(c.prefix.suffix(n))
                guard s.hasPrefix(typed) else { continue }
                let before = String(c.prefix.dropLast(n))
                if String(before.suffix(prefixWindow)) == e.prefixTail || before.hasSuffix(e.prefixTail) {
                    touch(e)
                    return String(s.dropFirst(typed.count))
                }
            }
        }
        return nil
    }

    private mutating func touch(_ k: Key) {
        order.removeAll { $0 == k }
        order.append(k)
    }
}
