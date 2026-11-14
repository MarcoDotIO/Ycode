import Foundation
import YcodeDebug

/// The language server's work in progress (`$/progress`, LSP 3.17 work-done
/// progress): while any is running, the workspace is indexing, and the
/// activity view says so under the window's title (`workspace-window.md`
/// W7.2, council row 189; Ycode's own words).
public struct LanguageProgress: Equatable, Sendable {
    /// Running work by token.
    public private(set) var running: [String: String] = [:]

    public init() {}

    public var isActive: Bool { !running.isEmpty }

    /// Applies one `$/progress` notification's parameters; true when the
    /// set of running work changed.
    @discardableResult
    public mutating func apply(_ params: JSON) -> Bool {
        guard let token = params["token"].map(Self.key), let value = params["value"] else { return false }
        switch value["kind"]?.string {
        case "begin":
            running[token] = value["title"]?.string ?? ""
            return true
        case "end":
            return running.removeValue(forKey: token) != nil
        default:
            return false
        }
    }

    static func key(_ token: JSON) -> String {
        if let s = token.string { return s }
        if let n = token.int { return String(n) }
        return "\(token)"
    }
}

extension WorkspaceChrome {
    /// The subtitle while the language server indexes the workspace.
    public static let indexingText = "Indexing files"

    /// The idle subtitle: starting the language server, else indexing, else nothing.
    public static func idleActivityText(preparingEditorServices: Bool, indexing: Bool) -> String {
        preparingEditorServices ? preparingEditorServicesText : indexing ? indexingText : ""
    }
}
