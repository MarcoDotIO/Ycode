import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// Get a Runtime in Window ▸ Downloads (#55, `runtime-downloads.md` §6.1):
/// on Linux Ycode's own download first (its decryptor, disk image reader and
/// space are the checks below), then how to get one with Xcode on a Mac, then
/// a runtime you have. The same model as the macOS window; each route starts
/// from the confirmation that shows its exact command.
extension RuntimeSetupSheet {
    var downloads: RuntimeDownloadModel { session.downloads }

    func downloadStep(_ c: ShellColors) -> some View {
        let busy = downloads.activity?.isRunning == true || session.running != nil
        return VStack(alignment: .leading, spacing: 8) {
            downloadPlatformRow(c)
            if let a = downloads.activity { activityView(a, c) }
            if session.machine.isMac {
                xcodeSection(busy: busy, c)
                directSection(busy: busy, c)
            } else {
                directSection(busy: busy, c)
                heading("With Xcode on a Mac", c)
                note(downloads.macRouteNote(downloads.platform), c).shellTarget("runtime download mac note")
            }
            heading("A runtime you have", c)
            note("An exported bundle, .simruntime bundle or RuntimeRoot from your own Xcode installation.", c)
            Button("Go to Add a Runtime") { go(to: .add) }.buttonStyle(.bordered).shellTarget("runtime download go add")
        }
    }

    func downloadPlatformRow(_ c: ShellColors) -> some View {
        let shown = SimPlatform.allCases.filter { session.choices.platforms.contains($0) || $0 == downloads.platform }
        let have = session.report?.readyPlatforms.contains(downloads.platform) == true
        return HStack(alignment: .center, spacing: 8) {
            Text(verbatim: "Platform:").font(.system(size: 13)).foregroundStyle(c.label)
            Picker("", selection: Binding(get: { downloads.platform }, set: { downloads.setPlatform($0) })) {
                ForEach(shown, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: CGFloat(80 * shown.count))
            .disabled(downloads.activity?.isRunning == true)
            .shellTarget("runtime download platform")
            Text(verbatim: have ? "You have a \(downloads.platform.title) runtime already." : "No \(downloads.platform.title) runtime yet.")
                .font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
        }
    }

    @ViewBuilder
    func xcodeSection(busy: Bool, _ c: ShellColors) -> some View {
        heading("With Xcode (recommended on a Mac)", c)
        note("Apple's own tool downloads the runtime and installs it on this Mac.", c)
        Text(verbatim: downloads.xcodeDownload.shownCommand).font(.system(size: 11, design: .monospaced)).foregroundStyle(c.label)
        Button("Download with Xcode…") { if let a = downloads.xcodeAction { session.request(a) } }
            .buttonStyle(.borderedProminent).disabled(busy || !downloads.xcodeAvailable).shellTarget("runtime download xcode")
    }

    @ViewBuilder
    func directSection(busy: Bool, _ c: ShellColors) -> some View {
        heading("Downloaded by Ycode", c)
        note("Ycode asks Apple for the runtime, describing this computer as it is (\(downloads.host.summary)), downloads it (a stopped download resumes), "
             + "checks its size and SHA-256, decrypts it with the key Apple returns, and puts its RuntimeRoot in Ycode's folder.", c)
        switch downloads.indexState {
        case .idle:
            Button("Show Versions") { downloads.loadIndex() }.buttonStyle(.bordered).shellTarget("runtime download versions")
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                note("Reading Apple's runtime index…", c)
            }
        case .failed(let why):
            Text(verbatim: why).font(.system(size: 12)).foregroundStyle(c.error).fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { downloads.loadIndex() }.buttonStyle(.bordered).shellTarget("runtime download versions")
        case .loaded:
            let list = Array(downloads.candidates.prefix(24))
            let rec = downloads.recommended
            if list.isEmpty {
                note("Apple's index lists no arm64 \(downloads.platform.title) runtime Ycode can fetch.", c)
            } else {
                HStack(spacing: 8) {
                    Text(verbatim: "Version:").font(.system(size: 13)).foregroundStyle(c.label)
                    Picker("", selection: Binding(get: { downloads.chosen?.build ?? "" },
                                                  set: { b in downloads.select(build: b == rec?.build ? nil : b) })) {
                        ForEach(list, id: \.build) { e in
                            Text(verbatim: "\(e.title) — \(RuntimeSize.format(e.fileSize))" + (e == rec ? "  (recommended)" : "")).tag(e.build)
                        }
                    }
                    .frame(width: 380)
                    .disabled(busy)
                    .shellTarget("runtime download version")
                }
            }
            Button("Download…") { if let a = downloads.directAction { session.request(a) } }
                .buttonStyle(.borderedProminent)
                .disabled(busy || downloads.directAction == nil || !downloads.directReady)
                .shellTarget("runtime download direct")
        }
    }

    func activityView(_ a: RuntimeDownloadModel.Activity, _ c: ShellColors) -> some View {
        let words: String
        var failed = false
        switch a.state {
        case .running: words = a.phase
        case .finished(let w): words = w
        case .cancelled: words = a.route == .direct ? "Cancelled. What was downloaded is kept; Resume continues from there." : "Cancelled."
        case .failed(let w, _, _): words = w; failed = true
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: a.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.label).shellTarget("runtime download activity")
            HStack(spacing: 8) {
                if failed {
                    EmptyView()
                } else if let f = a.fraction { ProgressView(value: f).frame(width: 380).shellTarget("runtime download progress") }
                else if a.isRunning { ProgressView().frame(width: 380).shellTarget("runtime download progress") }
                switch a.state {
                case .running:
                    Button("Cancel") { downloads.cancel() }.buttonStyle(.bordered).shellTarget("runtime download cancel")
                case .cancelled:
                    Button(a.route == .direct ? "Resume" : "Retry") { downloads.retry() }.buttonStyle(.borderedProminent).shellTarget("runtime download retry")
                case .failed(_, let retry, _):
                    if retry { Button("Retry") { downloads.retry() }.buttonStyle(.borderedProminent).shellTarget("runtime download retry") }
                case .finished:
                    EmptyView()
                }
            }
            Text(verbatim: words).font(.system(size: 12)).foregroundStyle(failed ? c.error : c.label).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .shellTarget("runtime download phase")
            if case .failed(_, _, let refused) = a.state, refused {
                Button("Go to Add a Runtime") { go(to: .add) }.buttonStyle(.bordered).shellTarget("runtime download refused add")
            }
            if !downloads.log.isEmpty {
                ScrollView {
                    Text(verbatim: String(downloads.log.suffix(5000))).font(.system(size: 10, design: .monospaced)).foregroundStyle(c.label)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                .frame(width: Self.columnWidth, height: 110)
                .background(c.fieldFill)
                .overlay(Rectangle().stroke(c.fieldStroke, lineWidth: 1))
                .shellTarget("runtime download log")
            }
        }
    }
}
