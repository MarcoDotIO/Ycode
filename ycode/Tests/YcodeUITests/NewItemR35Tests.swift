import AppKit
import Foundation
import Testing
import YcodePlist
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// reference-ui-5.md §11.3 (P10): template contents, the save step's Group
/// and Targets, and Choose Template…'s empty workspace window.
@MainActor
@Suite struct NewItemR35Tests {
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
    /// the toolchain has it).
    @Test func sourceTemplatesBuild() throws {
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

    func helloProject(in dir: URL) throws -> (URL, PBXProj) {
        let proj = dir.appendingPathComponent("Hello.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let text = try String(contentsOf: ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj"), encoding: .utf8)
        try text.write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Hello"), withIntermediateDirectories: true)
        try "print(1)\n".write(to: dir.appendingPathComponent("Hello/main.swift"), atomically: true, encoding: .utf8)
        return (proj, try PBXProj(parsing: text))
    }

    @Test func saveStepGroupsAndTargets() throws {
        let dir = try temp("save")
        defer { try? FileManager.default.removeItem(at: dir) }
        var (url, proj) = try helloProject(in: dir)
        // A second target, so the check can be told apart.
        proj.addTarget(.init(name: "Other", productType: "com.apple.product-type.tool", productPath: "Other", productFileType: "compiled.mach-o.executable",
                             settings: [], phases: ["PBXSourcesBuildPhase"]))
        let main = dir.appendingPathComponent("Hello/main.swift")
        let a = SaveStepAccessory(proj: proj, xcodeprojURL: url, selectedFile: main, directory: main.deletingLastPathComponent())
        _ = a.view
        #expect(a.groups.map(\.title) == ["Hello", "Hello"] && a.groups.map(\.depth) == [0, 1])
        #expect(a.groupPopUp.itemTitles == ["Hello", "Hello"] && a.groupPopUp.indexOfSelectedItem == 1)
        #expect(a.selectedDirectory.standardizedFileURL.path == main.deletingLastPathComponent().standardizedFileURL.path)
        #expect(a.targets == ["Hello", "Other"] && a.checkedTargets == ["Hello"])
        #expect(a.targetBoxes.map(\.state) == [.on, .off])
        var moved: URL?
        a.onGroupChange = { moved = $0 }
        a.selectGroup(0)
        #expect(moved?.standardizedFileURL.path == dir.standardizedFileURL.path)
        a.setTarget("Other", checked: true)
        a.setTarget("Hello", checked: false)
        #expect(a.checkedTargets == ["Other"] && a.targetBoxes.map(\.state) == [.off, .on])
        // A file of no target: the first target is checked.
        let none = SaveStepAccessory(proj: proj, xcodeprojURL: url, selectedFile: nil, directory: dir)
        #expect(none.checkedTargets == ["Hello"] && none.selectedGroup == 0)
        // Created files join the checked targets' phases.
        var p: PBXProj? = proj
        let made = try FileTemplateCatalog.create(TemplateEntry("C File", ext: "c"), name: "util", in: main.deletingLastPathComponent(),
                                                  project: &p, xcodeprojURL: url, targets: ["Other"])
        #expect(made.map(\.lastPathComponent) == ["util.c"])
        let written = try #require(p)
        let other = try #require(written.targets.first { $0.string("name") == "Other" })
        let files = written.buildPhases(ofTarget: other.id).first?.references("files") ?? []
        #expect(files.count == 1 && written.fileReference(ofBuildFile: files[0])?.string("path") == "util.c")
        let hello = try #require(written.targets.first { $0.string("name") == "Hello" })
        #expect(written.buildPhases(ofTarget: hello.id).first { $0.isa == "PBXSourcesBuildPhase" }?.references("files").count == 2)
        // A resource goes to Copy Bundle Resources when the target has one.
        _ = try FileTemplateCatalog.create(TemplateEntry("Asset Catalog", ext: "xcassets"), name: "Media", in: main.deletingLastPathComponent(),
                                           project: &p, xcodeprojURL: url, targets: ["Hello"])
        #expect(FileManager.default.fileExists(atPath: main.deletingLastPathComponent().appendingPathComponent("Media.xcassets/Contents.json").path))
    }

    @Test func chooseTemplateOpensAnEmptyWorkspaceWindow() throws {
        _ = NSApplication.shared
        let wc = NewProjectFlow.emptyWorkspaceWindow()
        #expect(wc.session.model.kind == .workspace && wc.session.model.isUntitled)
        #expect(wc.window?.title == "Untitled")
        #expect(wc.session.model.root.children.isEmpty && wc.session.model.projects.isEmpty)
        // It is a full workspace window: navigator, editor and inspector areas.
        _ = wc.window?.contentView
        #expect(wc.navigator.isViewLoaded || wc.navigator.view.superview != nil)
        wc.close()
    }
}
