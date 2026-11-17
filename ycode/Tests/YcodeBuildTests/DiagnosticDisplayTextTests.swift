import Testing
@testable import YcodeBuild

/// P-121: issue messages read as the issue navigator shows them.
struct DiagnosticDisplayTextTests {
    @Test func groupSuffixDroppedAndFirstWordCapitalized() {
        #expect(Diagnostic.displayMessage("variable 'neverMutated' was never mutated; consider changing to 'let' constant [#VariableNeverMutated]")
            == "Variable 'neverMutated' was never mutated; consider changing to 'let' constant")
        #expect(Diagnostic.displayMessage("cannot find 'Counter' in scope") == "Cannot find 'Counter' in scope")
        #expect(Diagnostic.displayMessage("'foo' is deprecated [#DeprecatedDeclaration]") == "'foo' is deprecated")
        #expect(Diagnostic.displayMessage("ld: library not found") == "ld: library not found")
        #expect(Diagnostic.displayMessage("Already Capital") == "Already Capital")
        #expect(Diagnostic.displayMessage("init(x:) is unavailable") == "init(x:) is unavailable")
        #expect(Diagnostic.displayMessage("") == "")
        // clang's warning flag is not a diagnostic group: kept.
        #expect(Diagnostic.displayMessage("unused variable 'x' [-Wunused-variable]") == "Unused variable 'x' [-Wunused-variable]")
    }

    @Test func parsedBuildLinesUseTheDisplayForm() {
        let d = DiagnosticParser.parseLine("/p/A.swift:3:9: warning: variable 'n' was never mutated [#VariableNeverMutated]")
        #expect(d?.message == "Variable 'n' was never mutated")
        #expect(d?.location?.line == 3)
    }
}
