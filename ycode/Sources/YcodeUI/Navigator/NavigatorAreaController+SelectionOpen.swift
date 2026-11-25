import AppKit

/// P-199: a plain single click on a file row opens the file when the
/// button goes down, as soon as the row is selected, instead of when it
/// comes up (the reference's editor starts to change ≈ 90 ms after the
/// click; Ycode's changed at +269 ms, after the release and the
/// outline's drag-or-click wait). A press with modifiers, a second click
/// and a press on the row already selected still open on the release
/// (`rowClicked`), with their modifiers.
@MainActor
final class NavigatorPressState {
    /// The file opened by the press in progress (cleared on the release).
    var openedPath: String?
}

extension NavigatorAreaController {
    /// Whether a press opens its row at once: a single left click with no
    /// modifiers.
    static func opensOnPress(_ e: NSEvent) -> Bool {
        e.type == .leftMouseDown && e.clickCount == 1
            && e.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
    }

    /// Opens the pressed row's file now; the release will not open it again.
    func openOnPress(_ path: String, line: Int?) {
        pressState.openedPath = path
        onOpen?(path, line)
    }

    /// The release of a press that opened `path` already: true (and the
    /// press is forgotten) when it is that file.
    func pressOpened(_ path: String?) -> Bool {
        guard let opened = pressState.openedPath else { return false }
        pressState.openedPath = nil
        return opened == path
    }

    /// The file the press in progress opened (tests).
    public var fileOpenedOnPress: String? { pressState.openedPath }
}
