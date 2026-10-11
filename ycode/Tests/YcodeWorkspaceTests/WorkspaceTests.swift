import Foundation
import Testing
@testable import YcodeWorkspace

private func fixtureURL(_ path: String) throws -> URL {
    let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(path)
}

@Suite struct XcodeXMLTests {
    @Test func roundTripsXcodeLayout() throws {
        for path in ["Demo.xcworkspace/contents.xcworkspacedata", "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"] {
            let text = try String(contentsOf: fixtureURL(path), encoding: .utf8)
            #expect(XcodeXML.write(try XcodeXML.parse(text)) == text, "\(path)")
        }
    }

    @Test func readsCompactXMLAndKeepsAttributeOrder() throws {
        let node = try XcodeXML.parse(#"<?xml version="1.0"?><!-- c --><A z="1" a="2"><B/><![CDATA[x<y]]></A>"#)
        #expect(node.attributes.map(\.name) == ["z", "a"])
        #expect(node.children.map(\.name) == ["B"])
        #expect(node.text == "x<y")
    }

    @Test func decodesAndEncodesEntities() throws {
        let node = try XcodeXML.parse(#"<A v="&lt;&amp;&gt;&quot;&apos;&#10;&#x41;"/>"#)
        #expect(node["v"] == "<&>\"'\nA")
        #expect(XcodeXML.escape("<&>\"\n\t") == "&lt;&amp;&gt;&quot;&#10;&#9;")
    }

    @Test(arguments: ["<A>", "<A></B>", "<A v=x/>", "<A/><B/>", "<A>&bogus;</A>"])
    func rejectsMalformed(_ text: String) {
        #expect(throws: XMLReadError.self) { try XcodeXML.parse(text) }
    }
}

@Suite struct WorkspaceTests {
    @Test func resolvesLocations() throws {
        let ws = try Workspace(contentsOf: fixtureURL("Demo.xcworkspace").path)
        let dir = try fixtureURL("").standardizedFileURL.path
        #expect(ws.items.count == 4)
        #expect(ws.items[0].kind == .group)
        #expect(ws.items[0].resolvedPath == dir + "/Libs")
        #expect(ws.items[0].children[0].resolvedPath == dir + "/Libs/Core/Core.xcodeproj")
        #expect(ws.projectPaths == [dir + "/Libs/Core/Core.xcodeproj", dir + "/App.xcodeproj", "/opt/Shared/Shared.xcodeproj"])
    }

    @Test func projectWithoutEmbeddedWorkspaceActsAsSelf() throws {
        let ws = try Workspace(contentsOf: fixtureURL("App.xcodeproj").path)
        #expect(ws.items.map(\.location) == [.selfReference("")])
        #expect(ws.projectPaths == [try fixtureURL("App.xcodeproj").standardizedFileURL.path])
    }

    @Test func locationRawValuesRoundTrip() {
        for raw in ["group:a/b", "container:", "absolute:/x", "self:", "developer:Tools", "weird"] {
            #expect(Workspace.Location(raw).rawValue == raw)
        }
    }
}

@Suite struct SchemeTests {
    @Test func readsActions() throws {
        let s = try Scheme(contentsOf: fixtureURL("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"))
        #expect(s.name == "App")
        #expect(s.buildEntries.count == 1)
        #expect(s.buildEntries[0].actions == Set(Scheme.Action.allCases))
        #expect(s.testables.map(\.reference.blueprintName) == ["AppTests"])
        #expect(s.launchTarget?.buildableName == "App.app")
        #expect(s.configuration(for: "LaunchAction") == "Debug")
        #expect(s.configuration(for: "ArchiveAction") == "Release")
        #expect(s.launchArguments == [.init(value: "--verbose \"quoted\" & more", isEnabled: true), .init(value: "--off", isEnabled: false)])
        #expect(s.launchEnvironment == [.init(key: "SCRIPT", value: "line1\nline2", isEnabled: true)])
    }

    @Test func discoversSharedSchemes() throws {
        let schemes = Scheme.discover(in: try fixtureURL("App.xcodeproj"), user: "nobody")
        #expect(schemes.map(\.name) == ["App"])
        #expect(schemes[0].isShared)
    }

    @Test func autocreatesSchemeForTarget() {
        let ref = Scheme.BuildableReference(blueprintIdentifier: "ID", buildableName: "T.app", blueprintName: "T", referencedContainer: "container:T.xcodeproj")
        let s = Scheme.autocreated(for: ref, isTestBundle: false, isRunnable: true)
        #expect(s.buildEntries.first?.actions == Set(Scheme.Action.allCases))
        #expect(s.launchTarget == ref)
        #expect(s.testables.isEmpty)
    }
}
