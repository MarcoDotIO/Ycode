import Foundation
import Observation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// File dialogs (round R13; public API names: `fileImporter`, `fileExporter`,
// `FileDocument`, `FileDocumentConfiguration`, `fileDialogDefaultDirectory`,
// `fileDialogMessage`, `fileDialogConfirmationLabel`, `UTType`).
//
// Design (Ycode's): the dialog is OpenViews' own, drawn in the window as a
// sheet (the "open panel" of a Linux app on OpenViews; no desktop portal is
// used). It lists one folder: a bar with Back (to the enclosing folder) and
// the folder's path, the entries sorted by name (hidden files left out), and
// a "Go to" field that takes a path (Return opens a folder or chooses a
// file). Folders open with a double click or Return; a folder whose
// extension names one of the allowed types (a package, such as a project
// bundle) is chosen like a file. Entries that are not allowed are dimmed and
// cannot be chosen. The exporter adds a name field and asks before replacing
// a file. Escape cancels.
//
// `UTType` is OpenViews' own small type registry (the system's
// UniformTypeIdentifiers is not available on Linux): the public type
// identifiers of the common types, their file name extensions and
// conformance, plus dynamic types for other extensions.

// MARK: - UTType

/// A uniform type: an identifier, its file name extensions and the types it
/// conforms to.
public struct UTType: Hashable, Sendable, CustomStringConvertible {
    public let identifier: String
    /// Extensions, the preferred one first.
    let extensions: [String]
    /// Direct supertypes (identifiers).
    let parents: [String]
    public let isDynamic: Bool

    init(identifier: String, extensions: [String], parents: [String], isDynamic: Bool = false) {
        self.identifier = identifier
        self.extensions = extensions
        self.parents = parents
        self.isDynamic = isDynamic
    }

    public static func == (a: UTType, b: UTType) -> Bool { a.identifier == b.identifier }
    public func hash(into h: inout Hasher) { h.combine(identifier) }
    public var description: String { identifier }

    public var preferredFilenameExtension: String? { extensions.first }
    public var isDeclared: Bool { !isDynamic }
    public var isPublic: Bool { identifier.hasPrefix("public.") }

    /// The registered type with this identifier.
    public init?(_ identifier: String) {
        guard let t = UTType.registry[identifier] else { return nil }
        self = t
    }

    /// The registered type for this extension, else a dynamic type that
    /// conforms to `supertype`.
    public init?(filenameExtension ext: String, conformingTo supertype: UTType = .data) {
        let e = ext.lowercased()
        guard !e.isEmpty, !e.contains("/") else { return nil }
        if let t = UTType.byExtension[e], t.conforms(to: supertype) {
            self = t
            return
        }
        self.init(identifier: "dyn.\(supertype.identifier).\(e)", extensions: [e], parents: [supertype.identifier],
                  isDynamic: true)
    }

    /// A type the app declares.
    public init(exportedAs identifier: String, conformingTo parent: UTType? = nil) {
        self = UTType.registry[identifier]
            ?? UTType(identifier: identifier, extensions: [], parents: [(parent ?? .data).identifier])
    }

    /// A type another app declares.
    public init(importedAs identifier: String, conformingTo parent: UTType? = nil) {
        self.init(exportedAs: identifier, conformingTo: parent)
    }

    /// The types this one conforms to (itself excluded).
    public var supertypes: Set<UTType> {
        var out: Set<UTType> = []
        var queue = parents
        while let id = queue.popLast() {
            guard let t = UTType.registry[id], out.insert(t).inserted else { continue }
            queue += t.parents
        }
        return out
    }

    public func conforms(to other: UTType) -> Bool {
        other.identifier == identifier || parents.contains(other.identifier) || supertypes.contains(other)
    }

    public func isSupertype(of other: UTType) -> Bool { other.conforms(to: self) }
    public func isSubtype(of other: UTType) -> Bool { conforms(to: other) }

