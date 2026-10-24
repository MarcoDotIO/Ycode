import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The normative menu bar of `specs/ide/reference-ui-5.md` §2, transcribed
/// from the spec: generic titles (§1.3), order, separators ("—"), section
/// labels ("[…]"), submenus ("▸"), shortcuts in the spec's notation (any
/// spelling of a keystroke: "⌘<" or "⇧⌘,"), alternates ("alt", with the
/// revealing modifiers for one without a shortcut) and conditional items
/// ("when", hidden until their condition holds). System items (§1.6) are
/// not listed: AppKit adds them. The Editor menu, one per editor kind
/// (§2.7/§2.8), is in `EditorMenuGoldenTests.swift`.
let menuBarGolden = """
Ycode ▸
  About Ycode
  Ycode Extensions…
  —
  Settings… | ⌘,
  Behaviors ▸
    No Custom Behaviors
    —
    Edit Behaviors…
  —
  Open Developer Tool ▸
    —
    More Developer Tools…
  Services ▸
  —
  Hide Ycode | ⌘H
  Hide Others | ⌥⌘H
  Show All
  —
  Quit Ycode | ⌘Q
  Quit and Keep Windows | ⌥⌘Q | alt
File ▸
  New ▸
    Conversation | ⌃⌘H
    Conversation in New Tab | ⌃⌥⌘H | alt
    Conversation in Editor Pane | ⌃⌥⇧⌘H | alt
    —
    Tab | ⌘T
    —
    Editor Pane On Right | ⌃⌘T
    Editor Pane Below | ⌃⌥⌘T
    Window Tab
    Window | ⇧⌘T
    —
    Empty File
    New File from Clipboard
    File from Template… | ⌘N
    Target…
    —
    Project… | ⇧⌘N
    Choose Template… | ⌥⇧⌘N | alt
    Workspace… | ⌃⌘N
    —
    Group
    Group without Folder
    Group from Selection
    Group from Selection without Folder
    Folder | ⌥⌘N
    Folder from Selection
  —
  Add Files… | ⌥⌘A
  Add Package Dependencies…
  —
  Open… | ⌘O
  Open Recent ▸
    Clear Menu
  Open Quickly… | ⇧⌘O
  —
  Close Tab, Editor Pane, Window Tab, or Window | ⌘W
  Close Other Tabs | ⌥⌘W | alt
  Close Document | ⌃⌘W
  Close Editor Pane | ⌃⇧⌘W
  Close Other Editor Panes | ⌃⌥⇧⌘W | alt
  Close Window | ⇧⌘W | when
  Close Other Window Tabs | ⌥⇧⌘W | alt | when
  Close Workspace | ⌃⌥⌘W
  —
  Duplicate Editor Tab
  Save | ⌘S
  Save All | ⌥⌘S
  Duplicate… | ⇧⌘S
  Save As… | ⌥⇧⌘S
  Revert to Saved…
  Unlock…
  Export…
  —
  Show in Finder
  Open Terminal at Location
  Open in New Tab | ⌥⌘O
  Open in New Window
  Open with External Editor
  —
  Packages ▸
    Reset Package Caches
    Resolve Package Versions
    —
    Update to Latest Package Versions
  —
  Save As Workspace…
  Workspace Settings…
  —
  Page Setup…
  Print… | ⌘P
Edit ▸
  Undo | ⌘Z
  Redo | ⇧⌘Z
  —
  Cut | ⌘X
  Copy | ⌘C
  Copy File and Line | ⌃⌥⌘C | alt
  Copy Symbol Name | ⌃⇧⌘C | alt
  Copy Qualified Symbol Name | ⌃⌥⇧⌘C | alt
  Paste | ⌘V
  Move Item Here | ⌥⌘V | alt
  Paste and Preserve Formatting | ⌥⇧⌘V | alt
  Duplicate | ⌘D
  Delete | ⌘⌫
  —
  Select All | ⌘A
  —
  Bookmark Line | ⌃⌘'
  Bookmark Line With Dialog | ⌃⌥⌘'
  Bookmark File | ⌃⇧⌘'
  Bookmark File With Dialog | ⌃⌥⇧⌘'
  —
  Sort ▸
    By Name
    By Type
  Format ▸
    Show Fonts | ⌃⇧⌘T
    Show Colors
    Font ▸
      Bold
      Italic
      Underline
      —
      Bigger
      Smaller
    Text ▸
      Align Left
      Center
      Justify
      Align Right
    Spelling and Grammar ▸
      Show Spelling and Grammar | ⌘:
      Check Document Now | ⌘;
      —
      Check Spelling While Typing
      Check Grammar With Spelling
      Correct Spelling Automatically
    Substitutions ▸
      Show Substitutions
      —
      Smart Copy/Paste
      Smart Quotes
      Smart Dashes
      Smart Links
      Data Detectors
      Text Replacement
    Transformations ▸
      Make Upper Case
      Make Lower Case
      Capitalize
    Speech ▸
      Start Speaking
      Stop Speaking
  —
  Convert ▸
    To Group
    To Folder
    Preflight Conversion To Folder
    To String Catalogs…
View ▸
  Editor ▸
    Focus Editor Pane | ⌃⇧⌘↩
    —
    Show Related Items | ⌃1
    Show Previous History | ⌃2
    Show Previous Files History | ⌃⌘2
    Show Next History | ⌃3
    Show Next Files History | ⌃⌘3
    Show Top Level Items | ⌃4
    Show Group Files | ⌃5
    Show Document Items | ⌃6
  —
  Show Editor Tab Bar
  Pin Editor Tab | ⇧⌘P
  Change Editor Orientation
  Reset Editor Sizes
  Reset Assistant Selection | ⌥⇧⌘Z
  —
  Show Quick Actions… | ⇧⌘A
  —
  Navigators ▸
    Project | ⌘1
    Source Control | ⌘2
    Bookmarks | ⌘3
    Find | ⌘4
    Issues | ⌘5
    Tests | ⌘6
    Debug | ⌘7
    Breakpoints | ⌘8
    Reports | ⌘9
    —
    Show Coding Assistant | ⌘0
    Show Navigator
    Filter in Navigator | ⌥⌘J
  Debug Area ▸
    Activate Console | ⇧⌘C
    —
    Show Debug Area | ⇧⌘Y
  Inspectors ▸
    File | ⌥⌘1
    History | ⌥⌘2
    Quick Help | ⌥⌘3
    —
    Show Inspector
  Show Library | ⇧⌘L
  Open Library | ⌥⇧⌘L
  Reload Organizer | ⌃R
  —
  Choose Theme…
  —
  Show Toolbar | ⌥⌘T
  Customize Toolbar…
  Show Window Tab Bar
  Show All Window Tabs | ⇧⌘\\
  —
  Enter Full Screen | ⌃⌘F
Find ▸
  Find in Workspace | ⇧⌘F
  Find and Replace in Workspace… | ⌥⇧⌘F
  Find Next in Workspace | ⌃⌘G
  Find Previous in Workspace | ⌃⇧⌘G
  —
  Find Selected Text in Workspace
  Find Selected Words in Workspace
  Find Selected Symbol in Workspace | ⌃⇧⌘F
  Find Call Hierarchy | ⌃⇧⌘H
  Find Ancestor Types
  Find Descendent Types
  Find Conforming Types
  Find in Selected Groups…
  —
  Find… | ⌘F
  Find and Replace… | ⌥⌘F
  Find Next | ⌘G
  Find Previous | ⇧⌘G
  Find and Select Next | ⌥⌘G
  Find and Select Previous | ⌥⇧⌘G
  —
  Replace
  Replace All
  Replace and Find Next
  Replace and Find Previous
  —
  Use Selection for Find | ⌘E
  Use Selection for Replace | ⇧⌘E
  Select Next Occurrence | ⌥⌘E
  Select Previous Occurrence | ⌥⇧⌘E
  —
  Select All Find Matches
  Select Find Matches in Selection
  —
  Hide Find Bar
Navigate ▸
  Reveal in Project Navigator | ⇧⌘J
  Reveal in Changes Navigator | ⇧⌘M
  Reveal in Debug Navigator | ⇧⌘D
  Open using Tab | ⌥⌘,
  Open in Next Editor Pane | ⌥⌘< | alt
  —
  Move Focus to Next Area | ⌥⌘`
  Move Focus to Previous Area | ⌥⇧⌘`
  Move Focus to Next Editor Pane | ⌃`
  Move Focus to Previous Editor Pane | ⌃⇧`
  Move Focus to Editor Pane… | ⌘J
  —
  Show Previous Tab | ⇧⌘[
  Show Next Tab | ⇧⌘]
  —
  Show Next Location in History | ⌃⌘→
  Show Next Location in History using Tab | ⌃⌥⌘→ | alt
  Show Next Location in History in Next Editor Pane | ⌃⌥⇧⌘→ | alt
  Show Previous Location in History | ⌃⌘←
  Show Previous Location in History using Tab | ⌃⌥⌘← | alt
  Show Previous Location in History in Next Editor Pane | ⌃⌥⇧⌘← | alt
  —
  Jump to Next Active Conversation | ⌃⌘K
  —
  Jump to Selection | ⌥⌘L
  Jump to Definition | ⌃⌘J
  Jump to Definition using Tab | ⌃⌥⌘J | alt
  Jump to Definition in Next Editor Pane | ⌃⌥⇧⌘J | alt
  Jump to Original Source/Generated Interface
  Jump to Last Destination
  —
  Jump to Next Issue | ⌘'
  Jump to Previous Issue | ⇧⌘'
  —
  Jump to Next Bookmark | ⌃;
  Jump to Next Bookmark In Workspace | ⌃⌥;
  Jump to Previous Bookmark | ⌃⇧;
  Jump to Previous Bookmark In Workspace | ⌃⌥⇧;
  —
  Jump to Program Counter | ⌃⌘P
  —
  Jump to Next Counterpart | ⌃⌘↑ | when
  Jump to Next Counterpart using Tab | ⌃⌥⌘↑ | alt | when
  Jump to Next Counterpart in Next Editor Pane | ⌃⌥⇧⌘↑ | alt | when
  Jump to Previous Counterpart | ⌃⌘↓ | when
  Jump to Previous Counterpart using Tab | ⌃⌥⌘↓ | alt | when
  Jump to Previous Counterpart in Next Editor Pane | ⌃⌥⇧⌘↓ | alt | when
  Jump to Line… | ⌘L | when
  —
  Jump to Next Placeholder | ⌃/ | when
  Jump to Previous Placeholder | ⌃? | when
  —
  Jump to Next Change | ⌃\\ | when
  Jump to Next Local or Upstream Change | ⌃⌥\\ | alt | when
  Jump to Previous Change | ⌃| | when
  Jump to Previous Local or Upstream Change | ⌃⌥| | alt | when
Product ▸
  Run | ⌘R
  Run… | ⌥⌘R | alt
  Test | ⌘U
  Test… | ⌥⌘U | alt
  Profile | ⌘I
  Profile… | ⌥⌘I | alt
  Analyze | ⇧⌘B
  Analyze… | ⌥⇧⌘B | alt
  Archive
  Archive… | ⌥ | alt
  Stop | ⌘.
  —
  Build For ▸
    Running | ⇧⌘R
    Testing | ⇧⌘U
    Profiling | ⇧⌘I
  Perform Action ▸
    Run Without Building | ⌃⌘R
    Test Without Building | ⌃⌘U
    Profile Without Building | ⌃⌘I
    —
    Build with Timing Summary
    Build and Export Test Products
    —
    Test | ⌃⌥⌘U
    Test Again | ⌃⌥⌘G
    Test Without Building Again
    Profile
    Profile Again
    —
    Compile File | ⌃⌘B
    Analyze File | ⌃⇧⌘B
    —
    Preprocess File
    Assemble File
    —
    Generate Optimization Profile…
  —
  Build | ⌘B
  Clean Build Folder… | ⇧⌘K
  Clean Build Folder Immediately | ⌥⇧⌘K
  Delete Derived Data…
  Clear Test Results | ⌃⌥⌘K
  Clear All Issues
  —
  Build Documentation | ⌃⇧⌘D
  —
  Show Build Folder in Finder
  Copy Build Folder Path
  —
  Export Localizations…
  Import Localizations…
  —
  Scheme ▸
    Choose Scheme | ⌃0
    Select Next Scheme | ⌃⌘]
    Select Previous Scheme | ⌃⌘[
    —
    Edit Scheme… | ⌘<
    New Scheme…
    Manage Schemes…
  Destination ▸
    Choose Destination | ⌃⇧0
    Select Next Destination | ⌃⌥⌘]
    Select Previous Destination | ⌃⌥⌘[
    —
    Show All Run Destinations
    —
    [Devices]
    —
    [Simulators]
    —
    [Build]
    —
    Incompatible ▸
    —
    Manage Devices… | ⇧⌘2
  Test Plan ▸
    Select Next Test Plan
    Select Previous Test Plan
    —
    Edit Test Plan | ⌘>
    New Test Plan…
    Manage Test Plans…
  —
  App Shortcuts Preview
Debug ▸
  Pause | ⌃⌘Y
  Continue To Current Line | ⌃⌘C
  Step Over | F6
  Step Over Instruction | ⌃F6
  Step Over Thread | ⌃⇧F6
  Step Into | F7
  Step Into Instruction | ⌃F7
  Step Into Thread | ⌃⇧F7
  Step Out | F8
  —
  Step Over and Follow Program Counter
  Step Into and Follow Program Counter
  Step Out and Follow Program Counter
  —
  Deactivate Breakpoints | ⌘Y
  Breakpoints ▸
    Create Breakpoint at Current Line | ⌘\\
    Enable Breakpoints at Current Line
    Create Column Breakpoint
    Delete Column Breakpoints at Current Line
    Create Swift Error Breakpoint
    Create Exception Breakpoint…
    Create Symbolic Breakpoint… | ⌥⌘\\
    Create Test Failure Breakpoint
    Delete All Breakpoints
  —
  Console ▸
    Copy Row with Visible Metadata | ⌥⇧C
    Copy Row with All Metadata
    Copy Row without Metadata
    —
    Jump To Source | ⌥⇧⌘J
    —
    Hide Similar Items ▸
      Type
      Process
      PID
      Library
      Subsystem
      Category
      TID
    Show Similar Items ▸
      Type
      Process
      PID
      Library
      Subsystem
      Category
      TID
    —
    Clear Console | ⌘K
    Reload Console | ⌥⌘K
    Select Last Output | ⌥⇧⌘A
  Debug Workflow ▸
    Navigate to Source File when Process Pauses
    Synchronize Insertion Point to Program Counter
    Always Show Disassembly
    Show Library Info…
    Load Symbols… | when
    View Memory | ⌃⌥⇧⌘M
    Interrupt Debugger Operation | ⌃C
  —
  Attach to Process by PID or Name…
  Attach to Process ▸
    Getting Process List…
  Detach
  Debug Executable…
  Debug Crash Log…
  —
  Capture GPU Workload
  Simulate Location ▸
  Induce Device Conditions ▸
  View Debugging ▸
    Capture View Hierarchy
    —
    Show View Frames
    Show Alignment Rectangles
    Show View Drawing
    Show Responsive Scrolling Status
    —
    Configure Environment Overrides…
    Disable All Environment Overrides
    —
    Rendering ▸
      Color Blended Layers
      Color Hits Green and Misses Red
      Color Copied Images
      Color Layer Formats
      Color Immediately
      Color Misaligned Images
      Color Offscreen-Rendered Yellow
      Color Compositing Fast-Path Blue
      Flash Updated Regions
    Appearance ▸
      System Appearance
      —
      Light
      Dark
      High Contrast Light
      High Contrast Dark
  —
  StoreKit ▸
    Manage Transactions…
    —
    Approve Transaction
    Decline Transaction
    Refund Purchase
    Resolve Issue
    Request Price Increase Consent
    Edit Subscription
    —
    Delete Transaction
  GameKit ▸
    Manage Game Progress…
Integrate ▸
  [Source Control]
  Commit… | ⌥⌘C
  Push…
  Pull… | ⌥⌘X
  Fetch Changes
  Refresh File Status
  —
  Stage All Changes
  Stage Selected Files
  Unstage All Changes
  Unstage Selected Files
  Mark as Resolved
  —
  Add
  Cherry-Pick…
  Stash Changes…
  —
  Create Pull Request… | when
  —
  Discard All Changes…
  Discard Changes in Selected Files…
  —
  Clone…
  New Git Repository…
  —
  [Cloud]
  Create Workflow…
  Manage Workflows…
Window ▸
  Minimize | ⌘M
  Zoom
  —
  Rename Window Tab… | ⌥⇧⌘T
  Show Previous Window Tab | ⌃⇧⇥
  Show Next Window Tab | ⌃⇥
  Move Tab to New Window
  Merge All Windows
  —
  Developer Documentation | ⇧⌘0
  Welcome to Ycode | ⇧⌘1
  Downloads | ⇧⌘9
  Organizer | ⌥⇧⌘O
  —
  Bring All to Front
Help ▸
  Developer Documentation | ⇧⌘0
  Human Interface Guidelines | ⇧⌘H
  —
  Ycode Help
  What's New in Ycode
  Release Notes
  The Swift Programming Language
  Provide Feedback…
  —
  Show Keyboard Hints | ⌥⌘?
  Show Quick Help for Selected Item | ⌃⌘?
  Search Documentation for Selected Text | ⌃⌥⌘/
"""

