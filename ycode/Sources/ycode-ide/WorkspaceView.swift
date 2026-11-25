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
    /// The panes' show/hide slides (InspectorSlide.swift; P-190–P-192).
    @State private var inspectorSlide = PaneSlideState(.inspector)
    @State private var navigatorSlide = PaneSlideState(.navigator)
    @State private var debugSlide = PaneSlideState(.debugArea)
    /// The window's last width (P-024: a narrowing that would put the editor
    /// under 300 points collapses the navigator).
    @State private var lastWidth: Double?

    var body: some View {
        let c = ShellColors(scheme)
        let sliding = inspectorSlide.isSliding(modelShows: model.isInspectorShown)
        let navSliding = navigatorSlide.isSliding(modelShows: model.isNavigatorShown)
        HSplitView {
            if model.isNavigatorShown || navSliding {
                NavigatorSlidePane(progress: navigatorSlide.progress, isRunning: navSliding) {
                    NavigatorColumn(model: model)
                        .environment(\.navigatorToolbarDetached, navSliding)
                }
                .background(c.navigatorBackground)
                .shellTarget("navigator column")
            }
            CenterColumn(model: model, app: app, inspectorSliding: sliding, navigatorSliding: navSliding, debugSlide: debugSlide)
                .frame(minWidth: CGFloat(NarrowWindowLayout.editorMinimum), maxWidth: .infinity)
                .background(c.content)
            if model.isInspectorShown || sliding {
                InspectorSlidePane(progress: inspectorSlide.progress, isRunning: sliding) {
                    InspectorColumn(model: model, showsToolbar: !sliding)
                }
                .background(c.sidebar)
            }
        }
        // The window's minimum (P-024, `window-layout.md` §4.1): ≈ 503 with
        // the inspector shown, the toolbar's 410 with it hidden.
        .frame(minWidth: CGFloat(NarrowWindowLayout.minimumWindowWidth(inspectorShown: model.isInspectorShown)))
        // While the inspector slides its toggle stays at the window's edge.
        .overlay(alignment: .topTrailing) {
            if sliding { InspectorToolbar(model: model).frame(width: 52) }
        }
        // While the navigator slides the toolbar is one band in its
        // navigator-hidden arrangement, pinned to the window (P-190, §6.1).
        .overlay(alignment: .topLeading) {
            if navSliding {
                HStack(spacing: 0) {
                    NavigatorToolbar(model: model, compact: true).frame(width: NavigatorToolbar.compactWidth)
                    CenterToolbar(model: model, app: app)
                    if !model.isInspectorShown && !sliding { InspectorToolbar(model: model).frame(width: 52) }
                }
                .frame(width: max(0, CGFloat(lastWidth ?? 0) - (model.isInspectorShown || sliding ? CGFloat(WorkspaceChrome.inspectorWidth) + 1 : 0)),
                       alignment: .leading)
                .environment(\.navigatorToolbarDetached, false)
            }
        }
        .onAppear {
            inspectorSlide.sync(model.isInspectorShown)
            navigatorSlide.sync(model.isNavigatorShown)
            debugSlide.sync(model.isDebugAreaShown)
        }
        .onChange(of: model.isInspectorShown) { _, shown in inspectorSlide.run(show: shown, bySelector: PaneMotion.takeInspectorSelector()) }
        .onChange(of: model.isNavigatorShown) { _, shown in navigatorSlide.run(show: shown, trigger: PaneMotion.takeNavigatorTrigger()) }
        .onChange(of: model.isDebugAreaShown) { _, shown in debugSlide.run(show: shown) }
        // Narrowing the window collapses the navigator, with its slide, once
        // the editor would go below 300 points beside it (P-024,
        // `window-layout.md` §4.2; it never shrinks first); it stays hidden.
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width in
            defer { lastWidth = width }
            guard let last = lastWidth, width < last, model.isNavigatorShown, !navSliding,
                  NarrowWindowLayout.liveResizeHidesNavigator(width: width, navigator: WorkspaceChrome.navigatorWidth,
                                                              inspector: model.isInspectorShown ? WorkspaceChrome.inspectorWidth : nil)
            else { return }
            model.isNavigatorShown = false
        }
        // Under the merge alert and sheet the window draws disabled (§13.1).
        .opacity(model.sourceControl.isMergeModalShown ? MergeModalTone.text : 1)
        .background(Color(mergeHex: MergeModalTone.backdrop(dark: c.dark)))   // MergeOverlay.swift: what the dimmed window shows through
        .animation(.easeOut(duration: MergeSheetMotion.veilIn), value: model.sourceControl.isMergeModalShown)
        .overlay { BuildBezelOverlay(notifier: model.notifier) }
        .overlay { BreakpointEditorLayer(model: model) }   // DebugEditors.swift
        .overlay { MergeOverlayLayer(scm: model.sourceControl, app: app) }   // MergeOverlay.swift: the merge alert and sheet
        .overlay(alignment: .top) { OpenQuicklyLayer(model: model) }   // OpenQuicklyPanel.swift (row 215)
        .modifier(WorkspacePopovers(model: model, app: app))   // PopoverOverlay.swift: choosers, capsules, New Scheme (beta 5)
        .navigationTitle(model.windowTitle)
        .modifier(EditorPrompts(model: model))
        .modifier(LanguageSheets(model: model, app: app))
        .modifier(SourceControlDialogs(scm: model.sourceControl))
        .modifier(AssistantPrompts(assistant: model.assistant))
    }
}

