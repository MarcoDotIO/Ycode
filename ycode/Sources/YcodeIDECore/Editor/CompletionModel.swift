import Foundation
import YcodeLanguage

/// The list of completions under the insertion point. It filters by the
/// partial word typed since it opened. See `specs/ide/language.md`
/// §Completion.
@MainActor
public struct CompletionModel {
    public private(set) var all: [CompletionItem] = []
    public private(set) var visible: [CompletionItem] = []
    public var selected = 0
    /// Where the word being completed starts (UTF-16 offset).
    public private(set) var wordStart = 0

    public init() {}

    public mutating func reset(items: [CompletionItem], wordStart: Int, prefix: String) {
        all = items
        self.wordStart = wordStart
        filter(prefix)
    }

    /// Prefix matches first (case-insensitive), then substring matches.
    public mutating func filter(_ prefix: String) {
        guard !prefix.isEmpty else { visible = all; selected = 0; return }
        let p = prefix.lowercased()
        let starts = all.filter { $0.label.lowercased().hasPrefix(p) }
        let contains = all.filter { !$0.label.lowercased().hasPrefix(p) && $0.label.lowercased().contains(p) }
        visible = starts + contains
        selected = 0
    }

    public mutating func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        selected = min(max(0, selected + delta), visible.count - 1)
    }

    public var current: CompletionItem? { visible.indices.contains(selected) ? visible[selected] : nil }

    /// The start of the identifier that ends at `offset` in `text`.
    public static func wordStart(in text: NSString, before offset: Int) -> Int {
        var i = offset
        while i > 0 {
            let c = text.character(at: i - 1)
            let isWord = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
            if !isWord { break }
            i -= 1
        }
        return i
    }
}
