import AppKit
import Foundation
import Testing
import YcodeAssistant
@testable import YcodeUI

/// Round R44 of reference-ui-6.md §9: the Coding Assistant pane's layout
/// (A1), the New Conversation menu (A2), the toolbar prompt popover (A3),
/// Show Coding Tools enablement (A4), the left-area switch (A5), the File ▸
/// New ▸ Conversation variants (§9.5) and Show / Hide Coding Assistant (A7).
@MainActor
@Suite(.serialized) struct CodingAssistantPaneR44Tests {
    typealias Env = CodingAssistantUITests.Env

    func item(_ action: String) -> NSMenuItem { NSMenuItem(title: "", action: NSSelectorFromString(action), keyEquivalent: "") }

    // MARK: A1 — header, outline with groups and the Archive

    @Test func paneHeaderAndListLayout() async throws {
        let env = try Env("r44-layout")
        defer { env.restore() }
        let wc = try env.window()
        wc.showCodingAssistant(nil)
        let pane = wc.codingAssistant
        // Header: New Conversation with a chevron, then New Group, 8 apart.
        #expect(pane.newConversationButton.title == "New Conversation" && pane.newConversationButton.style == .split)
        #expect(pane.newGroupButton.title == "New Group")
        #expect(CodingAssistantViewController.newConversationSize == NSSize(width: 146, height: 27))
        #expect(CodingAssistantViewController.newGroupSize == NSSize(width: 115, height: 27))
        let window = try #require(wc.window)
        window.setContentSize(NSSize(width: 1400, height: 800))
        wc.mainSplit.splitView.setPosition(320, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        let a = pane.newConversationButton.frame, b = pane.newGroupButton.frame
        #expect(a.size == NSSize(width: 146, height: 27) && b.size == NSSize(width: 115, height: 27))
        if #available(macOS 26, *) {
            // liquid-glass.md §2.4: each button on a 30-point glass capsule
            // (150 and 118 wide), the capsules 7 apart, 7 from the edges.
            let caps = pane.headerCapsules.map(\.frame)
            #expect(caps.count == 2 && caps.allSatisfy { $0.height == 30 })
            #expect(caps.map(\.width) == [150, 118], "\(caps)")
            #expect(abs(caps[1].minX - caps[0].maxX - 7) <= 0.5 && abs(caps[0].minX - 7) <= 0.5, "\(caps)")
        } else {
            #expect(b.minX - a.maxX == 8)
        }
        // The header sits where the navigator selector does; no bottom bar or filter.
        #expect(wc.navigator.filter.isHidden || wc.navigator.filter.superview?.isHidden == true || !isVisible(wc.navigator.filter))
        // Empty: only Archive.
        #expect(pane.listRows == ["Archive"])
        #expect(pane.groupGlyphs["Archive"] == "archivebox")

        // Groups: New Group adds one before the conversations.
        pane.newGroupClicked()
        let first = pane.model.newConversation()
        #expect(pane.listRows == ["New Group", first.title, "Archive"])
        #expect(pane.groupGlyphs["New Group"] == "folder")
        pane.newGroupClicked()
        #expect(pane.model.groups.map(\.title) == ["New Group", "New Group 2"])
        let group = pane.model.groups[0].id
        pane.drop(first.id, on: .group(group))
        #expect(pane.listRows == ["New Group", "  New Conversation", "New Group 2", "Archive"])
        // Archive it: it moves under Archive (shown, as it is selected).
        pane.drop(first.id, on: .archive)
        #expect(pane.model.conversation(first.id)?.isArchived == true)
        #expect(pane.listRows == ["New Group", "New Group 2", "Archive", "  New Conversation"])
        // Back to the top level.
        pane.drop(first.id, on: nil)
        #expect(pane.listRows == ["New Group", "New Group 2", "New Conversation", "Archive"])
        // Deleting a group keeps its conversations.
        pane.model.move(first.id, toGroup: group)
        pane.model.deleteGroup(group)
        #expect(pane.listRows == ["New Group 2", "New Conversation", "Archive"])
        pane.model.renameGroup(pane.model.groups[0].id, to: "Ideas")
        #expect(pane.listRows.first == "Ideas")
    }

    func isVisible(_ v: NSView) -> Bool {
        var view: NSView? = v
        while let x = view { if x.isHidden { return false }; view = x.superview }
        return true
    }

