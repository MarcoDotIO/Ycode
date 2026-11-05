import Foundation

/// Writes `.xcarchive` bundles in the layout `specs/ide/organizer.md`
/// reads (Info.plist and, with an application, its Products folder), with
/// no tools: the tests run on macOS and Linux alike.
struct ArchiveFixtures {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-organizer-\(UUID().uuidString)/Archives")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    @discardableResult
    func make(day: String = "2026-11-05", _ name: String, app: String?, version: String = "1.0", build: String = "1",
              created: Date, comment: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(day).appendingPathComponent("\(name).xcarchive")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dSYMs"), withIntermediateDirectories: true)
        var info: [String: Any] = ["ArchiveVersion": 2, "CreationDate": created, "Name": name, "SchemeName": name]
        if let comment { info["Comment"] = comment }
        if let app {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Products/Applications/\(app).app/Contents"),
                                                    withIntermediateDirectories: true)
            info["ApplicationProperties"] = ["ApplicationPath": "Applications/\(app).app", "Architectures": ["arm64", "x86_64"],
                                             "CFBundleIdentifier": "org.example.\(app)", "CFBundleShortVersionString": version,
                                             "CFBundleVersion": build]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Info.plist"))
        return url
    }
}
