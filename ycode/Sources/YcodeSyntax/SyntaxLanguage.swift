import Foundation

/// The languages the editor colors, indents and pairs brackets for
/// (`specs/ide/source-editor.md`, "Ycode implementation").
///
/// The order is part of the editor's Syntax Coloring menu tags, so new
/// cases go at the end.
public enum SyntaxLanguage: String, Sendable, CaseIterable, Hashable {
    case swift, objc, c, plain
    case cpp, metal, json, xml, markdown, yaml, shell, xcconfig

    /// The language for a file name, by extension (and a few well-known
    /// names). Headers are Objective-C, a superset of C; `.mm` files are
    /// colored as Objective-C (its keyword set includes C++'s).
    public init(fileName: String) {
        let url = URL(fileURLWithPath: fileName)
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "swift", "swiftinterface": self = .swift
        case "m", "mm", "h", "pch": self = .objc
        case "c": self = .c
        case "cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "ipp", "tpp", "inl", "modulemap": self = .cpp
        case "metal": self = .metal
        case "json", "jsonc", "geojson", "xcstrings", "xcactivitylog-json", "resolved", "ycodetheme": self = .json
        case "xml", "plist", "entitlements", "xib", "storyboard", "xcscheme", "xcworkspacedata", "xcsettings", "svg",
             "xcplayground", "xcbkptlist", "html", "htm", "xhtml", "xliff", "xlf", "strings-xml", "sdef", "intentdefinition",
             "xccheckout", "xcscmblueprint", "dae", "rss", "atom":
            self = .xml
        case "md", "markdown", "mdown", "mkd", "docc": self = .markdown
        case "yml", "yaml": self = .yaml
        case "sh", "bash", "zsh", "ksh", "command", "tool": self = .shell
        case "xcconfig": self = .xcconfig
        default:
            switch name {
            case "Package.resolved": self = .json
            case ".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", "Makefile.sh": self = .shell
            case ".swiftlint.yml", ".clang-format": self = .yaml
            default: self = .plain
            }
        }
    }

    /// The name shown in Editor ▸ Syntax Coloring.
    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .objc: "Objective-C"
        case .c: "C"
        case .plain: "None"
        case .cpp: "C++"
        case .metal: "Metal"
        case .json: "JSON"
        case .xml: "XML"
        case .markdown: "Markdown"
        case .yaml: "YAML"
        case .shell: "Shell Script"
        case .xcconfig: "Build Configuration File"
        }
    }

    /// C, C++, Objective-C and Metal: one lexer with per-dialect keywords.
    public var isCFamily: Bool { self == .c || self == .cpp || self == .objc || self == .metal }

    /// Programming languages with declarations (symbols, functions, folding
    /// by braces): Swift and the C family.
    public var isCode: Bool { self == .swift || isCFamily }

    /// How the language comments out a line.
    public enum CommentStyle: Equatable, Sendable {
        /// A prefix at the line start (`//`, `#`).
        case line(String)
        /// A pair around the lines (`<!--`, `-->`).
        case block(String, String)
    }

    /// The comment Editor ▸ Structure ▸ Comment Selection uses; nil: the
    /// language has none.
    public var commentStyle: CommentStyle? {
        switch self {
        case .swift, .objc, .c, .cpp, .metal, .json, .xcconfig: .line("//")
        case .yaml, .shell: .line("#")
        case .xml, .markdown: .block("<!--", "-->")
        case .plain: nil
        }
    }

    /// The bracket pairs typing pairs and the structure model matches
    /// (the same in every language).
    public static let bracketPairs: [(open: Character, close: Character)] = [("(", ")"), ("[", "]"), ("{", "}")]

    /// The quote characters typing pairs.
    public var quotes: [Character] {
        switch self {
        case .swift: ["\""]
        case .objc, .c, .cpp, .metal: ["\"", "'"]
        case .json, .xcconfig: ["\""]
        case .xml: ["\"", "'"]
        case .markdown: ["`"]
        case .yaml: ["\"", "'"]
        case .shell: ["\"", "'", "`"]
        case .plain: ["\""]
        }
    }
}
