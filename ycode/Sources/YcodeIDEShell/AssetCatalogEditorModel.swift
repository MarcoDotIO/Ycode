import Foundation
import Observation
import YcodeIDECore

/// The asset catalog editor of the Linux IDE (`specs/ide/asset-catalog.md`,
/// `reference-ui-3.md` §3): the outline of folders and sets with its filter,
/// "+" and "−", the selected set's slots or colors, and the attributes
/// inspector. Every edit writes the set's `Contents.json` at once; removing
/// a set or folder moves it to the trash (the freedesktop.org trash on
/// Linux), and the last removal can be put back. No toolkit types.
@MainActor
@Observable
public final class AssetCatalogEditorModel {
    public let catalog: AssetCatalog
    public var path: String { catalog.url.path }
    public private(set) var rows: [AssetCatalog.OutlineRow] = []
    public private(set) var collapsed: Set<String> = []
    public private(set) var filter = ""
    /// The selected outline row's id (its path in the catalog).
    public private(set) var selectedID: String?
    /// Why the last edit failed.
    public private(set) var problem: String?
    /// Bumped on every change on disk (views reread slots and colors).
    public private(set) var revision = 0
    /// The last removal, which Undo Remove puts back.
    public private(set) var lastRemoval: (original: URL, trashed: URL)?
    @ObservationIgnored let bin: TrashBin

    public init(path: String, bin: TrashBin = .user) {
        catalog = AssetCatalog(url: URL(fileURLWithPath: path))
        self.bin = bin
        reload()
        if let first = rows.first(where: { !$0.isFolder }) ?? rows.first { selectedID = first.id }
    }

    // MARK: Outline

    public var selectedRow: AssetCatalog.OutlineRow? { rows.first { $0.id == selectedID } }
    public var selectedSet: AssetCatalog.AssetSet? { selectedRow?.set }
    public var selectedFolder: URL? { selectedRow.flatMap { $0.isFolder ? $0.url : nil } }

    public func reload() {
        rows = catalog.outline(collapsed: collapsed, filter: filter)
        if let id = selectedID, !rows.contains(where: { $0.id == id }) { selectedID = nil }
        revision += 1
    }

    public func select(_ id: String?) {
        selectedID = id.flatMap { i in rows.contains { $0.id == i } ? i : nil }
        problem = nil
    }

    /// Selects the row of a set or folder URL.
    public func select(url: URL) {
        selectedID = rows.first { AssetCatalog.same($0.url, url) }?.id
    }

