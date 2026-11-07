import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell

/// The workspace window (`workspace-window.md` §Areas), laid out as the
/// AppKit IDE lays it out (`docs/PARITY.md` §5.10): three columns, the
/// navigator (290), the editor over the debug area, and the inspector
/// (260), each running the full height of the window with its part of the
/// toolbar in a 52-point band at its top (the AppKit window's toolbar
/// tracks the split view's columns the same way).
struct WorkspaceView: View {
    @Bindable var model: WorkspaceShellModel
    var app: ShellAppModel
    @Environment(\.colorScheme) private var scheme
    /// The inspector's show/hide slide (InspectorSlide.swift).
    @State private var inspectorSlide = InspectorSlideState()

    var body: some View {
        let c = ShellColors(scheme)
        let sliding = inspectorSlide.isSliding(modelShows: model.isInspectorShown)
        HSplitView {
            if model.isNavigatorShown {
                NavigatorColumn(model: model)
                    .frame(minWidth: 180, idealWidth: CGFloat(WorkspaceChrome.navigatorWidth), maxWidth: 500)
                    .background(c.sidebar)
            }
            CenterColumn(model: model, app: app, inspectorSliding: sliding)
                .frame(minWidth: 300, maxWidth: .infinity)
                .background(c.content)
            if model.isInspectorShown || sliding {
                InspectorSlidePane(progress: inspectorSlide.progress, isRunning: sliding) {
                    InspectorColumn(model: model, showsToolbar: !sliding)
                }
                .background(c.sidebar)
            }
        }
        // While the inspector slides its toggle stays at the window's edge.
        .overlay(alignment: .topTrailing) {
            if sliding { InspectorToolbar(model: model).frame(width: 52) }
        }
        .onAppear { inspectorSlide.sync(model.isInspectorShown) }
        .onChange(of: model.isInspectorShown) { _, shown in inspectorSlide.run(show: shown) }
        // Under the merge alert and sheet the window draws disabled (§13.1).
        .opacity(model.sourceControl.isMergeModalShown ? MergeModalTone.text : 1)
        .background(Color(mergeHex: MergeModalTone.backdrop(dark: c.dark)))   // MergeOverlay.swift: what the dimmed window shows through
        .animation(.easeOut(duration: MergeSheetMotion.veilIn), value: model.sourceControl.isMergeModalShown)
        .overlay { BuildBezelOverlay(notifier: model.notifier) }
        .overlay { BreakpointEditorLayer(model: model) }   // DebugEditors.swift
        .overlay { MergeOverlayLayer(scm: model.sourceControl, app: app) }   // MergeOverlay.swift: the merge alert and sheet
        .navigationTitle(model.windowTitle)
        .modifier(EditorPrompts(model: model))
        .modifier(LanguageSheets(model: model, app: app))
        .modifier(SourceControlDialogs(scm: model.sourceControl))
        .modifier(AssistantPrompts(assistant: model.assistant))
    }
}

// MARK: - Toolbar bands

/// The navigator column's toolbar: Navigators | Coding Assistant, then
/// Run | Stop at the column's end (`liquid-glass.md` §2.2).
struct NavigatorToolbar: View {
    var model: WorkspaceShellModel

    var body: some View {
        let lp = WorkspaceChrome.leftPanes, rs = WorkspaceChrome.runStop
        HStack(spacing: 0) {
            // Navigators | Coding Assistant: clicking the shown one hides the area.
            let navigatorsOn = model.isNavigatorShown && !model.assistant.isShown
            GlassSegments(segments: [
                .init(symbol: lp.symbols[0], help: navigatorsOn ? "Hide the Navigator" : "Show the Navigator", isOn: navigatorsOn,
                      target: "tb navigator") { model.showLeftPane(assistant: false) },
                .init(symbol: lp.symbols[1], help: lp.toolTips[1], isOn: model.isAssistantPaneShown, target: "tb assistant") {
                    model.showLeftPane(assistant: true)
                },
            ], segmentWidth: 29, dividers: false)   // 78 wide with its rim, as the AppKit toolbar (parity §2)
            Spacer(minLength: 8)
            GlassSegments(segments: [
                .init(symbol: rs.symbols[0], help: rs.toolTips[0], isEnabled: model.isEnabled(.run), target: "tb run") { model.perform(.run) },
                .init(symbol: rs.symbols[1], help: rs.toolTips[1], isEnabled: model.isEnabled(.stop), target: "tb stop") { model.perform(.stop) },
            ], segmentWidth: 26.5)   // 75 wide with its rim, as the AppKit toolbar (parity §2)
        }
        // The AppKit window keeps its first 96 points for the window's
        // buttons; the shell keeps the same room so the items line up.
        .padding(.leading, 96)
        .padding(.trailing, 8.5)
        .frame(height: CGFloat(WorkspaceChrome.toolbarHeight) - 1)
    }
}

