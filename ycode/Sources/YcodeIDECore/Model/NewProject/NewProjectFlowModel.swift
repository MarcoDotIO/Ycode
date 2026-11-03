import Foundation
import YcodePlist
import YcodeProject
import YcodeSubprocess
import YcodeWorkspace

/// File ▸ New ▸ Project…'s steps as one portable model, driven by the
/// AppKit sheet, the Linux shell's sheet and tests (`specs/ide/templates.md`
/// § "Template chooser", § "Options step"): the template step (tab,
/// filter, sectioned grid, the per-tab memory), the options step (the
/// template's form) and what the next New Project starts from.
public struct NewProjectFlowModel: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case template, options }
    /// The New Project chooser or the Package… chooser.
    public enum Chooser: String, Equatable, Sendable { case project, package }

    /// The save step's remembered folder and Git checkbox (§ Persistence, § Save step).
    public static let saveFolderKey = Keys.saveFolder
    public static let gitKey = Keys.git

    public static let templateHeading = ProjectTemplateCatalog.heading
    public static let optionsHeading = ProjectOptions.heading

    /// § Persistence keys (Ycode's own names).
    enum Keys {
        static func tab(_ c: Chooser) -> String { c == .project ? "YcodeNewProjectTab" : "YcodeNewPackageTab" }
        static func template(_ c: Chooser, _ tab: String) -> String { "\(c == .project ? "YcodeNewProjectTemplate" : "YcodeNewPackageTemplate").\(tab)" }
        static let options = "YcodeNewProjectOptions"
        static let saveFolder = "YcodeNewProjectLocation"
        static let pickerRow = "YcodeNewProjectPickerRow"
        static let git = "YcodeNewProjectCreateGitRepository"
        /// The older single-template key ("<tab>/<title>" or an identifier).
        static let legacy = "YcodeLastProjectTemplate"
    }

    public let chooser: Chooser
    public private(set) var step = Step.template
    public private(set) var platform: String
    public private(set) var filter = ""
    /// The selected template (nil when the filter hides every template).
    public private(set) var selected: ProjectTemplateDescriptor?
    /// The options of the selected template.
    public private(set) var form: TemplateOptionsForm
    /// The template last selected on each tab ("<Section>/<Template>").
    private var perTab: [String: String] = [:]
    /// Option values shared by every template (§ Persistence): each
    /// template's options start from them when still allowed.
    public private(set) var sharedValues: [String: String]
    /// The Team pop-up's value (rule 8; not a template option).
    public var team = "None"

    var catalog: TemplateChooserCatalog { chooser == .project ? ProjectTemplates.projects : ProjectTemplates.packages }

    public init(chooser: Chooser = .project, platform: String? = nil, template: String? = nil, organization: String = "",
                sharedValues: [String: String] = [:], perTab: [String: String] = [:]) {
        self.chooser = chooser
        let catalog = chooser == .project ? ProjectTemplates.projects : ProjectTemplates.packages
        var shared = sharedValues
        if !organization.isEmpty { shared[TemplateOptionID.organizationIdentifier] = organization }
        self.sharedValues = shared
        self.perTab = perTab
        let start = template.flatMap { catalog.find($0) }
        let tab = start?.platform ?? platform ?? catalog.tabs[0]
        self.platform = catalog.tabs.contains(tab) ? tab : catalog.tabs[0]
        let first = start ?? Self.remembered(catalog, self.platform, perTab) ?? catalog.templates(platform: self.platform).first
        selected = first
        form = (first ?? catalog.templates[0]).makeForm(shared)
        if let first { self.perTab[self.platform] = first.memoryKey }
    }

    static func remembered(_ catalog: TemplateChooserCatalog, _ tab: String, _ perTab: [String: String]) -> ProjectTemplateDescriptor? {
        guard let key = perTab[tab] else { return nil }
        return catalog.templates(platform: tab).first { $0.memoryKey == key }
    }

    /// The model the last New Project left (§ Persistence): its tab, that
    /// tab's template, the shared option values.
    public init(defaults: UserDefaults, chooser: Chooser = .project) {
        let catalog = chooser == .project ? ProjectTemplates.projects : ProjectTemplates.packages
        var perTab: [String: String] = [:]
        for t in catalog.tabs { if let v = defaults.string(forKey: Keys.template(chooser, t)) { perTab[t] = v } }
        var tab = defaults.string(forKey: Keys.tab(chooser))
        var template: String?
        if chooser == .project, tab == nil, let raw = defaults.string(forKey: Keys.legacy), let d = ProjectTemplates.find(raw) {
            tab = d.platform
            template = d.id
        }
        let shared = (defaults.dictionary(forKey: Keys.options) as? [String: String]) ?? [:]
        self.init(chooser: chooser, platform: tab, template: template, sharedValues: shared, perTab: perTab)
    }

    /// Stores the tab, the tab's template and the shared option values.
    public func remember(in defaults: UserDefaults) {
        defaults.set(platform, forKey: Keys.tab(chooser))
        for (t, v) in perTab { defaults.set(v, forKey: Keys.template(chooser, t)) }
        defaults.set(sharedValues.merging(form.persistedValues) { $1 }, forKey: Keys.options)
        if chooser == .project, let selected { defaults.set(selected.id, forKey: Keys.legacy) }
    }

    public var tabs: [String] { catalog.tabs }
    public var sections: [TemplateSection] { catalog.sections(platform: platform, filter: filter) }
    public var visibleTemplates: [ProjectTemplateDescriptor] {
        sections.flatMap(\.entries).compactMap { e in catalog.templates.first { $0.id == e.templateID } }
    }

    /// Switching tabs selects the tab's remembered template.
    public mutating func setPlatform(_ p: String) {
        guard catalog.tabs.contains(p), step == .template else { return }
        platform = p
        let keep = Self.remembered(catalog, p, perTab).flatMap { d in visibleTemplates.contains(d) ? d : nil }
        choose(keep ?? visibleTemplates.first)
    }

    public mutating func setFilter(_ f: String) {
        guard step == .template else { return }
        filter = f
        if let s = selected, visibleTemplates.contains(s) { return }
        choose(visibleTemplates.first)
    }

    /// Selects a template (identifier, "<Tab>/<Name>" or name on this tab).
    @discardableResult
    public mutating func select(_ key: String) -> Bool {
        guard step == .template, let d = catalog.find(key, platform: platform) ?? catalog.find(key) else { return false }
        if d.platform != platform {
            platform = d.platform
            filter = ""
        } else if !visibleTemplates.contains(d) {
            return false
        }
        choose(d)
        return true
    }

    private mutating func choose(_ d: ProjectTemplateDescriptor?) {
        // Values chosen so far carry over (shared namespace).
        sharedValues.merge(form.persistedValues) { $1 }
        if form.productName.isEmpty == false { sharedValues[TemplateOptionID.productName] = form.value(TemplateOptionID.productName) }
        selected = d
        guard let d else { return }
        perTab[d.platform] = d.memoryKey
        form = d.makeForm(sharedValues)
    }

    // MARK: Options

    public mutating func setOption(_ id: String, _ value: String) {
        if id == TemplateOptionID.team { team = value; return }
        form.set(id, value)
    }

    // MARK: Buttons

    public var isPreviousEnabled: Bool { step == .options }

    /// Next on the template step: a template Ycode can create is selected.
    /// On the options step: the form has no issues.
    public var isNextEnabled: Bool {
        switch step {
        case .template: selected?.isAvailable == true
        case .options: form.isNextEnabled
        }
    }

    /// The line below the grid: the template's summary, why it cannot be
    /// created, or the filter's empty state.
    public var templateCaption: String {
        guard let s = selected else { return "No templates match “\(filter)”." }
        return s.unavailableReason ?? s.summary
    }

    /// Next. Returns true when the save step should open.
    @discardableResult
    public mutating func next() -> Bool {
        guard isNextEnabled else { return false }
        switch step {
        case .template:
            step = .options
            return false
        case .options:
            return true
        }
    }

    /// Previous keeps the values (rule 10).
    public mutating func previous() {
        guard step == .options else { return }
        sharedValues.merge(form.persistedValues) { $1 }
        step = .template
    }

    /// Opens the options step for a template directly (picker rows).
    public mutating func jump(to key: String) {
        step = .template
        filter = ""
        if select(key) { _ = next() }
    }

    /// The save step's default name: the product name, or a package
    /// template's default (MyLibrary, …).
    public var defaultSaveName: String {
        let n = form.productName
        return n.isEmpty ? (selected?.defaultSaveName ?? "") : n
    }
}