    // The public types (identifiers and extensions are interoperability
    // facts of the public type system).
    public static let item = UTType(identifier: "public.item", extensions: [], parents: [])
    public static let content = UTType(identifier: "public.content", extensions: [], parents: [])
    public static let data = UTType(identifier: "public.data", extensions: [], parents: ["public.item"])
    public static let directory = UTType(identifier: "public.directory", extensions: [], parents: ["public.item"])
    public static let folder = UTType(identifier: "public.folder", extensions: [], parents: ["public.directory"])
    public static let package = UTType(identifier: "com.apple.package", extensions: [], parents: ["public.directory"])
    public static let text = UTType(identifier: "public.text", extensions: [], parents: ["public.data", "public.content"])
    public static let plainText = UTType(identifier: "public.plain-text", extensions: ["txt", "text"], parents: ["public.text"])
    public static let utf8PlainText = UTType(identifier: "public.utf8-plain-text", extensions: [], parents: ["public.plain-text"])
    public static let sourceCode = UTType(identifier: "public.source-code", extensions: [], parents: ["public.plain-text"])
    public static let swiftSource = UTType(identifier: "public.swift-source", extensions: ["swift"], parents: ["public.source-code"])
    public static let cSource = UTType(identifier: "public.c-source", extensions: ["c"], parents: ["public.source-code"])
    public static let cHeader = UTType(identifier: "public.c-header", extensions: ["h"], parents: ["public.source-code"])
    public static let json = UTType(identifier: "public.json", extensions: ["json"], parents: ["public.text"])
    public static let xml = UTType(identifier: "public.xml", extensions: ["xml"], parents: ["public.text"])
    public static let yaml = UTType(identifier: "public.yaml", extensions: ["yaml", "yml"], parents: ["public.text"])
    public static let propertyList = UTType(identifier: "com.apple.property-list", extensions: ["plist"], parents: ["public.data"])
    public static let image = UTType(identifier: "public.image", extensions: [], parents: ["public.data", "public.content"])
    public static let png = UTType(identifier: "public.png", extensions: ["png"], parents: ["public.image"])
    public static let jpeg = UTType(identifier: "public.jpeg", extensions: ["jpeg", "jpg"], parents: ["public.image"])
    public static let svg = UTType(identifier: "public.svg-image", extensions: ["svg"], parents: ["public.image"])
    public static let pdf = UTType(identifier: "com.adobe.pdf", extensions: ["pdf"], parents: ["public.data", "public.content"])
    public static let archive = UTType(identifier: "public.archive", extensions: [], parents: ["public.data"])
    public static let zip = UTType(identifier: "public.zip-archive", extensions: ["zip"], parents: ["public.archive"])
    public static let executable = UTType(identifier: "public.executable", extensions: [], parents: ["public.item"])
    public static let shellScript = UTType(identifier: "public.shell-script", extensions: ["sh"], parents: ["public.source-code"])
    public static let markdown = UTType(identifier: "net.daringfireball.markdown", extensions: ["md", "markdown"], parents: ["public.plain-text"])

    static let registry: [String: UTType] = {
        let all: [UTType] = [.item, .content, .data, .directory, .folder, .package, .text, .plainText, .utf8PlainText,
                             .sourceCode, .swiftSource, .cSource, .cHeader, .json, .xml, .yaml, .propertyList, .image,
                             .png, .jpeg, .svg, .pdf, .archive, .zip, .executable, .shellScript, .markdown]
        var d: [String: UTType] = [:]
        for t in all { d[t.identifier] = t }
        return d
    }()

    static let byExtension: [String: UTType] = {
        var d: [String: UTType] = [:]
        for t in registry.values { for e in t.extensions where d[e] == nil { d[e] = t } }
        return d
    }()

    /// The type of a file or folder on disk (packages: a folder whose
    /// extension one of `packages` names).
    static func of(_ url: URL, isDirectory: Bool, packages: [UTType] = []) -> UTType {
        let ext = url.pathExtension.lowercased()
        if isDirectory {
            if !ext.isEmpty, let p = packages.first(where: { $0.extensions.contains(ext) }) { return p }
            return .folder
        }
        return UTType(filenameExtension: ext) ?? .data
    }
}

// MARK: - FileWrapper (Linux)

#if !canImport(Darwin)
/// A file or folder as data (corelibs Foundation has no `FileWrapper`;
/// regular files and folders only).
open class FileWrapper {
    public enum Kind { case regular(Data), directory([String: FileWrapper]) }
    var kind: Kind
    open var preferredFilename: String?
    open var filename: String?

