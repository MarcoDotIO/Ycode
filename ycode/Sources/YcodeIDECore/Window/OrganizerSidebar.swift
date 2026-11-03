import Foundation

/// The Organizer sidebar (specs/ide/reference-ui-3.md §6): sections and
/// pages, and the empty state of pages without data.
public enum OrganizerSidebar {
    public struct Section: Equatable, Sendable {
        public var title: String
        public var pages: [String]
    }

    public static let sections: [Section] = [
        Section(title: "Products", pages: ["Archives"]),
        Section(title: "Insights", pages: ["Overview"]),
        Section(title: "Reports", pages: ["Crashes", "Disk Writes", "Energy", "Feedback", "Hangs", "Launches"]),
        Section(title: "Metrics", pages: ["Battery Usage", "Disk Writes", "Hang Rate", "Hitches", "Launch Time", "Memory", "Storage", "Terminations"]),
    ]

    /// Flattened rows: a section heading (page nil) or a page.
    public static var rows: [(section: String, page: String?)] {
        sections.flatMap { s in [(s.title, nil)] + s.pages.map { (s.title, $0) } }
    }

    /// Insights, Reports and Metrics need App Store Connect data, which
    /// Ycode does not fetch: they always show the empty state.
    public static func hasData(section: String) -> Bool { section == "Products" }

    /// Empty-state title and message for a page, e.g. "No Overview Data" /
    /// "There is no overview data available for version 1.0.".
    public static func emptyState(page: String, version: String) -> (title: String, message: String) {
        ("No \(page) Data", "There is no \(page.lowercased()) data available for version \(version).")
    }
}
