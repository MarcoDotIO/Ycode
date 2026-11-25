import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell

// The center column's toolbar in a narrow window (P-025), the title area
// (P-029) and Run | Stop with Run's press-and-hold menu (P-028), as the
// AppKit IDE draws them (`ToolbarOverflow`, `ToolbarFit`, `RunButtonMenu`).

/// The center column's toolbar: Back | Forward, the activity view; New
/// Conversation, the scheme › destination capsule and the issue capsule;
/// Add Editor and Editor Options, then the editor modes. Short of room it
/// gives up what the AppKit toolbar does (`liquid-glass.md` §8.2,
/// `editor-area.md` G.4): the scheme capsule's titles (and the issue
/// capsule's counts), then the editor modes into the "»" menu, then the
/// activity subtitle truncates in the middle to the room left, then the
/// items leave for "»" in `ToolbarOverflow.leavingOrder` (the right group
/// first, the title area and Back | Forward last).
struct CenterToolbar: View {
    @Bindable var model: WorkspaceShellModel
    var app: ShellAppModel

    /// One way of fitting the row: a `ToolbarFit` step, whether the
    /// subtitle truncates to the room, and the items in "»".
    struct Stage {
        var fit: ToolbarFit
        var truncates = false
        var out: [ToolbarOverflow.Item] = []
    }

    /// The center band's items, by the order they leave (the AppKit
    /// toolbar's Navigators and Run | Stop are in the navigator's band).
    static let leaving: [ToolbarOverflow.Item] = ToolbarOverflow.leavingOrder.filter {
        ![.editorModes, .leftPanes, .run].contains($0)
    }

    /// Every stage, from nothing given up to the tightest.
    static let stages: [Stage] = {
        let modes = ToolbarFit(editorModesInOverflow: true, schemeGlyphsOnly: true)
        var out = [Stage(fit: ToolbarFit()), Stage(fit: ToolbarFit(schemeGlyphsOnly: true)), Stage(fit: modes), Stage(fit: modes, truncates: true)]
        for n in 1...leaving.count { out.append(Stage(fit: modes, truncates: true, out: Array(leaving.prefix(n)))) }
        return out
    }()

    /// The band's width: the content section (council round 12,
    /// `window-layout.md` §2.3).
    @State private var bandWidth: CGFloat = 0

    /// The first stage the content section allows: the items
    /// `ToolbarOverflow.forcedOut` puts in "»" for a band `width` wide are
    /// there however much room the row would leave (the AppKit toolbar
    /// sends them the same way).
    static func minimumStage(width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        let forced = ToolbarOverflow.forcedOut(content: Double(width))
        let rest = forced.filter { $0 != .editorModes }.count
        if rest > 0 { return min(stages.count - 1, 3 + rest) }
        return forced.isEmpty ? 0 : 2
    }

    var body: some View {
        let s = Self.stages
        let m = Self.minimumStage(width: bandWidth)
        let k = { (i: Int) in max(i, m) }
        // One candidate per stage (ViewThatFits takes the first that fits);
        // the stages the content section rules out stand for the first it allows.
        ViewThatFits(in: .horizontal) {
            row(s[k(0)], index: k(0))
            row(s[k(1)], index: k(1))
            row(s[k(2)], index: k(2))
            row(s[k(3)], index: k(3))
            row(s[k(4)], index: k(4))
            row(s[k(5)], index: k(5))
            row(s[k(6)], index: k(6))
            row(s[k(7)], index: k(7))
            row(s[k(8)], index: k(8))
            row(s[k(9)], index: k(9))
            row(s[k(10)], index: k(10))
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bandWidth = $0 }
        .frame(height: CGFloat(WorkspaceChrome.toolbarHeight))
    }

