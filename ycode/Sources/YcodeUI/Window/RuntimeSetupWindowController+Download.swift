import AppKit
import YcodeIDECore

/// Get a Runtime (#55, `runtime-downloads.md` §6.1): on a Mac the routes in
/// order — Xcode's own tool, Ycode's direct download, a runtime you have —
/// each a short section with its one button; the button opens the sheet with
/// the exact command. While a route runs, a bar, the phase, Cancel and the
/// tool's output take the step's top; a failure shows its words and Retry.
extension RuntimeSetupWindowController {
    var downloads: RuntimeDownloadModel { session.downloads }

    func downloadViews() -> [NSView] {
        var out: [NSView] = []
        out.append(platformRow())
        if let a = downloads.activity { out += activityViews(a) }
        let busy = downloads.activity?.isRunning == true || session.running != nil
        if session.machine.isMac {
            out += xcodeSection(busy: busy)
            out += directSection(busy: busy, title: "Downloaded by Ycode")
        } else {
            out += directSection(busy: busy, title: "Downloaded by Ycode")
            out.append(heading("With Xcode on a Mac"))
            out.append(note(downloads.macRouteNote(downloads.platform), id: "runtime-download-mac-note"))
        }
        out.append(heading("A runtime you have"))
        out.append(note("An exported bundle, disk image, .simruntime bundle or RuntimeRoot from your own Xcode installation."))
        out.append(button("Go to Add a Runtime", #selector(goToStep(_:)), id: "runtime-download-go-add", tag: RuntimeSetupStep.add.rawValue))
        return out
    }

    private func platformRow() -> NSView {
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        let shown = SimPlatform.allCases.filter { session.choices.platforms.contains($0) || $0 == downloads.platform }
        for p in shown {
            pop.addItem(withTitle: p.title)
            pop.lastItem?.tag = SimPlatform.allCases.firstIndex(of: p) ?? 0
        }
        pop.selectItem(withTitle: downloads.platform.title)
        pop.target = self
        pop.action = #selector(downloadPlatformChanged(_:))
        pop.identifier = .init("runtime-download-platform")
        pop.isEnabled = downloads.activity?.isRunning != true
        let have = session.report?.readyPlatforms.contains(downloads.platform) == true
        let state = NSTextField(labelWithString: have ? "You have a \(downloads.platform.title) runtime already." : "No \(downloads.platform.title) runtime yet.")
        state.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 11)
        let row = NSStackView(views: [label("Platform:"), pop, state])
        row.spacing = 8
        row.alignment = .firstBaseline
        return row
    }

    private func xcodeSection(busy: Bool) -> [NSView] {
        var out: [NSView] = [heading("With Xcode (recommended on a Mac)")]
        out.append(note("Apple's own tool downloads the runtime and installs it on this Mac, where Xcode and Ycode both use it."))
        let d = downloads.xcodeDownload
        let cmd = NSTextField(labelWithString: d.shownCommand)
        cmd.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cmd.isSelectable = true
        cmd.identifier = .init("runtime-download-xcode-command")
        out.append(cmd)
        let save = NSButton(checkboxWithTitle: "Also save a copy for a Linux computer or simulator host", target: self, action: #selector(exportToggled(_:)))
        save.state = downloads.exportCopy ? .on : .off
        save.identifier = .init("runtime-download-export")
        out.append(save)
        if downloads.exportCopy {
            if exportField.currentEditor() == nil { exportField.stringValue = downloads.exportPath }
            exportField.placeholderString = "Folder for the copy"
            exportField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            exportField.identifier = .init("runtime-download-export-path")
            exportField.target = self
            exportField.action = #selector(exportPathEdited)
            exportField.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
            let choose = button("Choose…", #selector(chooseExportFolder), id: "runtime-download-export-choose")
            let row = NSStackView(views: [exportField, choose])
            row.spacing = 8
            out.append(row)
            out.append(note("The copy is an exported bundle: copy it to the other computer and add it there (ycode runtime import <folder>)."))
        }
        let go = button("Download with Xcode…", #selector(xcodeDownloadClicked), id: "runtime-download-xcode", primary: true)
        go.isEnabled = !busy && downloads.xcodeAvailable
        out.append(go)
        return out
    }

    private func directSection(busy: Bool, title: String) -> [NSView] {
        var out: [NSView] = [heading(title)]
        out.append(note(session.machine.isMac
            ? "Ycode fetches the runtime from Apple for you, checks its size and SHA-256, decrypts it with the key Apple returns, and keeps its RuntimeRoot in Ycode's folder (for a Linux computer or a simulator host)."
            : "Ycode asks Apple for the runtime, describing this computer as it is, downloads it (a stopped download resumes), checks its size and SHA-256, decrypts it with the key Apple returns, and puts its RuntimeRoot in Ycode's folder."))
        switch downloads.indexState {
        case .idle:
            out.append(button("Show Versions", #selector(showVersionsClicked), id: "runtime-download-versions"))
        case .loading:
            out.append(note("Reading Apple's runtime index…"))
        case .failed(let why):
            let t = note(why, id: "runtime-download-index-error")
            t.textColor = .systemRed
            out += [t, button("Try Again", #selector(showVersionsClicked), id: "runtime-download-versions")]
        case .loaded:
            let list = downloads.candidates
            if list.isEmpty {
                out.append(note("Apple's index lists no arm64 \(downloads.platform.title) runtime Ycode can fetch."))
            } else {
                let pop = NSPopUpButton(frame: .zero, pullsDown: false)
                let rec = downloads.recommended
                for (i, e) in list.prefix(24).enumerated() {
                    pop.addItem(withTitle: "\(e.title) — \(RuntimeSize.format(e.fileSize))" + (e == rec ? "  (recommended)" : ""))
                    pop.lastItem?.tag = i
                    if e == downloads.chosen { pop.select(pop.lastItem) }
                }
                pop.target = self
                pop.action = #selector(versionChanged(_:))
                pop.identifier = .init("runtime-download-version")
                pop.isEnabled = !busy
                let row = NSStackView(views: [label("Version:"), pop])
                row.spacing = 8
                row.alignment = .firstBaseline
                out.append(row)
            }
            let go = button("Download…", #selector(directDownloadClicked), id: "runtime-download-direct", primary: !session.machine.isMac)
            go.isEnabled = !busy && downloads.directAction != nil && downloads.directReady
            out.append(go)
        }
        return out
    }

    private func activityViews(_ a: RuntimeDownloadModel.Activity) -> [NSView] {
        var out: [NSView] = []
        let title = NSTextField(labelWithString: a.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.identifier = .init("runtime-download-activity")
        out.append(title)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.identifier = .init("runtime-download-progress")
        bar.widthAnchor.constraint(equalToConstant: 380).isActive = true
        bar.minValue = 0
        bar.maxValue = 1
        if let f = a.fraction { bar.isIndeterminate = false; bar.doubleValue = f } else { bar.isIndeterminate = a.isRunning; if a.isRunning { bar.startAnimation(nil) } }
        var failed = false
        if case .failed = a.state { failed = true }
        var line: [NSView] = failed ? [] : [bar]
        let phase: String
        switch a.state {
        case .running:
            line.append(button("Cancel", #selector(cancelDownloadClicked), id: "runtime-download-cancel"))
            phase = a.phase
        case .finished(let words):
            bar.doubleValue = 1
            phase = words
        case .cancelled:
            line.append(button(a.route == .direct ? "Resume" : "Retry", #selector(retryDownloadClicked), id: "runtime-download-retry", primary: true))
            phase = a.route == .direct ? "Cancelled. What was downloaded is kept; Resume continues from there." : "Cancelled."
        case .failed(let words, let retry, _):
            if retry { line.append(button("Retry", #selector(retryDownloadClicked), id: "runtime-download-retry", primary: true)) }
            phase = words
        }
        let row = NSStackView(views: line)
        row.spacing = 8
        out.append(row)
        let text = NSTextField(wrappingLabelWithString: phase)
        text.font = .systemFont(ofSize: 12)
        text.identifier = .init("runtime-download-phase")
        text.widthAnchor.constraint(lessThanOrEqualToConstant: 540).isActive = true
        if case .failed = a.state { text.textColor = .systemRed }
        out.append(text)
        if case .failed(_, _, let refused) = a.state, refused {
            out.append(note("The other routes still work:"))
            var offers: [NSView] = []
            if session.machine.isMac {
                let x = button("Download with Xcode…", #selector(xcodeDownloadClicked), id: "runtime-download-refused-xcode", primary: true)
                x.isEnabled = downloads.xcodeAvailable
                offers.append(x)
            }
            offers.append(button("Go to Add a Runtime", #selector(goToStep(_:)), id: "runtime-download-refused-add", tag: RuntimeSetupStep.add.rawValue))
            out.append(NSStackView(views: offers))
        }
        if !downloads.log.isEmpty {
            let scroll = NSTextView.scrollableTextView()
            scroll.identifier = .init("runtime-download-log")
            let tv = scroll.documentView as? NSTextView
            tv?.isEditable = false
            tv?.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            tv?.string = downloads.log
            tv?.scrollToEndOfDocument(nil)
            scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
            scroll.borderType = .lineBorder
            out.append(scroll)
        }
        return out
    }

    // MARK: Actions

    @objc func downloadPlatformChanged(_ sender: NSPopUpButton) {
        let i = sender.selectedItem?.tag ?? 0
        guard i < SimPlatform.allCases.count else { return }
        downloads.setPlatform(SimPlatform.allCases[i])
    }

    @objc func versionChanged(_ sender: NSPopUpButton) {
        let list = downloads.candidates
        let i = sender.selectedItem?.tag ?? 0
        guard i < list.count else { return }
        downloads.select(build: list[i] == downloads.recommended ? nil : list[i].build)
    }

    @objc func exportToggled(_ sender: NSButton) { downloads.setExportCopy(sender.state == .on) }
    @objc func exportPathEdited() { downloads.setExportPath(exportField.stringValue.trimmingCharacters(in: .whitespaces)) }

    @objc func chooseExportFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "Choose"
        p.message = "Choose the folder where Xcode saves a copy of the runtime."
        guard p.runModal() == .OK, let url = p.url else { return }
        downloads.setExportPath(url.path)
    }

    @objc func xcodeDownloadClicked() {
        exportPathEdited()
        if let a = downloads.xcodeAction { session.request(a) }
    }

    @objc func showVersionsClicked() { downloads.loadIndex() }
    @objc func directDownloadClicked() { if let a = downloads.directAction { session.request(a) } }
    @objc func cancelDownloadClicked() { downloads.cancel() }
    @objc func retryDownloadClicked() { downloads.retry() }
}
