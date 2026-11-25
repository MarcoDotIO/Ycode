import Foundation

extension WorkspaceModel {
    /// Whether the workspace has a test target (Product ▸ Test and Test
    /// Without Building are disabled without one, P-013): a unit- or
    /// UI-testing bundle in a project, or a package with a test target (or a
    /// Tests folder, SwiftPM's default place for them).
    /// Menus ask on every key equivalent, so a package's manifest is read
    /// at most every few seconds.
    public var hasTestTargets: Bool {
        if projects.values.contains(where: { p in p.targets.contains { ($0.string("productType") ?? "").contains("test") } }) { return true }
        guard kind == .package else { return false }
        let manifest = url.lastPathComponent == "Package.swift" ? url : url.appendingPathComponent("Package.swift")
        return PackageTestTargetCache.shared.hasTestTarget(manifest: manifest)
            || FileManager.default.fileExists(atPath: manifest.deletingLastPathComponent().appendingPathComponent("Tests").path)
    }
}

/// The last answer per manifest, kept a few seconds.
final class PackageTestTargetCache: @unchecked Sendable {
    static let shared = PackageTestTargetCache()
    private let lock = NSLock()
    private var answers: [URL: (date: Date, value: Bool)] = [:]

    func hasTestTarget(manifest: URL, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let a = answers[manifest], now.timeIntervalSince(a.date) < 3 { return a.value }
        let text = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
        let value = text.contains(".testTarget(")
        answers[manifest] = (now, value)
        return value
    }
}

/// The menu items drawn with a glyph (P-013): Product's Run, Test,
/// Profile, Analyze, Archive and Stop, and Debug's step items (the debug
/// bar's glyphs). Symbol names; each IDE draws its toolkit's symbol (the
/// macOS IDE asks the system for it at run time, the Linux IDE draws
/// OpenViews' own artwork of the same name), so both use names both have.
public enum MenuIcons {
    public static let symbols: [String: String] = [
        "runProduct:": "play", "testProduct:": "checkmark.diamond", "profileProduct:": "gauge.with.dots.needle.33percent",
        "analyzeProduct:": "magnifyingglass", "archiveProduct:": "archivebox", "stopProduct:": "stop",
        "stepOver:": "arrow.turn.down.right", "stepInto:": "arrow.down.to.line", "stepOut:": "arrow.up.to.line",
    ]

    /// The glyph of a menu command; none for an alternate (it takes its
    /// base item's row).
    public static func symbol(for c: MenuCommand) -> String? {
        c.isAlternate ? nil : symbols[c.action]
    }
}
