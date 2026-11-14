import Foundation

/// The File inspector's Widths row (`workspace-window.md` W7.5, council row
/// 193), shared by both IDEs: per width an editable text field showing the
/// value right-aligned, then a stepper, filling the value column; "Tab"
/// and "Indent" at the inspector's label size centred under their fields.
public enum InspectorWidthsRow {
    /// The Tab field 64 × 21, the Indent field 65 × 21.
    public static let fieldWidths = [64.0, 65.0]
    public static let fieldHeight = 21.0
    /// Each stepper 19 × 24, right after its field.
    public static let stepperWidth = 19.0, stepperHeight = 24.0
    /// From the Tab stepper to the Indent field.
    public static let pairGap = 5.0
    /// The labels: 10.3 points (ink "Tab" 16.5 and "Indent" 30 wide; 9
    /// points drew them at 0.87 of that).
    public static let labelSize = 10.3
    /// How far the row runs past the other rows' value column (which ends 8
    /// from the inspector's edge; this one 5).
    public static let overhang = 3.0
    /// The whole row's width (the value column at the 260-point inspector).
    public static var width: Double { fieldWidths.reduce(0, +) + 2 * stepperWidth + pairGap }
}
