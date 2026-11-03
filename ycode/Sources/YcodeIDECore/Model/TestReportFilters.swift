import Foundation
import YcodeBuild

/// The Tests page's filter pop-ups besides Failed Tests (reference-ui-2.md
/// §6.4; reference-ui-5.md §11.3, P12): Failed Runs, the run destination,
/// the configuration and the tags. A run is one test on one destination in
/// one configuration; Ycode's runs use a single destination and the scheme's
/// test action, and its runners report no tags, so every test is untagged.
public struct TestReportFilters: Equatable, Sendable {
    public var failedRunsOnly = false
    /// nil = all destinations.
    public var device: String?
    /// nil = all configurations.
    public var configuration: String?
    /// nil = all tags.
    public var tag: String?
    public init() {}

    public static let untagged = "Untagged Tests"
    public static let configurationTitle = "Test Scheme Action"

    /// Each pop-up's title and items (the first item means "all").
    public static func menus(_ r: BuildReport) -> [(title: String, items: [String])] {
        let titles = TestReportModel.filterTitles(r)
        let device = r.context.destination.isEmpty ? "My Mac" : r.context.destination
        return [(titles[0], ["All Tests", "Failed Tests Only"]), (titles[1], ["All Runs", "Failed Runs Only"]),
                (titles[2], ["All Run Destinations", device]), (titles[3], ["All Configurations", configurationTitle]),
                (titles[4], ["All Tags", untagged])]
    }

    /// The Tests page rows under every filter.
    public func rows(_ r: BuildReport, failedOnly: Bool, text: String) -> [TestReportModel.TestRow] {
        let device = r.context.destination.isEmpty ? "My Mac" : r.context.destination
        if let d = self.device, d != device { return [] }
        if let c = configuration, c != Self.configurationTitle { return [] }
        if let t = tag, t != Self.untagged { return [] }
        return TestReportModel.testRows(r, failedOnly: failedOnly || failedRunsOnly, text: text)
    }
}