    public init(regularFileWithContents contents: Data) { kind = .regular(contents) }

    public init(directoryWithFileWrappers childrenByPreferredName: [String: FileWrapper]) {
        kind = .directory(childrenByPreferredName)
    }

    public init(url: URL, options: ReadingOptions = []) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if isDir.boolValue {
            var kids: [String: FileWrapper] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                let w = try FileWrapper(url: url.appendingPathComponent(name), options: options)
                w.preferredFilename = name
                w.filename = name
                kids[name] = w
            }
            kind = .directory(kids)
        } else {
            kind = .regular(try Data(contentsOf: url))
        }
        filename = url.lastPathComponent
        preferredFilename = url.lastPathComponent
    }

    open var isRegularFile: Bool { if case .regular = kind { return true } else { return false } }
    open var isDirectory: Bool { if case .directory = kind { return true } else { return false } }
    open var regularFileContents: Data? { if case .regular(let d) = kind { return d } else { return nil } }
    open var fileWrappers: [String: FileWrapper]? { if case .directory(let k) = kind { return k } else { return nil } }

    public struct ReadingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let immediate = ReadingOptions(rawValue: 1)
        public static let withoutMapping = ReadingOptions(rawValue: 2)
    }

    public struct WritingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let atomic = WritingOptions(rawValue: 1)
        public static let withNameUpdating = WritingOptions(rawValue: 2)
    }

    open func write(to url: URL, options: WritingOptions = [], originalContentsURL: URL?) throws {
        switch kind {
        case .regular(let d):
            try d.write(to: url, options: options.contains(.atomic) ? .atomic : [])
        case .directory(let kids):
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, w) in kids { try w.write(to: url.appendingPathComponent(name), options: options, originalContentsURL: nil) }
        }
    }
}
#endif

// MARK: - FileDocument

/// A document a file dialog reads and writes.
@preconcurrency
public protocol FileDocument {
    static var readableContentTypes: [UTType] { get }
    static var writableContentTypes: [UTType] { get }
    init(configuration: ReadConfiguration) throws
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper
    typealias ReadConfiguration = FileDocumentReadConfiguration
    typealias WriteConfiguration = FileDocumentWriteConfiguration
}

extension FileDocument {
    public static var writableContentTypes: [UTType] { readableContentTypes }
}

public struct FileDocumentReadConfiguration {
    public let contentType: UTType
    public let file: FileWrapper
}

public struct FileDocumentWriteConfiguration {
    public let contentType: UTType
    public let existingFile: FileWrapper?
}

// MARK: - Dialog options in the environment

private enum FileDialogDirectoryKey: EnvironmentKey { static let defaultValue: URL? = nil }
private enum FileDialogMessageKey: EnvironmentKey { static let defaultValue: String? = nil }
private enum FileDialogConfirmationKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    var _fileDialogDirectory: URL? {
        get { self[FileDialogDirectoryKey.self] }
        set { self[FileDialogDirectoryKey.self] = newValue }
    }

    var _fileDialogMessage: String? {
        get { self[FileDialogMessageKey.self] }
        set { self[FileDialogMessageKey.self] = newValue }
    }

    var _fileDialogConfirmation: String? {
        get { self[FileDialogConfirmationKey.self] }
        set { self[FileDialogConfirmationKey.self] = newValue }
    }
}

/// Errors the dialogs report.
public enum FileDialogError: Error, Equatable {
    case notAllowed(URL)
    case writeFailed(String)
}

extension View {
    /// The folder a file dialog in this view opens in.
    public func fileDialogDefaultDirectory(_ url: URL?) -> some View { environment(\._fileDialogDirectory, url) }

    /// A message the dialog shows under its title.
    public func fileDialogMessage(_ message: Text?) -> some View {
        environment(\._fileDialogMessage, message?.plainString)
    }

    @_disfavoredOverload
    public func fileDialogMessage<S: StringProtocol>(_ message: S) -> some View {
        environment(\._fileDialogMessage, String(message))
    }

    /// The title of the dialog's confirm button.
    public func fileDialogConfirmationLabel(_ label: Text?) -> some View {
        environment(\._fileDialogConfirmation, label?.plainString)
    }