/// Renders a built menu in the golden notation (canonical shortcuts).
@MainActor
func renderMenu(_ menu: NSMenu, depth: Int = 0) -> [String] {
    var out: [String] = []
    let pad = String(repeating: "  ", count: depth)
    for i in menu.items {
        if i.isSeparatorItem { out.append(pad + "—"); continue }
        if i.isSectionHeader { out.append(pad + "[\(i.title)]"); continue }
        if let sub = i.submenu {
            out.append(pad + i.title + " ▸")
            out += renderMenu(sub, depth: depth + 1)
            continue
        }
        var fields = [pad + i.title]
        let sc = MainMenu.canonicalShortcut(i)
        if !sc.isEmpty {
            fields.append(sc)
        } else if i.isAlternate {
            fields.append(Shortcut.canonical(Shortcut.modifierText(modifiers(i.keyEquivalentModifierMask))))
        }
        if i.isAlternate { fields.append("alt") }
        if (i as? CommandMenuItem)?.spec?.condition != nil { fields.append("when") }
        out.append(fields.joined(separator: " | "))
    }
    return out
}

func modifiers(_ f: NSEvent.ModifierFlags) -> MenuCommand.Modifiers {
    var m: MenuCommand.Modifiers = []
    if f.contains(.command) { m.insert(.command) }
    if f.contains(.shift) { m.insert(.shift) }
    if f.contains(.option) { m.insert(.option) }
    if f.contains(.control) { m.insert(.control) }
    return m
}

