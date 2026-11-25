import Foundation

/// An editor pane with nothing to show beside another pane (P-066,
/// `specs/ide/parity-inventory.md`; `reference-ui-4.md` §16): the assistant
/// with no counterpart, or a split's pane whose file was closed (File ▸
/// Close "<file>" empties only the focused pane). The pane keeps its share
/// of the split and shows "No Editor" centred in it, with no text, gutter,
/// minimap or scroll bar. A lone editor with nothing open shows its start
/// page (macOS) or the editor's background (Linux) instead. One rule for
/// both IDEs.
public enum EditorPanePlaceholder {
    public static let title = "No Editor"
    /// The title's size: the editor's empty-state titles.
    public static let fontSize: Double = 20

    /// Whether an empty pane shows the placeholder: only beside another pane.
    public static func shows(paneCount: Int) -> Bool { paneCount > 1 }
}