    @_disfavoredOverload
    public func fileDialogConfirmationLabel<S: StringProtocol>(_ label: S) -> some View {
        environment(\._fileDialogConfirmation, String(label))
    }

    /// Asks for a file (or folder) of `allowedContentTypes` to open.
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType],
                             onCompletion: @escaping (Result<URL, any Error>) -> Void) -> some View {
        modifier(FileDialogModifier(isPresented: isPresented, mode: .open(types: allowedContentTypes, multiple: false),
                                    complete: { r in onCompletion(r.map { $0[0] }) }, cancelled: {}))
    }

    /// Asks for one or several files to open.
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool,
                             onCompletion: @escaping (Result<[URL], any Error>) -> Void) -> some View {
        modifier(FileDialogModifier(isPresented: isPresented, mode: .open(types: allowedContentTypes, multiple: allowsMultipleSelection),
                                    complete: onCompletion, cancelled: {}))
    }

    /// Like `fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:onCompletion:)`, and
    /// `onCancellation` runs when the dialog is dismissed without a choice.
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool,
                             onCompletion: @escaping (Result<[URL], any Error>) -> Void,
                             onCancellation: @escaping () -> Void) -> some View {
        modifier(FileDialogModifier(isPresented: isPresented, mode: .open(types: allowedContentTypes, multiple: allowsMultipleSelection),
                                    complete: onCompletion, cancelled: onCancellation))
    }

    /// Asks where to save `document` and writes it there.
    public func fileExporter<D: FileDocument>(isPresented: Binding<Bool>, document: D?, contentType: UTType,
                                              defaultFilename: String? = nil,
                                              onCompletion: @escaping (Result<URL, any Error>) -> Void) -> some View {
        let write: (URL) throws -> Void = { url in
            guard let document else { throw FileDialogError.writeFailed("no document") }
            let existing = try? FileWrapper(url: url, options: [])
            let w = try document.fileWrapper(configuration: FileDocumentWriteConfiguration(contentType: contentType, existingFile: existing))
            try w.write(to: url, options: .atomic, originalContentsURL: nil)
        }
        return modifier(FileDialogModifier(isPresented: isPresented,
                                           mode: .save(type: contentType, defaultName: defaultFilename, write: write),
                                           complete: { r in onCompletion(r.map { $0[0] }) }, cancelled: {}))
    }
}

// MARK: - The dialog

enum FileDialogMode {
    case open(types: [UTType], multiple: Bool)
    case save(type: UTType, defaultName: String?, write: (URL) throws -> Void)
}

struct FileDialogModifier: ViewModifier {
    let isPresented: Binding<Bool>
    let mode: FileDialogMode
    let complete: (Result<[URL], any Error>) -> Void
    let cancelled: () -> Void
    @Environment(\._fileDialogDirectory) private var directory
    @Environment(\._fileDialogMessage) private var message
    @Environment(\._fileDialogConfirmation) private var confirmation

    func body(content: Content) -> some View {
        let binding = isPresented, complete = complete, cancelled = cancelled
        let start = directory ?? FileManager.default.homeDirectoryForCurrentUser
        content.sheet(isPresented: isPresented) {
            FilePanel(mode: mode, start: start, message: message, confirmation: confirmation,
                      finish: { result in
                          binding.wrappedValue = false
                          if let result { complete(result) } else { cancelled() }
                      })
        }
    }
}

/// One entry of the listed folder.
struct FilePanelEntry: Identifiable, Hashable {
    let url: URL
    let isFolder: Bool
    let type: UTType
    let isAllowed: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// The dialog's state and rules (no view types; tested directly).
@MainActor
@Observable
final class FilePanelModel {
    let mode: FileDialogMode
    private(set) var folder: URL
    private(set) var entries: [FilePanelEntry] = []
    var selection: Set<URL> = []
    var goTo = ""
    var name = ""
    private(set) var error: String?
    /// The file the exporter asks about replacing.
    private(set) var confirmReplace: URL?

    init(mode: FileDialogMode, start: URL) {
        self.mode = mode
        folder = FilePanelModel.normalized(start)
        if case .save(let type, let defaultName, _) = mode {
            let base = defaultName ?? "Untitled"
            if let ext = type.preferredFilenameExtension, (base as NSString).pathExtension.isEmpty {
                name = base + "." + ext
            } else {
                name = base
            }
        }
        reload()
    }