    @Test func listContextMenuOffersGroupsAndArchive() async throws {
        let env = try Env("r44-menu")
        defer { env.restore() }
        let wc = try env.window()
        let pane = wc.codingAssistant
        _ = pane.view
        pane.model.newGroup(title: "Fixes")
        let c = pane.model.newConversation()
        let row = try #require((0..<pane.list.numberOfRows).first { pane.listRows[$0] == c.title })
        pane.list.selectRowIndexes([row], byExtendingSelection: false)
        let menu = try #require(pane.list.menu)
        pane.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["Rename Conversation…", "Move to Group", "Archive", "", "Delete Conversation"])
        #expect(menu.items[1].submenu?.items.map(\.title) == ["Fixes", "", "No Group"])
        let groupRow = try #require(pane.listRows.firstIndex(of: "Fixes"))
        pane.list.selectRowIndexes([groupRow], byExtendingSelection: false)
        pane.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["Rename Group…", "Delete Group"])
        // Selecting a group row keeps the shown conversation.
        #expect(pane.model.selectedID == c.id)
    }

    @Test func groupsAndArchiveAreSaved() throws {
        let env = try Env("r44-save")
        defer { env.restore() }
        let url = env.dir.appendingPathComponent("conversations.json")
        let model = CodingAssistantModel(workspaceRoot: env.dir, archiveURL: url, prefs: env.prefs)
        let g = model.newGroup()
        let c = model.newConversation()
        model.move(c.id, toGroup: g.id)
        model.setArchived(c.id, true)
        // Saving is detached: wait for the file.
        let deadline = Date().addingTimeInterval(5)
        var lib = ConversationLibrary()
        while Date() < deadline {
            lib = ConversationArchive.loadLibrary(url)
            if lib.groups.count == 1 && lib.conversations.first?.isArchived == true { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(lib.groups.map(\.id) == [g.id])
        #expect(lib.conversations.first?.groupID == g.id && lib.conversations.first?.isArchived == true)
        let reopened = CodingAssistantModel(workspaceRoot: env.dir, archiveURL: url, prefs: env.prefs)
        #expect(reopened.groups.map(\.title) == ["New Group"])
    }

    // MARK: A2 — New Conversation menu

    @Test func newConversationMenuListsBackEnds() async throws {
        let env = try Env("r44-ncmenu", ready: [.ollama, .codex])
        defer { env.restore() }
        let wc = try env.window()
        let pane = wc.codingAssistant
        _ = pane.view
        #expect(pane.newConversationMenuTitles.first == "# Model Providers")
        #expect(pane.newConversationMenuTitles.dropFirst().allSatisfy { $0.hasSuffix(" — Checking…") })
        await pane.model.refreshAvailability().value
        #expect(pane.newConversationMenuTitles == ["# Model Providers", "Ollama", "llama.cpp — Set Up", "OpenAI — Set Up",
                                                   "Claude Code — Set Up", "Codex", "Antigravity — Set Up"])
        let menu = try #require(pane.newConversationButton.menu)
        #expect(menu.items[0].isSectionHeader)
        // Not set up: the hint, and Set Up opens Settings.
        let llama = menu.items[2]
        #expect(llama.subtitle == "llama.cpp is not running.")
        var opened = 0
        pane.onOpenSettings = { opened += 1 }
        _ = (llama.target as? NSObject)?.perform(llama.action, with: llama)
        #expect(opened == 1)
        // A ready row starts a conversation with that back end.
        let codex = menu.items[5]
        _ = (codex.target as? NSObject)?.perform(codex.action, with: codex)
        #expect(pane.model.providerKind == .codex)
        #expect(pane.model.selected?.messages.isEmpty == true)
        #expect(pane.model.conversations.count == 1)
        // The button part starts one with the chosen back end.
        pane.messageView.string = ""
        pane.model.send("Hi")
        pane.newConversationClicked()
        #expect(pane.model.conversations.count == 2 && pane.newConversationMenuPresentations == 0)
        if let id = pane.model.conversations.first?.id { await pane.model.response(id)?.value }
    }

    @Test func newConversationButtonOpensTheMenuWithoutABackEnd() async throws {
        let env = try Env("r44-nobackend", ready: [])
        defer { env.restore() }
        let wc = try env.window()
        let pane = wc.codingAssistant
        _ = pane.view
        await pane.model.refreshAvailability().value
        pane.newConversationClicked()
        #expect(pane.newConversationMenuPresentations == 1)
        #expect(pane.model.conversations.isEmpty)
        #expect(pane.newConversationMenuTitles.dropFirst().allSatisfy { $0.hasSuffix(" — Set Up") })
    }

    // MARK: A3 — prompt popover

    @Test func toolbarPromptPopover() async throws {
        let env = try Env("r44-prompt", reply: "Sure.")
        defer { env.restore() }
        let wc = try env.window()
        await wc.codingAssistant.model.refreshAvailability().value
        #expect(wc.newConversationPrompt == nil)
        wc.toggleNewConversationPrompt(nil)
        let prompt = try #require(wc.newConversationPrompt)
        #expect(NewConversationPromptController.size == NSSize(width: 342, height: 146))
        #expect(prompt.placeholder == "New conversation with Ollama")
        prompt.advanceHint()
        #expect(prompt.placeholder != "New conversation with Ollama" && prompt.hints.contains(prompt.placeholder))
        // Attach and options at the left, send at the right, disabled while empty.
        #expect(prompt.attachButton.superview === prompt.sendButton.superview && prompt.optionsButton.superview === prompt.sendButton.superview)
        let row = try #require(prompt.sendButton.superview as? NSStackView)
        #expect(row.arrangedSubviews.firstIndex(of: prompt.attachButton)! < row.arrangedSubviews.firstIndex(of: prompt.sendButton)!)
        #expect(!prompt.sendButton.isEnabled)
        #expect(ProviderMenu.choiceTitles(prompt.optionsButton.menu).contains("Ollama/ollama-model"))
        prompt.setPrompt("   ")
        #expect(!prompt.sendButton.isEnabled)
        // Clicking the toolbar button again closes it; Escape too.
        wc.toggleNewConversationPrompt(nil)
        #expect(wc.newConversationPrompt == nil)
        wc.toggleNewConversationPrompt(nil)
        try #require(wc.newConversationPrompt).onCancel?()
        #expect(wc.newConversationPrompt == nil)
        // Sending starts a conversation in the pane.
        wc.toggleNewConversationPrompt(nil)
        let p = try #require(wc.newConversationPrompt)
        p.attach(Attachment(kind: .file, path: "Sources/Demo/Model.swift", text: "struct Model {}"))
        p.setPrompt("What does Model hold?")
        #expect(p.sendButton.isEnabled)
        p.send()
        #expect(wc.newConversationPrompt == nil)
        #expect(wc.shownLeftPane == .codingAssistant)
        let model = wc.codingAssistant.model
        let id = try #require(model.selectedID)
        await model.response(id)?.value
        #expect(model.selected?.title == "What does Model hold?")
        #expect(model.selected?.messages.first?.attachments.count == 1)
        #expect(model.selected?.messages.last?.text == "Sure.")
    }

    // MARK: A4 — Show Coding Tools enablement

    @Test func codingToolsNeedAProvider() async throws {
        let env = try Env("r44-tools", ready: [])
        defer { env.restore() }
        let wc = try env.window()
        wc.open(path: env.modelURL.path, line: nil)
        // Before the back ends are checked: enabled (the run explains).
        #expect(wc.validateMenuItem(item("codingToolExplain:")))
        await wc.codingAssistant.model.refreshAvailability().value
        for a in ["codingToolExplain:", "codingToolDocument:", "codingToolGeneratePlayground:"] {
            #expect(!wc.validateMenuItem(item(a)), "\(a) without a provider")
        }
        // The submenu lists all six.
        let editor = EditorMenu.items(for: .source)
        let tools = editor.compactMap { spec -> [MenuItemSpec]? in
            if case .submenu("Show Coding Tools", let items) = spec { return items }
            return nil
        }.first ?? []
        #expect(tools.count == 6)
    }

    // MARK: A5 / A7 — the switch and Show / Hide Coding Assistant

    @Test func commandZeroTogglesAndRetitles() throws {
        let env = try Env("r44-toggle")
        defer { env.restore() }
        let wc = try env.window()
        func title() -> String {
            let spec = MenuCommand("Show Coding Assistant", shortcut: "⌘0", "showCodingAssistant:")
            return MenuTitles.title(for: spec, in: wc.menuContext)
        }
        #expect(wc.shownLeftPane == .navigators)
        #expect(title() == "Show Coding Assistant")
        #expect(wc.validateMenuItem(item("filterInNavigator:")))
        wc.showCodingAssistant(nil)
        #expect(wc.shownLeftPane == .codingAssistant && wc.leftPanesControl.isSelected(forSegment: 1))
        #expect(title() == "Hide Coding Assistant")
        #expect(!wc.validateMenuItem(item("filterInNavigator:")))
        // "Hide Navigator" keeps its title.
        #expect(MenuTitles.title(generic: "Show Navigator", in: wc.menuContext) == "Hide Navigator")
        // ⌘0 again hides the assistant: the left area collapses.
        wc.showCodingAssistant(nil)
        #expect(wc.shownLeftPane == nil)
        #expect(!wc.leftPanesControl.isSelected(forSegment: 0) && !wc.leftPanesControl.isSelected(forSegment: 1))
        #expect(title() == "Show Coding Assistant")
        // ⌘0, then ⌘1: the navigator is back.
        wc.showCodingAssistant(nil)
        wc.showNavigator(0)
        #expect(wc.shownLeftPane == .navigators && title() == "Show Coding Assistant")
        // Plain items with the action follow too.
        let plain = NSMenuItem(title: "Show Coding Assistant", action: #selector(WorkspaceWindowController.showCodingAssistant(_:)), keyEquivalent: "0")
        wc.showCodingAssistant(nil)
        _ = wc.validateMenuItem(plain)
        #expect(plain.title == "Hide Coding Assistant")
    }

    // MARK: §9.5 — Conversation in New Tab / in Editor Pane

    @Test func conversationInNewTabAndEditorPane() async throws {
        let env = try Env("r44-tab", reply: "In a tab.")
        defer { env.restore() }
        let wc = try env.window()
        wc.open(path: env.modelURL.path, line: nil)
        await wc.codingAssistant.model.refreshAvailability().value
        #expect(wc.validateMenuItem(item("newConversationInNewTab:")) && wc.validateMenuItem(item("newConversationInEditorPane:")))
        let tabs = wc.editorArea.tabs.count
        wc.newConversationInNewTab(nil)
        #expect(wc.editorArea.tabs.count == tabs + 1)
        let v = try #require(wc.editor.auxiliary as? ConversationView)
        let id = try #require(v.fixedID)
        #expect(wc.editor.pathComponents.map(\.0) == ["Conversations", "New Conversation"])
        #expect(wc.editorArea.tabTitles.last == "New Conversation")
        // The tab's conversation is sent to, whatever the pane selects.
        wc.codingAssistant.model.newConversation()
        #expect(wc.codingAssistant.model.selectedID != id || wc.codingAssistant.model.conversation(id)?.messages.isEmpty == true)
        v.messageView.string = "Explain tabs"
        v.sendClicked()
        await wc.codingAssistant.model.response(id)?.value
        #expect(wc.codingAssistant.model.conversation(id)?.messages.last?.text == "In a tab.")
        #expect(v.messageViews.count == 2)
        // The jump bar and tab follow the conversation's title.
        #expect(wc.editor.pathComponents.last?.0 == "Explain tabs")
        #expect(wc.editorArea.tabTitles.last == "Explain tabs")
        // The menu items are real (not the unavailable placeholders).
        let file = CommandTable.menus.first { $0.0 == "File" }!.1
        guard case .submenu(_, let new)? = file.first else { Issue.record("File ▸ New"); return }
        let actions = new.compactMap { spec -> String? in if case .command(let c) = spec { c.action } else { nil } }
        #expect(actions.prefix(3) == ["newConversation:", "newConversationInNewTab:", "newConversationInEditorPane:"])

        // In Editor Pane: the next pane (a new one with one pane).
        wc.editorArea.selectTab(0)
        #expect(wc.editorArea.tab.editors.count == 1)
        wc.newConversationInEditorPane(nil)
        #expect(wc.editorArea.tab.editors.count == 2)
        #expect(wc.editor.auxiliary is ConversationView && wc.editor === wc.editorArea.tab.editors[1])
        // Deleting the conversation leaves a note.
        let paneView = try #require(wc.editor.auxiliary as? ConversationView)
        wc.codingAssistant.model.delete(try #require(paneView.fixedID))
        #expect(!paneView.sendButton.isEnabled)
    }
}
