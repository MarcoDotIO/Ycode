import Foundation
@_exported import YcodeSyntax

/// The editor's lexical tokens as color roles: a thin view of
/// `YcodeSyntax` (`specs/ide/source-editor.md`, "Ycode implementation")
/// for the code that masks comments and strings (folding, Re-Indent,
/// test discovery, the symbol index) and for the theme's color rows.
/// Highlighting itself goes through `SyntaxDocument`.
public struct SourceTokenizer: Sendable {
    /// The languages Ycode colors (`SyntaxLanguage`).
    public typealias Language = SyntaxLanguage

    /// A token's color role: the theme's color and font keys.
    public typealias Kind = SyntaxTokenKind.Role

    public struct Token: Equatable, Sendable {
        public var kind: Kind
        /// UTF-16 range, ready for NSAttributedString.
        public var range: NSRange
    }

    public let language: Language
    public init(language: Language) { self.language = language }

    /// The text's tokens with a color (multi-line tokens whole), in order.
    public func tokens(in text: String) -> [Token] {
        SyntaxLexers.tokens(in: text, language: language).compactMap { t in
            let role = t.kind.role
            return role == .identifier ? nil : Token(kind: role, range: t.range)
        }
    }
}

extension EditorTheme {
    /// The theme color for a token kind: its role's entry (nil: the
    /// system color for the role). Portable; each shell converts it.
    public func color(for kind: SyntaxTokenKind) -> ThemeColor? { ThemeColor(hex: tokens[kind.role.rawValue]) }
}
