import Foundation
import YcodeBuild
import YcodeDebug
import YcodeLanguage

/// The scheme and run destination a project's build server indexes for
/// (`specs/ide/language.md` §Build server: they are in the connection
/// file's `argv`).
public struct LanguageBuildContext: Equatable, Sendable {
    public var scheme: String?
    /// The destination's specifier (`platform=iOS Simulator,id=…`).
    public var destination: String?
    public init(scheme: String?, destination: String?) {
        self.scheme = scheme
        self.destination = destination
    }
}

/// The session's record of the context its language server was started
/// with, and the restart a change schedules.
@MainActor
final class LanguageRestartState {
    /// The context the running server serves; nil when it has none to
    /// follow (a package, no build server, or not started).
    var context: LanguageBuildContext?
    var pending: Task<Void, Never>?
    /// Makes the transport of a restarted server (tests; nil: sourcekit-lsp).
    var makeTransport: (() -> DAPTransport)?
    var count = 0
}

/// Following the scheme and destination (`specs/ide/language.md` §Build
/// server, "Context changes"): the build server reads both from its command
/// line, so a change of either rewrites the connection file and restarts
/// sourcekit-lsp, which starts the build server again. The open documents
/// are opened in the new server, so live issues and completion use the new
/// SDK's settings. Shared by the macOS window and the Linux shell.
extension WorkspaceSession {
    /// The context the window's scheme and destination give now.
    public var languageBuildContext: LanguageBuildContext {
        LanguageBuildContext(scheme: scheme, destination: destination?.specifier)
    }

    /// The context the running language server serves (nil: it follows none).
    public var languageServedContext: LanguageBuildContext? { languageRestart.context }

    /// How many times the language server was restarted for a new context.
    public var languageRestartCount: Int { languageRestart.count }

    /// The transport for restarted servers (tests). With one set, a server
    /// started on an injected transport for a project follows the context too.
    public var languageTransportFactory: (() -> DAPTransport)? {
        get { languageRestart.makeTransport }
        set { languageRestart.makeTransport = newValue }
    }

    /// The scheme or destination changed: restarts the server shortly after
    /// (a burst of changes, such as a scheme switch that picks a new
    /// destination, restarts it once).
    func buildContextChanged() {
        guard language != nil, let served = languageRestart.context, served != languageBuildContext else { return }
        languageRestart.pending?.cancel()
        languageRestart.pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.restartLanguageService()
        }
    }

    /// Waits for a scheduled restart to finish (tests, drivers).
    public func languageContextSettled() async {
        while let t = languageRestart.pending {
            await t.value
            if languageRestart.pending == t { languageRestart.pending = nil }
        }
    }

    /// Stops the language server and starts it again for the current
    /// context; the open documents and the edit handler carry over. Live
    /// issues are cleared until the new server publishes its own.
    public func restartLanguageService() async {
        guard let old = language else { return }
        let documents = old.openTexts
        let applyEdit = old.onApplyEdit
        language = nil
        notify(.issues)
        await old.stop()
        await startLanguageService(transport: languageRestart.makeTransport?())
        languageRestart.count += 1
        guard let new = language else { return }
        new.onApplyEdit = applyEdit
        for (url, text) in documents.sorted(by: { $0.key.path < $1.key.path }) { new.open(url, text: text) }
    }
}
