import Foundation

/// Uses `primary` for requests it supports and `fallback` for the rest, so
/// choosing swift-build never makes a project unbuildable. See
/// `specs/ide/settings.md`.
public struct FallbackEngine: BuildEngine {
    public let primary: BuildEngine
    public let fallback: BuildEngine
    public let supports: @Sendable (BuildRequest) -> Bool

    public init(primary: BuildEngine, fallback: BuildEngine, supports: @escaping @Sendable (BuildRequest) -> Bool) {
        self.primary = primary
        self.fallback = fallback
        self.supports = supports
    }

    public var name: String { primary.name }

    public func engine(for request: BuildRequest) -> BuildEngine { supports(request) ? primary : fallback }

    public func start(_ request: BuildRequest) -> BuildOperation { engine(for: request).start(request) }

    public func executablePath(for request: BuildRequest) -> String? { engine(for: request).executablePath(for: request) }
}
