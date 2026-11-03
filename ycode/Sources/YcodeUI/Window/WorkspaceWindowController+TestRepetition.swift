import AppKit
import YcodeIDECore

/// The Test navigator's row menu (`specs/ide/testing.md` §Repetitions):
/// Run “<test>” and Run “<test>” Repeatedly…, whose sheet picks the mode
/// and the most iterations.
extension WorkspaceWindowController {
    /// The selected row's display name ("testAdds", a suite, a target).
    var selectedTestTitle: String? { navigator.selectedIndex == 5 ? navigator.selectedItem?.title : nil }

    func testRowMenuItems() -> [NSMenuItem] {
        guard let title = selectedTestTitle, !selectedTests.isEmpty else { return [] }
        let run = NSMenuItem(title: "Run \u{201C}\(title)\u{201D}", action: #selector(testSelectedTests(_:)), keyEquivalent: "")
        run.target = self
        let again = NSMenuItem(title: "Run \u{201C}\(title)\u{201D} Repeatedly…", action: #selector(runSelectedTestsRepeatedly(_:)), keyEquivalent: "")
        again.target = self
        return [run, again]
    }

    /// Run Repeatedly…: the sheet, then the iterations.
    @objc public func runSelectedTestsRepeatedly(_ sender: Any?) {
        let tests = selectedTests
        guard !tests.isEmpty, let window, window.isVisible else { NSSound.beep(); return }
        let (alert, read) = repetitionSheet(title: selectedTestTitle ?? "Tests")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            Task { await self?.session.runTestsRepeatedly(only: tests, repetition: read()) }
        }
    }

    /// The sheet: Repeat pop-up (Fixed Iterations, Until Failure, Retry on
    /// Failure) and Maximum Repetitions; `read` gives the choice.
    public func repetitionSheet(title: String) -> (NSAlert, () -> TestRepetition) {
        let alert = NSAlert()
        alert.messageText = "Run \u{201C}\(title)\u{201D} Repeatedly"
        alert.informativeText = "Each iteration is a test run with its own report. Stop ends the series after the current iteration."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: TestRepetition.Mode.allCases.map(\.rawValue))
        mode.setAccessibilityIdentifier("repetitionMode")
        let count = NSTextField(string: "\(TestRepetition.defaultMaximum)")
        count.formatter = { let f = NumberFormatter(); f.minimum = 1; f.maximum = 10_000; f.allowsFloats = false; return f }()
        count.widthAnchor.constraint(equalToConstant: 70).isActive = true
        count.setAccessibilityIdentifier("repetitionMaximum")
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Repeat:"), mode],
                                      [NSTextField(labelWithString: "Maximum Repetitions:"), count]])
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = grid
        let read = { () -> TestRepetition in
            TestRepetition(TestRepetition.Mode.allCases[max(0, mode.indexOfSelectedItem)], maximum: Int(count.stringValue) ?? TestRepetition.defaultMaximum)
        }
        return (alert, read)
    }
}