/// The compact picker's rows (`templates.md` § "Compact picker rows").
extension NewProjectPicker {
    /// The rows' internal values, in order.
    public static let rowValues = ["app", "commandLineTool", "package", "playground", "template"]

    /// The template a row opens on the options step: Command Line Tool;
    /// Playground opens App Playground (Ycode's choice: the reference's is
    /// OPEN). App is the untitled project, Package… the package chooser,
    /// Choose Template… the full sheet.
    public static func templateID(forRow i: Int) -> String? {
        switch i {
        case 1: "macos.command-line-tool"
        case 3: "ios.app-playground"
        default: nil
        }
    }

    /// Stores the last chosen row (§ Persistence).
    public static func remember(row i: Int, in defaults: UserDefaults) {
        if rowValues.indices.contains(i) { defaults.set(rowValues[i], forKey: NewProjectFlowModel.Keys.pickerRow) }
    }

    public static func lastRow(_ defaults: UserDefaults) -> Int? {
        defaults.string(forKey: NewProjectFlowModel.Keys.pickerRow).flatMap { rowValues.firstIndex(of: $0) }
    }
}

// MARK: - Save step

/// The save step's choices: Save As, Where, Create Git repository, and
/// Add to (an open project or workspace) with its Group.
public struct NewProjectSaveOptions: Equatable, Sendable {
    public var location: URL
    /// The folder's name; nil uses the template's (the product name).
    public var saveAs: String?
    public var createGitRepository = true
    /// An `.xcworkspace` or `.xcodeproj` the new project is added to.
    public var addTo: URL?
    /// In `addTo`: the group (a workspace group's location path, or a
    /// project group's object ID); nil is the top level.
    public var group: String?
    /// Add to = a project: save both in a new workspace (else a sub-project reference).
    public var newWorkspaceForProject = true
    /// `DEVELOPMENT_TEAM` (nil or "None": no team).
    public var team: String?