/// The golden text with each shortcut in canonical notation.
func canonicalGolden(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
        var f = line.components(separatedBy: " | ")
        if f.count > 1, f[1] != "alt", f[1] != "when" { f[1] = Shortcut.canonical(f[1]) }
        return f.joined(separator: " | ")
    }
}

@MainActor
@Suite(.serialized) struct MenuBarGoldenTests {
    /// A menu bar built with factory key bindings.
    func withFactoryBar(_ body: @MainActor (NSMenu) throws -> Void) rethrows {
        let t = TestDefaults("menu-golden")
        let dir = ycodeDir.appendingPathComponent(".build-ide/menu-golden/\(UUID().uuidString)")
        let p = Preferences(defaults: t.defaults, themesDirectory: dir.appendingPathComponent("Themes"))
        let old = Preferences.shared
        Preferences.shared = p
        defer {
            Preferences.shared = old
            t.remove()
            try? FileManager.default.removeItem(at: dir)
        }
        _ = NSApplication.shared
        try body(MainMenu.make())
    }

    /// §1.9 first test: titles, order, separators, labels, alternates,
    /// conditional items and shortcuts of the whole bar against §2.
    @Test func menuBarMatchesSpec() {
        withFactoryBar { bar in
            #expect(bar.items.map(\.title) == ["Ycode", "File", "Edit", "View", "Find", "Navigate", "Editor", "Product", "Debug", "Integrate", "Window", "Help"])
            var actual: [String] = []
            for top in bar.items where top.title != "Editor" {
                actual.append(top.title + " ▸")
                actual += renderMenu(top.submenu!, depth: 1)
            }
            let expected = canonicalGolden(menuBarGolden)
            if actual != expected {
                let n = min(actual.count, expected.count)
                let i = (0..<n).first { actual[$0] != expected[$0] } ?? n
                let ctx = max(0, i - 3)
                Issue.record("""
                    First difference at line \(i + 1):
                    expected: \(expected[ctx..<min(expected.count, i + 3)].joined(separator: "\n          "))
                    actual:   \(actual[ctx..<min(actual.count, i + 3)].joined(separator: "\n          "))
                    """)
            }
            #expect(actual.count == expected.count && expected.count > 550)
        }
    }