    /// `index` names the row's "»" for drivers ("tb overflow <n>": only
    /// the row ViewThatFits chose has a frame).
    func row(_ stage: Stage, index: Int) -> some View {
        let fit = stage.fit
        let out = Set(stage.out)
        let h = WorkspaceChrome.history, modes = WorkspaceChrome.editorModes
        // The issue capsule without issues is hidden, not in "»" (as AppKit's hidden item).
        let overflow = ToolbarOverflow.Item.allCases.filter {
            (out.contains($0) || ($0 == .editorModes && fit.editorModesInOverflow)) && !($0 == .issues && model.issueSummary.isEmpty)
        }
        return HStack(spacing: 0) {
            if !out.contains(.history) {
                GlassSegments(segments: [
                    .init(symbol: h.symbols[0], help: h.toolTips[0], isEnabled: model.canGoBack, target: "tb back") { model.perform(.goBack) },
                    .init(symbol: h.symbols[1], help: h.toolTips[1], isEnabled: model.canGoForward, target: "tb forward") { model.perform(.goForward) },
                ], segmentWidth: 26.5)   // 75 wide with its rim (parity §2)
            }
            if !out.contains(.activity) {
                ActivityView(model: model, truncates: stage.truncates)
                    // The mark at x 383.5 as on macOS (row 212); this capsule ends at
                    // 368.5, 2.5 before the macOS one, so the gap is 15 here.
                    .padding(.leading, out.contains(.history) ? 0 : 11)
            }
            Spacer(minLength: 8)
            if !out.contains(.newConversation) {
                NewConversationToolbarButton(assistant: model.assistant)   // AssistantPane.swift
            }
            if !out.contains(.scheme) {
                SchemeCapsule(model: model, app: app, glyphsOnly: fit.schemeGlyphsOnly)
                    .padding(.leading, 8)
            }
            if !out.contains(.issues) {
                IssueCapsule(summary: model.issueSummary, symbolsOnly: fit.schemeGlyphsOnly, underSheet: model.sourceControl.isMergeModalShown) {
                    model.showNavigator(.issues)
                }   // ToolbarChrome.swift
                .padding(.leading, model.issueSummary.isEmpty ? 0 : CGFloat(IssueSummary.Capsule.gapAfterScheme))
            }
            Spacer(minLength: 8)
            if !out.contains(.addEditor) || !out.contains(.editorOptions) {
                // ToolbarChrome.swift: Add Editor's pull-down and Editor Options, 81 wide
                AddEditorGroup(model: model, showsAdd: !out.contains(.addEditor), showsOptions: !out.contains(.editorOptions))
            }
            if !overflow.isEmpty {
                ToolbarOverflowMenu(model: model, app: app, items: overflow, target: "tb overflow \(index)")
                    .padding(.leading, CGFloat(WorkspaceChrome.overflowCapsuleGap))   // row 218
            }
            if !fit.editorModesInOverflow {
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
            // P-111, P-113: each half opens its chooser popover on mouse-down (PopoverOverlay.swift).
            ChooserCapsuleHalf(model: model, which: .scheme) {
                popUpTitle(schemeName, c) { SchemeGlyph(appIcon: SchemeCapsuleIcons.appIconURL(scheme: model.scheme, model: model.session.model)) }
            }
            .help(glyphsOnly ? schemeName : "")
            .shellTarget("tb scheme")
            Text(verbatim: "\u{203A}").font(ShellFonts.toolbarItem).foregroundStyle(c.tertiaryLabel)
                .padding(.horizontal, glyphsOnly ? 0 : 3)
            ChooserCapsuleHalf(model: model, which: .destination) {
                popUpTitle(destinationName, c) {
                    if model.destination?.kind == .simulator {
                        Image(systemName: "iphone").font(.system(size: 12)).foregroundStyle(c.label)
                    } else {
                        HostDestinationGlyph(fallbackColor: c.label)   // ToolbarChrome.swift (row 199)
                    }
                }
            }
            .help(glyphsOnly ? destinationName : "")
            .shellTarget("tb destination")
        }
        .padding(.horizontal, glyphsOnly ? 21.5 : 12)   // 89 wide with glyphs only, as the AppKit capsule
        .frame(height: CGFloat(WorkspaceChrome.toolbarItemHeight))
        .background { GlassCapsule(fill: c.capsuleFill) }
        .fixedSize()
    }

    func popUpTitle<Glyph: View>(_ title: String, _ c: ShellColors, @ViewBuilder glyph: () -> Glyph) -> some View {
        HStack(spacing: 5) {
            glyph()
            if !glyphsOnly {
                Text(verbatim: title).font(ShellFonts.toolbarItem).foregroundStyle(c.label).lineLimit(1)
            }
        }
        .fixedSize()
    }
}

/// The workspace's glyph, then two lines: the name and the activity
/// (`reference-ui-6.md` §3.1); idle, only the name, centered. In an
/// inactive window both lines take the same dimmed grey, as the AppKit
/// view (`liquid-glass.md` §7.1 item 3; L-016). With `truncates` the view
/// takes the room the row leaves it, down to `ToolbarFit.activityMinimum`,
/// and the subtitle truncates in the middle to it (P-029, N02).
struct ActivityView: View {
    var model: WorkspaceShellModel
    var truncates = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let c = ShellColors(scheme)
        let active = appearsActive
        let content = HStack(spacing: 8) {
            // Ycode's mark in a 19.5-point box, centred on the title's line,
            // the title 8 after it; the build ring while busy (row 212; BuildRing.swift).
            TitleMark(isBusy: model.isBusy, isPaused: model.isActivityPaused, activity: model.activityText)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: model.workspaceName).font(ShellFonts.activityName).foregroundStyle(active ? c.label : c.tertiaryLabel).lineLimit(1)
                if !model.activityText.isEmpty {
                    Text(verbatim: model.activityText)
                        .font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(active ? c.secondaryLabel : c.tertiaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)   // as the AppKit view (reference-ui-6.md §3.1.3)
                        .shellTarget("activity")
                }
            }
        }
        .frame(height: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.workspaceName)
        .shellTarget("title area")
        if truncates {
            content.frame(minWidth: CGFloat(ToolbarFit.activityMinimum), idealWidth: CGFloat(ToolbarFit.activityMinimum), alignment: .leading)
        } else {
            content
        }
    }
}