/// The center column's toolbar: Back | Forward, the activity view; New
/// Conversation, the scheme › destination capsule and the issue capsule;
/// Add Editor and Editor Options, then the editor modes. Short of room it
/// gives up what the AppKit toolbar does, in `ToolbarFit`'s order
/// (`liquid-glass.md` §8.2, `editor-area.md` G.4): the scheme capsule's
/// titles (and the issue capsule's counts), then the editor modes into
/// the "»" menu, then the activity subtitle truncates.
struct CenterToolbar: View {
    @Bindable var model: WorkspaceShellModel
    var app: ShellAppModel
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(ToolbarFit())
            row(ToolbarFit(schemeGlyphsOnly: true))
            row(ToolbarFit(editorModesInOverflow: true, schemeGlyphsOnly: true))
        }
        .frame(height: CGFloat(WorkspaceChrome.toolbarHeight))
    }

    func row(_ fit: ToolbarFit) -> some View {
        let h = WorkspaceChrome.history, modes = WorkspaceChrome.editorModes
        return HStack(spacing: 0) {
            GlassSegments(segments: [
                .init(symbol: h.symbols[0], help: h.toolTips[0], isEnabled: model.canGoBack, target: "tb back") { model.perform(.goBack) },
                .init(symbol: h.symbols[1], help: h.toolTips[1], isEnabled: model.canGoForward, target: "tb forward") { model.perform(.goForward) },
            ], segmentWidth: 26.5)   // 75 wide with its rim (parity §2)
            ActivityView(model: model)
                .padding(.leading, 10)   // the icon 14 after Back | Forward's capsule (liquid-glass.md §7.1)
            Spacer(minLength: 8)
            NewConversationToolbarButton(assistant: model.assistant)   // AssistantPane.swift
            SchemeCapsule(model: model, app: app, glyphsOnly: fit.schemeGlyphsOnly)
                .padding(.leading, 8)
            IssueCapsule(summary: model.issueSummary, symbolsOnly: fit.schemeGlyphsOnly) { model.perform(.showIssueNavigator) }   // ToolbarChrome.swift
                .padding(.leading, model.issueSummary.isEmpty ? 0 : CGFloat(IssueSummary.Capsule.gapAfterScheme))
            Spacer(minLength: 8)
            AddEditorGroup(model: model)   // ToolbarChrome.swift: Add Editor's pull-down and Editor Options, 81 wide
            if fit.editorModesInOverflow {
                ToolbarOverflowMenu(model: model)   // ToolbarChrome.swift
                    .padding(.leading, 8)
            } else {
                GlassSegments(segments: [
                    .init(symbol: modes.symbols[0], help: modes.toolTips[0], isOn: model.previewCanvas.isModeOn, isEnabled: model.isEnabled(.toggleCanvas),
                          target: "tb canvas") { model.perform(.toggleCanvas) },
                    .init(symbol: modes.symbols[1], help: ShellText.notInBeta(modes.toolTips[1]), isEnabled: false, target: "tb assistant editor") {},
                    .init(symbol: modes.symbols[2], help: ShellText.notInBeta(modes.toolTips[2]), isEnabled: false, target: "tb code review") {},
                ], segmentWidth: 33)   // 125 wide with its rim (parity §2)
                .padding(.leading, 8)
            }
        }
        .padding(.leading, 7.5)
        .padding(.trailing, 8)
        .frame(height: CGFloat(WorkspaceChrome.toolbarHeight))
    }
}

/// The workspace's glyph, then two lines: the name and the activity
/// (`reference-ui-6.md` §3.1); idle, only the name, centered.
struct ActivityView: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 8) {
            Image(systemName: model.containerKind == .package ? "shippingbox" : "folder.badge.gearshape")
                .font(.system(size: 12))
                .foregroundStyle(c.toolbarIcon)
                .frame(width: 19, height: 19)   // 19 wide, the text 8 after it (liquid-glass.md §7.1 item 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: model.workspaceName).font(ShellFonts.activityName).foregroundStyle(c.label).lineLimit(1)
                if !model.activityText.isEmpty {
                    Text(verbatim: model.activityText)
                        .font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel).lineLimit(1)
                        .truncationMode(.middle)   // as the AppKit view (reference-ui-6.md §3.1.3)
                        .shellTarget("activity")
                }
            }
        }
        .frame(height: 34)
    }
}

