import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The inspector column (`metrics.md` §5): its toolbar band, the tab
/// capsule (File, History, Quick Help), then the File inspector's sections
/// for the open file (`WorkspaceShellModel.fileInspector`, the rows the
/// AppKit inspector shows): 12-point side insets, an 80-point key column,
/// values 8 after it, 11-point text.
struct InspectorColumn: View {
    var model: WorkspaceShellModel
    /// The asset catalog editor's Attributes tab is chosen.
    @State private var assetTab = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            InspectorToolbar(model: model)
            // File, History and Quick Help follow the model (Quick Help can be
            // asked for from the editor); the asset catalog editor adds its
            // Attributes tab on top.
            let tab = assetTab && assetModel != nil ? AssetInspectorTab.index : model.languageFeatures.inspectorTab.rawValue
            InspectorTabs(selected: tab, extra: assetModel != nil ? AssetInspectorTab.symbol : nil) { i in
                assetTab = i == AssetInspectorTab.index
                if !assetTab { model.showInspector(ShellLanguageFeatures.InspectorTab(rawValue: i) ?? .file) }
            }
                .padding(.horizontal, CGFloat(WorkspaceChrome.selectorInset))
            Group {
                if tab == AssetInspectorTab.index, let a = assetModel {
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
                    centered("Not Applicable", c)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.fileInspector.enumerated()), id: \.offset) { pair in
                            if pair.offset > 0 {
                                Hairline(color: c.separator).padding(.top, 10).padding(.bottom, 8)
                            }
                            section(pair.element, c)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CGFloat(WorkspaceChrome.inspectorContentInset))
                    .padding(.top, CGFloat(WorkspaceChrome.inspectorContentTopInset))
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

    /// An empty inspector's message, centered on the whole column (as the
    /// AppKit inspector centers it), 13 points.
    func centered(_ s: String, _ c: ShellColors) -> some View {
        Text(verbatim: s).font(Font.system(size: 13)).foregroundStyle(c.secondaryLabel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, -(CGFloat(WorkspaceChrome.toolbarHeight) + CGFloat(WorkspaceChrome.selectorHeight)))
    }

    func section(_ s: InspectorSection, _ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: s.title).font(ShellFonts.smallBold).tracking(ShellFonts.smallTracking).foregroundStyle(c.label)
                .padding(.bottom, 2)
            ForEach(Array(s.rows.enumerated()), id: \.offset) { pair in
                row(pair.element, c)
            }
        }
    }

    func row(_ r: InspectorRow, _ c: ShellColors) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CGFloat(WorkspaceChrome.inspectorKeyToValue)) {
            Text(verbatim: r.key).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                .frame(width: CGFloat(WorkspaceChrome.inspectorKeyColumnWidth), alignment: .trailing)
            value(r.value, c)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        // The row takes the content's width, never its controls' ideal
        // widths (a long pop-up title truncates inside its column).
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func value(_ v: InspectorRow.Value, _ c: ShellColors) -> some View {
        switch v {
        case .field(let s):
            Text(verbatim: s).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.fieldFill)
                        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                }
        case .popUp(let s, let button):
            HStack(spacing: 6) {
                PopUpLook(title: s)
                if let button { Image(systemName: button).font(.system(size: 12)).foregroundStyle(c.secondaryLabel) }
            }
        case .label(let s, let bold):
            Text(verbatim: s).font(bold ? ShellFonts.smallBold : ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
        case .path(let s, let button):
            HStack(alignment: .center, spacing: 6) {
                // The path wraps in 140 points (the AppKit label's preferred
                // width), less what the reveal button needs at this width.
                Text(verbatim: s).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(12)
                    .frame(width: 132, alignment: .leading)
                Spacer(minLength: 0)
                Image(systemName: button).font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
            }
        case .steppers(let list):
            HStack(spacing: 12) {
                ForEach(Array(list.enumerated()), id: \.offset) { pair in
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            Text(verbatim: "\(pair.element.value)").font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(c.secondaryLabel)
                                .frame(width: 14, height: 18)
                                .background { Capsule(style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                        }
                        Text(verbatim: pair.element.title).font(.system(size: 9)).foregroundStyle(c.secondaryLabel)
                    }
                }
            }
        }
    }
}

/// The inspector's tab capsule: File, History, Quick Help; the selected
/// tab in a 78 × 24 pill.
struct InspectorTabs: View {
    var selected: Int
    /// A fourth tab's symbol (the asset catalog's Attributes inspector).
    var extra: String?
    var select: (Int) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let pill = WorkspaceChrome.inspectorTabPillSize
        HStack(spacing: 0) {
            ForEach(Array((WorkspaceChrome.inspectorSymbols + (extra.map { [$0] } ?? [])).enumerated()), id: \.offset) { pair in
                let on = pair.offset == selected
                Button { select(pair.offset) } label: {
                    ZStack {
                        if on { Capsule(style: .continuous).fill(c.selectorPill).frame(width: extra == nil ? CGFloat(pill.width) : 58, height: CGFloat(pill.height)) }
                        Image(systemName: pair.element).font(.system(size: 13)).foregroundStyle(on ? c.accent : c.toolbarIcon)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: CGFloat(WorkspaceChrome.selectorHeight))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(["Show the File inspector", "Show the History inspector", "Show the Quick Help inspector", "Show the Attributes inspector"][pair.offset])
                .shellTarget("inspector tab \(pair.offset)")
            }
        }
        .padding(.horizontal, 3)
        .frame(height: CGFloat(WorkspaceChrome.selectorHeight))
        .background { GlassCapsule(height: CGFloat(WorkspaceChrome.selectorHeight)) }
    }
}
