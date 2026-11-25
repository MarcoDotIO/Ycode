import Foundation
import Observation
import YcodeIDECore

/// The Linux shell's New Project sheet state over the core's
/// `NewProjectFlowModel` (`templates.md` § Ycode implementation): the
/// compact picker (File ▸ New ▸ Project…, P-187), the template step, the
/// options step, and the save step drawn in the sheet (Save As, Where,
/// then the macOS save panel's accessory: Create Git repository, Add to,
/// Group and the new-workspace choice). OpenViews' file dialog takes no
/// accessory, so the save step stays a page of the sheet.
@MainActor
@Observable
public final class NewProjectShellModel {
    public enum Step: Equatable, Sendable { case picker, template, options, save }

    public private(set) var flow: NewProjectFlowModel
    public private(set) var step = Step.template
    /// Add to = a project: save both projects in a new workspace (L-154;
    /// on by default, as the macOS accessory).
    public var newWorkspaceForProject = true
    /// Save As: the folder's name.
    public var saveAs = ""
    /// Where: the folder the project folder is made in.
    public var location: String
    public var createGitRepository: Bool
    /// The open container offered in Add to (the open workspace), if any.
    public let openContainer: URL?
    public var addToOpenContainer = false
    /// The chosen Group (`NewProjectGroupChoice.key`).
    public var group: String?
    /// Why the last Create failed.
    public private(set) var error: String?
    /// The folder dialog for Where is up.
    public var isFolderDialogShown = false

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var gitEnvironment: [String: String]?

    /// - Parameter picker: open on the compact picker (File ▸ New ▸
    ///   Project…, P-187) instead of the template step.
    public init(defaults: UserDefaults = .standard, row: Int? = nil, openContainer: URL? = nil, gitEnvironment: [String: String]? = nil,
                picker: Bool = false) {
        self.defaults = defaults
        self.gitEnvironment = gitEnvironment
        flow = NewProjectFlowModel(defaults: defaults, chooser: row == 2 ? .package : .project)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dev = home.appendingPathComponent("Developer")
        location = (defaults.url(forKey: NewProjectFlowModel.saveFolderKey) ?? (FileManager.default.fileExists(atPath: dev.path) ? dev : home)).path
        createGitRepository = defaults.object(forKey: NewProjectFlowModel.gitKey) as? Bool ?? true
        self.openContainer = openContainer.flatMap { ["xcodeproj", "xcworkspace"].contains($0.pathExtension) ? $0 : nil }
        if let row { NewProjectPicker.remember(row: row, in: defaults) }
        if let row, let id = NewProjectPicker.templateID(forRow: row) {
            flow.jump(to: id)
            step = .options
        } else if row == nil, picker {
            step = .picker
        }
    }

    /// A compact-picker row (P-187): Command Line Tool and Playground jump
    /// to their options, Package… to the package chooser, Choose
    /// Template… to the template step. App (row 0) is the app's (the
    /// untitled project, no sheet).
    public func choose(row: Int) {
        guard step == .picker else { return }
        NewProjectPicker.remember(row: row, in: defaults)
        if row == 2 { flow = NewProjectFlowModel(defaults: defaults, chooser: .package) }
        if let id = NewProjectPicker.templateID(forRow: row) {
            flow.jump(to: id)
            step = .options
        } else {
            step = .template
        }
    }

    /// Whether the new-workspace choice applies: Add to names a project.
    public var offersNewWorkspace: Bool { addToOpenContainer && openContainer?.pathExtension == "xcodeproj" }

    public var heading: String {
        switch step {
        case .picker: NewProjectPicker.header
        case .template: flow.chooser == .project ? NewProjectFlowModel.templateHeading : "Choose a template for your new package:"
        case .options: NewProjectFlowModel.optionsHeading
        case .save: "Save your new project:"
        }
    }

    public func setPlatform(_ p: String) { flow.setPlatform(p) }
    public func setFilter(_ f: String) { flow.setFilter(f) }
    public func select(_ id: String) { flow.select(id) }
    public func setOption(_ id: String, _ value: String) { flow.setOption(id, value) }