/// Scheme › destination as two pop-ups in one capsule, as the AppKit
/// toolbar draws it (`liquid-glass.md` §7.1 item 2, `cross-platform-parity.md`
/// §2): each title after its glyph (the scheme's, the destination's),
/// 13 points regular, no up-down chevrons, a "›" between them; with
/// `glyphsOnly` (short of room) the glyphs alone, the titles in the help.
/// The issue counts are in their own capsule (`IssueCapsule`).
struct SchemeCapsule: View {
    @Bindable var model: WorkspaceShellModel
    var app: ShellAppModel
    var glyphsOnly = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let schemeName = model.scheme ?? "No Scheme", destinationName = model.destination?.name ?? "No Destination"
        HStack(spacing: glyphsOnly ? 4 : 0) {
            Menu {
                ForEach(model.schemes, id: \.self) { s in Button(s) { model.scheme = s } }
            } label: {
                popUpTitle(schemeName, symbol: "app.dashed", c)
            }
            .menuStyle(.borderlessButton)
            .help(glyphsOnly ? schemeName : "")
            .shellTarget("tb scheme")
            Text(verbatim: "\u{203A}").font(ShellFonts.toolbarItem).foregroundStyle(c.tertiaryLabel)
                .padding(.horizontal, glyphsOnly ? 0 : 3)
            Menu {
                DestinationMenuItems(model: model, groups: model.session.model.destinationGroups, secondary: c.secondaryLabel)
                if model.containerKind != .package, !model.destinations.contains(where: { ShellRemoteRun.target(of: $0) != nil }) {
                    Divider()
                    Button("Ycode Simulator (\(ExperimentalNotice.label))…") { app.explainSimulator() }
                }
            } label: {
                popUpTitle(destinationName, symbol: model.destination?.kind == .simulator ? "iphone" : "desktopcomputer", c)
            }
            .menuStyle(.borderlessButton)
            .help(glyphsOnly ? destinationName : "")
            .shellTarget("tb destination")
        }
        .padding(.horizontal, glyphsOnly ? 21.5 : 12)   // 89 wide with glyphs only, as the AppKit capsule
        .frame(height: CGFloat(WorkspaceChrome.toolbarItemHeight))
        .background { GlassCapsule(fill: c.capsuleFill) }
        .fixedSize()
    }

    func popUpTitle(_ title: String, symbol: String, _ c: ShellColors) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(c.label)
            if !glyphsOnly {
                Text(verbatim: title).font(ShellFonts.toolbarItem).foregroundStyle(c.label).lineLimit(1)
            }
        }
        .fixedSize()
    }
}

/// The inspector column's toolbar: the inspector toggle at its end.
struct InspectorToolbar: View {
    var model: WorkspaceShellModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(symbol: WorkspaceChrome.inspectorToggle.symbols[0],
                              help: model.isInspectorShown ? "Hide Inspector" : "Show Inspector", target: "tb inspector") {
                model.perform(.toggleInspector)
            }
        }
        .padding(.trailing, 8)
        .frame(height: CGFloat(WorkspaceChrome.toolbarHeight) - 1)
    }
}

// MARK: - Columns

/// The editor over the debug area, under the center toolbar. With the
/// navigator or the inspector hidden, their toolbar items join this band
/// (as the AppKit toolbar keeps them).
struct CenterColumn: View {
    var model: WorkspaceShellModel
    var app: ShellAppModel
    /// The inspector slides: its toggle is drawn at the window's edge.
    var inspectorSliding = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !model.isNavigatorShown { NavigatorToolbar(model: model).frame(width: 290) }
                CenterToolbar(model: model, app: app)
                if !model.isInspectorShown && !inspectorSliding { InspectorToolbar(model: model).frame(width: 52) }
            }
            if model.isDebugAreaShown {
                VSplitView {
                    EditorArea(model: model)
                        .frame(minHeight: 120, maxHeight: .infinity)
                    DebugArea(model: model)
                        .frame(minHeight: 80, idealHeight: CGFloat(WorkspaceChrome.debugAreaHeight), maxHeight: 600)
                }
            } else {
                EditorArea(model: model)
            }
        }
    }
}

/// What editing asks in the window: a save that needs the user, closing a
/// file with unsaved changes, Jump to Line.
struct EditorPrompts: ViewModifier {
    @Bindable var model: WorkspaceShellModel

    func body(content: Content) -> some View {
        content
            .alert(model.saveAlert?.title ?? "", isPresented: Binding(get: { model.saveAlert != nil }, set: { if !$0 { model.saveAlert = nil } })) {
                if case .conflict? = model.saveAlert {
                    Button("Overwrite", role: .destructive) { model.overwriteOnConflict() }
                    Button("Cancel", role: .cancel) { model.saveAlert = nil }
                } else {
                    Button("OK") { model.saveAlert = nil }
                }
            } message: {
                Text(verbatim: model.saveAlert?.message ?? "")
            }
            .alert("Save changes to “\(model.document?.name ?? "")”?", isPresented: $model.closeDocumentPrompt) {
                Button("Save") {
                    if model.saveCurrent() { model.closeCurrentDocument() }
                }
                .keyboardShortcut(.defaultAction)
                Button("Don't Save", role: .destructive) { model.closeCurrentDocument(discard: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(verbatim: "Your changes will be lost if you don't save them.")
            }
            .sheet(isPresented: $model.isJumpToLineShown) { JumpToLineSheet(model: model) }
    }
}
