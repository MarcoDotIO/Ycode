import Foundation
import YcodeDebug

/// The activity subtitle while a reopened workspace's editors get their
/// language features (`workspace-window.md` W7, council round 8, row 201,
/// completing row 189): the reference keeps its "preparing" line under the
/// title until the restored editors' language features are ready, then
/// shows its indexing line. Ycode keeps its own words
/// (`WorkspaceChrome.preparingEditorServicesText`) from the language
/// server's start until the server has published its first diagnostics for
/// every document the window opened with (or `editorServicesTimeout`
/// passes); the indexing subtitle follows while the server reports
/// progress. Both IDEs start their language service through this.
extension WorkspaceSession {
    /// The longest the subtitle waits for the server's first answer.
    public static let editorServicesTimeout: Duration = .seconds(20)

    /// Starts the language service and opens `documents` (the restored
    /// editors' files and texts) in it, keeping the preparing subtitle
    /// until each has its first diagnostics.
    public func startLanguageService(opening documents: [(url: URL, text: String)], transport: DAPTransport? = nil,
                                     timeout: Duration = editorServicesTimeout) async {
        await startLanguageService(transport: transport)
        // Only sources go to the server (row 228); waiting on a Markdown or
        // JSON file's diagnostics would hold the subtitle to the timeout.
        let documents = documents.filter { LanguageService.handles($0.url) }
        guard let language, !documents.isEmpty else { return }
        isPreparingEditorServices = true
        defer { isPreparingEditorServices = false }
        for d in documents { language.open(d.url, text: d.text) }
        let paths = Set(documents.map { $0.url.standardizedFileURL.path })
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end, !paths.isSubset(of: language.liveDiagnostics.keys), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