    /// §1.9 second test: no two items share a shortcut, alternates
    /// excepted (they differ by modifiers); the one command listed in two
    /// menus (Developer Documentation) counts once.
    @Test func noTwoItemsShareAShortcut() {
        withFactoryBar { bar in
            var seen: [String: (String, String)] = [:]
            @MainActor func walk(_ m: NSMenu, _ path: String) {
                for i in m.items {
                    if let s = i.submenu { walk(s, path + " ▸ " + i.title); continue }
                    let sc = MainMenu.canonicalShortcut(i)
                    guard !sc.isEmpty else { continue }
                    let action = i.action.map(NSStringFromSelector) ?? ""
                    if let (p, a) = seen[sc] {
                        #expect(a == action, "\(sc): \(p) and \(path) ▸ \(i.title)")
                    } else {
                        seen[sc] = (path + " ▸ " + i.title, action)
                    }
                }
            }
            for top in bar.items { walk(top.submenu!, top.title) }
            #expect(seen.count > 200)
        }
    }

    /// §2.0: the corrected bindings, including the Editor menu's.
    @Test func shortcutCorrections() {
        withFactoryBar { bar in
            @MainActor func find(_ path: [String]) -> NSMenuItem? {
                var menu: NSMenu? = bar
                for (n, t) in path.enumerated() {
                    guard let i = menu?.items.first(where: { $0.title == t }) else { return nil }
                    if n == path.count - 1 { return i }
                    menu = i.submenu
                }
                return nil
            }
            @MainActor func sc(_ path: String...) -> String? { find(path).map { MainMenu.canonicalShortcut($0) } }
            #expect(sc("View", "Show Quick Actions…") == "⇧⌘A")
            #expect(sc("View", "Navigators", "Show Coding Assistant") == "⌘0")
            #expect(sc("View", "Navigators", "Show Navigator") == "")
            #expect(sc("View", "Inspectors", "Show Inspector") == "")
            #expect(sc("Editor", "Show Coding Tools", "Show Coding Tools…") == "⌥⌘0")
            #expect(find(["Editor", "Show Coding Tools", "Show Coding Tools…"])?.action == NSSelectorFromString("showCodeActions:"))
            #expect(sc("Editor", "Code Folding", "Fold Methods & Functions") == "⌥⇧⌘←")
            #expect(sc("Editor", "Code Folding", "Unfold Methods & Functions") == "⌥⇧⌘→")
            #expect(sc("Editor", "Code Folding", "Unfold All") == "")
            #expect(sc("Editor", "Structure", "Re-Indent") == "⌃I")
            #expect(find(["Edit", "Format", "Re-Indent"]) == nil)
            #expect(sc("File", "Close Other Window Tabs") == "⌥⇧⌘W")
            #expect(sc("View", "Enter Full Screen") == "⌃⌘F")
            // Editor ▸ Show Coding Tools: the assistant items are listed disabled.
            let tools = find(["Editor", "Show Coding Tools"])?.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title }
            #expect(tools == ["Show Coding Tools…", "—", "Explain", "Document", "Generate a Playground", "Generate a Preview"])
            // §1.6: the table lists none of the system's items.
            let edit = find(["Edit"])?.submenu?.items.map(\.title) ?? []
            #expect(!edit.contains("Start Dictation…") && !edit.contains("Emoji & Symbols") && !edit.contains("AutoFill"))
            let window = find(["Window"])?.submenu?.items.map(\.title) ?? []
            #expect(!window.contains("Minimize All") && !window.contains("Zoom All"))
        }
    }

    /// §1.2: alternates are AppKit alternates of the item above, on the
    /// same key (a shifted spelling is paired through its unshifted key).
    @Test func alternatesPairWithTheirBase() {
        withFactoryBar { bar in
            @MainActor func walk(_ m: NSMenu) {
                var base: NSMenuItem?
                for i in m.items {
                    if let s = i.submenu { walk(s); base = nil; continue }
                    if i.isSeparatorItem || i.isSectionHeader { base = nil; continue }
                    if i.isAlternate {
                        #expect(base != nil, "\(i.title) has no base")
                        if let base {
                            #expect(base.keyEquivalent == i.keyEquivalent, "\(i.title) key differs from \(base.title)")
                            #expect(base.keyEquivalentModifierMask != i.keyEquivalentModifierMask, "\(i.title)")
                        }
                    } else {
                        base = i
                    }
                }
            }
            for top in bar.items { walk(top.submenu!) }
            let nav = bar.item(withTitle: "Navigate")!.submenu!
            let next = nav.item(withTitle: "Open in Next Editor Pane")!
            #expect(next.keyEquivalent == "," && next.keyEquivalentModifierMask == [.command, .option, .shift])
            let archive = bar.item(withTitle: "Product")!.submenu!.item(withTitle: "Archive…")!
            #expect(archive.isAlternate && archive.keyEquivalent.isEmpty && archive.keyEquivalentModifierMask == .option)
        }
    }

    /// §1.8: shifted punctuation is stored as AppKit expects; letters are
    /// lowercase with ⇧; function keys carry no implicit modifier.
    @Test func keyEquivalentsAsAppKitExpects() {
        withFactoryBar { bar in
            let nav = bar.item(withTitle: "Navigate")!.submenu!
            let prev = nav.item(withTitle: "Show Previous Tab")!
            #expect(prev.keyEquivalent == "{" && prev.keyEquivalentModifierMask == .command)
            let quick = bar.item(withTitle: "View")!.submenu!.item(withTitle: "Show Quick Actions…")!
            #expect(quick.keyEquivalent == "a" && quick.keyEquivalentModifierMask == [.command, .shift])
            let step = bar.item(withTitle: "Debug")!.submenu!.item(withTitle: "Step Over")!
            #expect(step.keyEquivalent == Key.f6 && step.keyEquivalentModifierMask.subtracting(.function).isEmpty)
            let delete = bar.item(withTitle: "Edit")!.submenu!.item(withTitle: "Delete")!
            #expect(delete.keyEquivalent == "\u{8}" && delete.keyEquivalentModifierMask == .command)
            #expect(Shortcut.canonical("⌘{") == Shortcut.canonical("⇧⌘[") && Shortcut.canonical("⌃:") == "⌃⇧;")
            #expect(MenuCommand("x", shortcut: "⌃⌥⇧⌘H", "a:").shortcutText == "⌃⌥⇧⌘H")
        }
    }
}
