import SwiftUI

/// The navigator's selection band (`navigators.md` round 3 §1, checklist
/// row 81): the accent colour with white text and icons while the outline
/// has the keyboard, the quiet grey band with the row's own colours once an
/// editor has it.
extension ShellColors {
    func onSelection(_ focused: Bool) -> ShellColors {
        var c = self
        c.onAccent = focused
        return c
    }
}
