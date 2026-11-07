import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The inspector column (`metrics.md` §5): its toolbar band, the tab
/// capsule (File, History, Quick Help), then the File inspector's sections
/// for the open file (`WorkspaceShellModel.fileInspector`, the rows the
/// AppKit inspector shows, laid out by `FileInspectorView` as the AppKit
/// inspector lays them out).
struct InspectorColumn: View {
    var model: WorkspaceShellModel
    /// Off while the column slides (the toggle stays at the window's edge).
    var showsToolbar = true
    /// The asset catalog editor's Attributes tab is chosen.
    @State private var assetTab = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            InspectorToolbar(model: model).opacity(showsToolbar ? 1 : 0)
            // File, History and Quick Help follow the model (Quick Help can be
            // asked for from the editor); the asset catalog editor adds its
            // Attributes tab on top.
            let ibTab = ibModel?.inspectorTab
            let tab = ibTab.map { 3 + $0.rawValue }
                ?? (assetTab && assetModel != nil ? AssetInspectorTab.index : model.languageFeatures.inspectorTab.rawValue)
            // Interface Builder documents add Identity, Attributes, Size and
            // Connections (InterfaceBuilderInspectors.swift).
            let extras = ibModel != nil ? IBInspectorTab.allCases.map(\.symbol) : assetModel != nil ? [AssetInspectorTab.symbol] : []
            InspectorTabs(selected: tab, extras: extras) { i in
                if let ib = ibModel {
                    ib.inspectorTab = IBInspectorTab(rawValue: i - 3)
                    if i < 3 { model.showInspector(ShellLanguageFeatures.InspectorTab(rawValue: i) ?? .file) }
                    return
                }
                assetTab = i == AssetInspectorTab.index
                if !assetTab { model.showInspector(ShellLanguageFeatures.InspectorTab(rawValue: i) ?? .file) }
            }
                .padding(.horizontal, CGFloat(WorkspaceChrome.selectorInset))
            Group {
                if let ib = ibModel, let t = ibTab {
                    IBInspectorView(model: ib, tab: t)
                } else if tab == AssetInspectorTab.index, let a = assetModel {
                    AssetAttributesInspector(model: a)
                } else if tab == 2 {
                    QuickHelpInspector(model: model)
                } else if tab == 1 {
                    FileHistoryInspector(model: model)
                } else if tab == 0, model.sourceControl.pane != nil {
                    SourceControlInspector(scm: model.sourceControl)
                } else if tab != 0 {
                    centered("No Quick Help", c)
                } else if model.document == nil {
                    // "No Selection" in the Repositories view (editor-area.md F.10).
                    centered(model.navigator == .sourceControl && model.sourceControl.mode == .repositories ? "No Selection" : "Not Applicable", c)
                } else {
                    // The contents scroll when taller than the area (an
                    // image's or a project file's sections).
                    ScrollView { FileInspectorView(sections: model.fileInspector) }   // FileInspectorView.swift
                        .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .shellTarget("inspector")
        // The asset catalog editor adds its Attributes tab and shows it.
        .onChange(of: assetModel != nil) { _, on in assetTab = on }
        .onAppear { if assetModel != nil { assetTab = true } }
    }

    var assetModel: AssetCatalogEditorModel? {
        if case .assetCatalog(let m)? = model.structuredEditor { return m }
        return nil
    }

    var ibModel: InterfaceBuilderShellModel? {
        if case .interfaceBuilder(let m)? = model.structuredEditor { return m }
        return nil
    }

    /// An empty inspector's message, centred in the room below the tab bar
    /// as the AppKit inspector centres it (navigators.md round 3 §2;
    /// `cross-platform-parity.md` §8: it was 41 higher), about 17 points
    /// (cap height 12; editor-area.md F.10, row 111).
    func centered(_ s: String, _ c: ShellColors) -> some View {
        Text(verbatim: s).font(Font.system(size: 17)).foregroundStyle(c.secondaryLabel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The inspector's tab capsule: File, History, Quick Help; the selected
/// tab in a 78 × 24 pill (narrower when an editor adds tabs).
struct InspectorTabs: View {
    var selected: Int
    /// Symbols of the tabs an editor adds (the asset catalog's Attributes
    /// inspector; Interface Builder's Identity, Attributes, Size, Connections).
    var extras: [String] = []
    var select: (Int) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let pill = WorkspaceChrome.inspectorTabPillSize
        HStack(spacing: 0) {
            ForEach(Array((WorkspaceChrome.inspectorSymbols + extras).enumerated()), id: \.offset) { pair in
                let on = pair.offset == selected
                let width: CGFloat = extras.isEmpty ? CGFloat(pill.width) : extras.count == 1 ? 58 : 30
                Button { select(pair.offset) } label: {
                    ZStack {
                        if on { Capsule(style: .continuous).fill(c.panePill).frame(width: width, height: CGFloat(pill.height)) }
                        // Grey glyphs on a grey pill, no accent (row 18).
                        Image(systemName: pair.element).font(.system(size: 13)).foregroundStyle(c.inspectorTabGlyph(selected: on))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: CGFloat(WorkspaceChrome.selectorHeight))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pair.offset < 3 ? ["Show the File inspector", "Show the History inspector", "Show the Quick Help inspector"][pair.offset]
                      : extras.count == 1 ? "Show the Attributes inspector" : "Show the \(IBInspectorTab(rawValue: pair.offset - 3)?.title ?? "") inspector")
                .shellTarget("inspector tab \(pair.offset)")
            }
        }
        .padding(.horizontal, 3)
        .frame(height: CGFloat(WorkspaceChrome.selectorHeight))
        .background { PaneCapsule(height: CGFloat(WorkspaceChrome.selectorHeight)) }   // PaneStyle.swift
    }
}
