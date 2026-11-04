import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(AppKit)
import AppKit
#endif
import YcodeIDECore
import YcodeIDEShell

/// The asset catalog editor (`specs/ide/asset-catalog.md`,
/// `reference-ui-3.md` §3): the outline of folders and sets at the left
/// with "+", "−" and the filter under it; the selected set at the right:
/// its name and type, then its slots (image sets, app icons) or colors
/// (color sets). A click on an empty slot chooses an image; a filled slot's
/// context menu replaces or removes it, as does Delete. The set's
/// attributes are in the inspector's Attributes tab.
struct AssetCatalogEditorView: View {
    var model: AssetCatalogEditorModel
    @State private var importing = false
    @State private var choosingFrame = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            if let p = model.problem { ProblemBanner(message: p) { model.clearProblem() } }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    AssetOutline(model: model)
                    Hairline(color: c.separator)
                    EditorListBar(removeEnabled: model.selectedRow != nil, remove: { model.removeSelected() }, filter: model.filter,
                                  setFilter: { model.setFilter($0) }, target: "assets") {
                        AddAssetMenu(model: model, importing: $importing, choosingFrame: $choosingFrame)
                    }
                }
                .frame(width: 230)
                .background(c.sidebar)
                Hairline(color: c.separator, vertical: true)
                AssetDetail(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(c.content)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { model.importFiles(urls) }
        }
        .fileImporter(isPresented: $choosingFrame, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { model.addStickerFrame(url) }
        }
        .shellTarget("asset catalog editor")
    }
}