// MARK: The "»" menu (P-025)

/// The toolbar's overflow control (G.4): a glass circle with "»" whose
/// menu holds the items that left the toolbar, in toolbar order, each with
/// its glyph and, for an item with a menu or segments, a sub-menu
/// (`ToolbarOverflow.entry`), as the AppKit toolbar's menu.
struct ToolbarOverflowMenu: View {
    var model: WorkspaceShellModel
    var app: ShellAppModel
    var items: [ToolbarOverflow.Item]
    /// The driver's name for it (one per toolbar row).
    var target = "tb overflow"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Menu {
            ForEach(items, id: \.self) { OverflowEntry(model: model, item: $0) }
        } label: {
            Text(verbatim: "\u{00BB}").font(.system(size: 17)).foregroundStyle(c.toolbarIcon)
                .frame(width: CGFloat(WorkspaceChrome.toolbarItemHeight), height: CGFloat(WorkspaceChrome.toolbarItemHeight))
                .background { Circle().fill(c.capsuleFill) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show more toolbar items")
        .shellTarget(target)
    }
}

/// One entry of the "»" menu.
struct OverflowEntry: View {
    var model: WorkspaceShellModel
    var item: ToolbarOverflow.Item
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let e = ToolbarOverflow.entry(item)
        let segments = ToolbarOverflow.segments(item)
        switch item {
        case .leftPanes:
            Menu {
                row(segments[0], on: model.isNavigatorShown && !model.assistant.isShown) { model.showLeftPane(assistant: false) }
                row(segments[1], on: model.isAssistantPaneShown) { model.showLeftPane(assistant: true) }
            } label: { Label(e.title, systemImage: e.symbol) }
        case .run:
            Menu {
                RunHoldMenuItems(model: model)
                Divider()
                Button { model.perform(.stop) } label: { Label("Stop", systemImage: WorkspaceChrome.runStop.symbols[1]) }
                    .disabled(!model.isEnabled(.stop))
            } label: { Label(e.title, systemImage: e.symbol) }
        case .history:
            Menu {
                row(segments[0]) { model.perform(.goBack) }.disabled(!model.canGoBack)
                row(segments[1]) { model.perform(.goForward) }.disabled(!model.canGoForward)
            } label: { Label(e.title, systemImage: e.symbol) }
        case .activity:
            Button {} label: {
                HStack(spacing: 6) {
                    YcodeSmallMark(size: 16)
                    Text(verbatim: e.title)
                }
            }
            .disabled(true)
        case .newConversation:
            Button { model.perform(.newConversation) } label: { Label(e.title, systemImage: e.symbol) }
                .disabled(!model.isEnabled(.newConversation))
        case .scheme:
            // No glyph, as the reference's Scheme and Destination entries.
            Menu(e.title) { OverflowSchemeItems(model: model) }
        case .issues:
            // The outlined warning triangle (`window-layout.md` §2.4); a row per kind with its count.
            let parts = model.issueSummary.parts
            Menu {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Button { model.showNavigator(.issues) } label: { Label(ToolbarOverflow.issueRow(p.kind, count: p.count), systemImage: p.kind.symbol) }
                }
            } label: { Label(e.title, systemImage: e.symbol) }
        case .addEditor:
            Menu { AddEditorMenuItems(model: model) } label: { Label(e.title, systemImage: e.symbol) }   // EditorOptionsMenu.swift
        case .editorOptions:
            Menu {
                EditorOptionsMenuItems(model: model, revision: ShellPreferences.shared.revision)   // EditorOptionsMenu.swift
            } label: { Label(e.title, systemImage: e.symbol) }
        case .editorModes:
            Menu {
                row(segments[0], on: model.previewCanvas.isModeOn) { model.perform(.toggleCanvas) }.disabled(!model.isEnabled(.toggleCanvas))
                row(segments[1]) {}.disabled(true)
                row(segments[2]) {}.disabled(true)
            } label: { Label(e.title, systemImage: e.symbol) }
        case .inspectorToggle:
            EmptyView()
        }
    }

    /// A segment's row: its glyph and title, checked when `on`.
    func row(_ s: (title: String, symbol: String), on: Bool = false, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { _ in action() })) { Label(s.title, systemImage: s.symbol) }
    }
}

