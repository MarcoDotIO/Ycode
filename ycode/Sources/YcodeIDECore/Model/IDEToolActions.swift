import Foundation
import YcodeBuild
import YcodeProject

/// Product menu commands that run one of ycodebuild's actions in the IDE
/// process (`specs/ide/build.md` §IDE tool actions): Export and Import
/// Localizations (`specs/xcodebuild/localization.md`), Build Documentation
/// (`build-actions.md` §5); plus Delete Derived Data. Command lines here,
/// the session runs them (`WorkspaceSession+Tools.swift`).
public enum IDEToolActions {
    /// What one tool run returns: exit status and the combined output.
    public typealias Runner = @Sendable (_ arguments: [String], _ cwd: String) -> (status: Int32, output: String)

    /// ycodebuild in this process, with its output captured.
    public static let inProcess: Runner = { args, cwd in Organizer.run(args, home: NSHomeDirectory(), cwd: cwd) }

    // MARK: Localizations

    /// The project localizations export and import act on: the project
    /// itself, or a workspace's first project (sorted by path); nil for a
    /// package (the items are disabled there, `reference-ui-5.md` §2.9).
    public static func localizationProject(_ model: WorkspaceModel) -> URL? {
        switch model.kind {
        case .package: nil
        case .project: model.url
        case .workspace: model.projects.keys.sorted().first.map { URL(fileURLWithPath: $0) }
        }
    }

    /// The languages Export Localizations writes: the project's development
    /// region first, then its other known regions (without `Base`), in
    /// project order.
    public static func exportLanguages(_ proj: PBXProj?) -> [String] {
        let dev = proj?.project?.string("developmentRegion") ?? "en"
        let known = proj?.project?.references("knownRegions") ?? []
        var out = [dev]
        for r in known where r != "Base" && !out.contains(r) { out.append(r) }
        return out
    }

    /// `-exportLocalizations -localizationPath <dir> -project <P> -exportLanguage <l>…`.
    public static func exportArguments(project: URL, to directory: URL, languages: [String]) -> [String] {
        ["-exportLocalizations", "-localizationPath", directory.path, "-project", project.path]
            + languages.flatMap { ["-exportLanguage", $0] }
    }

    /// `-importLocalizations -localizationPath <xcloc or xliff> -project <P>`.
    public static func importArguments(project: URL, from path: URL) -> [String] {
        ["-importLocalizations", "-localizationPath", path.path, "-project", project.path]
    }

    /// The folder name Export Localizations proposes: "<project> Localizations".
    public static func exportFolderName(project: URL) -> String {
        "\(project.deletingPathExtension().lastPathComponent) Localizations"
    }

    /// The `.xcloc` folders an export log names ("An xcloc was created at …").
    public static func createdLocalizations(in output: String) -> [String] {
        let marker = "An xcloc was created at "
        return output.split(separator: "\n").compactMap { line in
            line.range(of: marker).map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }
        }
    }

    // MARK: Documentation

    /// `docbuild` for the scheme: `-project`/`-workspace` or (packages) the
    /// package folder as the working directory, then `-scheme <S>
    /// -derivedDataPath <dd> docbuild`. Ycode keeps documentation builds in
    /// `<container folder>/.ycode-build/Documentation` (next to the IDE's
    /// own build folder), so the archives are found at a known place.
    public static func docbuildArguments(container: BuildRequest.Container, scheme: String) -> (arguments: [String], cwd: String, derivedData: String) {
        let (lead, cwd): ([String], String) = switch container {
        case .project(let p): (["-project", p], URL(fileURLWithPath: p).deletingLastPathComponent().path)
        case .workspace(let p): (["-workspace", p], URL(fileURLWithPath: p).deletingLastPathComponent().path)
        case .package(let d): ([], d)
        }
        let dd = cwd + "/.ycode-build/Documentation"
        return (lead + ["-scheme", scheme, "-derivedDataPath", dd, "docbuild"], cwd, dd)
    }

    /// The documentation archives under a docbuild's derived data
    /// (`<dd>/Build/Products/<configuration>/<Module>.doccarchive`), sorted.
    public static func documentationArchives(derivedData: String) -> [String] {
        let fm = FileManager.default
        let products = derivedData + "/Build/Products"
        var out: [String] = []
        for config in ((try? fm.contentsOfDirectory(atPath: products)) ?? []).sorted() {
            let dir = products + "/" + config
            for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where name.hasSuffix(".doccarchive") {
                out.append(dir + "/" + name)
            }
        }
        return out
    }

    // MARK: Derived data

    /// The workspace's derived data folder, from its build folder (the part
    /// of a product path before `/Products/`): the folder itself for
    /// swift-build's layout (`<…>/.ycode-build`), its parent for
    /// xcodebuild's (`<DerivedData>/<Name-hash>/Build`).
    public static func derivedDataFolder(buildFolder: URL) -> URL {
        buildFolder.lastPathComponent == "Build" ? buildFolder.deletingLastPathComponent() : buildFolder
    }

    /// Deletes the derived data folder. Returns false when it could not be
    /// removed (a missing folder counts as deleted).
    @discardableResult
    public static func deleteDerivedData(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return true }
        return (try? fm.removeItem(at: folder)) != nil
    }
}