/// The "+" pull-down: the set kinds by platform, folders and Import….
struct AddAssetMenu: View {
    var model: AssetCatalogEditorModel
    @Binding var importing: Bool
    @Binding var choosingFrame: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Menu {
            entries(model.addMenu)
        } label: {
            HStack(spacing: 1) {
                Image(systemName: "plus").font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .foregroundStyle(c.toolbarIcon)
            .frame(width: 30, height: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .hidingMenuIndicator()
        .fixedSize()
        .help("Add an asset")
        .shellTarget("assets add")
    }

    func entries(_ list: [AssetCatalog.AddMenuEntry]) -> AnyView {
        AnyView(ForEach(Array(list.enumerated()), id: \.offset) { pair in
            switch pair.element {
            case .separator: Divider()
            case let .submenu(title, children): Menu(title) { entries(children) }
            case let .item(title, enabled):
                let tag = AssetCatalog.AddMenuTags.creatable[title]
                Button(title) { run(tag) }
                    .disabled(!enabled || tag == nil || !(tag.map(model.canAdd(tag:)) ?? false))
            }
        })
    }

    func run(_ tag: Int?) {
        guard let tag else { return }
        switch tag {
        case AssetCatalog.AddMenuTags.importFiles: importing = true
        case AssetCatalog.AddMenuTags.stickerFrame: choosingFrame = true
        default: model.add(tag: tag)
        }
    }
}

/// The outline: folders and sets, 22-point rows indented by depth.
struct AssetOutline: View {
    var model: AssetCatalogEditorModel
    @FocusState private var hasKeyboard: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        // Icons show colors and images: drawn again after every edit.
        let _ = model.revision
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows, id: \.id) { r in
                    row(r, c)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.select(r.id)
                            hasKeyboard = true
                        }
                        .contextMenu {
                            Button("Delete") { model.select(r.id); model.removeSelected() }
                        }
                        .shellTarget("asset row \(r.id)")
                }
                if model.rows.isEmpty {
                    Text(verbatim: model.filter.isEmpty ? "No Assets" : "No Matches").font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }
            }
            .padding(.vertical, 6)
        }
        .focusable()
        .focused($hasKeyboard)
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.delete) { model.removeSelected(); return .handled }
        .onKeyPress(.deleteForward) { model.removeSelected(); return .handled }
        .shellTarget("asset outline")
    }

    func row(_ r: AssetCatalog.OutlineRow, _ c: ShellColors) -> some View {
        let selected = r.id == model.selectedID
        return HStack(spacing: 4) {
            Group {
                if r.hasChildren {
                    Image(systemName: model.isCollapsed(r.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(c.chevron)
                        .frame(width: 13, height: 22).contentShape(Rectangle())
                        .onTapGesture { model.toggle(r.id) }
                } else {
                    Color.clear.frame(width: 13, height: 22)
                }
            }
            .padding(.leading, 8 + CGFloat(r.depth) * 12)
            AssetIcon(row: r, revision: model.revision, colors: c)
            Text(verbatim: r.name).font(ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
            Spacer(minLength: 4)
        }
        .frame(height: 22)
        .background {
            if selected { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.rowSelection).padding(.horizontal, 6) }
        }
    }
}

/// A row's icon: a folder, a color set's first color, an image set's first
/// image, else the kind's symbol.
struct AssetIcon: View {
    var row: AssetCatalog.OutlineRow
    /// The editor's revision: a new one draws the icon again.
    var revision: Int
    var colors: ShellColors

    var body: some View {
        Group {
            if let set = row.set, set.kind == .colorSet, let first = AssetCatalog.colors(of: set).first {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(first.swiftUIColor)
                    .overlay { RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(colors.fieldStroke, lineWidth: 1) }
                    .frame(width: 14, height: 14)
            } else if let set = row.set, set.kind == .imageSet || set.kind == .appIconSet,
                      let file = AssetCatalog.slots(of: set).compactMap(\.filename).first,
                      FileManager.default.fileExists(atPath: set.url.appendingPathComponent(file).path) {
                FileImage(url: set.url.appendingPathComponent(file)).frame(width: 16, height: 16)
            } else {
                Image(systemName: Self.symbol(row)).font(.system(size: 12)).foregroundStyle(row.isFolder ? colors.accent : colors.secondaryLabel)
            }
        }
        .frame(width: 18, height: 18)
    }

    /// Symbols the shell's artwork has.
    static func symbol(_ r: AssetCatalog.OutlineRow) -> String {
        guard let k = r.set?.kind else { return "folder.fill" }
        switch k {
        case .imageSet: return "photo"
        case .colorSet: return "circle.fill"
        case .appIconSet, .solidImageStack, .brandAssets, .stickersIconSet: return "app.dashed"
        case .symbolSet: return "star"
        case .dataSet: return "doc"
        case .spriteAtlas, .arResourceGroup, .stickerPack: return "folder"
        default: return "square.stack.3d.up"
        }
    }
}

/// The right side: the selected set's header and content.
struct AssetDetail: View {
    var model: AssetCatalogEditorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        if let set = model.selectedSet {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: set.name).font(Font.system(size: 15, weight: .semibold)).foregroundStyle(c.label).lineLimit(1)
                    Spacer()
                    Text(verbatim: set.kind.typeLabel).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)
                .shellTarget("asset header")
                Hairline(color: c.separator).padding(.horizontal, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch set.kind {
                        case .colorSet: ColorSetDetail(model: model)
                        default:
                            if set.kind.slotKey != nil {
                                SlotGrid(model: model)
                            } else {
                                Text(verbatim: "Ycode edits this kind of set in its folder; its contents are kept as they are.")
                                    .font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if let folder = model.selectedFolder {
            VStack(spacing: 6) {
                Image(systemName: "folder.fill").font(.system(size: 40)).foregroundStyle(c.accent)
                Text(verbatim: folder.lastPathComponent).font(Font.system(size: 15, weight: .semibold)).foregroundStyle(c.label)
                Text(verbatim: model.providesNamespace ? "Folder · Provides Namespace" : "Folder").font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shellTarget("asset folder detail")
        } else {
            Text(verbatim: "No Selection").font(Font.system(size: 15)).foregroundStyle(c.secondaryLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Image and app-icon slots, grouped by idiom, four to a row.
struct SlotGrid: View {
    var model: AssetCatalogEditorModel
    @State private var chosenSlot: Int?
    @State private var choosing = false
    @State private var selectedSlot: Int?
    @FocusState private var hasKeyboard: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let slots = Array(model.slots.enumerated())
        let groups = Dictionary(grouping: slots, by: { $0.element.platform.map { AssetCatalogPlatform.title($0) } ?? AssetCatalogPlatform.idiom($0.element.idiom) })
        let order = slots.map { $0.element.platform.map { AssetCatalogPlatform.title($0) } ?? AssetCatalogPlatform.idiom($0.element.idiom) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 18) {
            ForEach(order, id: \.self) { g in
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 120), spacing: 12, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(groups[g] ?? [], id: \.offset) { pair in
                            SlotWell(model: model, slot: pair.element, index: pair.offset, selected: selectedSlot == pair.offset, colors: c) {
                                selectedSlot = pair.offset
                                hasKeyboard = true
                                if model.imageURL(slot: pair.element) == nil { chosenSlot = pair.offset; choosing = true }
                            } choose: {
                                chosenSlot = pair.offset
                                choosing = true
                            }
                        }
                    }
                    // Single-size icons name their platform under the slot already.
                    if !(groups[g] ?? []).allSatisfy({ $0.element.platform != nil }) {
                        Text(verbatim: g).font(ShellFonts.small.weight(.semibold)).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                    }
                }
            }
            if model.selectedSet?.kind == .imageSet, !model.slots.contains(where: { $0.appearance == "dark" }) {
                Button("Add Dark Appearance") { model.addDarkAppearance() }
                    .shellTarget("asset add dark")
            }
        }
        .focusable()
        .focused($hasKeyboard)
        .onKeyPress(.delete) { if let s = selectedSlot { model.clearImage(slot: s) }; return .handled }
        .onKeyPress(.deleteForward) { if let s = selectedSlot { model.clearImage(slot: s) }; return .handled }
        .onChange(of: model.selectedID) { _, _ in selectedSlot = nil }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let i = chosenSlot { model.setImage(url, slot: i) }
        }
        .shellTarget("asset slots")
    }
}

/// One slot: the image or a dashed box, and its captions.
struct SlotWell: View {
    var model: AssetCatalogEditorModel
    var slot: AssetCatalog.Slot
    var index: Int
    var selected: Bool
    var colors: ShellColors
    var tap: () -> Void
    var choose: () -> Void

    var body: some View {
        let c = colors
        let url = model.imageURL(slot: slot)
        VStack(spacing: 5) {
            ZStack {
                if let url {
                    FileImage(url: url).padding(4)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(c.tertiaryLabel, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    if let label = slot.boxLabel {
                        Text(verbatim: label).font(ShellFonts.mini).foregroundStyle(c.tertiaryLabel)
                    }
                }
            }
            .frame(width: 84, height: 84)
            .background {
                if selected { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.accent.opacity(0.18)).padding(-4) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            ForEach(Array((slot.captions.isEmpty ? [slot.title] : Array(slot.captions.dropFirst(slot.platform == nil ? 1 : 0))).enumerated()), id: \.offset) { p in
                Text(verbatim: p.element.isEmpty ? "Any" : p.element).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel).lineLimit(1)
            }
        }
        .frame(width: 104)
        .contextMenu {
            Button(url == nil ? "Choose Image…" : "Replace Image…", action: choose)
            Button("Remove") { model.clearImage(slot: index) }.disabled(url == nil)
        }
        .help(slot.filename ?? "Click to choose an image")
        .shellTarget("asset slot \(index)")
    }
}

/// Color sets: per appearance, the swatch and its components.
struct ColorSetDetail: View {
    var model: AssetCatalogEditorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let colors = Array(model.colors.enumerated())
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 280), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
            ForEach(colors, id: \.offset) { pair in
                ColorEntryView(model: model, color: pair.element, index: pair.offset, colors: c)
            }
        }
        .shellTarget("asset colors")
    }
}