/// The scheme entry's rows: the schemes (the current one checked), then
/// the run destinations under their heading, as the AppKit menu.
struct OverflowSchemeItems: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ForEach(model.schemes, id: \.self) { s in
            Toggle(s, isOn: Binding(get: { model.scheme == s }, set: { if $0 { model.scheme = s } }))
        }
        let all = model.session.model.destinationGroups.flatMap(\.destinations)
        if !all.isEmpty {
            Divider()
            Text(verbatim: ToolbarOverflow.destinationsHeading).font(.system(size: 11, weight: .semibold)).foregroundStyle(ShellColors(scheme).secondaryLabel)
                .padding(.horizontal, 12).padding(.top, 2)
            ForEach(Array(all.enumerated()), id: \.offset) { _, d in
                Toggle(d.name, isOn: Binding(get: { model.destination == d }, set: { if $0 { model.destination = d } }))
            }
        }
    }
}

// MARK: Run | Stop (P-028, P-204)

/// Run | Stop in one capsule (75 wide with its rim, as the AppKit
/// toolbar's). A click on Run runs; holding the mouse on it shows Run's
/// menu (`RunButtonMenu`: Run, Test, Profile, Analyze). Run stays enabled
/// while an action runs (L-017; a new run replaces it, as on macOS); Stop
/// is enabled exactly while an action runs, and says so to accessibility
/// clients (P-204).
struct RunStopCapsule: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme
    /// Run is under the pointer: the divider between Run and Stop hides
    /// (`control-states.md`, the Run row).
    @State private var runHovered = false

    static let segmentWidth: CGFloat = 26.5

    var body: some View {
        let c = ShellColors(scheme)
        let rs = WorkspaceChrome.runStop
        let w = Self.segmentWidth + 6, h = CGFloat(WorkspaceChrome.toolbarItemHeight)
        let stopEnabled = model.isEnabled(.stop)
        HStack(spacing: 0) {
            Menu {
                RunHoldMenuItems(model: model)
            } label: {
                Image(systemName: rs.symbols[0]).font(.system(size: 15)).foregroundStyle(c.toolbarIcon)
                    .frame(width: w, height: h)
                    .contentShape(Rectangle())
            } primaryAction: {
                model.perform(.run)
            }
            // P-198: Run draws as the other toolbar glass controls (hover
            // bezel, held fill and grow), through the menu's button.
            .menuStyle(.button)
            .buttonStyle(ToolbarGlassStyle(kind: .toolbarSegment, bezelWidth: w - 2))
            .fixedSize()
            .onHover { h in if runHovered != h { runHovered = h } }
            .help(rs.toolTips[0])
            .accessibilityLabel("Run")
            .shellTarget("tb run")
            Rectangle().fill(c.capsuleStroke).frame(width: 1, height: 18)
                .opacity(runHovered ? 0 : 1)
                .shellTarget("tb run stop divider")
            Button { model.perform(.stop) } label: {
                Image(systemName: rs.symbols[1]).font(.system(size: 15))
                    .foregroundStyle(ControlStates.toolbarGlyph(enabled: stopEnabled, normal: c.toolbarIcon, scheme))
                    .frame(width: w, height: h)
                    .contentShape(Rectangle())
            }
            // P-198: hover, held tint and grow; disabled, the table's grey once
            // and a press moves the window (ControlStateViews.swift).
            .buttonStyle(ToolbarGlassStyle(kind: .toolbarSegment, bezelWidth: w - 2))
            .disabled(!stopEnabled)
            .help(rs.toolTips[1])
            .accessibilityLabel("Stop")
            .shellTarget("tb stop")
        }
        .padding(.horizontal, 4)
        .background { GlassCapsule(fill: c.capsuleFill) }
    }
}

/// Run's menu rows (`RunButtonMenu`): each with its glyph and the Product
/// menu's key equivalent. The Linux IDE has no profiler or analyzer
/// action, so Profile and Analyze are shown disabled, as in its Product
/// menu (P-013).
struct RunHoldMenuItems: View {
    var model: WorkspaceShellModel

    /// The shell command of a row (nil: no such action on Linux).
    static func command(_ row: RunButtonMenu.Row) -> ShellCommand? {
        switch row.selector {
        case "runProduct:": .run
        case "testProduct:": .test
        default: nil
        }
    }

    var body: some View {
        ForEach(RunButtonMenu.rows, id: \.title) { r in
            let c = Self.command(r)
            Button { if let c { model.perform(c) } } label: { Label(r.title, systemImage: r.symbol) }
                .disabled(c.map { $0 == .run ? false : !model.isEnabled($0) } ?? true)
                .shellTarget("run menu \(r.title.lowercased())")
        }
    }
}
