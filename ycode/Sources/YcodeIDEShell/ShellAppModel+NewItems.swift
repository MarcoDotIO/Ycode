import Foundation
import YcodeIDECore

/// Beta 5's File ▸ New items and second windows on Linux (B5-NEWPROJECT):
/// File from Template… (⌘N, P-187), Choose Template… (⌥⇧⌘N), and File ▸
/// New ▸ Window (⇧⌘T, P-022): another window on the workspace; with two
/// or more workspace windows, Close Window (⇧⌘W) and ⌘W without a file
/// close only the active one. Window Tab stays disabled: OpenViews has no
/// window tabs.
extension ShellAppModel {
    /// The state of an action this file performs (nil: not one of them).
    public func newItemsMenuState(_ action: String) -> (enabled: Bool, checked: Bool)? {
        switch action {
        case "newFile:": return (workspace != nil, false)
        case "chooseProjectTemplate:": return (true, false)
        case "newWorkspaceWindow:": return (workspace != nil, false)
        case "newWindowForTab:": return (false, false)
        case "performClose:" where workspaceWindowCount > 1: return (true, false)
        default: return nil
        }
    }

    /// Performs an action of this file; false when it is not one.
    public func performNewItemsAction(_ action: String) -> Bool {
        switch action {
        case "newFile:":
            showNewFile()
            return workspace != nil
        case "chooseProjectTemplate:":
            showNewProject(row: NewProjectPicker.chooseTemplateIndex)
            return true
        case "newWorkspaceWindow:":
            guard workspace != nil else { return false }
            openWindow(Self.workspaceWindowID)
            return true
        case "performClose:" where workspaceWindowCount > 1:
            return closeActiveWorkspaceWindow()
        case "closeTab:" where workspaceWindowCount > 1 && workspace?.document == nil && workspace?.structuredEditor == nil:
            return closeActiveWorkspaceWindow()
        default:
            return false
        }
    }

    /// The workspace windows' scene.
    nonisolated public static let workspaceWindowID = "workspace"

    /// File ▸ New ▸ File from Template… (⌘N): the New File sheet on the
    /// workspace window.
    public func showNewFile(platform: String? = nil) {
        guard let w = workspace else { return }
        newFile = NewFileShellModel(workspace: w, platform: platform)
    }

    /// Create in the New File sheet: on success the sheet closes.
    @discardableResult
    public func createNewFile() -> [URL]? {
        guard let m = newFile, let urls = m.create() else { return nil }
        newFile = nil
        return urls
    }

    public func cancelNewFile() { newFile = nil }
}
