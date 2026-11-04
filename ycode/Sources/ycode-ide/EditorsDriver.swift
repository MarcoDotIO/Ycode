import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_EDITORS=<shot prefix>: a walk through the property list, asset
// catalog and String Catalog editors on OpenViews (issues #19, #20). The
// workspace must hold the files named by YCODE_IDE_EDITORS_FILES (a
// comma-separated list of names, default "Info.plist,Binary.plist,
// Legacy.plist,Assets.xcassets,Localizable.xcstrings"). Each step prints
// "editors <step>: ..." and writes <prefix>-<step>.png. Edits go through the
// pointer and keyboard where the step says so, else through the model, and
// each file's bytes are checked after its round trip: "unchanged" (opened,
// not edited) or the format it was written in. Removed asset sets go to
// the trash ($XDG_DATA_HOME/Trash), so run it with XDG_DATA_HOME set.

#if os(Linux)
@MainActor
enum EditorsDriver {
    static func say(_ s: String) { ShellDriver.say("editors " + s) }

    static func run(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("no workspace"); return }
        func shot(_ name: String) async {
            await ShellDriver.pause(0.7)
            say("shot \(name): " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(name).png"))
        }
        let names = (ShellDriver.env["YCODE_IDE_EDITORS_FILES"] ?? "Info.plist,Binary.plist,Legacy.plist,Assets.xcassets,Localizable.xcstrings")
            .split(separator: ",").map(String.init)
        func path(_ name: String) -> String? { w.root.allFiles.first { $0.name == name }?.path }
        func bytes(_ p: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: p))) ?? Data() }
        func click(_ target: String, dx: CGFloat? = nil) async { await ShellDriver.click(target, dx: dx) }

        // A plain look first: open each file and leave it; nothing is written.
        for n in names {
            guard let p = path(n), !n.hasSuffix(".xcassets") else { continue }
            let before = bytes(p)
            w.open(p)
            await ShellDriver.pause(0.6)
            say("round trip \(n): \(bytes(p) == before ? "unchanged" : "CHANGED") editor=\(w.editorKind.rawValue)")
        }

        // From the project navigator with the pointer: open the folders
        // above the catalog, then click it.
        if let p = path("Assets.xcassets"), let ids = w.root.idPath(to: p) {
            for id in ids.dropLast() where !w.isExpanded(id) {
                guard let item = w.root.find(id: id) else { continue }
                await ShellDriver.pause(0.3)
                await ShellDriver.clickNavigatorText(item.name, dx: -26)
            }
            await ShellDriver.pause(0.3)
            if let row = w.projectRows.first(where: { $0.id == ids.last! }) {
                await ShellDriver.clickNavigatorText(row.title, dx: 10)
            }
            await ShellDriver.pause(0.6)
            say("navigator opened: \(w.document?.name ?? "none") editor=\(w.editorKind.rawValue)")
            await shot("navigator-assets")
        }

        // MARK: Property list (XML)
        if let p = path("Info.plist"), case .propertyList(let m)? = { w.open(p); return w.structuredEditor }() {
            await shot("plist")
            // Select CFBundleName with the pointer, then edit its value by typing.
            if let row = m.rows.first(where: { $0.rawKey == "CFBundleName" }) {
                await click("plist row \(row.key)", dx: 40)
                await ShellDriver.pause(0.3)
                await click("plist value field")
                OpenViewsAutomation.press(.character("a"), modifiers: [.control])
                OpenViewsAutomation.type("Edited Name")
                OpenViewsAutomation.press(.return)
                await ShellDriver.pause(0.5)
                say("plist typed value: \(m.tree.item(at: row.path)?.summary ?? "?") saves=\(m.saveCount)")
            }
            await shot("plist-edited-value")
            // + on the selected row, then a type change and a key.
            await click("plist add")
            let added = m.selection ?? []
            m.setType("Boolean", at: added)
            m.setKey("YcodeFlag", at: added)
            m.setValueText("YES", at: added)
            m.moveSelected(by: -1)
            say("plist added: path=\(m.selection ?? []) rows=\(m.rows.count)")
            await shot("plist-added")
            // A refused value.
            if let n = m.rows.first(where: { $0.type == "Number" }) { m.setValueText("twelve", at: n.path) }
            say("plist refused: \(m.problem ?? "none")")
            await shot("plist-refused")
            m.clearProblem()
            // Raw keys through the Editor menu.
            await ShellDriver.clickText("Editor", inPopup: false)
            await shot("plist-editor-menu")
            await ShellDriver.clickText("Raw Keys and Values", inPopup: true)
            say("plist raw keys: \(m.showsRawKeys)")
            await shot("plist-raw-keys")
            m.showsRawKeys = false
            // Sort by Key.
            await click("plist header", dx: 20)
            say("plist sort: \(m.sortColumn?.rawValue ?? "none")")
            await shot("plist-sorted")
            m.sort(by: .key); m.sort(by: .key)
            // Open As Source Code and back.
            await click("open as source")
            OpenViewsAutomation.move(to: CGPoint(x: 700, y: 600))
            say("plist source view: \(w.isShowingSourceView) lines=\(w.editor?.buffer.lineCount ?? 0)")
            await shot("plist-source")
            await click("open as structured")
            OpenViewsAutomation.move(to: CGPoint(x: 700, y: 600))
            say("plist back: editor=\(w.editorKind.rawValue)")
            let text = String(decoding: bytes(p), as: UTF8.self)
            say("plist file: xml=\(text.hasPrefix("<?xml")) hasFlag=\(text.contains("<key>YcodeFlag</key>")) name=\(text.contains("Edited Name"))")
        }

        // MARK: Binary and OpenStep
        if let p = path("Binary.plist"), case .propertyList(let m)? = { w.open(p); return w.structuredEditor }() {
            m.selection = []
            m.addItem()
            say("binary: format=\(m.formatName) bplist=\(bytes(p).starts(with: Array("bplist00".utf8)))")
            await shot("plist-binary")
        }
        if let p = path("Legacy.plist"), case .propertyList(let m)? = { w.open(p); return w.structuredEditor }() {
            if let r = m.rows.dropFirst().first(where: { !$0.isContainer }) { m.setValueText("changed", at: r.path) }
            let text = String(decoding: bytes(p), as: UTF8.self)
            say("openstep: format=\(m.formatName) braces=\(text.hasPrefix("{")) changed=\(text.contains("changed"))")
            await shot("plist-openstep")
        }

        // MARK: Asset catalog
        if let p = path("Assets.xcassets"), case .assetCatalog(let m)? = { w.open(p); return w.structuredEditor }() {
            w.isInspectorShown = true
            await shot("assets")
            if let color = m.rows.first(where: { $0.set?.kind == .colorSet }) {
                await click("asset row \(color.id)", dx: 60)
                say("assets selected: \(m.selectedRow?.name ?? "none")")
                await shot("assets-color")
                await click("color hex 0")
                OpenViewsAutomation.press(.character("a"), modifiers: [.control])
                OpenViewsAutomation.type("#3478F6")
                OpenViewsAutomation.press(.return)
                await ShellDriver.pause(0.5)
                say("assets color: \(m.colors.first.map(AssetCatalogEditorModel.hex) ?? "?")")
                m.setAppearances("Any, Dark")
                await shot("assets-color-edited")
            }
            // Editor ▸ Add New Asset ▸ (the menu bar's way to the "+" items).
            await ShellDriver.clickText("Editor", inPopup: false)
            if let add = OpenViewsAutomation.texts().first(where: { $0.inPopup && $0.text == "Add New Asset" }) {
                OpenViewsAutomation.move(to: CGPoint(x: add.frame.midX, y: add.frame.midY))
                await ShellDriver.pause(0.3)
                await OpenViewsAutomation.click(at: CGPoint(x: add.frame.midX, y: add.frame.midY))
                await ShellDriver.pause(0.5)
            }
            await shot("assets-editor-menu")
            OpenViewsAutomation.press(.escape)
            await ShellDriver.pause(0.2)
            OpenViewsAutomation.press(.escape)
            await ShellDriver.pause(0.3)
            // "+" ▸ Image Set with the pointer.
            await click("assets add")
            await shot("assets-add-menu")
            await ShellDriver.clickText("Image Set", inPopup: true)
            OpenViewsAutomation.move(to: CGPoint(x: 800, y: 600))
            say("assets added: \(m.selectedRow?.name ?? "none") slots=\(m.slots.count)")
            if let png = ShellDriver.env["YCODE_IDE_EDITORS_PNG"] {
                m.setImage(URL(fileURLWithPath: png), slot: 1)
                say("assets image: \(m.slots[1].filename ?? "none")")
            }
            await shot("assets-image-set")
            if let icon = m.rows.first(where: { $0.set?.kind == .appIconSet }) {
                m.select(icon.id)
                await shot("assets-app-icon")
            }
            // "−": the new image set goes to the trash.
            if let made = m.rows.first(where: { $0.name.hasPrefix("Image") && $0.set?.kind == .imageSet }) {
                m.select(made.id)
                await click("assets remove")
                let trash = (ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? "~/.local/share") + "/Trash/files"
                say("assets removed: \(made.name) gone=\(!FileManager.default.fileExists(atPath: made.url.path)) "
                    + "inTrash=\(m.lastRemoval.map { FileManager.default.fileExists(atPath: $0.trashed.path) } ?? false) trash=\(trash)")
                await shot("assets-removed")
            }
            m.setFilter("Acc")
            await shot("assets-filtered")
            m.setFilter("")
        }

        // MARK: String Catalog
        if let p = path("Localizable.xcstrings"), case .stringCatalog(let m)? = { w.open(p); return w.structuredEditor }() {
            await shot("strings")
            if let de = m.languages.first(where: { $0 != m.catalog.sourceLanguage }) {
                await click("language \(de)", dx: 30)
                say("strings language: \(m.language) rows=\(m.rows.count)")
                await shot("strings-language")
                if let r = m.rows.first(where: { $0.state == .new }) {
                    await click("string row \(r.key)", dx: 20)
                    await click("string translation \(r.key)")
                    OpenViewsAutomation.type("Übersetzt")
                    OpenViewsAutomation.press(.return)
                    await ShellDriver.pause(0.5)
                    say("strings translated: \(m.rows.first { $0.key == r.key }.map { "\($0.translation) \($0.state)" } ?? "?")")
                }
                await shot("strings-translated")
            }
            m.addLanguage("fr")
            await click("strings add")
            OpenViewsAutomation.move(to: CGPoint(x: 700, y: 600))
            say("strings key added: \(m.selectedKey ?? "none") count=\(m.catalog.keys.count)")
            let summary = m.refreshFromSource()
            say("strings refresh: \(m.refreshText ?? "") added=\(summary.added)")
            await shot("strings-refreshed")
            m.sort(by: .state)
            await shot("strings-sorted")
        }
        // Reopen: close each file, open it again, and read what was saved.
        for n in names {
            guard let p = path(n) else { continue }
            w.open(p)
            w.closeCurrentDocument()
            w.open(p)
            switch w.structuredEditor {
            case .propertyList(let m): say("reopened \(n): \(m.formatName) \(m.rows.count) rows")
            case .assetCatalog(let m): say("reopened \(n): \(m.rows.map(\.name))")
            case .stringCatalog(let m): say("reopened \(n): \(m.catalog.keys.count) keys, languages \(m.languages)")
            case nil: say("reopened \(n): NOT IN ITS EDITOR")
            }
        }
        say("done")
    }
}
#else
@MainActor
enum EditorsDriver {
    static func run(_ app: ShellAppModel, prefix: String) async {}
}
#endif
