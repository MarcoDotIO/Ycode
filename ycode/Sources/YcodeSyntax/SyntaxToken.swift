import Foundation

/// What a highlighted range is. Finer than the editor theme's color
/// roles: `role` maps each kind onto one (the theme has a color per role).
public enum SyntaxTokenKind: UInt8, Sendable, CaseIterable, Hashable {
    // Code
    case keyword, comment, docComment, string, character, number, preprocessor, attribute, typeName, identifier
    case regex, escape, variable, placeholder
    // Data and markup
    case key, tagName, attributeName, entity, heading, emphasis, strong, codeSpan, link, url, listMarker, quote

    /// The editor theme's color roles (`EditorTheme.tokens` keys).
    public enum Role: String, Sendable, CaseIterable, Hashable {
        case keyword, comment, docComment, string, number, preprocessor, attribute, typeName, identifier
    }

    /// The color role a kind is drawn with.
    public var role: Role {
        switch self {
        case .keyword, .heading, .tagName, .listMarker: .keyword
        case .comment, .quote: .comment
        case .docComment: .docComment
        case .string, .character, .regex, .codeSpan, .url: .string
        case .number, .entity, .escape: .number
        case .preprocessor: .preprocessor
        case .attribute, .attributeName, .key, .strong, .emphasis: .attribute
        case .typeName, .variable, .link: .typeName
        case .identifier, .placeholder: .identifier
        }
    }

    /// Comments and strings: brackets inside them do not count for the
    /// structure model and typing does not pair inside them.
    public var isCommentOrString: Bool {
        switch self {
        case .comment, .docComment, .string, .character, .regex, .codeSpan: true
        default: false
        }
    }
}

/// One highlighted range, in UTF-16 code units (the editor's and LSP's
/// offsets).
public struct SyntaxToken: Equatable, Sendable, Hashable {
    public var kind: SyntaxTokenKind
    public var location: Int
    public var length: Int

    public init(kind: SyntaxTokenKind, location: Int, length: Int) {
        self.kind = kind
        self.location = location
        self.length = length
    }

    public var end: Int { location + length }
    public var range: NSRange { NSRange(location: location, length: length) }
}
