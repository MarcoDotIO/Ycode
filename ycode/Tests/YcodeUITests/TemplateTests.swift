import AppKit
import Foundation
import Testing
import YcodeBuild
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(5))) struct TemplateTests {
    @Test func fileTemplateContents() {
        #expect(FileTemplate.swiftClass.files(named: "Widget").map(\.0) == ["Widget.swift"])
        #expect(FileTemplate.objcClass.files(named: "Widget").map(\.0) == ["Widget.h", "Widget.m"])
        #expect(FileTemplate.propertyList.files(named: "Config")[0].1.contains("<dict/>"))
        #expect(FileTemplate.empty.files(named: "README").first?.1 == "")
    }

    @Test func newProjectsBuildAndNewFilesJoinTheProject() async throws {
        _ = NSApplication.shared
        let location = ycodeDir.appendingPathComponent(".build-ide/new-projects")
        try? FileManager.default.removeItem(at: location)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)

        // New Project through the compact picker's Command Line Tool row.
        let host = try WorkspaceModel(url: try WindowSnapshotTests().samplePackage())
        let hostWindow = WorkspaceWindowController(session: WorkspaceSession(model: host), loadDestinations: false, startLanguageService: false)
        let td = TestDefaults("new-project")
        defer { td.remove() }
        hostWindow.templateDefaults = td.defaults
        hostWindow.newProjectLocation = location
        let sheet = hostWindow.projectPickerChose(1)
        #expect(sheet.steps.index == 1 && sheet.selectedEntry?.title == "Command Line Tool")
        #expect(!sheet.options.isNextEnabled)
        sheet.options.productName = "Hello Tool"
        sheet.options.organizationIdentifier = "org.ycode.tests"
        sheet.nextClicked()
        let toolProj = try #require(hostWindow.lastCreatedProject)
        #expect(toolProj.lastPathComponent == "Hello Tool.xcodeproj")
        // Creating it again fails without touching anything.
        sheet.nextClicked()
        #expect(hostWindow.lastNewProjectError?.contains("already exists") == true)
        // The template is remembered for next time.
        let last = ProjectTemplateCatalog.lastSelection(td.defaults)
        #expect(last.platform == "macOS" && last.title == "Command Line Tool")
        let appProj = try ProjectTemplate.app.create(name: "Viewer", organization: "org.ycode.tests", in: location)
        let pkg = try ProjectTemplate.swiftPackage.create(name: "Kit", organization: "", in: location)

        // The generated project file round-trips byte for byte.
        let text = try String(contentsOf: toolProj.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        #expect(try PBXProj(parsing: text).serialized(projectName: "Hello Tool") == text)

        // Generated projects build with swift-build (when swbuild is available).
        let probe = ycodeDir.appendingPathComponent("Tools/ycode-swb/.build/debug/swbuild").path
        if let tool = SwiftBuildEngine.locate() ?? (FileManager.default.isExecutableFile(atPath: probe) ? probe : nil) {
            let engine = SwiftBuildEngine(swbuild: tool)
            for (container, scheme) in [(BuildRequest.Container.project(toolProj.path), "Hello Tool"),
                                        (.project(appProj.path), "Viewer"), (.package(pkg.path), "Kit")] {
                let r = await engine.start(BuildRequest(container: container, scheme: scheme, destination: "platform=macOS",
                                                        derivedDataPath: location.appendingPathComponent("dd-\(scheme)").path)).run()
                #expect(r.status == .succeeded, "\(scheme): \(r.issues)")
            }
        }

        // New File inside the tool project: added to its group and target.
        let session = WorkspaceSession(model: try WorkspaceModel(url: toolProj))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        #expect(wc.editor.fileURL?.lastPathComponent == "main.swift")
        let fileSheet = wc.newFile(nil)
        _ = fileSheet.view
        #expect(fileSheet.platform == "macOS")
        #expect(fileSheet.select(title: "Objective-C File"))
        let w = NSWindow(contentRect: fileSheet.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = fileSheet.view
        _ = try WindowSnapshotTests().render(fileSheet.view, to: "new-file-sheet.png")
        _ = try wc.createFile(entry: try #require(fileSheet.selectedEntry), name: "Widget")
        let pbx = try String(contentsOf: toolProj.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        #expect(pbx.contains("/* Widget.m in Sources */") && pbx.contains("path = Widget.h;") && !pbx.contains("Widget.h in Sources"))
        let folder = toolProj.deletingLastPathComponent().appendingPathComponent("Hello Tool")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Widget.m").path))
        #expect(wc.editor.fileURL?.lastPathComponent == "Widget.h")
        #expect(session.model.root.allFiles.contains { $0.name == "Widget.m" })
        _ = try wc.createFile(.swiftClass, name: "Gadget")
        #expect((try String(contentsOf: toolProj.appendingPathComponent("project.pbxproj"), encoding: .utf8)).contains("/* Gadget.swift in Sources */"))
        #expect(throws: NewFileError.self) { try wc.createFile(.swiftClass, name: "Gadget") }
    }
}