    public var isPreviousEnabled: Bool { step != .template && step != .picker }
    public var isNextEnabled: Bool {
        switch step {
        case .picker: false
        case .template, .options: flow.isNextEnabled
        case .save: !saveAs.trimmingCharacters(in: .whitespaces).isEmpty && !location.isEmpty
        }
    }
    public var nextTitle: String { step == .save ? "Create" : "Next" }

    /// The Group pop-up's entries (empty while Add to is "Don't add…").
    public var groups: [NewProjectGroupChoice] {
        guard addToOpenContainer, let c = openContainer else { return [] }
        return NewProjectCreator.groups(in: c)
    }

    public func next() {
        switch step {
        case .picker: break
        case .template:
            flow.next()
            if flow.step == .options { step = .options }
        case .options:
            if flow.next() {
                flow.remember(in: defaults)
                saveAs = flow.defaultSaveName
                step = .save
            }
        case .save: break
        }
    }

    public func previous() {
        switch step {
        case .picker, .template: break
        case .options:
            flow.previous()
            step = .template
        case .save: step = .options
        }
    }

    /// Create: writes the project; returns what to open (nil on failure,
    /// with `error` set).
    @discardableResult
    public func create() -> NewProjectCreator.Created? {
        guard step == .save, let d = flow.selected else { return nil }
        var save = NewProjectSaveOptions(location: URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true),
                                         saveAs: saveAs, createGitRepository: createGitRepository,
                                         addTo: addToOpenContainer ? openContainer : nil, group: group)
        save.team = flow.team
        save.newWorkspaceForProject = newWorkspaceForProject
        defaults.set(save.location, forKey: NewProjectFlowModel.saveFolderKey)
        defaults.set(createGitRepository, forKey: NewProjectFlowModel.gitKey)
        do {
            let c = try NewProjectCreator.create(d, flow.form, save: save, gitEnvironment: gitEnvironment)
            error = c.gitWarning
            return c
        } catch {
            self.error = "\(error)"
            return nil
        }
    }

    public func clearError() { error = nil }
}

extension ShellAppModel {
    /// File ▸ New ▸ Project… (and the Welcome screen's New Project rows):
    /// row 0 makes the untitled app at once; the others show the sheet.
    public func showNewProject(row: Int? = nil) {
        if row == 0 {
            do {
                let created = try UntitledAppProject.create()
                open(path: created.project.path)
            } catch {
                newProject = nil
                notice = ShellNotice("Could Not Create the Project", error.localizedDescription)
            }
            return
        }
        newProject = NewProjectShellModel(defaults: newProjectDefaults, row: row, openContainer: workspace?.session.model.url)
    }

    /// File ▸ New ▸ Project… (⇧⌘N, P-187): the compact picker first, as
    /// on macOS; its rows go on in the same sheet.
    public func showNewProjectPicker() {
        newProject = NewProjectShellModel(defaults: newProjectDefaults, openContainer: workspace?.session.model.url, picker: true)
    }

    /// A compact-picker row chosen in the sheet (P-187): App closes the
    /// sheet and makes the untitled project; the others go on in the sheet.
    public func chooseNewProjectRow(_ row: Int) {
        if NewProjectPicker.template(forRow: row) == .app {
            NewProjectPicker.remember(row: row, in: newProjectDefaults)
            newProject = nil
            showNewProject(row: 0)
            return
        }
        newProject?.choose(row: row)
    }

    /// Create in the sheet; on success the sheet closes and the result opens
    /// (a project added to the open workspace stays in that window).
    @discardableResult
    public func createNewProject() -> NewProjectCreator.Created? {
        guard let m = newProject, let c = m.create() else { return nil }
        newProject = nil
        if c.addedTo == nil {
            // The template's initial file in the editor (templates.md § Save step, 5).
            if open(path: c.openURL.path), let entry = c.entryFile { workspace?.open(entry.path) }
        } else if let w = workspace { open(path: w.session.model.url.path) }
        return c
    }

    public func cancelNewProject() { newProject = nil }
}
