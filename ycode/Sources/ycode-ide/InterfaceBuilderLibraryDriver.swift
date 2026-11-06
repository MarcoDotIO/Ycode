import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// The Library part of the YCODE_IDE_IB walk (#84): the panel in list and
// icon view, with and without details; then a sample of kinds, each found
// with the search field, inserted with Return, and one Attributes inspector
// field edited with the pointer or keyboard. Each step prints
// "ib library <step>: ..." and writes <prefix>-library-<step>.png. Run once
// with OV_COLOR_SCHEME=dark for the dark shots.

#if os(Linux)
@MainActor
enum InterfaceBuilderLibraryDriver {
    static func say(_ s: String) { ShellDriver.say("ib library " + s) }

    /// One sampled kind: the field edited, how, and the attribute to check.
    struct Step {
        var kind: IBDocument.NewObject
        /// A shell target in the inspector, and text to type (nil: a click).
        var target: String
        var typed: String?
        /// The edited object's attribute (or a path) and its value afterwards.
        var check: (IBDocument, String) -> String?
    }

    static let steps: [Step] = [
        Step(kind: .switchControl, target: "ib field Title", typed: "Wi-Fi") { d, id in d.byID[id]?.attribute("title") },
        Step(kind: .label, target: "ib icon textAlignment Center") { d, id in d.byID[id]?.attribute("textAlignment") },
        Step(kind: .segmentedControl, target: "ib check momentary") { d, id in d.byID[id]?.attribute("momentary") },
        Step(kind: .textField, target: "ib field Placeholder", typed: "Name") { d, id in d.byID[id]?.attribute("placeholder") },
        Step(kind: .slider, target: "ib check continuous") { d, id in d.byID[id]?.attribute("continuous") },
        Step(kind: .verticalStackView, target: "ib check baselineRelativeArrangement") { d, id in d.byID[id]?.attribute("baselineRelativeArrangement") },
        Step(kind: .navigationBar, target: "ib check translucent") { d, id in d.byID[id]?.attribute("translucent") },
        Step(kind: .tapGesture, target: "ib check cancelsTouchesInView") { d, id in d.byID[id]?.attribute("cancelsTouchesInView") },
        Step(kind: .viewController, target: "ib check hidesBottomBarWhenPushed") { d, id in d.byID[id]?.attribute("hidesBottomBarWhenPushed") },
    ]

    static func run(_ m: InterfaceBuilderShellModel, prefix: String, selectRoot: () async -> Void) async {
        func shot(_ name: String) async {
            await ShellDriver.pause(0.7)
            say("shot \(name): " + OpenViewsAutomation.screenshot(to: "\(prefix)-library-\(name).png"))
        }
        func click(_ t: String) async { await ShellDriver.click(t) }

        // The panel: list view with details, then the icon view, then no details.
        await selectRoot()
        if !m.isLibraryShown { await click("ib bar Library") }
        say("open: shown=\(m.isLibraryShown) tab=\(m.libraryTab.title) count=\(m.libraryObjects.count) selection=\(m.librarySelection?.rawValue ?? "-")")
        await shot("list")
        await click("ib library Switch to Icon View")
        say("icon view: \(m.libraryIsIconView)")
        await shot("icons")
        await click("ib library Hide Details")
        say("details: \(m.libraryShowsDetails)")
        await shot("no-details")
        await click("ib library Show Details")
        await click("ib library Switch to List View")
        // The search rule: every word in the name or the class name.
        await click("ib library filter")
        OpenViewsAutomation.type("UIButton")
        OpenViewsAutomation.press(.return)
        await ShellDriver.pause(0.5)
        say("search UIButton: \(m.libraryObjects.map(\.rawValue)) selection=\(m.librarySelection?.rawValue ?? "-")")
        await shot("search")

        for step in steps {
            await selectRoot()
            if !m.isLibraryShown { await click("ib bar Library") }
            await click("ib library filter")
            OpenViewsAutomation.press(.character("a"), modifiers: [.control])
            OpenViewsAutomation.type(step.kind.rawValue)
            OpenViewsAutomation.press(.return)
            await ShellDriver.pause(0.5)
            // The first match is selected; Return in the list inserts it.
            say("search \(step.kind.rawValue): \(m.libraryObjects.map(\.rawValue)) selection=\(m.librarySelection?.rawValue ?? "-")")
            let before = m.saveCount
            for _ in 0..<2 where m.saveCount == before {
                await click("ib library \(step.kind.rawValue)")
                // A single click is told from a double click after a short wait.
                await ShellDriver.pause(0.5)
                OpenViewsAutomation.press(.return)
                await ShellDriver.pause(0.6)
            }
            let id = m.selectedID ?? ""
            say("insert \(step.kind.rawValue): selected=\(id) element=\(m.selected?.element ?? "-") sections=\(m.inspectorSections(.attributes).map(\.title))")
            await click("ib bar Library")
            if let text = step.typed {
                await click(step.target)
                OpenViewsAutomation.press(.character("a"), modifiers: [.control])
                OpenViewsAutomation.type(text)
                OpenViewsAutomation.press(.return)
            } else {
                await click(step.target)
            }
            await ShellDriver.pause(0.6)
            let saved = (try? IBDocument(url: URL(fileURLWithPath: m.path))).flatMap { step.check($0, id) } ?? "-"
            say("edit \(step.kind.rawValue): \(step.target) -> \(saved) saves=\(m.saveCount)")
            await shot("kind-\(step.kind.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
    }
}
#else
@MainActor
enum InterfaceBuilderLibraryDriver {
    static func run(_ m: InterfaceBuilderShellModel, prefix: String, selectRoot: () async -> Void) async {}
}
#endif