struct ColorEntryView: View {
    var model: AssetCatalogEditorModel
    var color: AssetCatalog.ColorValue
    var index: Int
    var colors: ShellColors
    var showsAppearance: Bool { model.colors.contains { $0.appearance != nil } }

    var body: some View {
        let c = colors
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.swiftUIColor)
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                .frame(width: 84, height: 84)
            // The slot's caption (reference-ui-3 §3.4): "Universal", and the
            // appearance once there is more than one.
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Universal").font(ShellFonts.small.weight(.semibold)).tracking(ShellFonts.smallTracking).foregroundStyle(c.label)
                if showsAppearance {
                    Text(verbatim: color.appearance.map { $0 == "dark" ? "Dark" : $0.capitalized } ?? "Any Appearance")
                        .font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    label("Content")
                    CellPopUp(title: color.space == .sRGB ? "sRGB" : "Display P3", choices: ["sRGB", "Display P3"]) { s in
                        var v = color
                        v.space = s == "sRGB" ? .sRGB : .displayP3
                        model.setColor(v, at: index)
                    }
                    .shellTarget("color space \(index)")
                }
                GridRow {
                    label("Hex")
                    InlineField(text: AssetCatalogEditorModel.hex(color)) { t in
                        if let v = AssetCatalogEditorModel.color(color, hex: t) { model.setColor(v, at: index) }
                    }
                    .frame(width: 90)
                    .shellTarget("color hex \(index)")
                }
                ForEach(Array(["Red", "Green", "Blue", "Alpha"].enumerated()), id: \.offset) { p in
                    GridRow {
                        label(p.element)
                        InlineField(text: String(format: "%.3f", component(p.offset))) { t in
                            guard let x = Double(t.trimmingCharacters(in: .whitespaces)) else { return }
                            var v = color
                            switch p.offset {
                            case 0: v.red = x
                            case 1: v.green = x
                            case 2: v.blue = x
                            default: v.alpha = x
                            }
                            model.setColor(v, at: index)
                        }
                        .frame(width: 90)
                        .shellTarget("color \(p.element.lowercased()) \(index)")
                    }
                }
            }
        }
    }

    func component(_ i: Int) -> Double { [color.red, color.green, color.blue, color.alpha][i] }

    func label(_ s: String) -> some View {
        Text(verbatim: s).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(colors.secondaryLabel)
            .frame(width: 52, alignment: .trailing)
    }
}

