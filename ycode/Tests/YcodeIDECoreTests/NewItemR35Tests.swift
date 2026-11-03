import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
import YcodePlist
import YcodeProject
@testable import YcodeIDECore

/// reference-ui-5.md §11.3 (P10): template contents, the save step's Group
/// and Targets, and Choose Template…'s empty workspace window.
@MainActor
@Suite struct NewItemR35Tests {
    #if os(macOS)
    nonisolated static let hasMacSDK = true
    #else
    nonisolated static let hasMacSDK = false
    #endif

    func temp(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-newitem-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = [tool] + args
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    @Test func everyTemplateWritesItsContent() throws {
        for platform in FileTemplateCatalog.platforms {
            for section in FileTemplateCatalog.sections(platform: platform) {
                for entry in section.entries {
                    let dir = try temp("t")
                    defer { try? FileManager.default.removeItem(at: dir) }
                    var proj: PBXProj?
                    let urls = try FileTemplateCatalog.create(entry, name: "My Item", in: dir, platform: platform, project: &proj, xcodeprojURL: nil)
                    #expect(!urls.isEmpty, "\(platform) \(entry.title)")
                    for u in urls {
                        var isDir: ObjCBool = false
                        #expect(FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), "\(entry.title)")
                        let files = isDir.boolValue ? (FileManager.default.enumerator(atPath: u.path)?.allObjects as? [String] ?? []).map { u.appendingPathComponent($0) } : [u]
                        for f in files where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                            let data = try Data(contentsOf: f)
                            switch f.pathExtension {
                            case "json", "geojson", "xcstrings", "xctestplan", "storekit":
                                #expect((try? JSONSerialization.jsonObject(with: data)) != nil, "\(entry.title) JSON")
                            case "plist", "xcprivacy", "stringsdict", "intentdefinition":
                                #expect((try? PropertyListDocument(data: data)) != nil, "\(entry.title) plist")
                            case "storyboard", "xib", "gpx", "":
                                if f.lastPathComponent == "contents" || ["storyboard", "xib", "gpx"].contains(f.pathExtension) {
                                    #expect(XMLParser(data: data).parse(), "\(entry.title) XML")
                                }
                            default: break
                            }
                        }
                    }
                    // Source templates write non-empty files.
                    if section.title == "Source" {
                        for u in urls { #expect(((try? Data(contentsOf: u))?.count ?? 0) > 0, "\(entry.title) is empty") }
                    }
                }
            }
        }
    }

    /// The Source templates compile (Swift, C, C++, Objective-C, Metal when
    /// the toolchain has it). They are macOS templates: they need the macOS
    /// SDK's headers and modules, so this runs on macOS only.
    @Test(.enabled(if: Self.hasMacSDK)) func sourceTemplatesBuild() throws {
        let dir = try temp("build")
        defer { try? FileManager.default.removeItem(at: dir) }
        for entry in FileTemplateCatalog.sections(platform: "macOS")[0].entries {
            var proj: PBXProj?
            let sub = dir.appendingPathComponent(entry.title.replacingOccurrences(of: " ", with: "_"))
            let urls = try FileTemplateCatalog.create(entry, name: "Sample", in: sub, platform: "macOS", project: &proj, xcodeprojURL: nil)
            for u in urls {
                let (status, out): (Int32, String) = switch u.pathExtension {
                case "swift": run("swiftc", ["-typecheck", u.path])
                case "c": run("clang", ["-fsyntax-only", "-Werror", u.path])
                case "cpp": run("clang++", ["-fsyntax-only", "-Werror", u.path])
                case "m": run("clang", ["-fsyntax-only", "-fobjc-arc", "-I", sub.path, u.path])
                case "h": run("clang", ["-fsyntax-only", "-x", "objective-c-header", u.path])
                case "metal": run("metal", ["-c", u.path, "-o", u.deletingPathExtension().appendingPathExtension("air").path])
                default: (0, "")
                }
                if u.pathExtension == "metal", status != 0, out.contains("unable to find utility") || out.contains("cannot execute tool") { continue }
                #expect(status == 0, "\(entry.title): \(out)")
            }
        }
    }
}
