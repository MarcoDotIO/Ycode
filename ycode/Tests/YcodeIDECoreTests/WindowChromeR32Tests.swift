import Foundation
import Testing
import YcodeBuild
import YcodeProject
@testable import YcodeDebug
@testable import YcodeIDECore

/// R32 (`specs/ide/reference-ui-5.md` §4, §5.2–§5.3, §6.1–§6.2, §7, §8):
/// window chrome — toolbar, jump bars, debug bar, navigators' bottom bars,
/// inspectors and the debug area's bars.
@MainActor
@Suite(.serialized) struct WindowChromeR32Tests {
    @Test func synchronizedFolderMembershipWritesExceptionSets() throws {
        let text = """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 77;
        \tobjects = {
        \t\tAA0000000000000000000001 = {isa = PBXProject; mainGroup = AA0000000000000000000002; targets = (AA0000000000000000000004, AA0000000000000000000005, ); };
        \t\tAA0000000000000000000002 = {isa = PBXGroup; children = (AA0000000000000000000003, ); sourceTree = "<group>"; };
        \t\tAA0000000000000000000003 = {isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; };
        \t\tAA0000000000000000000004 = {isa = PBXNativeTarget; buildPhases = (); fileSystemSynchronizedGroups = (AA0000000000000000000003, ); name = App; };
        \t\tAA0000000000000000000005 = {isa = PBXNativeTarget; buildPhases = (); name = Other; };
        \t};
        \trootObject = AA0000000000000000000001;
        }
        """
        var p = try PBXProj(parsing: text)
        let dir = URL(fileURLWithPath: "/tmp/proj")
        let file = "/tmp/proj/App/Views/Main.swift"
        let app = "AA0000000000000000000004", other = "AA0000000000000000000005", group = "AA0000000000000000000003"
        #expect(p.targetMemberships(ofFile: file, projectDirectory: dir).map(\.isMember) == [true, false])
        #expect(p.targetMemberships(ofFile: file, projectDirectory: dir).map(\.isEditable) == [true, true])
        // Removing writes an exception set for the target.
        let r1 = p.setMembership(ofFile: file, target: app, member: false, projectDirectory: dir)
        #expect(r1)
        let set = try #require(p[group]?.references("exceptions").first.flatMap { p[$0] })
        #expect(set.isa == "PBXFileSystemSynchronizedBuildFileExceptionSet" && set.string("target") == app)
        #expect(set.references("membershipExceptions") == ["Views/Main.swift"])
        #expect(p.targetMemberships(ofFile: file, projectDirectory: dir).map(\.isMember) == [false, false])
        // A target without the folder takes the file through its own
        // exception set, which lists the files it includes (IDE-SMALL).
        let r2 = p.setMembership(ofFile: file, target: other, member: true, projectDirectory: dir)
        #expect(r2)
        #expect(p.targetMemberships(ofFile: file, projectDirectory: dir).map(\.isMember) == [false, true])
        let otherSet = try #require(p.objects(isa: "PBXFileSystemSynchronizedBuildFileExceptionSet").first { $0.string("target") == other })
        #expect(otherSet.references("membershipExceptions") == ["Views/Main.swift"])
        let r4 = p.setMembership(ofFile: file, target: other, member: false, projectDirectory: dir)
        #expect(r4)
        #expect(p.objects(isa: "PBXFileSystemSynchronizedBuildFileExceptionSet").map { $0.string("target") } == [app])
        // Adding back empties the set, which goes away.
        let r3 = p.setMembership(ofFile: file, target: app, member: true, projectDirectory: dir)
        #expect(r3)
        #expect(p[group]?.references("exceptions").isEmpty == true && p.objects(isa: "PBXFileSystemSynchronizedBuildFileExceptionSet").isEmpty)
        #expect(p.targetMemberships(ofFile: file, projectDirectory: dir).map(\.isMember) == [true, false])
    }
}
