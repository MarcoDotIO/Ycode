import Foundation

/// The merge alert's accessibility (`merge-sheet.md` §15.4, council row
/// 168), shared by both IDEs: its children in the reference's order (the
/// default button, the cancel button, the message, the application's icon,
/// the informative text) and the icon's description, in Ycode's own words.
extension MergeSheetText {
    /// The application icon's accessibility description.
    public static let alertIconDescription = "Ycode application icon"

    /// The alert's accessibility children, by role, in order.
    public enum AlertChild: String, CaseIterable, Sendable {
        case defaultButton, cancelButton, message, icon, informativeText
    }

    public static let alertChildOrder = AlertChild.allCases
}
