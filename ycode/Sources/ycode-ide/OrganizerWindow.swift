import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux) && canImport(OVDBus)
import OVDBus
#endif

/// The Organizer window (Window ▸ Organizer, `specs/ide/organizer.md`,
/// `reference-ui-3.md` §6), laid out as the macOS IDE's
/// `OrganizerController`: a toolbar row with back/forward, the page title
/// and the notifications bell; the sidebar with the app picker and the
/// Products, Insights, Reports and Metrics pages; on Archives the list
/// (Name, Creation Date, Version, Status, grouped under the application)
/// and the selection's details with Distribute App…; on the other pages
/// their empty state. The state is the core's `OrganizerState`
/// (`OrganizerShellModel`), so both IDEs list and describe an archive alike.
struct OrganizerWindowView: View {
    var model: OrganizerShellModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    /// The macOS IDE's Organizer: 900 × 552 under its 52-point toolbar
    /// (the sidebar's pages set the height).
    static let contentSize = CGSize(width: 900, height: 552)
    static let toolbarHeight: CGFloat = 52
    /// The window: the toolbar row and the content, plus, on Linux, the
    /// in-window menu bar.
    static var windowSize: CGSize {
        #if os(Linux)
        CGSize(width: contentSize.width, height: contentSize.height + toolbarHeight + ShellMetrics.menuBarHeight)
        #else
        CGSize(width: contentSize.width, height: contentSize.height + toolbarHeight)
        #endif
    }

