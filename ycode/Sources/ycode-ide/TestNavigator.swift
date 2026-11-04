import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell

/// The Test navigator (⌘6; `specs/ide/testing.md`, `reference-ui-6.md`
/// §5.4): the package or project, its test targets, suites and tests, each
/// with its result diamond. Selecting a test opens its line; the run
/// button that appears on the selected row (and its context menu) runs
/// that test, suite, target or everything.
struct TestNavigator: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = model.testing
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Test Plan").font(ShellFonts.mini.weight(.semibold)).foregroundStyle(c.secondaryLabel)
                Text(verbatim: model.scheme ?? model.workspaceName).font(ShellFonts.mini.weight(.semibold)).foregroundStyle(c.label)
                Spacer()
                if t.running != nil {
                    ProgressView().controlSize(.small)
                }
                Button { model.perform(.test) } label: {
                    Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(model.isEnabled(.test) ? c.secondaryLabel : c.tertiaryLabel)
                }
                .buttonStyle(.plain)
                .disabled(!model.isEnabled(.test))
                .help("Run all tests (Product ▸ Test)")
                .shellTarget("tests run all")
            }
            .padding(.horizontal, 12)
            .frame(height: 22)
            .padding(.top, 4)
            if !t.hasDiscovered {
                EmptyNavigator(lines: ["Tests", "Looking for tests…"])
            } else if t.tests.isEmpty {
                EmptyNavigator(lines: NavigatorBars.specs[5].emptyState)
                    .shellTarget("tests empty")
            } else {
                TestOutline(model: model)
            }
        }
        .task { t.discover() }
        .shellTarget("test navigator")
    }
}

/// The Test navigator's outline: rows with diamonds; the selected row
/// shows a run button before its diamond.
struct TestOutline: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = model.testing
        let c = ShellColors(scheme)
        let rows = t.rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in
                    OutlineRowView(row: r, isSelected: r.id == t.selection, colors: c, toggle: { t.setExpanded($0, $1) })
                        .overlay(alignment: .trailing) {
                            if r.id == t.selection || t.isRunning(r.id) {
                                runButton(r, c)
                                    .padding(.trailing, 32)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { select(r) }
                        .contextMenu {
                            Button("Run \u{201C}\(r.title)\u{201D}") { model.runTests(forRow: r.id) }.disabled(model.isBusy)
                            if let loc = t.location(ofRow: r.id) {
                                Button("Jump to Definition") { model.open(loc.file, line: loc.line) }
                            }
                        }
                        .shellTarget("test row \(r.title)")
                }
            }
            .padding(.top, CGFloat(WorkspaceChrome.firstRowGap))
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .shellTarget("test outline")
    }

    func select(_ r: OutlineRow) {
        let t = model.testing
        t.select(r.id)
        if let loc = t.location(ofRow: r.id) { model.open(loc.file, line: loc.line) }
    }

    @ViewBuilder
    func runButton(_ r: OutlineRow, _ c: ShellColors) -> some View {
        if model.testing.isRunning(r.id) {
            ProgressView().controlSize(.mini)
        } else {
            Button { model.runTests(forRow: r.id) } label: {
                Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(c.label)
                    .frame(width: 18, height: 18)
                    .background { Circle().fill(c.popUpFill) }
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .help("Run \(r.title)")
            .shellTarget("test run \(r.title)")
        }
    }
}

// MARK: - Reports

/// The Report navigator (⌘9): the scheme's builds and test runs, newest
/// first, a test run's Tests and Log pages under it.
struct ReportNavigator: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = model.testing
        let c = ShellColors(scheme)
        let rows = t.reportRows
        if rows.isEmpty {
            EmptyNavigator(lines: NavigatorBars.specs[8].emptyState)
                .shellTarget("reports empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { r in
                        OutlineRowView(row: r, isSelected: r.id == t.reportSelection, colors: c, toggle: { t.setReportExpanded($0, $1) })
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if r.id.hasPrefix("group:") { t.setReportExpanded(r.id, !r.isExpanded) } else { t.selectReport(r.id) }
                            }
                            .shellTarget("report row \(r.title)")
                    }
                }
                .padding(.top, CGFloat(WorkspaceChrome.firstRowGap))
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .shellTarget("report navigator")
        }
    }
}

