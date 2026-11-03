import Foundation

// `OpenURLAction` and `EnvironmentValues.openURL` (api-inventory.md: declared
// in SwiftUICore). The default action hands the URL to the system; an
// application host installs it (on Linux the desktop's URL opener).

/// Opens a URL: `openURL(url)` from the environment.
public struct OpenURLAction: Sendable {
    /// What a handler did with a URL.
    public struct Result: Sendable, Equatable {
        package enum Kind: Sendable, Equatable {
            case handled
            case discarded
            case systemAction(URL?)
        }
        package let kind: Kind

        public static let handled = Result(kind: .handled)
        public static let discarded = Result(kind: .discarded)
        public static let systemAction = Result(kind: .systemAction(nil))
        public static func systemAction(_ url: URL) -> Result { Result(kind: .systemAction(url)) }
    }

    package let handler: @MainActor @Sendable (URL) -> Result

    /// The system's URL opener, used for `.systemAction` (installed by the
    /// application host; on Linux the desktop's opener).
    @MainActor package static var systemOpener: (URL) -> Bool = { _ in false }

    /// An action whose handler decides; `.systemAction` falls through to the
    /// system.
    public init(handler: @escaping @MainActor @Sendable (URL) -> Result) {
        self.handler = handler
    }

    @MainActor
    @discardableResult
    package func open(_ url: URL) -> Bool {
        switch handler(url).kind {
        case .handled: return true
        case .discarded: return false
        case .systemAction(let other): return Self.systemOpener(other ?? url)
        }
    }

    @MainActor
    public func callAsFunction(_ url: URL) { open(url) }

    @MainActor
    public func callAsFunction(_ url: URL, completion: (Bool) -> Void) { completion(open(url)) }
}

private enum OpenURLKey: EnvironmentKey {
    static let defaultValue = OpenURLAction { _ in .systemAction }
}

extension EnvironmentValues {
    /// The action that opens URLs for views in this environment.
    public var openURL: OpenURLAction {
        get { self[OpenURLKey.self] }
        set { self[OpenURLKey.self] = newValue }
    }
}