    /// A folder URL by its standardized path (no trailing slash), so that
    /// folders compare equal however they were reached.
    static func normalized(_ url: URL) -> URL {
        var p = url.standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    var allowedTypes: [UTType] {
        switch mode {
        case .open(let t, _): return t
        case .save(let t, _, _): return [t]
        }
    }

    var allowsMultiple: Bool {
        if case .open(_, let m) = mode { return m }
        return false
    }

    var isSave: Bool { if case .save = mode { return true } else { return false } }

    /// Whether folders themselves can be chosen.
    var foldersAllowed: Bool { allowedTypes.contains { UTType.folder.conforms(to: $0) } }

    func isAllowed(_ type: UTType) -> Bool { allowedTypes.contains { type.conforms(to: $0) } }

    func reload() {
        error = nil
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let packages = allowedTypes.filter { $0.conforms(to: .directory) && $0.preferredFilenameExtension != nil }
        var out: [FilePanelEntry] = []
        for n in names where !n.hasPrefix(".") {
            let u = folder.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            let type = UTType.of(u, isDirectory: isDir.boolValue, packages: packages)
            let isFolder = type == .folder
            let allowed = isFolder ? foldersAllowed : isAllowed(type)
            out.append(FilePanelEntry(url: u, isFolder: isFolder, type: type, isAllowed: allowed))
        }
        entries = out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selection = selection.filter { s in entries.contains { $0.url == s } }
        if names.isEmpty && !fm.fileExists(atPath: folder.path) { error = "The folder “\(folder.lastPathComponent)” does not exist." }
    }

    func open(folder url: URL) {
        folder = FilePanelModel.normalized(url)
        selection = []
        reload()
    }

    func goUp() {
        let parent = folder.deletingLastPathComponent()
        if parent.path != folder.path { open(folder: parent) }
    }

    /// The parts of the folder's path, root first.
    var pathComponents: [(name: String, url: URL)] {
        var out: [(String, URL)] = []
        var u = folder
        while true {
            out.append((u.path == "/" ? "/" : u.lastPathComponent, u))
            let p = u.deletingLastPathComponent()
            if p.path == u.path || u.path == "/" { break }
            u = p
        }
        return out.reversed()
    }

    var selectedEntries: [FilePanelEntry] { entries.filter { selection.contains($0.url) } }

    /// The URLs the confirm button would choose (nil: it cannot).
    var choice: [URL]? {
        if isSave {
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, !n.contains("/") else { return nil }
            return [folder.appendingPathComponent(n)]
        }
        let sel = selectedEntries
        if sel.isEmpty { return foldersAllowed ? [folder] : nil }
        guard sel.allSatisfy(\.isAllowed) else { return nil }
        return sel.map(\.url)
    }

    /// The confirm button opens the selected folder instead of choosing.
    var confirmEntersFolder: Bool {
        let sel = selectedEntries
        return sel.count == 1 && sel[0].isFolder && (!sel[0].isAllowed || isSave)
    }

    var canConfirm: Bool { confirmEntersFolder || choice != nil }

    /// A double click (or Return) on an entry: folders open, allowed files
    /// are chosen. Returns the choice to finish with.
    func activate(_ e: FilePanelEntry) -> [URL]? {
        if e.isFolder {
            open(folder: e.url)
            return nil
        }
        if isSave {
            name = e.name
            return confirm()
        }
        return e.isAllowed ? [e.url] : nil
    }

    /// The confirm button. Returns the choice to finish with.
    func confirm() -> [URL]? {
        if confirmEntersFolder, let e = selectedEntries.first {
            open(folder: e.url)
            return nil
        }
        guard let c = choice else { return nil }
        if isSave, let u = c.first, FileManager.default.fileExists(atPath: u.path), confirmReplace != u {
            confirmReplace = u
            return nil
        }
        return c
    }

    func cancelReplace() { confirmReplace = nil }

    /// The "Go to" field: a folder opens, an allowed file is chosen.
    func goToPath() -> [URL]? {
        var p = goTo.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        if p.hasPrefix("~") { p = FileManager.default.homeDirectoryForCurrentUser.path + p.dropFirst() }
        let u = p.hasPrefix("/") ? URL(fileURLWithPath: p) : folder.appendingPathComponent(p)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else {
            if isSave, FileManager.default.fileExists(atPath: u.deletingLastPathComponent().path) {
                open(folder: u.deletingLastPathComponent())
                name = u.lastPathComponent
                goTo = ""
                return nil
            }
            error = "“\(p)” does not exist."
            return nil
        }
        goTo = ""
        let packages = allowedTypes.filter { $0.conforms(to: .directory) && $0.preferredFilenameExtension != nil }
        let type = UTType.of(u, isDirectory: isDir.boolValue, packages: packages)
        if type == .folder {
            open(folder: u)
            return nil
        }
        if isSave {
            open(folder: u.deletingLastPathComponent())
            name = u.lastPathComponent
            return confirm()
        }
        guard isAllowed(type) else {
            error = "“\(u.lastPathComponent)” cannot be opened here."
            return nil
        }
        return [u.standardizedFileURL]
    }
}

/// The dialog's view.
struct FilePanel: View {
    let finish: (Result<[URL], any Error>?) -> Void
    let message: String?
    let confirmation: String?
    @State private var model: FilePanelModel