// MARK: - Toolbar bands

/// The navigator column's toolbar: Navigators | Coding Assistant, then
/// Run | Stop at the column's end (`liquid-glass.md` §2.2). With the
/// navigator hidden (`compact`, P-190, `window-layout.md` §5.1) the group
/// stays at x 96 and Run | Stop follows it 9 points later; the band ends
/// there and Back | Forward comes next. While the navigator slides the
/// column's own band is empty (`navigatorToolbarDetached`): the window
/// draws the compact band at its leading edge, so the items switch at the
/// start of a hide and the end of a show and never travel with the pane.
struct NavigatorToolbar: View {
    var model: WorkspaceShellModel
    var compact = false
    @Environment(\.navigatorToolbarDetached) private var detached

    /// The compact band's width: 96 + 78 (the group) + 9 + 75 (Run | Stop).
    static let compactWidth: CGFloat = 258

    var body: some View {
        let lp = WorkspaceChrome.leftPanes
        if detached && !compact {
            Color.clear.frame(height: CGFloat(WorkspaceChrome.toolbarHeight) - 1)
        } else {
            HStack(spacing: 0) {
                // Navigators | Coding Assistant: clicking the shown one hides the area.
                let navigatorsOn = model.isNavigatorShown && !model.assistant.isShown && !compact
                let assistantOn = model.isAssistantPaneShown && !compact
                GlassSegments(segments: [
                    .init(symbol: lp.symbols[0], help: navigatorsOn ? "Hide the Navigator" : "Show the Navigator", isOn: navigatorsOn,
                          target: "tb navigator") {
                        PaneMotion.noteNavigatorClick()
                        model.showLeftPane(assistant: false)
                    },
                    .init(symbol: lp.symbols[1], help: lp.toolTips[1], isOn: assistantOn, target: "tb assistant") {
                        PaneMotion.noteNavigatorClick()
                        model.showLeftPane(assistant: true)
                    },
                ], segmentWidth: 29, dividers: compact)   // 78 wide with its rim, as the AppKit toolbar (parity §2); a hairline between the halves when hidden (§5.1)
                if compact {
                    RunStopCapsule(model: model).padding(.leading, 9)
                } else {
                    Spacer(minLength: 8)
                    RunStopCapsule(model: model)   // ToolbarChrome.swift: Run's press-and-hold menu (P-028), 75 wide
                }
            }
            // The AppKit window keeps its first 96 points for the window's
            // buttons; the shell keeps the same room so the items line up.
            .padding(.leading, 96)
            .padding(.trailing, compact ? 0 : 8.5)
            .frame(height: CGFloat(WorkspaceChrome.toolbarHeight) - 1)
        }
    }
}

/// While the navigator slides its column draws no toolbar items.
struct NavigatorToolbarDetachedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var navigatorToolbarDetached: Bool {
        get { self[NavigatorToolbarDetachedKey.self] }
        set { self[NavigatorToolbarDetachedKey.self] = newValue }
    }
}

// The center column's toolbar (`CenterToolbar`) and the title area (`ActivityView`): ToolbarChrome.swift.

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
    /// The navigator slides: the window draws the toolbar band meanwhile.
    var navigatorSliding = false
    /// The debug area's slide (P-191).
    var debugSlide: PaneSlideState?

    var body: some View {
        let debugSliding = debugSlide?.isSliding(modelShows: model.isDebugAreaShown) ?? false
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if navigatorSliding {
                    // The window draws the band while the navigator slides.
                    Color.clear.frame(height: CGFloat(WorkspaceChrome.toolbarHeight))
                } else {
                    if !model.isNavigatorShown { NavigatorToolbar(model: model, compact: true).frame(width: NavigatorToolbar.compactWidth) }
                    CenterToolbar(model: model, app: app)
                    if !model.isInspectorShown && !inspectorSliding { InspectorToolbar(model: model).frame(width: 52) }
                }
            }
            if model.isDebugAreaShown || debugSliding {
                VSplitView {
                    EditorArea(model: model)
                        .frame(minHeight: 120, maxHeight: .infinity)
                    DebugSlidePane(progress: debugSlide?.progress ?? 1, isRunning: debugSliding) {
                        DebugArea(model: model)
                    }
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
            .sheet(isPresented: Binding(get: { model.recommendedSettings.isShown }, set: { if !$0 { model.recommendedSettings.cancel() } })) {
                RecommendedSettingsSheet(model: model)   // RecommendedSettingsSheet.swift (P-120)
            }
    }
}
