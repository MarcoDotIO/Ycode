import Foundation

/// What to build. See `specs/ide/build.md` §Requests.
public struct BuildRequest: Equatable, Sendable {
    public enum Container: Equatable, Sendable {
        case project(String)
        case workspace(String)
        /// A directory with a `Package.swift`.
        case package(String)

        /// Picks the container kind from a path's extension.
        public init(path: String) {
            switch URL(fileURLWithPath: path).pathExtension {
            case "xcworkspace": self = .workspace(path)
            case "xcodeproj": self = .project(path)
            default:
                self = .package(path.hasSuffix("Package.swift") ? URL(fileURLWithPath: path).deletingLastPathComponent().path : path)
            }
        }

        public var path: String {
            switch self { case .project(let p), .workspace(let p), .package(let p): p }
        }
    }

    public enum Action: String, Sendable, CaseIterable {
        case build, clean, test, analyze
        /// `build-for-testing`, the build half of a test run.
        case buildForTesting = "build-for-testing"
        /// `test-without-building`: runs tests built by an earlier
        /// `build-for-testing`.
        case testWithoutBuilding = "test-without-building"
    }

    public var container: Container
    public var scheme: String?
    public var configuration: String?
    /// A destination specifier, `key=value[,key=value]` (e.g.
    /// `platform=macOS,arch=arm64`).
    public var destination: String?
    public var action: Action
    public var derivedDataPath: String?
    /// `NAME=value` overrides at the highest precedence level.
    public var settings: [(String, String)]

    public init(container: Container, scheme: String? = nil, configuration: String? = nil, destination: String? = nil,
                action: Action = .build, derivedDataPath: String? = nil, settings: [(String, String)] = []) {
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
        self.action = action
        self.derivedDataPath = derivedDataPath
        self.settings = settings
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.container == b.container && a.scheme == b.scheme && a.configuration == b.configuration
            && a.destination == b.destination && a.action == b.action && a.derivedDataPath == b.derivedDataPath
            && a.settings.elementsEqual(b.settings, by: ==)
    }
}

public enum BuildStatus: Equatable, Sendable {
    case succeeded, failed, cancelled
}

public struct BuildResult: Equatable, Sendable {
    public var status: BuildStatus
    public var exitCode: Int32
    public var issues: [Diagnostic]
    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    public init(status: BuildStatus, exitCode: Int32, issues: [Diagnostic]) {
        self.status = status
        self.exitCode = exitCode
        self.issues = issues
    }
}

/// Everything a build reports while it runs, in order.
public enum BuildEvent: Equatable, Sendable {
    /// One raw log line, for the build log and console.
    case output(String)
    case issue(Diagnostic)
    /// The engine's own progress text (for the toolbar activity view).
    case activity(String)
    case finished(BuildResult)
}

/// A build back end. The first one drives `xcodebuild`; the planned second
/// one generates PIF and drives swift-build directly (M3). Both report
/// through the same event stream so the UI does not care which runs.
public protocol BuildEngine: Sendable {
    var name: String { get }
    /// Starts a build. The stream ends after `.finished`.
    func start(_ request: BuildRequest) -> BuildOperation
    /// The executable that Run launches after building `request`, if any.
    func executablePath(for request: BuildRequest) -> String?
}

extension BuildEngine {
    public func executablePath(for request: BuildRequest) -> String? { nil }
}

/// A running build: its events and a way to stop it.
public struct BuildOperation: Sendable {
    public let events: AsyncStream<BuildEvent>
    public let cancel: @Sendable () -> Void
    public init(events: AsyncStream<BuildEvent>, cancel: @escaping @Sendable () -> Void) {
        self.events = events
        self.cancel = cancel
    }

    /// Waits for the build, passing each event to `handler`.
    public func run(_ handler: (BuildEvent) -> Void = { _ in }) async -> BuildResult {
        for await e in events {
            handler(e)
            if case .finished(let r) = e { return r }
        }
        return BuildResult(status: .cancelled, exitCode: -1, issues: [])
    }

    /// Blocks the calling thread until the build ends (command-line use).
    public func runBlocking(_ handler: @escaping @Sendable (BuildEvent) -> Void) -> BuildResult {
        final class Box: @unchecked Sendable { var result = BuildResult(status: .cancelled, exitCode: -1, issues: []) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let events = self.events
        Task.detached {
            for await e in events {
                handler(e)
                if case .finished(let r) = e { box.result = r }
            }
            done.signal()
        }
        done.wait()
        return box.result
    }
}

/// Splits a byte stream into lines. Partial lines wait for more data.
public struct LineBuffer: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            buffer = Data(buffer[(nl + 1)...])
        }
        return lines
    }

    /// The final unterminated line, if any.
    public mutating func flush() -> String? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}