    var body: some View {
        let c = ShellColors(scheme)
        let state = model.state
        VStack(spacing: 0) {
            OrganizerToolbar(model: model)
            Hairline(color: OrganizerColors(c).toolbarLine)
            HStack(alignment: .top, spacing: 0) {
                OrganizerSidebarView(model: model)
                    .frame(width: OrganizerMetrics.sidebarWidth)
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                if state.showsArchives {
                    OrganizerArchiveList(model: model)
                    OrganizerDetails(model: model)
                        .frame(width: OrganizerMetrics.detailsWidth)
                } else {
                    emptyState(state.emptyState, c)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(c.content)
        .frame(minWidth: Self.contentSize.width, minHeight: Self.contentSize.height + Self.toolbarHeight)
        .onAppear {
            let openURL = openURL
            model.revealInFiles = { url in DesktopFiles.reveal(url) { openURL($0) } }
            model.reload()
        }
        .shellTarget("organizer")
    }

    func emptyState(_ e: (title: String, message: String), _ c: ShellColors) -> some View {
        VStack(spacing: 6) {
            Text(verbatim: e.title).font(.system(size: 17, weight: .bold)).foregroundStyle(c.label)
                .shellTarget("organizer empty title")
            Text(verbatim: e.message).font(ShellFonts.row).foregroundStyle(c.secondaryLabel)
                .shellTarget("organizer empty message")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sizes from the macOS IDE's Organizer (its frames in `OrganizerController`).
enum OrganizerMetrics {
    static let sidebarWidth: CGFloat = 180
    static let detailsWidth: CGFloat = 250
    static let pickerHeight: CGFloat = 24
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 26
}

/// The Organizer's own colors (read from the macOS IDE's window): the
/// source-list sidebar, the app picker's fill, the list's stripes.
struct OrganizerColors {
    let c: ShellColors
    init(_ c: ShellColors) { self.c = c }

    private func gray(_ light: Double, _ dark: Double) -> Color {
        let v = (c.dark ? dark : light) / 255
        return Color(.sRGB, red: v, green: v, blue: v)
    }

    var sidebar: Color { gray(240, 40) }
    var picker: Color { gray(235, 48) }
    var stripe: Color { gray(244, 41) }
    var toolbarLine: Color { gray(229, 46) }
    var headingLine: Color { gray(216, 55) }
    var groupLine: Color { gray(227, 58) }
    var selection: Color { gray(220, 70) }
    var button: Color { gray(235, 48) }
}

// MARK: Toolbar

/// Back/forward, the page title, and the notifications bell with its
/// "No Notifications" popover.
struct OrganizerToolbar: View {
    var model: OrganizerShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let s = model.state
        HStack(spacing: 6) {
            GlassSegments(segments: [
                .init(symbol: "chevron.left", help: "Back", isEnabled: s.canGoBack, target: "organizer back") { model.goBack() },
                .init(symbol: "chevron.right", help: "Forward", isEnabled: s.canGoForward, target: "organizer forward") { model.goForward() },
            ], segmentWidth: 22, symbolSize: 12)
            Text(verbatim: s.page)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(c.label)
                .padding(.leading, 4)
                .shellTarget("organizer title")
            Spacer(minLength: 0)
            Button { model.toggleNotifications() } label: {
                Image(systemName: "bell")
                    .font(.system(size: 14))
                    .foregroundStyle(c.toolbarIcon)
                    .frame(width: 30, height: CGFloat(WorkspaceChrome.toolbarItemHeight))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Notifications")
            .accessibilityLabel("Notifications")
            .popover(isPresented: Binding(get: { model.state.notificationsShown }, set: { if !$0 { model.hideNotifications() } }),
                     arrowEdge: .bottom) {
                Text(verbatim: OrganizerState.noNotificationsText)
                    .font(ShellFonts.row)
                    .foregroundStyle(c.secondaryLabel)
                    .frame(width: 220, height: 80)
                    .shellTarget("organizer notifications")
            }
            .shellTarget("organizer bell")
        }
        .padding(.horizontal, 14)
        .frame(height: OrganizerWindowView.toolbarHeight)
    }
}

// MARK: Sidebar

/// The app picker and the source list of pages under their section
/// headings.
struct OrganizerSidebarView: View {
    var model: OrganizerShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let oc = OrganizerColors(c)
        let s = model.state
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                // The chosen application carries the check mark, as a pop-up button's item.
                ForEach(s.appPickerTitles, id: \.self) { app in
                    Toggle(app, isOn: Binding(get: { model.state.selectedApp == app }, set: { _ in model.chooseApp(app) }))
                }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: s.selectedApp ?? s.appPickerTitles[0]).font(ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(c.label)
                }
                .padding(.horizontal, 10)
                .frame(height: OrganizerMetrics.pickerHeight)
                .background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(oc.picker) }
            }
            .menuStyle(.borderlessButton)
            .disabled(s.groups.isEmpty)
            .shellTarget("organizer app picker")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(OrganizerSidebar.sections.enumerated()), id: \.offset) { pair in
                        section(pair.element, index: pair.offset, c, oc, s)
                    }
                }
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)
            .background(oc.sidebar)
        }
        .padding(.top, 9)
    }

    @ViewBuilder
    func section(_ sec: OrganizerSidebar.Section, index: Int, _ c: ShellColors, _ oc: OrganizerColors, _ s: OrganizerState) -> some View {
        // The macOS source list's spacing: a heading's text 17 points above
        // its first page's, 39 below the last page of the section before
        // (35 after Products, whose heading has a line under it).
        let first = index == 0
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: sec.title)
                .font(ShellFonts.smallBold).tracking(ShellFonts.smallTracking)
                .foregroundStyle(c.secondaryLabel)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, minHeight: 10, maxHeight: 10, alignment: .leading)
            if first {
                Hairline(color: oc.headingLine).padding(.top, 5)
                Spacer(minLength: 0).frame(height: 6)
            }
            ForEach(sec.pages, id: \.self) { page in
                let on = s.section == sec.title && s.page == page
                Button { model.showPage(page, section: sec.title) } label: {
                    Text(verbatim: page).font(ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, minHeight: OrganizerMetrics.rowHeight, alignment: .leading)
                        .background { if on { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(oc.selection) } }
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page)
                .shellTarget("organizer page \(sec.title) \(page)")
            }
        }
        .padding(.top, first ? 5 : (index == 1 ? 19 : 23))
    }
}

// MARK: Archive list