    public init(location: URL, saveAs: String? = nil, createGitRepository: Bool = true, addTo: URL? = nil, group: String? = nil) {
        self.location = location
        self.saveAs = saveAs
        self.createGitRepository = createGitRepository
        self.addTo = addTo
        self.group = group
    }
}

/// One entry of the save step's Group pop-up.
public struct NewProjectGroupChoice: Equatable, Sendable {
    public var title: String
    public var depth: Int
    /// `NewProjectSaveOptions.group`.
    public var key: String?
}

/// Creates a project from the flow: writes it, makes the Git repository,
/// and adds it to a workspace or project.
public enum NewProjectCreator {
    public struct Created: Equatable, Sendable {
        /// The `.xcodeproj` or package folder to open.
        public var openURL: URL
        public var folder: URL
        public var entryFile: URL?
        /// Set when the Git step failed (the project is still created).
        public var gitWarning: String?
        public var addedTo: URL?
    }

    /// The Group pop-up's entries for an `addTo` container.
    public static func groups(in container: URL) -> [NewProjectGroupChoice] {
        if container.pathExtension == "xcworkspace" {
            guard let ws = try? Workspace(contentsOf: container.path) else { return [] }
            var out = [NewProjectGroupChoice(title: container.deletingPathExtension().lastPathComponent, depth: 0, key: nil)]
            func walk(_ nodes: [YcodeWorkspace.XMLNode], _ depth: Int, _ prefix: String) {
                for n in nodes where n.name == "Group" {
                    let loc = n["location"] ?? ""
                    let key = prefix.isEmpty ? loc : prefix + "|" + loc
                    out.append(NewProjectGroupChoice(title: n["name"] ?? Workspace.Location(loc).displayPath, depth: depth, key: key))
                    walk(n.children, depth + 1, key)
                }
            }
            walk(ws.document.children, 1, "")
            return out
        }
        guard let proj = try? PBXProj(contentsOf: container.appendingPathComponent("project.pbxproj")),
              let main = proj.project?.string("mainGroup") else { return [] }
        var out: [NewProjectGroupChoice] = []
        let products = proj.project?.string("productRefGroup")
        func walk(_ id: String, _ depth: Int) {
            guard let g = proj[id], g.isa == "PBXGroup" else { return }
            let title = depth == 0 ? container.deletingPathExtension().lastPathComponent
                : g.string("name") ?? g.string("path").map { ($0 as NSString).lastPathComponent } ?? "Group"
            out.append(NewProjectGroupChoice(title: title, depth: depth, key: depth == 0 ? nil : id))
            for c in g.references("children") where c != products { walk(c, depth + 1) }
        }
        walk(main, 0)
        return out
    }

