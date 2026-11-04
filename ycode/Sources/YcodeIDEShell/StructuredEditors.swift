import Foundation
import YcodeIDECore

/// An editor other than the source editor, chosen by file type as the
/// macOS IDE chooses (`WorkspaceWindowController.display`): asset catalogs
/// (`.xcassets`), String Catalogs (`.xcstrings`), property lists (`.plist`,
/// `.entitlements`).
@MainActor
public enum StructuredEditor {
    case propertyList(PlistEditorModel)
    case assetCatalog(AssetCatalogEditorModel)
    case stringCatalog(StringCatalogEditorModel)

    public var path: String {
        switch self {
        case .propertyList(let m): m.path
        case .assetCatalog(let m): m.path
        case .stringCatalog(let m): m.path
        }
    }

    /// The Editor menu's kind while this editor is shown.
    public var editorKind: EditorKind {
        switch self {
        case .propertyList: .propertyList
        case .assetCatalog: .assetCatalog
        case .stringCatalog: .other
        }
    }

    /// The structured editor's name in the Open As switch.
    public var title: String {
        switch self {
        case .propertyList: "Property List"
        case .assetCatalog: "Asset Catalog"
        case .stringCatalog: "String Catalog"
        }
    }

    /// Whether a file of this name opens in a structured editor.
    public static func handles(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["plist", "entitlements", "xcassets", "xcstrings"].contains(ext)
    }

    /// Whether the file can also be shown as source text (Open As ▸ Source
    /// Code): everything but asset catalogs, which are folders.
    public static func hasSourceView(_ path: String) -> Bool {
        handles(path) && (path as NSString).pathExtension.lowercased() != "xcassets"
    }

    /// The editor for `path`, or nil when the file is not one of these
    /// types or cannot be read as one (it then opens as text).
    public static func open(_ path: String) -> StructuredEditor? {
        switch (path as NSString).pathExtension.lowercased() {
        case "xcassets":
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return .assetCatalog(AssetCatalogEditorModel(path: path))
        case "xcstrings": return (try? StringCatalogEditorModel(path: path)).map(StructuredEditor.stringCatalog)
        case "plist", "entitlements": return (try? PlistEditorModel(path: path)).map(StructuredEditor.propertyList)
        default: return nil
        }
    }
}

/// The structured editors in the workspace window (`specs/ide/plist-editor.md`,
/// `asset-catalog.md`, `string-catalog.md`).
extension WorkspaceShellModel {
    /// Shows `path` in its structured editor unless the user chose its
    /// source view; true when it did.
    func showStructured(_ path: String) -> Bool {
        guard !sourceViewPaths.contains(path), let s = StructuredEditor.open(path) else {
            structuredEditor = nil
            return false
        }
        if case .stringCatalog(let m) = s {
            m.onAddLanguage = { [weak self] code in self?.addKnownRegion(code, forFileAt: path) }
            m.sourceFiles = { [weak self] in self?.stringCatalogSourceFiles(forCatalogAt: path) ?? [] }
        }
        structuredEditor = s
        editor = nil
        document = SourceDocument(path: path, language: SyntaxLanguage(fileName: (path as NSString).lastPathComponent), lines: [])
        findBar.documentChanged(to: nil)
        syncEditorIssues()
        return true
    }

    /// The Editor menu's kind for what is shown.
    public var editorKind: EditorKind { structuredEditor?.editorKind ?? .source }

    /// Whether the open file is shown as source text although it has a
    /// structured editor.
    public var isShowingSourceView: Bool { document.map { sourceViewPaths.contains($0.path) } ?? false }

    /// Open As ▸ Source Code / Property List (String Catalog): switches the
    /// open file between its structured editor and its text. Unsaved text is
    /// saved first, so the structured editor reads what the text says; a
    /// text document the structured editor wrote under is read again.
    public func setShowsSourceView(_ on: Bool) {
        guard let path = document?.path, StructuredEditor.hasSourceView(path), on != sourceViewPaths.contains(path) else { return }
        if on {
            sourceViewPaths.insert(path)
            if let d = openDocuments[path], !d.isDirty { openDocuments[path] = nil }
        } else {
            if editor?.path == path, editor?.isDirty == true {
                guard saveCurrent() else { return }
            }
            openDocuments[path] = nil
            sourceViewPaths.remove(path)
        }
        structuredEditor = nil
        document = nil
        showFile(path)
    }

    /// Editor-menu actions of the structured editors, by `CommandTable`
    /// action; true when it was performed.
    @discardableResult
    public func performEditorAction(_ action: String, tag: Int = 0) -> Bool {
        switch (structuredEditor, action) {
        case (.propertyList(let m), "addPlistItem:"): m.addItem()
        case (.propertyList(let m), "setPlistValueType:"):
            guard PlistTree.types.indices.contains(tag) else { return false }
            return m.setTypeOfSelection(PlistTree.types[tag])
        case (.propertyList(let m), "toggleRawKeysAndValues:"): m.showsRawKeys.toggle()
        case (.assetCatalog(let m), "addNewAsset:"): return m.add(tag: tag)
        case (.assetCatalog(let m), "deleteSelectedAssets:"): return m.removeSelected()
        default: return false
        }
        return true
    }

    /// Whether an Editor-menu action applies now, and whether it shows a
    /// check mark.
    public func editorActionState(_ action: String, tag: Int = 0) -> (enabled: Bool, checked: Bool)? {
        switch (structuredEditor, action) {
        case (.propertyList, "addPlistItem:"): return (true, false)
        case (.propertyList(let m), "setPlistValueType:"):
            let type = PlistTree.types.indices.contains(tag) ? PlistTree.types[tag] : ""
            return (m.selection != nil, m.selectedTypeName == type)
        case (.propertyList(let m), "toggleRawKeysAndValues:"): return (true, m.showsRawKeys)
        case (.assetCatalog(let m), "addNewAsset:"): return (m.canAdd(tag: tag) && tag != AssetCatalog.AddMenuTags.importFiles
                                                               && tag != AssetCatalog.AddMenuTags.stickerFrame, false)
        case (.assetCatalog(let m), "deleteSelectedAssets:"): return (m.selectedRow != nil, false)
        default: return nil
        }
    }

    // MARK: Project hooks

    /// A language added in a String Catalog joins its project's
    /// `knownRegions` (once), as the macOS IDE does.
    func addKnownRegion(_ code: String, forFileAt file: String) {
        let paths = session.model.projects.keys.sorted()
        guard let path = paths.first(where: { file.hasPrefix(URL(fileURLWithPath: $0).deletingLastPathComponent().path + "/") }) ?? paths.first,
              var proj = session.model.projects[path] else { return }
        let before = proj.objects
        proj.addKnownRegion(code)
        guard proj.objects != before else { return }
        session.model.projects[path] = proj
        try? session.model.saveProjects()
    }

    /// The sources Refresh from Source reads: those of the targets that
    /// hold the catalog (empty: the editor reads its folder).
    func stringCatalogSourceFiles(forCatalogAt path: String) -> [String] {
        let paths = session.model.projects.keys.sorted()
        guard let project = paths.first(where: { path.hasPrefix(URL(fileURLWithPath: $0).deletingLastPathComponent().path + "/") }),
              let proj = session.model.projects[project] else { return [] }
        return proj.localizableSourceFiles(forResourceAt: path, projectDirectory: proj.projectDirectory(xcodeprojURL: URL(fileURLWithPath: project)))
    }
}
