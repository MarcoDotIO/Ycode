import Foundation
import Testing
import YcodeBuild
import YcodeDebug
@testable import YcodeIDECore

/// Stale issues (reference-ui-5.md §5.3.2, N10) and the Debug navigator's
/// process row (§11.6, D3).
@MainActor
@Suite struct StaleIssuesAndProcessRowTests {
    func d(_ msg: String, _ file: String?) -> Diagnostic {
        Diagnostic(severity: .warning, message: msg, location: file.map { .init(file: $0, line: 1) })
    }

    @Test func nextBuildReplacesIssuesOfFilesItCompiled() {
        var m = IssueNavigatorModel()
        let a = d("a", "/p/A.swift"), b = d("b", "/p/B.swift"), n = d("n", nil)
        m.finishBuild([a, b, n], full: false, compiledFiles: ["A.swift", "B.swift"])
        // During the next build the earlier issues stay, shown stale.
        m.startBuild()
        #expect(m.entries(fresh: []).map(\.isStale) == [true, true, true])
        #expect(m.capsuleCounts(fresh: []).warnings == 3)
        // It compiled A only: A's issue is gone, B's stays stale, the
        // file-less one is gone.
        m.finishBuild([], full: false, compiledFiles: ["A.swift"])
        #expect(!m.isBuilding)
        #expect(m.stale == [b])
        // A later build that compiles B drops it.
        m.finishBuild([], full: false, compiledFiles: ["B.swift"])
        #expect(m.stale.isEmpty)
        // Unknown compile set: every unreported issue goes.
        m.finishBuild([a], full: false, compiledFiles: [])
        m.finishBuild([], full: false, compiledFiles: nil)
        #expect(m.stale.isEmpty)
    }

    @Test func compiledFilesFromTheLog() {
        let swiftpm = ["Building for debugging...", "[3/7] Compiling Demo main.swift other.swift", "[5/7] Linking Demo", "Build complete!"]
        #expect(IssueNavigatorModel.compiledFiles(inLog: swiftpm, isPackage: true) == ["main.swift", "other.swift"])
        let xcb = ["SwiftCompile normal arm64 /p/App/View.swift (in target 'App' from project 'App')",
                   "CompileC /p/b/x.o /p/App/x.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler (in target 'App' from project 'App')"]
        #expect(IssueNavigatorModel.compiledFiles(inLog: xcb, isPackage: false) == ["View.swift", "x.c"])
        #expect(IssueNavigatorModel.compiledFiles(inLog: ["Build complete!"], isPackage: true) == nil)
    }
}