/// The inspector's Attributes tab for the selected set or folder
/// (`reference-ui-5.md` §7.6): Name, then the set's rows (Color Set:
/// devices, Appearances, High Contrast; App Icon: platforms), or a
/// folder's Provides Namespace.
struct AssetAttributesInspector: View {
    var model: AssetCatalogEditorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 7) {
            if let row = model.selectedRow {
                Text(verbatim: row.isFolder ? "Folder" : (model.inspector?.title ?? "")).font(ShellFonts.smallBold).tracking(ShellFonts.smallTracking)
                    .foregroundStyle(c.label).padding(.bottom, 3)
                line("Name") {
                    InlineField(text: row.name) { model.renameSelected($0) }.shellTarget("asset name field")
                }
                if row.isFolder {
                    line("") {
                        Toggle("Provides Namespace", isOn: Binding(get: { model.providesNamespace }, set: { model.setProvidesNamespace($0) }))
                            .font(ShellFonts.small)
                            .toggleStyle(.checkbox)
                            .shellTarget("asset namespace")
                    }
                } else if let section = model.inspector {
                    let editable = model.selectedSet?.kind == .colorSet
                    ForEach(Array(section.rows.dropFirst().enumerated()), id: \.offset) { pair in
                        let r = pair.element
                        if let checked = r.checked {
                            line("") {
                                Toggle(r.label, isOn: Binding(get: { checked }, set: { model.setInspectorCheckbox(r.label, on: $0) }))
                                    .font(ShellFonts.small)
                                    .toggleStyle(.checkbox)
                                    .disabled(!editable)
                                    .shellTarget("asset check \(r.label)")
                            }
                        } else if r.label == "Appearances", model.selectedSet?.kind == .colorSet || model.selectedSet?.kind == .imageSet {
                            line(r.label) {
                                CellPopUp(title: r.value ?? "None", choices: ["None", "Any, Dark"]) { model.setAppearances($0) }
                                    .shellTarget("asset appearances")
                            }
                        } else {
                            line(r.label) {
                                Text(verbatim: r.value ?? "").font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(1)
                            }
                        }
                    }
                    if model.selectedSet?.kind == .imageSet {
                        line("Appearances") {
                            CellPopUp(title: model.slots.contains { $0.appearance == "dark" } ? "Any, Dark" : "None", choices: ["None", "Any, Dark"]) {
                                model.setAppearances($0)
                            }
                            .shellTarget("asset appearances")
                        }
                    }
                }
            } else {
                Text(verbatim: "No Selection").font(Font.system(size: 13)).foregroundStyle(c.secondaryLabel)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CGFloat(WorkspaceChrome.inspectorContentInset))
        .padding(.top, CGFloat(WorkspaceChrome.inspectorContentTopInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shellTarget("asset inspector")
    }

    func line<V: View>(_ key: String, @ViewBuilder _ value: () -> V) -> some View {
        let c = ShellColors(scheme)
        return HStack(alignment: .center, spacing: CGFloat(WorkspaceChrome.inspectorKeyToValue)) {
            Text(verbatim: key).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                .frame(width: CGFloat(WorkspaceChrome.inspectorKeyColumnWidth), alignment: .trailing)
            value().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Group captions for slots.
enum AssetCatalogPlatform {
    static func title(_ p: String) -> String {
        switch p { case "ios": "iOS"; case "macos": "macOS"; case "watchos": "watchOS"; case "tvos": "tvOS"; case "xros", "visionos": "visionOS"; default: p }
    }

    static func idiom(_ i: String) -> String {
        switch i {
        case "universal": "Universal"; case "iphone": "iPhone"; case "ipad": "iPad"; case "mac": "Mac"; case "watch": "Apple Watch"
        case "tv": "Apple TV"; case "vision": "Apple Vision"; case "car": "CarPlay"; case "ios-marketing": "App Store"
        default: i.capitalized
        }
    }
}

extension AssetCatalog.ColorValue {
    var swiftUIColor: Color {
        Color(space == .sRGB ? .sRGB : .displayP3, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// An image file shown scaled to fit. OpenViews reads PNG and JPEG files
/// through a bundle rooted at the file's folder; macOS reads any image.
struct FileImage: View {
    var url: URL

    var body: some View {
        #if canImport(AppKit)
        if let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        } else {
            placeholder
        }
        #else
        if ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()), let bundle = Bundle(path: url.deletingLastPathComponent().path) {
            Image(url.deletingPathExtension().lastPathComponent, bundle: bundle).resizable().aspectRatio(contentMode: .fit)
        } else {
            placeholder
        }
        #endif
    }

    var placeholder: some View {
        Image(systemName: "doc").font(.system(size: 22)).foregroundStyle(Color.gray)
    }
}

/// The inspector's fourth tab while an asset catalog is shown.
enum AssetInspectorTab {
    static let index = 3
    static let symbol = "slider.horizontal.3"
}
