import Foundation
import Testing

/// Every pbxproj text that the package writes or tests with (templates, test
/// fixtures) must pair `objectVersion` and its compatibility attribute as
/// specs/formats/pbxproj.md "Project format (Compatibility)" says: at
/// objectVersion 77 only `preferredProjectObjectVersion = 77`, never a
/// `compatibilityVersion`; below 77, a `compatibilityVersion` (if present)
/// names the choice for that objectVersion.
@Suite struct FixtureCompatibilityTests {
    static let choices: [Int: String] = [
        63: "Xcode 15.3", 60: "Xcode 15.0", 56: "Xcode 14.0", 55: "Xcode 13.0", 54: "Xcode 12.0",
        53: "Xcode 11.4", 52: "Xcode 11.0", 51: "Xcode 10.0", 50: "Xcode 9.3", 48: "Xcode 8.0",
        47: "Xcode 6.3", 46: "Xcode 3.2", 45: "Xcode 3.1",
    ]

    static func firstInt(after key: String, in text: String) -> Int? {
        guard let r = text.range(of: key) else { return nil }
        return Int(text[r.upperBound...].prefix { $0.isNumber })
    }

    static func compatibilityValues(in text: String) -> [String] {
        text.components(separatedBy: "compatibilityVersion = \"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
    }

    @Test func packagePBXProjTextsMatchCompatibilityTable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var checked = 0
        for dir in ["Sources", "Tests"] {
            let e = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil))
            for case let url as URL in e where ["swift", "pbxproj"].contains(url.pathExtension) && url.lastPathComponent != "FixtureCompatibilityTests.swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                guard let ov = Self.firstInt(after: "objectVersion = ", in: text) else { continue }
                checked += 1
                let compat = Self.compatibilityValues(in: text)
                if ov >= 77 {
                    #expect(compat.isEmpty, "\(url.lastPathComponent): objectVersion \(ov) with compatibilityVersion \(compat)")
                } else if let want = Self.choices[ov] {
                    #expect(compat.allSatisfy { $0 == want }, "\(url.lastPathComponent): objectVersion \(ov) wants \(want), has \(compat)")
                }
            }
        }
        #expect(checked > 5)
    }
}