/// The archives of the chosen application: the column headers, the
/// application's heading row and one row per archive, newest first, with
/// stripes; a row's menu has Show in Files.
struct OrganizerArchiveList: View {
    var model: OrganizerShellModel
    @FocusState private var hasKeyboard: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let oc = OrganizerColors(c)
        let rows = model.state.rows
        GeometryReader { geo in
            let widths = Self.widths(for: geo.size.width - 20)
            VStack(alignment: .leading, spacing: 0) {
                header(widths, c, oc)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                            row(pair.offset, pair.element, widths, c, oc)
                        }
                    }
                }
                .focusable()
                .focused($hasKeyboard)
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
            }
        }
        .shellTarget("organizer list")
    }

    /// The columns' widths: the core's, scaled to the list's width.
    static func widths(for width: CGFloat) -> [CGFloat] {
        let total = OrganizerState.columns.reduce(0) { $0 + $1.width }
        return OrganizerState.columns.map { CGFloat($0.width / total) * max(width, 200) }
    }

    func header(_ widths: [CGFloat], _ c: ShellColors, _ oc: OrganizerColors) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(OrganizerState.columns.enumerated()), id: \.offset) { pair in
                    HStack(spacing: 0) {
                        if pair.offset > 0 { Rectangle().fill(oc.groupLine).frame(width: 1, height: 14) }
                        Text(verbatim: pair.element.title).font(ShellFonts.small).tracking(ShellFonts.smallTracking)
                            .foregroundStyle(c.secondaryLabel).lineLimit(1)
                            .padding(.leading, 8)
                        Spacer(minLength: 0)
                    }
                    .frame(width: widths[pair.offset])
                    .shellTarget("organizer column \(pair.element.id)")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: OrganizerMetrics.headerHeight)
            Hairline(color: oc.groupLine)
        }
    }

    @ViewBuilder
    func row(_ i: Int, _ r: OrganizerState.Row, _ widths: [CGFloat], _ c: ShellColors, _ oc: OrganizerColors) -> some View {
        if let a = r.archive {
            let selected = model.state.selectedRow == i
            HStack(spacing: 0) {
                ForEach(Array(OrganizerState.columns.enumerated()), id: \.offset) { pair in
                    Text(verbatim: OrganizerState.cellText(a, column: pair.element.id))
                        .font(ShellFonts.row)
                        .foregroundStyle(selected ? Color.white : c.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 8)
                        .frame(width: widths[pair.offset], alignment: .leading)
                }
            }
            .frame(height: OrganizerMetrics.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? c.accent : (i % 2 == 0 ? oc.stripe : Color.clear))
            }
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectRow(i)
                hasKeyboard = true
            }
            .contextMenu {
                Button(OrganizerState.showInFilesTitle) { model.showInFiles(row: i) }
            }
            .accessibilityLabel(a.name)
            .shellTarget("organizer row \(i)")
        } else {
            // The macOS table's group row: its title 16 points under the
            // header, a line 12 under that, then the first row.
            VStack(spacing: 0) {
                Text(verbatim: r.title).font(ShellFonts.smallBold).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                    .lineLimit(1)
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                    .padding(.top, 3)
                Hairline(color: oc.groupLine)
                Spacer(minLength: 0).frame(height: 1)
            }
            .shellTarget("organizer group \(r.title)")
        }
    }

    func step(_ d: Int) {
        let rows = model.state.rows
        let archives = rows.indices.filter { rows[$0].archive != nil }
        guard !archives.isEmpty else { return }
        let at = model.state.selectedRow.flatMap { archives.firstIndex(of: $0) } ?? (d > 0 ? -1 : archives.count)
        model.selectRow(archives[min(max(at + d, 0), archives.count - 1)])
    }
}

// MARK: Details

/// The selection's details (label over value) and Distribute App…, which
/// stays disabled until distribution comes to the Linux IDE.
struct OrganizerDetails: View {
    var model: OrganizerShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let oc = OrganizerColors(c)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.state.detailRows.enumerated()), id: \.offset) { pair in
                    Text(verbatim: pair.element.0).font(ShellFonts.smallBold).tracking(ShellFonts.smallTracking).foregroundStyle(c.label)
                    if !pair.element.1.isEmpty {
                        Text(verbatim: pair.element.1).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label)
                            .lineLimit(3)
                            .frame(maxWidth: 220, alignment: .leading)
                            .shellTarget("organizer detail \(pair.element.0)")
                    }
                }
            }
            Button {} label: {
                Text(verbatim: OrganizerState.distributeTitle).font(ShellFonts.row).foregroundStyle(c.label)
                    .opacity(model.canDistribute ? 1 : 0.35)
                    .padding(.horizontal, 12)
                    .frame(height: 23)
                    .background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(oc.button) }
            }
            .buttonStyle(.plain)
            .disabled(!model.canDistribute)
            .shellTarget("organizer distribute")
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Show in Files

/// The desktop's file manager: shows an item selected in its folder
/// (`org.freedesktop.FileManager1.ShowItems` on the session bus), else
/// opens the folder that holds it.
enum DesktopFiles {
    static let service = "org.freedesktop.FileManager1"

    /// Asks the file manager over the session bus (which starts it when
    /// needed); with no bus, or an error reply (no file manager offers the
    /// interface), opens the folder instead.
    @MainActor
    static func reveal(_ url: URL, fallback: @escaping (URL) -> Void) {
        let folder = url.deletingLastPathComponent()
        #if os(Linux) && canImport(OVDBus)
        guard let bus = try? DBusConnection.session(timeout: 1) else { return fallback(folder) }
        bus.startDispatch()
        let show = DBusMessage.methodCall(destination: service, path: "/org/freedesktop/FileManager1", interface: service,
                                          member: "ShowItems", body: [.strings([url.absoluteString]), .string("")])
        do {
            try bus.call(show) { reply in
                bus.close()
                if reply.type != .methodReturn { fallback(folder) }
            }
        } catch {
            bus.close()
            fallback(folder)
        }
        #else
        fallback(folder)
        #endif
    }
}
