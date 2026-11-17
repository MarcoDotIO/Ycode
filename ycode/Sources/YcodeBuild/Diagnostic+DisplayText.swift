import Foundation

extension Diagnostic {
    /// An issue's message as the issue navigator, the editor's annotations
    /// and the toolbar show it (`specs/ide/parity-inventory.md` P-121): the
    /// compiler's diagnostic-group suffix (" [#VariableNeverMutated]") is
    /// dropped and the first word starts with a capital letter
    /// ("Variable 'neverMutated' was never mutated…").
    ///
    /// Only a first word made of lower-case letters and followed by a space
    /// is capitalized, so tool prefixes ("ld: …"), quoted names
    /// ("'x' is deprecated") and identifiers stay as written.
    public static func displayMessage(_ raw: String) -> String {
        var text = raw
        while let r = text.range(of: #"\s*\[#[A-Za-z0-9_]+\]\s*$"#, options: .regularExpression) {
            text.removeSubrange(r)
        }
        guard let space = text.firstIndex(of: " ") else { return text }
        let first = text[..<space]
        guard !first.isEmpty, first.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else { return text }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The same issue with its message, and its notes' messages, in display form.
    public var displayed: Diagnostic {
        var d = self
        d.message = Self.displayMessage(message)
        d.notes = notes.map(\.displayed)
        return d
    }
}