/// A report over the editor area: a test run's Tests page (each test with
/// its result, time and failures) or a run's log.
struct ReportPaneView: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let t = model.testing
        VStack(spacing: 0) {
            if let r = t.report, let shown = t.shownReport {
                HStack(spacing: 4) {
                    Image(systemName: r.kind == .test ? "checkmark.diamond" : "hammer").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                    Text(verbatim: r.schemeName).font(ShellFonts.small.weight(.medium)).foregroundStyle(c.label)
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(c.tertiaryLabel)
                    Text(verbatim: r.title).font(ShellFonts.small.weight(.medium)).foregroundStyle(c.label)
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(c.tertiaryLabel)
                    Text(verbatim: shown.page).font(ShellFonts.small.weight(.medium)).foregroundStyle(c.label)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: CGFloat(WorkspaceChrome.jumpBarBandHeight))
                .overlay(alignment: .top) { Hairline(color: c.separator) }
                Hairline(color: c.separator)
                Group {
                    if shown.page == "Tests" {
                        TestReportView(report: r, model: model, colors: c)
                    } else {
                        ReportLogView(lines: r.log, colors: c)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(c.content)
            } else {
                Text("No Report").font(Font.system(size: 15)).foregroundStyle(c.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            DebugBar(model: model)
        }
        .shellTarget("editor")
    }
}

/// A test run's Tests page: the result, the counts, then each test.
struct TestReportView: View {
    var report: BuildReport
    var model: WorkspaceShellModel
    var colors: ShellColors

    var body: some View {
        let c = colors
        let outcomes = TestShellModel.reportTests(report)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                let d = TestShellModel.diamond(report.succeeded ? .passed : .failed)
                Image(systemName: d.symbol).font(.system(size: 22)).foregroundStyle(c.tint(d.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: report.succeeded ? "Test Succeeded" : "Test Failed").font(Font.system(size: 15, weight: .semibold)).foregroundStyle(c.label)
                    Text(verbatim: "\(TestShellModel.summary(report)) • \(ReportFormat.dayAndTime(report.date))").font(ShellFonts.small)
                        .foregroundStyle(c.secondaryLabel)
                }
                Spacer()
            }
            .padding(16)
            Hairline(color: c.separator)
            HStack(spacing: 0) {
                Text("Test").frame(maxWidth: .infinity, alignment: .leading)
                Text("Suite").frame(width: 200, alignment: .leading)
                Text("Duration").frame(width: 80, alignment: .trailing)
            }
            .font(ShellFonts.small.weight(.semibold)).foregroundStyle(c.secondaryLabel)
            .padding(.horizontal, 16).frame(height: 24)
            Hairline(color: c.separator)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(outcomes.enumerated()), id: \.offset) { pair in
                        row(pair.element, c)
                        Hairline(color: c.separator).padding(.leading, 16)
                    }
                }
            }
            .shellTarget("test report")
        }
    }

    func row(_ o: TestOutcome, _ c: ShellColors) -> some View {
        let d = TestShellModel.diamond(o.status)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: d.symbol).font(.system(size: 12)).foregroundStyle(c.tint(d.tint))
                Text(verbatim: "\(o.name)()").font(ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: o.suite ?? "—").font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
                    .frame(width: 200, alignment: .leading)
                Text(verbatim: o.duration.map { String(format: "%.3f s", $0) } ?? "—").font(ShellFonts.small.monospacedDigit())
                    .foregroundStyle(c.secondaryLabel).frame(width: 80, alignment: .trailing)
            }
            ForEach(Array(o.failures.enumerated()), id: \.offset) { f in
                let issue = f.element
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(c.error)
                    Text(verbatim: issue.message).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(3)
                    if let loc = issue.location {
                        Spacer(minLength: 6)
                        Text(verbatim: "\((loc.file as NSString).lastPathComponent):\(loc.line)").font(ShellFonts.small).foregroundStyle(c.accent)
                            .onTapGesture { if loc.file.hasPrefix("/") { model.open(loc.file, line: loc.line) } }
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// A run's log, line by line.
struct ReportLogView: View {
    var lines: [String]
    var colors: ShellColors

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.suffix(2000).enumerated()), id: \.offset) { pair in
                    Text(verbatim: pair.element).font(Font.system(size: 11, design: .monospaced)).foregroundStyle(colors.label).lineLimit(1)
                        .frame(height: 15)
                }
            }
            .padding(12)
        }
    }
}
