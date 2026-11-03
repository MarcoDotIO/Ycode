import Foundation
import Observation
import YcodeIDECore

/// The Linux shell's New Project sheet state over the core's
/// `NewProjectFlowModel` (`templates.md` § Ycode implementation): the
/// template step, the options step, and the save step drawn in the sheet
/// (Save As, Where, Create Git repository, Add to, Group).
@MainActor
@Observable
public final class NewProjectShellModel {
    public enum Step: Equatable, Sendable { case template, options, save }

    public private(set) var flow: NewProjectFlowModel
    public private(set) var step = Step.template
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

    public init(defaults: UserDefaults = .standard, row: Int? = nil, openContainer: URL? = nil, gitEnvironment: [String: String]? = nil) {
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
        }
    }

    public var heading: String {
        switch step {
        case .template: flow.chooser == .project ? NewProjectFlowModel.templateHeading : "Choose a template for your new package:"
        case .options: NewProjectFlowModel.optionsHeading
        case .save: "Save your new project:"
        }
    }

    public func setPlatform(_ p: String) { flow.setPlatform(p) }
    public func setFilter(_ f: String) { flow.setFilter(f) }
    public func select(_ id: String) { flow.select(id) }
    public func setOption(_ id: String, _ value: String) { flow.setOption(id, value) }

    public var isPreviousEnabled: Bool { step != .template }
    public var isNextEnabled: Bool {
        switch step {
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
        case .template: break
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

    /// Create in the sheet; on success the sheet closes and the result opens
    /// (a project added to the open workspace stays in that window).
    @discardableResult
    public func createNewProject() -> NewProjectCreator.Created? {
        guard let m = newProject, let c = m.create() else { return nil }
        newProject = nil
        if c.addedTo == nil { open(path: c.openURL.path) } else if let w = workspace { open(path: w.session.model.url.path) }
        return c
    }

    public func cancelNewProject() { newProject = nil }
}
