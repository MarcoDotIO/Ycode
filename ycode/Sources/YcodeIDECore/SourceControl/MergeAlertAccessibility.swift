import Foundation

/// The merge alert's accessibility (`merge-sheet.md` §15.4, council row
/// 168, round 7 row 195), shared by both IDEs: its children in the
/// reference's order (an empty status image, the default button, the
/// cancel button, the message, the application's icon, the informative
/// text) and the icon's description, in Ycode's own words.
extension MergeSheetText {
    /// The application icon's accessibility description.
    public static let alertIconDescription = "Ycode application icon"

    /// The alert's accessibility children, by role, in order.
    public enum AlertChild: String, CaseIterable, Sendable {
        case statusImage, defaultButton, cancelButton, message, icon, informativeText
    }

    public static let alertChildOrder = AlertChild.allCases

    /// Round 7 (`merge-sheet.md` §16.1, row 195): before the buttons, an
    /// image with no description, 18 × 18 at the alert's bottom left (the
    /// reference's empty status image; nothing is drawn); the icon's
    /// element 66 × 66 round the drawn icon; the message 34 and the
    /// informative text 30 tall; no description on the sheet or the
    /// buttons (their titles name them).
    public static let alertStatusImageSide = 18.0
    public static let alertStatusImageOrigin = (x: 20.0, y: 94.0)
    public static let alertIconElementSide = 66.0
    public static let alertMessageElementHeight = 34.0, alertInformativeElementHeight = 30.0
    public static let alertTextElementWidth = 296.0
}
