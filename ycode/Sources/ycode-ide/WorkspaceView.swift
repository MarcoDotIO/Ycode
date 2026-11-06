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

    var body: some View {
        let c = ShellColors(scheme)
        HSplitView {
            if model.isNavigatorShown {
                NavigatorColumn(model: model)
                    .frame(minWidth: 180, idealWidth: CGFloat(WorkspaceChrome.navigatorWidth), maxWidth: 500)
                    .background(c.sidebar)
            }
            CenterColumn(model: model, app: app)
                .frame(minWidth: 300, maxWidth: .infinity)
                .background(c.content)
            if model.isInspectorShown {
                InspectorColumn(model: model)
                    .frame(minWidth: 220, idealWidth: CGFloat(WorkspaceChrome.inspectorWidth), maxWidth: 400)
                    .background(c.sidebar)
            }
        }
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
            ], segmentWidth: 36, dividers: false)
            Spacer(minLength: 8)
            GlassSegments(segments: [
                .init(symbol: rs.symbols[0], help: rs.toolTips[0], isEnabled: model.isEnabled(.run), target: "tb run") { model.perform(.run) },
                .init(symbol: rs.symbols[1], help: rs.toolTips[1], isEnabled: model.isEnabled(.stop), target: "tb stop") { model.perform(.stop) },
            ], segmentWidth: 34)
        }
        // The AppKit window keeps its first 96 points for the window's
        // buttons; the shell keeps the same room so the items line up.
        .padding(.leading, 96)
        .padding(.trailing, 8.5)
        .frame(height: CGFloat(WorkspaceChrome.toolbarHeight) - 1)
    }
}

/// The center column's toolbar: Back | Forward, the activity view; New
/// Conversation and the scheme › destination capsule (with the issue
/// counts); Add Editor and Editor Options, then the editor modes.
struct CenterToolbar: View {
    @Bindable var model: WorkspaceShellModel
    var app: ShellAppModel
    var body: some View {
        let h = WorkspaceChrome.history, modes = WorkspaceChrome.editorModes
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GlassSegments(segments: [
                    .init(symbol: h.symbols[0], help: h.toolTips[0], isEnabled: model.canGoBack, target: "tb back") { model.perform(.goBack) },
                    .init(symbol: h.symbols[1], help: h.toolTips[1], isEnabled: model.canGoForward, target: "tb forward") { model.perform(.goForward) },
                ], segmentWidth: 34)
                ActivityView(model: model)
                    .padding(.leading, 4)
                Spacer(minLength: 8)
                NewConversationToolbarButton(assistant: model.assistant)   // AssistantPane.swift
                SchemeCapsule(model: model, app: app)
                    .padding(.leading, 8)
                Spacer(minLength: 8)
                GlassSegments(segments: [
                    .init(symbol: WorkspaceChrome.addEditor.symbols[0], help: ShellText.notInBeta(WorkspaceChrome.addEditor.toolTips[0]), isEnabled: false, target: "tb add editor") {},
                    .init(symbol: WorkspaceChrome.editorOptions.symbols[0], help: ShellText.notInBeta(WorkspaceChrome.editorOptions.toolTips[0]), isEnabled: false, target: "tb editor options") {},
                ], segmentWidth: 34, dividers: false)
                GlassSegments(segments: [
                    .init(symbol: modes.symbols[0], help: modes.toolTips[0], isOn: model.previewCanvas.isModeOn, isEnabled: model.isEnabled(.toggleCanvas),
                          target: "tb canvas") { model.perform(.toggleCanvas) },
                    .init(symbol: modes.symbols[1], help: ShellText.notInBeta(modes.toolTips[1]), isEnabled: false, target: "tb assistant editor") {},
                    .init(symbol: modes.symbols[2], help: ShellText.notInBeta(modes.toolTips[2]), isEnabled: false, target: "tb code review") {},
                ], segmentWidth: 34)
                .padding(.leading, 8)
            }
            .padding(.leading, 7.5)
            .padding(.trailing, 8)
            .frame(height: CGFloat(WorkspaceChrome.toolbarHeight))
        }
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
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: model.workspaceName).font(ShellFonts.activityName).foregroundStyle(c.label).lineLimit(1)
                if !model.activityText.isEmpty {
                    Text(verbatim: model.activityText)
                        .font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel).lineLimit(1)
                        .shellTarget("activity")
                }
            }
        }
        .frame(height: 34)
    }
}

/// Scheme › destination as two pop-ups in one capsule, and the issue
/// counts in it when there are any (`liquid-glass.md` §2.2).
struct SchemeCapsule: View {
    @Bindable var model: WorkspaceShellModel
    var app: ShellAppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let counts = model.issueCounts
        HStack(spacing: 4) {
            Menu {
                ForEach(model.schemes, id: \.self) { s in Button(s) { model.scheme = s } }
            } label: {
                popUpTitle(model.scheme ?? "No Scheme", symbol: nil, c)
            }
            .menuStyle(.borderlessButton)
            .shellTarget("tb scheme")
            Text(verbatim: "\u{203A}").font(ShellFonts.toolbarTitle).foregroundStyle(c.tertiaryLabel)
            Menu {
                DestinationMenuItems(model: model, groups: model.session.model.destinationGroups, secondary: c.secondaryLabel)
                if model.containerKind != .package, !model.destinations.contains(where: { ShellRemoteRun.target(of: $0) != nil }) {
                    Divider()
                    Button("Ycode Simulator (\(ExperimentalNotice.label))…") { app.explainSimulator() }
                }
            } label: {
                popUpTitle(model.destination?.name ?? "No Destination", symbol: model.destination?.kind == .simulator ? "iphone" : "desktopcomputer", c)
            }
            .menuStyle(.borderlessButton)
            .shellTarget("tb destination")
            if counts.errors > 0 || counts.warnings > 0 {
                Button { model.perform(.showIssueNavigator) } label: {
                    HStack(spacing: 6) {
                        if counts.errors > 0 { count("xmark.circle.fill", c.error, counts.errors, c) }
                        if counts.warnings > 0 { count("exclamationmark.triangle.fill", c.warning, counts.warnings, c) }
                    }
                    .padding(.leading, 12)
                }
                .buttonStyle(.plain)
                .help("Show the Issue navigator")
                .shellTarget("tb issues")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: CGFloat(WorkspaceChrome.toolbarItemHeight))
        .background { GlassCapsule() }
    }

    func popUpTitle(_ title: String, symbol: String?, _ c: ShellColors) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(c.label) }
            Text(verbatim: title).font(ShellFonts.toolbarTitle).foregroundStyle(c.label).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(c.label)
        }
        .fixedSize()
    }

    func count(_ symbol: String, _ color: Color, _ n: Int, _ c: ShellColors) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
            Text(verbatim: "\(n)").font(ShellFonts.toolbarTitle).foregroundStyle(c.label)
        }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !model.isNavigatorShown { NavigatorToolbar(model: model).frame(width: 290) }
                CenterToolbar(model: model, app: app)
                if !model.isInspectorShown { InspectorToolbar(model: model).frame(width: 52) }
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
