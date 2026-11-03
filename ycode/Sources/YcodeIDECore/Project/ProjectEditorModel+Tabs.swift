import Foundation
import YcodeProject

// Model helpers of the project editor's tabs (YcodeUI: ProjectEditorTabs.swift).

extension ProjectEditorModel {
    /// The Combined view's value column: the shown level's name.
    package static func levelsColumnTitle(_ owner: String) -> String { owner }
}