    init(mode: FileDialogMode, start: URL, message: String?, confirmation: String?,
         finish: @escaping (Result<[URL], any Error>?) -> Void) {
        _model = State(initialValue: FilePanelModel(mode: mode, start: start))
        self.message = message
        self.confirmation = confirmation
        self.finish = finish
    }

    private func done(_ urls: [URL]?) {
        guard let urls else { return }
        if case .save(_, _, let write) = model.mode, let u = urls.first {
            do {
                try write(u)
                finish(.success(urls))
            } catch {
                finish(.failure(error))
            }
        } else {
            finish(.success(urls))
        }
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 10) {
            Text(model.isSave ? "Save" : "Open").font(.headline)
            if let message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
            if model.isSave {
                HStack(spacing: 8) {
                    Text("Save As:").font(.callout)
                    TextField("Name", text: Bindable(model).name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { done(model.confirm()) }
                        .accessibilityIdentifier("file dialog name")
                }
            }
            HStack(spacing: 6) {
                Button { model.goUp() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Enclosing Folder")
                    .accessibilityLabel("Enclosing Folder")
                    .accessibilityIdentifier("file dialog up")
                Text(verbatim: model.folder.path).font(.callout).lineLimit(1).truncationMode(.head)
                    .accessibilityIdentifier("file dialog folder")
                Spacer(minLength: 0)
            }
            List(selection: Bindable(model).selection) {
                ForEach(model.entries) { e in
                    HStack(spacing: 6) {
                        Image(systemName: e.isFolder ? "folder.fill" : (e.type.conforms(to: .directory) ? "square.stack.3d.up" : "doc"))
                            .foregroundStyle(e.isFolder ? Color.accentColor : Color.secondary)
                        Text(verbatim: e.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .opacity(e.isAllowed || e.isFolder ? 1 : 0.4)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 2).onEnded { done(model.activate(e)) })
                    .accessibilityIdentifier("file \(e.name)")
                    .tag(e.url)
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 220)
            .accessibilityIdentifier("file dialog list")
            if let replace = model.confirmReplace {
                HStack(spacing: 8) {
                    Text(verbatim: "“\(replace.lastPathComponent)” already exists. Replace it?").font(.callout)
                    Spacer(minLength: 0)
                    Button("Don’t Replace") { model.cancelReplace() }
                    Button("Replace") { done(model.confirm()) }
                        .accessibilityIdentifier("file dialog replace")
                }
            }
            if let error = model.error {
                Text(verbatim: error).font(.callout).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Text("Go to:").font(.callout).foregroundStyle(.secondary)
                TextField("Path", text: Bindable(model).goTo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { done(model.goToPath()) }
                    .accessibilityIdentifier("file dialog path")
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("file dialog cancel")
                Button(model.confirmEntersFolder ? "Open Folder" : (confirmation ?? (model.isSave ? "Save" : "Open"))) {
                    done(model.confirm())
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConfirm)
                .accessibilityIdentifier("file dialog confirm")
            }
        }
        .padding(16)
        .frame(width: 620, height: 440)
    }
}