    /// The generated project with the save step's folder name applied.
    public static func generate(_ d: ProjectTemplateDescriptor, _ form: TemplateOptionsForm, saveAs: String?, team: String? = nil) throws -> GeneratedProject {
        var g = try ProjectGenerator.generate(d, form, team: team)
        if let s = saveAs?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            g.folderName = g.folderName.hasSuffix(".swiftpm") && !s.hasSuffix(".swiftpm") ? s + ".swiftpm" : s
        }
        return g
    }

    /// Writes the project; runs Git; adds it to the container. Blocks
    /// (Git runs as a subprocess): call it off the main thread.
    public static func create(_ d: ProjectTemplateDescriptor, _ form: TemplateOptionsForm, save: NewProjectSaveOptions,
                              gitEnvironment: [String: String]? = nil) throws -> Created {
        let g = try generate(d, form, saveAs: save.saveAs, team: save.team)
        let open = try g.write(in: save.location)
        let folder = save.location.appendingPathComponent(g.folderName, isDirectory: true)
        var created = Created(openURL: open, folder: folder, entryFile: g.entryFile.map { folder.appendingPathComponent($0) })
        if save.createGitRepository { created.gitWarning = initializeRepository(folder, environment: gitEnvironment) }
        if let target = save.addTo {
            created.addedTo = try add(open, to: target, group: save.group, newWorkspace: save.newWorkspaceForProject)
        }
        return created
    }

    /// `git init`, every created file staged, one commit "Initial Commit"
    /// (§ Save step). No repository is made inside an existing work tree.
    /// Returns a warning when Git is missing or a step fails.
    static func initializeRepository(_ folder: URL, environment: [String: String]?) -> String? {
        let git = [HostTool.path("git"), "/usr/local/bin/git", "/opt/homebrew/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let git else { return "Git was not found; no repository was created." }
        let env = environment.map { ProcessInfo.processInfo.environment.merging($0) { $1 } }
        if let inside = try? Subprocess.run(git, ["rev-parse", "--is-inside-work-tree"], environment: env, currentDirectory: folder),
           inside.status == 0, inside.stdoutText.hasPrefix("true") {
            return nil
        }
        for args in [["init", "--quiet"], ["add", "--all"], ["commit", "--quiet", "--message", "Initial Commit"]] {
            guard let out = try? Subprocess.run(git, args, environment: env, currentDirectory: folder) else {
                return "git \(args[0]) could not run."
            }
            if out.status != 0 {
                let why = out.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                return "git \(args[0]) failed\(why.isEmpty ? "" : ": \(why)")."
            }
        }
        return nil
    }

    /// Adds the new project (or package folder) to a workspace (a
    /// `FileRef` in the group) or to a project. For a project the
    /// reference asks whether to save both in a new workspace (§ Save
    /// step); with `newWorkspace` Ycode makes `<project>.xcworkspace` next
    /// to it holding both, otherwise it adds a file reference in the group
    /// (a sub-project or a local package folder). Returns the container
    /// that now holds the new project.
    @discardableResult
    public static func add(_ item: URL, to container: URL, group: String?, newWorkspace: Bool = false) throws -> URL {
        if container.pathExtension == "xcodeproj", newWorkspace {
            let ws = container.deletingPathExtension().appendingPathExtension("xcworkspace")
            let base = ws.deletingLastPathComponent().standardizedFileURL.path
            let refs = [container, item].map { "   <FileRef\n      location = \"group:\(relativePath($0.standardizedFileURL.path, from: base))\">\n   </FileRef>\n" }
            let text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Workspace\n   version = \"1.0\">\n" + refs.joined() + "</Workspace>\n"
            guard !FileManager.default.fileExists(atPath: ws.path) else { return try add(item, to: ws, group: nil) }
            try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
            try text.write(to: ws.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)
            return ws
        }
        if container.pathExtension == "xcworkspace" {
            let dataURL = container.appendingPathComponent("contents.xcworkspacedata")
            var ws = try Workspace(contentsOf: container.path)
            let base = container.deletingLastPathComponent()
            // Workspace group locations nest: the path is relative to the
            // group it sits in.
            var groupDir = base.standardizedFileURL.path
            var path: [Int] = []
            if let group {
                var nodes = ws.document.children
                for loc in group.split(separator: "|").map(String.init) {
                    guard let i = nodes.firstIndex(where: { $0.name == "Group" && $0["location"] == loc }) else { break }
                    path.append(i)
                    if case .group(let p) = Workspace.Location(loc) {
                        groupDir = p.hasPrefix("/") ? p : URL(fileURLWithPath: groupDir).appendingPathComponent(p).standardizedFileURL.path
                    }
                    nodes = nodes[i].children
                }
            }
            let ref = YcodeWorkspace.XMLNode("FileRef", attributes: [("location", "group:" + relativePath(item.standardizedFileURL.path, from: groupDir))])
            func insert(_ node: inout YcodeWorkspace.XMLNode, _ rest: ArraySlice<Int>) {
                guard let i = rest.first else { node.children.append(ref); return }
                insert(&node.children[i], rest.dropFirst())
            }
            insert(&ws.document, path[...])
            try ws.serialized().write(to: dataURL, atomically: true, encoding: .utf8)
            return container
        }
        let pbx = container.appendingPathComponent("project.pbxproj")
        var proj = try PBXProj(contentsOf: pbx)
        let projectDir = proj.projectDirectory(xcodeprojURL: container)
        let parents = proj.parentMap()
        let groupID = group.flatMap { proj[$0] != nil ? $0 : nil } ?? proj.project?.string("mainGroup") ?? ""
        let groupDir = proj.resolvedPath(of: groupID, projectDirectory: projectDir, parents: parents) ?? projectDir.path
        let id = proj.makeObjectID()
        let isProject = item.pathExtension == "xcodeproj"
        var attrs: [(String, PlistValue)] = [("isa", "PBXFileReference")]
        attrs.append(("lastKnownFileType", isProject ? "wrapper.pb-project" : "wrapper"))
        attrs += [("name", .string(item.lastPathComponent)), ("path", .string(relativePath(item.standardizedFileURL.path, from: groupDir))),
                  ("sourceTree", "<group>")]
        proj[id] = PBXObject(id: id, attributes: PlistDictionary(attrs))
        if var g = proj[groupID] {
            g["children"] = .array((g.references("children") + [id]).map(PlistValue.string))
            proj[groupID] = g
        }
        let name = container.deletingPathExtension().lastPathComponent
        try proj.serialized(projectName: name).write(to: pbx, atomically: true, encoding: .utf8)
        return container
    }

    /// `path` relative to the directory `base` ("../x" when outside it).
    static func relativePath(_ path: String, from base: String) -> String {
        let a = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let b = URL(fileURLWithPath: base).standardizedFileURL.pathComponents
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: b.count - i) + a[i...]).joined(separator: "/")
    }
}

extension Workspace.Location {
    /// The location's path, for a group's title.
    var displayPath: String {
        switch self {
        case .group(let p), .container(let p), .absolute(let p), .developer(let p), .selfReference(let p): (p as NSString).lastPathComponent
        case .unknown(let s): s
        }
    }
}
