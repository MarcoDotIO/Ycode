import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import YcodeIDECore
import YcodeIDEShell

/// Window ▸ Downloads on Linux: the simulator runtime wizard
/// (`runtime-onboarding.md` §11), the same session and checks as the macOS
/// window. The steps sit in a panel at the left; the selected step's
/// choices, runtimes and checks (state, reason, one fix) at the right;
/// Re-check, Back and Next at the bottom. An action runs only after an alert
/// that shows its exact command.
struct RuntimeSetupSheet: View {
    @Bindable var session: RuntimeSetupSession
    var app: ShellAppModel
    @Environment(\.colorScheme) private var scheme
    @State private var host = ""
    @State private var data = ""
    @State private var link = ""
    @State private var ports = ""
    @State private var isPicking = false
    @State private var isScriptShown = false

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                steps(c)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: ExperimentalNotice.runtimes).font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: session.step.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(c.label)
                            .shellTarget("runtime title")
                        Text(verbatim: session.step.summary(machine: session.machine, target: session.choices.target))
                            .font(.system(size: 13)).foregroundStyle(c.secondaryLabel).fixedSize(horizontal: false, vertical: true)
                        stepContent(c)
                        if !session.shownChecks.isEmpty {
                            if session.step != .target && session.step != .host {
                                Text("Checks").font(.system(size: 13, weight: .semibold)).foregroundStyle(c.label).padding(.top, 4)
                            }
                            ForEach(session.shownChecks) { check in checkRow(check, c) }
                        }
                        if session.report == nil {
                            Text(verbatim: session.isChecking ? "Checking…" : "Not checked yet.").font(.system(size: 13)).foregroundStyle(c.secondaryLabel)
                        }
                        if session.logStep == session.step, !session.log.isEmpty { logView(c) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .shellTarget("runtime content")
            }
            .frame(maxHeight: .infinity)
            bottomBar(c)
        }
        .overlay { if let confirmation = session.confirmation { confirmationPanel(confirmation, c) } }
        .frame(width: 840, height: 600)
        .background(c.content)
        .onAppear { syncFields() }
        .onChange(of: session.choices.host) { _, _ in syncFields() }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { session.pick(path: url.path) }
        }
        .sheet(isPresented: $isScriptShown) { scriptSheet(c) }
    }

    func syncFields() {
        let h = session.choices.host
        host = h.destination
        data = h.dataDirectory
        link = h.linkName
        ports = "\(h.tcpPort)/\(h.udpPort)"
    }

    func commitHost() {
        var h = session.choices.host
        h.destination = host.trimmingCharacters(in: .whitespaces)
        h.dataDirectory = data.trimmingCharacters(in: .whitespaces)
        h.linkName = link.trimmingCharacters(in: .whitespaces)
        if let (t, u) = RuntimeHostSettings.ports(ports) { (h.tcpPort, h.udpPort) = (t, u) }
        session.setHost(h)
    }

    // MARK: Steps

    func steps(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(session.steps.enumerated()), id: \.offset) { pair in
                let s = pair.element
                let selected = s == session.step
                Button {
                    session.show(s)
                } label: {
                    HStack(spacing: 7) {
                        mark(session.state(of: s), c)
                        Text(verbatim: "\(pair.offset + 1). \(s.title)")
                            .font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(c.label)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? c.selectorPill : Color.clear))
                }
                .buttonStyle(.plain)
                .shellTarget("runtime step \(pair.offset)")
            }
            Spacer()
        }
        .padding(.top, 20)
        .padding(.horizontal, 8)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(c.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(c.capsuleStroke, lineWidth: 1))
        .padding(8)
    }

    func mark(_ s: SetupCheckState?, _ c: ShellColors) -> some View {
        let (name, color): (String, Color) = switch s {
        case .ok: ("checkmark.circle.fill", Color(.sRGB, red: 52 / 255, green: 199 / 255, blue: 89 / 255))
        case .missing: ("xmark.circle.fill", c.error)
        case .notApplicable: ("minus.circle", c.secondaryLabel)
        default: ("questionmark.circle", c.secondaryLabel)
        }
        return symbol(name).foregroundStyle(color).frame(width: 16, height: 16).accessibilityLabel(s?.title ?? "Not checked")
    }

    @ViewBuilder
    func stepContent(_ c: ShellColors) -> some View {
        switch session.step {
        case .target: targetStep(c)
        case .host: hostStep(c)
        case .prepare: prepareStep(c)
        case .runtimes: runtimesStep(c)
        case .add: addStep(c)
        case .finish: finishStep(c)
        }
    }

    func label(_ t: String, _ c: ShellColors) -> some View {
        Text(verbatim: t).font(.system(size: 13)).foregroundStyle(c.label).frame(width: 120, alignment: .trailing)
    }

    func note(_ t: String, _ c: ShellColors) -> some View {
        Text(verbatim: t).font(.system(size: 11)).foregroundStyle(c.secondaryLabel).fixedSize(horizontal: false, vertical: true)
    }

    func heading(_ t: String, _ c: ShellColors) -> some View {
        Text(verbatim: t).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.label).padding(.top, 4)
    }

    func targetStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label("Platforms:", c)
                ForEach(SimPlatform.allCases, id: \.self) { p in
                    Toggle(p.title, isOn: Binding(get: { session.choices.platforms.contains(p) }, set: { session.setPlatform(p, on: $0) }))
                        .toggleStyle(.checkbox)
                        .shellTarget("runtime platform \(p.rawValue)")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label("Simulators run:", c)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("On this computer", isOn: Binding(get: { !session.choices.useHost }, set: { if $0 { session.setUseHost(false) } }))
                        .toggleStyle(.checkbox)
                        .disabled(!session.machine.canRunSimulatorHere)
                        .shellTarget("runtime target here")
                    Toggle("On a simulator host (arm64 Linux with KVM)", isOn: Binding(get: { session.choices.useHost }, set: { session.setUseHost($0) }))
                        .toggleStyle(.checkbox)
                        .shellTarget("runtime target host")
                }
            }
            note(RuntimeSize.convention, c)
        }
    }

    func hostStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { label("Host:", c); field("user@sim-host", $host, "runtime host") }
            HStack { label("Data folder:", c); field("/data/ycode", $data, "runtime data") }
            HStack { label("Link name:", c); field("The host's name on Ycode's link", $link, "runtime link") }
            HStack { label("Ports (TCP/UDP):", c); field("47800/47801", $ports, "runtime ports") }
            HStack {
                Spacer().frame(width: 128)
                Button("Check Host") { commitHost() }.buttonStyle(.bordered).shellTarget("runtime host check")
            }
            HStack(alignment: .top) {
                Spacer().frame(width: 128)
                note("Ycode logs in with an ssh key only and never asks for a password. The data folder holds runtimes and devices; choose a volume with room for them (about 16 GB per iOS runtime).", c)
            }
        }
    }

    func field(_ placeholder: String, _ text: Binding<String>, _ id: String) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 340)
            .onSubmit { commitHost() }
            .shellTarget(id)
    }

    func prepareStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Check Host") { session.runSetupReport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.running != nil || !session.choices.host.isComplete)
                    .shellTarget("runtime setup report")
                Button("View Script…") { isScriptShown = true }.buttonStyle(.bordered).shellTarget("runtime setup view")
                Button("Save Script") { saveScript() }.buttonStyle(.bordered).shellTarget("runtime setup save")
            }
            note("The script only looks until you apply it. View it first, or save it and run it yourself: bash ycode-host-setup --report.", c)
            if let setup = session.hostSetup {
                if !setup.rootSteps.isEmpty {
                    heading("Needs root (run in your terminal)", c)
                    ForEach(setup.rootSteps) { s in stepLine(s, c) }
                    Button("Show Terminal Command") { session.prepareRootSteps() }.buttonStyle(.bordered).shellTarget("runtime setup root")
                    commandLine(session.rootCommand, note: "sudo asks for your password in your terminal; Ycode never sees it.", c)
                }
                if !setup.userSteps.isEmpty {
                    heading("Ycode can do as you", c)
                    ForEach(setup.userSteps) { s in stepLine(s, c) }
                    Button("Apply…") { session.request(.provisionApply) }.buttonStyle(.borderedProminent)
                        .disabled(session.running != nil).shellTarget("runtime setup apply")
                }
                if setup.isSettled {
                    note(setup.passed == true ? "Nothing left to do: a second run only reports." : "Nothing more the script can do; the checks below say what is left.", c)
                }
            }
        }
    }

    func saveScript() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let folder = FileManager.default.fileExists(atPath: dir.path) ? dir : FileManager.default.homeDirectoryForCurrentUser
        try? session.saveScript(to: folder.appendingPathComponent(HostSetupScript.fileName))
    }

    func stepLine(_ s: HostSetupOutput.Step, _ c: ShellColors) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: s.id).font(.system(size: 11, weight: .medium)).foregroundStyle(c.secondaryLabel).frame(width: 96, alignment: .leading)
            Text(verbatim: s.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(c.label).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 460, alignment: .leading)
        }
    }

    /// A command to run by hand: in a read-only field, where it can be
    /// selected and copied with the field's own Copy.
    func commandLine(_ cmd: String, note words: String, _ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: .constant(cmd))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 500)
                .shellTarget("runtime command")
            note(words, c)
        }
    }

    func runtimesStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.choices.useHost {
                heading("On \(session.choices.host.hostName.isEmpty ? "the host" : session.choices.host.hostName)", c)
                let host = session.report?.host ?? []
                if host.isEmpty { note(session.report == nil ? "Not checked yet." : "No runtimes on the host yet.", c) }
                ForEach(host) { r in runtimeRow(r, copy: false, c) }
                heading(session.machine.isMac ? "On this Mac" : "On this computer", c)
                if session.copyableRuntimes.isEmpty { note("No runtimes here to copy. Use Add a Runtime to pick a runtime bundle or RuntimeRoot.", c) }
                ForEach(session.copyableRuntimes) { r in runtimeRow(r, copy: true, c) }
            } else {
                let local = session.report?.local ?? []
                if local.isEmpty && session.report != nil { note("No runtimes yet.", c) }
                ForEach(local) { r in runtimeRow(r, copy: false, c) }
            }
        }
    }

    func runtimeRow(_ r: SimRuntimeRecord, copy: Bool, _ c: ShellColors) -> some View {
        var details = [r.sizeText, r.architectures.joined(separator: ", ")]
        if let used = r.lastUsed { details.append("last used \(used.prefix(10))") }
        switch r.owner {
        case .coreSimulator: details.append("installed by Xcode; manage it in Xcode")
        case .ycode: details.append("copied by Ycode")
        case .external: details.append("configured on the host")
        }
        if !r.isUsable { details.append(r.availabilityError ?? r.state) }
        return HStack(alignment: .top, spacing: 8) {
            mark(r.isUsable ? .ok : .missing, c)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: r.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.label)
                Text(verbatim: details.filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
            }
            Spacer()
            if copy {
                Button("Copy to Host…") {
                    if let root = r.runtimeRoot { session.request(.copyToHost(source: root, record: r, host: session.choices.host.destination)) }
                }
                .buttonStyle(.bordered)
                .disabled(session.running != nil || !session.choices.host.isComplete)
            } else if r.isRemovable {
                Button("Remove…") { session.request(.remove(r)) }.buttonStyle(.bordered).shellTarget("runtime remove \(r.folderName)")
            }
        }
        .shellTarget("runtime row \(r.folderName)")
    }

    func addStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Choose Runtime…") { isPicking = true }.buttonStyle(.borderedProminent).disabled(session.running != nil).shellTarget("runtime choose")
            note("A .simruntime bundle, or its RuntimeRoot, from your own Xcode installation.", c)
            if let p = session.picked {
                Text(verbatim: pickedText(p)).font(.system(size: 13)).foregroundStyle(c.label).shellTarget("runtime picked")
                if let a = session.pickedAction {
                    Button(actionTitle(a)) { session.request(a) }.buttonStyle(.borderedProminent).disabled(session.running != nil)
                        .shellTarget("runtime add picked")
                }
            }
            if let t = session.transfer { transferView(t, c) }
            let missing = SimPlatform.allCases.filter { session.choices.platforms.contains($0) && !(session.report?.readyPlatforms.contains($0) ?? false) }
            if let p = missing.first {
                heading("Don't have a runtime?", c)
                note(RuntimeSetupChecker.acquisitionNote(p), c).shellTarget("runtime acquisition")
            }
        }
    }

    func pickedText(_ p: RuntimeSetupSession.PickedRuntime) -> String {
        let what: String = switch p.kind {
        case .diskImage: "Runtime disk image"
        case .bundle: "Runtime bundle"
        case .runtimeRoot: "RuntimeRoot"
        case .unknown: "Not a runtime"
        }
        return "\(what): \((p.path as NSString).lastPathComponent)" + (p.record.map { " — \($0.title), \($0.sizeText)" } ?? "")
    }

    func actionTitle(_ a: RuntimeAction) -> String {
        switch a {
        case .copyToHost: "Copy to Host…"
        case .importImage: "Add to This Mac…"
        default: "Copy…"
        }
    }

    func transferView(_ t: RuntimeTransfer, _ c: ShellColors) -> some View {
        let (fraction, text): (Double, String) = switch session.transferState {
        case .copying(let kb): (t.fraction(copiedKB: kb), "Copying \(t.record.title): " + t.progressText(copiedKB: kb))
        case .interrupted(let kb, let why): (t.fraction(copiedKB: kb), "Stopped at \(t.progressText(copiedKB: kb)). \(why)")
        case .finished: (1, "\(t.record.title) is on \(t.host.hostName).")
        case .failed(let why): (0, why)
        case .idle: (0, "")
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 360).shellTarget("runtime transfer progress")
                if case .copying = session.transferState { Button("Stop") { session.stop() }.buttonStyle(.bordered).shellTarget("runtime transfer stop") }
                if case .interrupted = session.transferState {
                    Button("Resume") { session.request(.copyToHost(source: t.source, record: t.record, host: t.host.destination)) }
                        .buttonStyle(.borderedProminent).shellTarget("runtime transfer resume")
                }
            }
            Text(verbatim: text).font(.system(size: 11)).foregroundStyle(c.label)
        }
    }

    func finishStep(_ c: ShellColors) -> some View {
        let ready = session.report?.readyPlatforms ?? []
        let whereText = session.choices.useHost ? "on \(session.choices.host.hostName)" : "on this computer"
        return VStack(alignment: .leading, spacing: 8) {
            if ready.isEmpty { note("No platform has a runtime yet. Go back to Add a Runtime, or finish now and come back with Window ▸ Downloads.", c) }
            ForEach(SimPlatform.allCases.filter { session.choices.platforms.contains($0) }, id: \.self) { p in
                HStack(spacing: 8) {
                    mark(ready.contains(p) ? .ok : .missing, c)
                    Text(verbatim: ready.contains(p) ? "\(p.title) simulators run \(whereText)." : "\(p.title): no runtime yet.")
                        .font(.system(size: 13)).foregroundStyle(c.label)
                }
            }
            ForEach(session.finishNotes, id: \.self) { n in note(n, c) }
        }
    }

    func checkRow(_ check: RuntimeCheck, _ c: ShellColors) -> some View {
        HStack(alignment: .top, spacing: 8) {
            mark(check.state, c)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: check.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.label)
                Text(verbatim: check.reason).font(.system(size: 13)).foregroundStyle(c.secondaryLabel).fixedSize(horizontal: false, vertical: true)
                if let fix = check.fix, check.state != .ok, check.state != .notApplicable { fixView(fix, check, c) }
            }
        }
        .shellTarget("runtime check \(check.id)")
    }

    @ViewBuilder
    func fixView(_ fix: RuntimeFix, _ check: RuntimeCheck, _ c: ShellColors) -> some View {
        switch fix {
        case .command(let cmd): commandLine(cmd, note: "Run this yourself in your terminal.", c)
        case .instructions(let words): Text(verbatim: words).font(.system(size: 12)).foregroundStyle(c.label).fixedSize(horizontal: false, vertical: true)
        case .step(let s): Button("Go to \(s.title)") { session.show(s) }.buttonStyle(.bordered).controlSize(.small)
        case .action(let a):
            Button({ if case .remove = a { "Remove…" } else if case .provisionApply = a { "Apply…" } else { "Fix…" } }()) { session.request(a) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    func logView(_ c: ShellColors) -> some View {
        ScrollView {
            Text(verbatim: String(session.log.suffix(6000))).font(.system(size: 10, design: .monospaced)).foregroundStyle(c.label)
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .frame(width: 540, height: 140)
        .background(c.fieldFill)
        .overlay(Rectangle().stroke(c.fieldStroke, lineWidth: 1))
        .shellTarget("runtime log")
    }

    func scriptSheet(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: HostSetupScript.fileName).font(.system(size: 13, weight: .bold)).foregroundStyle(c.label)
            ScrollView {
                Text(verbatim: HostSetupScript.text).font(.system(size: 10, design: .monospaced)).foregroundStyle(c.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { isScriptShown = false }.keyboardShortcut(.defaultAction).buttonStyle(.bordered) }
        }
        .padding(16)
        .frame(width: 720, height: 520)
        .background(c.content)
    }

    // MARK: Confirmation

    /// What an action will run, before it runs: the command in a read-only
    /// field (select and copy it there), Cancel and the action's button.
    func confirmationPanel(_ k: RuntimeConfirmation, _ c: ShellColors) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: k.title).font(.system(size: 13, weight: .bold)).foregroundStyle(c.label)
                Text(verbatim: k.message).font(.system(size: 12)).foregroundStyle(c.label).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(verbatim: k.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(c.label)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 120)
                .background(c.fieldFill)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(c.fieldStroke, lineWidth: 1))
                .shellTarget("runtime confirm command")
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { session.cancelConfirmation() }.keyboardShortcut(.cancelAction).buttonStyle(.bordered)
                        .shellTarget("runtime confirm cancel")
                    Button(k.confirmTitle) { session.confirm() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .tint(k.isDestructive ? c.error : c.accent)
                        .shellTarget("runtime confirm ok")
                }
            }
            .padding(18)
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 14).fill(c.content))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(c.capsuleStroke, lineWidth: 1))
        }
    }

    // MARK: Bar

    func bottomBar(_ c: ShellColors) -> some View {
        HStack(spacing: 8) {
            if session.isChecking || session.running != nil { ProgressView().controlSize(.small) }
            Text(verbatim: session.running ?? session.status ?? (session.isChecking ? "Checking…" : ""))
                .font(.system(size: 11)).foregroundStyle(c.secondaryLabel).lineLimit(2).shellTarget("runtime status")
            Spacer()
            Button("Close") { app.closeRuntimeSetup() }.keyboardShortcut(.cancelAction).buttonStyle(.bordered).shellTarget("runtime close")
            Button("Re-check") { session.recheck() }.buttonStyle(.bordered).disabled(session.isChecking).shellTarget("runtime recheck")
            Button("Back") { session.back() }.buttonStyle(.bordered).disabled(session.isFirstStep).shellTarget("runtime back")
            Button(session.isLastStep ? "Done" : "Next") {
                if session.isLastStep { app.closeRuntimeSetup() } else { session.next() }
            }
            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).shellTarget("runtime next")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
