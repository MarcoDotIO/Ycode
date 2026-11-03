import Foundation
import YcodeBuild

/// Product ▸ Export Localizations…, Import Localizations…, Build
/// Documentation: one ycodebuild action run off the main thread, shown in
/// the activity view and recorded in the Report navigator
/// (`specs/ide/build.md` §IDE tool actions).
extension WorkspaceSession {
    /// The outcome of one tool action.
    public struct ToolOutcome: Equatable, Sendable {
        public var succeeded: Bool
        public var output: String
        /// What it made: `.xcloc` folders or `.doccarchive` bundles.
        public var products: [String]
    }

    /// Runs `arguments` through `runner`, with "<title>" while it runs and
    /// "<title> Succeeded" / "<title> Failed" after; the log becomes a
    /// report named "<title> <subject>".
    @discardableResult
    public func runToolAction(title: String, arguments: [String], cwd: String, runner: @escaping IDEToolActions.Runner = IDEToolActions.inProcess,
                              products: @escaping @Sendable (String) -> [String] = { _ in [] }) async -> ToolOutcome {
        let started = Date()
        setActivity(.building(title))
        let (status, output) = await Task.detached { runner(arguments, cwd) }.value
        let ok = status == 0
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var report = BuildReport(title: "\(title) \(scheme ?? model.displayName)", date: Date(), succeeded: ok, log: lines,
                                 errorCount: lines.filter { $0.contains("error:") }.count, warningCount: lines.filter { $0.contains("warning:") }.count)
        report.context = reportContext(action: title, started: started)
        recordReport(report)
        setActivity(.finished("\(title) \(ok ? "Succeeded" : "Failed")"))
        return ToolOutcome(succeeded: ok, output: output, products: ok ? products(output) : [])
    }

    /// Product ▸ Export Localizations…: every language of the project into
    /// `directory` (one `<lang>.xcloc` each).
    @discardableResult
    public func exportLocalizations(to directory: URL, runner: @escaping IDEToolActions.Runner = IDEToolActions.inProcess) async -> ToolOutcome? {
        guard let project = IDEToolActions.localizationProject(model) else { return nil }
        let languages = IDEToolActions.exportLanguages(model.projects[project.path])
        return await runToolAction(title: "Export Localizations", arguments: IDEToolActions.exportArguments(project: project, to: directory, languages: languages),
                                   cwd: project.deletingLastPathComponent().path, runner: runner, products: IDEToolActions.createdLocalizations(in:))
    }

    /// Product ▸ Import Localizations…: one `.xcloc` (or `.xliff`) into the project.
    @discardableResult
    public func importLocalizations(from path: URL, runner: @escaping IDEToolActions.Runner = IDEToolActions.inProcess) async -> ToolOutcome? {
        guard let project = IDEToolActions.localizationProject(model) else { return nil }
        return await runToolAction(title: "Import Localizations", arguments: IDEToolActions.importArguments(project: project, from: path),
                                   cwd: project.deletingLastPathComponent().path, runner: runner)
    }

    /// Product ▸ Build Documentation (⌃⇧⌘D): `docbuild` of the scheme.
    @discardableResult
    public func buildDocumentation(runner: @escaping IDEToolActions.Runner = IDEToolActions.inProcess) async -> ToolOutcome? {
        guard let scheme else { return nil }
        let request = model.buildRequest(scheme: scheme, destination: destination, action: .build)
        let (args, cwd, dd) = IDEToolActions.docbuildArguments(container: request.container, scheme: scheme)
        return await runToolAction(title: "Build Documentation", arguments: args, cwd: cwd, runner: runner,
                                   products: { _ in IDEToolActions.documentationArchives(derivedData: dd) })
    }
}