    public func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        reload()
    }

    public func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    public func setFilter(_ text: String) {
        filter = text
        reload()
    }

    /// Up and Down in the outline.
    public func moveSelection(_ d: Int) {
        guard !rows.isEmpty else { return }
        let i = selectedID.flatMap { s in rows.firstIndex { $0.id == s } } ?? (d > 0 ? -1 : rows.count)
        selectedID = rows[min(max(i + d, 0), rows.count - 1)].id
    }

    // MARK: Adding and removing

    public var insertionDirectory: URL { catalog.insertionDirectory(folder: selectedFolder, set: selectedSet) }
    public var isInsideStickerPack: Bool { AssetCatalog.isInsideStickerPack(insertionDirectory) }

    /// The "+" menu for the selection.
    public var addMenu: [AssetCatalog.AddMenuEntry] { AssetCatalog.addMenu(insideStickerPack: isInsideStickerPack) }

    /// Whether a "+" item can run here (Folder from Selection needs a
    /// selection; Import and frames need files, which the view asks for).
    public func canAdd(tag: Int) -> Bool {
        tag == AssetCatalog.AddMenuTags.folderFromSelection ? selectedRow != nil : true
    }

    /// Runs a "+" item by tag; selects what it made.
    @discardableResult
    public func add(tag: Int) -> Bool {
        let t = AssetCatalog.AddMenuTags.self
        return attempt {
            switch tag {
            case t.folder, t.folder + 1:
                let dir = insertionDirectory
                let u = try catalog.addFolder(named: AssetCatalog.uniqueName("Folder", ext: nil, in: dir), namespace: tag == t.folder + 1,
                                              in: catalog.relativePath(dir))
                reloadSelecting(u)
            case t.folderFromSelection:
                guard let item = selectedRow?.url else { return }
                reloadSelecting(try catalog.folder(fromSelection: [item]))
            default:
                let set = try catalog.addSet(tag: tag, in: insertionDirectory)
                reloadSelecting(set.url)
            }
        }
    }

    /// "+" ▸ Import…: images become image sets, other files data sets.
    @discardableResult
    public func importFiles(_ files: [URL]) -> Bool {
        attempt {
            let made = try catalog.importFiles(files, into: insertionDirectory)
            reloadSelecting(made.last?.url)
        }
    }

    /// "+" ▸ Sticker Sequence Frame: a frame for the selected sequence (a
    /// new sequence in the pack when none is selected).
    @discardableResult
    public func addStickerFrame(_ file: URL) -> Bool {
        guard isInsideStickerPack else { return false }
        return attempt {
            let seq = selectedSet?.kind == .stickerSequence ? selectedSet!
                : try catalog.addSet(tag: AssetCatalog.AddMenuTags.creatable["Sticker Sequence"]!, in: insertionDirectory)
            try AssetCatalog.addStickerSequenceFrame(file, to: seq)
            reloadSelecting(seq.url)
        }
    }

    /// "−" and Editor ▸ Delete Selected Items: the selected set or folder
    /// moves to the trash (issue #3: never deleted outright).
    @discardableResult
    public func removeSelected() -> Bool {
        guard let row = selectedRow else { return false }
        let index = rows.firstIndex { $0.id == row.id } ?? 0
        return attempt {
            let trashed = row.isFolder ? try catalog.removeFolder(row.url, bin: bin) : try catalog.remove(row.set!, bin: bin)
            lastRemoval = (row.url, trashed)
            reload()
            selectedID = rows.isEmpty ? nil : rows[min(index, rows.count - 1)].id
        }
    }

    /// Puts the last removed set or folder back from the trash.
    @discardableResult
    public func undoRemove() -> Bool {
        guard let r = lastRemoval else { return false }
        return attempt {
            try bin.restore(r.trashed, r.original)
            lastRemoval = nil
            reloadSelecting(r.original)
        }
    }

    /// The attributes inspector's Name: renames the selected set or folder.
    @discardableResult
    public func renameSelected(_ name: String) -> Bool {
        guard let row = selectedRow, name != row.name else { return false }
        return attempt { reloadSelecting(try catalog.rename(row.url, to: name)) }
    }

    // MARK: The selected set

    public var slots: [AssetCatalog.Slot] { _ = revision; return selectedSet.map(AssetCatalog.slots(of:)) ?? [] }
    public var colors: [AssetCatalog.ColorValue] { _ = revision; return selectedSet.map(AssetCatalog.colors(of:)) ?? [] }
    public var inspector: AssetCatalog.InspectorSection? { _ = revision; return selectedSet.map(AssetCatalog.inspector(for:)) }

    /// Where a slot's image is, if it has one.
    public func imageURL(slot: Slot) -> URL? {
        guard let set = selectedSet, let f = slot.filename else { return nil }
        let u = set.url.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    public typealias Slot = AssetCatalog.Slot

    /// Copies an image into a slot (replacing what was there).
    @discardableResult
    public func setImage(_ file: URL, slot: Int) -> Bool {
        guard let set = selectedSet else { return false }
        return attempt { try AssetCatalog.setImage(file, slot: slot, in: set); changed() }
    }

    /// Empties a slot (the Delete key or the slot's Remove).
    @discardableResult
    public func clearImage(slot: Int) -> Bool {
        guard let set = selectedSet else { return false }
        return attempt { try AssetCatalog.clearImage(slot: slot, in: set); changed() }
    }

    /// Image sets: adds Dark-appearance slots.
    @discardableResult
    public func addDarkAppearance() -> Bool {
        guard let set = selectedSet else { return false }
        return attempt { try AssetCatalog.addDarkAppearance(to: set); changed() }
    }

    @discardableResult
    public func setColor(_ c: AssetCatalog.ColorValue, at index: Int) -> Bool {
        guard let set = selectedSet else { return false }
        return attempt { try AssetCatalog.setColor(c, at: index, in: set); changed() }
    }

    /// A Color Set inspector checkbox: a device or High Contrast.
    @discardableResult
    public func setInspectorCheckbox(_ label: String, on: Bool) -> Bool {
        guard let set = selectedSet, set.kind == .colorSet else { return false }
        return attempt {
            if label == "High Contrast" {
                try AssetCatalog.setColorHighContrast(on, in: set)
            } else if let d = AssetCatalog.colorDevices.first(where: { $0.label == label }) {
                try AssetCatalog.setColorIdiom(d.idiom, included: on, in: set)
            }
            changed()
        }
    }

    /// The Color Set Appearances pop-up ("None" or "Any, Dark").
    @discardableResult
    public func setAppearances(_ value: String) -> Bool {
        guard let set = selectedSet else { return false }
        return attempt {
            if set.kind == .colorSet {
                try AssetCatalog.setColorDarkAppearance(value == "Any, Dark", in: set)
            } else if value == "Any, Dark" {
                try AssetCatalog.addDarkAppearance(to: set)
            }
            changed()
        }
    }

    /// A folder's Provides Namespace.
    public var providesNamespace: Bool { _ = revision; return selectedFolder.map(AssetCatalog.providesNamespace) ?? false }

    @discardableResult
    public func setProvidesNamespace(_ on: Bool) -> Bool {
        guard let f = selectedFolder else { return false }
        return attempt { try AssetCatalog.setProvidesNamespace(on, folder: f); changed() }
    }

    /// One color as `#RRGGBB` (alpha left out) and back.
    public static func hex(_ c: AssetCatalog.ColorValue) -> String {
        func b(_ x: Double) -> String { String(format: "%02X", Int((min(max(x, 0), 1) * 255).rounded())) }
        return "#" + b(c.red) + b(c.green) + b(c.blue)
    }

    public static func color(_ c: AssetCatalog.ColorValue, hex: String) -> AssetCatalog.ColorValue? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        var out = c
        out.red = Double((v >> 16) & 0xFF) / 255
        out.green = Double((v >> 8) & 0xFF) / 255
        out.blue = Double(v & 0xFF) / 255
        return out
    }

    public func clearProblem() { problem = nil }

    private func changed() { revision += 1 }

    private func reloadSelecting(_ url: URL?) {
        reload()
        if let url { select(url: url) }
    }

    @discardableResult
    private func attempt(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            problem = nil
            return true
        } catch {
            problem = (error as? CocoaError).map { e in
                switch e.code {
                case .fileWriteFileExists: "An item with that name already exists."
                case .fileWriteInvalidFileName: "That name can't be used."
                default: e.localizedDescription
                }
            } ?? "\(error)"
            reload()
            return false
        }
    }
}
