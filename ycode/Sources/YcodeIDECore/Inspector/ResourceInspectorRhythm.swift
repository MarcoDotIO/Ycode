import Foundation

/// An image's File inspector from On Demand Resource Tags down, for both
/// IDEs (`editor-area.md` G.5, `fidelity-council.md` row 135): a section
/// header's ink starts 8.5 below the rule above it, its content 13–18
/// below the header, the next rule 12–16.5 below the content, property rows
/// 18 apart. Values are the stack's gaps (points).
public enum ResourceInspectorRhythm {
    /// After the tags header, to the tags field's box (22 from ink to box).
    public static let headerToTags = 7.5
    /// The tags field's box height.
    public static let tagsHeight = 24.0
    /// From the tags field's box to the rule under it.
    public static let tagsToRule = 12.0
    /// From a rule to the next header (8.5 from the line to the ink).
    public static let ruleToHeader = 2.0
    /// After Image Properties' header, to the first row (25.5 ink to ink).
    public static let headerToProperties = 6.5
    /// A property row's room above and below its line (an 18-point pitch).
    public static let propertyInset = 2.0
    /// From the last property to the rule under it (22.5 from its ink).
    public static let propertiesToRule = 9.0
    /// After Localization's header, to the Localize… button (28 ink to box).
    public static let headerToButton = 13.5
    /// From the Localize… button to the rule under it.
    public static let buttonToRule = 16.5
    /// After Target Membership's header, to its box (18.5 ink to box).
    public static let headerToMembership = 3.5
}
