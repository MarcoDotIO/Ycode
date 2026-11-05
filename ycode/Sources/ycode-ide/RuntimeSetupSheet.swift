import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import YcodeIDECore
import YcodeIDEShell

/// Window ▸ Downloads on Linux: the simulator runtime wizard
/// (`runtime-onboarding.md` §11), the same session and checks as the macOS
/// window, as the same paged assistant (`liquid-glass-ycode.md` §11): page
/// dots that show each step's state and jump to it, a centred page with the
/// step's glyph, title and summary over a 520-point column (checks in a
/// grouped box), and Back, Close, Re-check and Continue in the footer. The
/// page pushes in from the trailing edge going forward and from the leading
/// edge going back (a crossfade under Reduce Motion). An action runs only
/// after an alert that shows its exact command.
struct RuntimeSetupSheet: View {
    static let size = CGSize(width: 760, height: 600)
    static let columnWidth: CGFloat = 520
    static let summaryWidth: CGFloat = 480
    @Bindable var session: RuntimeSetupSession
    var app: ShellAppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which way the page moves; read when a page enters and when it leaves.
    @State private var direction = PageDirection()
    /// The step the page shows: follows the session's in an animated
    /// transaction, so every step change moves the page.
    @State private var shownStep: RuntimeSetupStep?
    @State private var host = ""
    @State private var data = ""
    @State private var link = ""
    @State private var ports = ""
    @State private var isPicking = false
    @State private var isScriptShown = false

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            dots(c).frame(height: 20).padding(.top, 20)
            ZStack {
                // One conditional page per step, so a step change removes one
                // page and inserts another, each with the page transition.
                ForEach(RuntimeSetupStep.allCases, id: \.self) { step in
                    if step == (shownStep ?? session.step) {
                        page(c, step: step)
                            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(PageTurn(direction: direction, distance: Self.size.width)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .padding(.bottom, 12)
            footer(c)
        }
        .overlay { if let confirmation = session.confirmation { confirmationPanel(confirmation, c) } }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(c.content)
        .onAppear { syncFields(); shownStep = session.step }
        .onChange(of: session.choices.host) { _, _ in syncFields() }
        .onChange(of: session.step) { _, new in follow(new) }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { session.pick(path: url.path) }
        }
        .sheet(isPresented: $isScriptShown) { scriptSheet(c) }
    }

    /// The header (glyph, title, summary) and the column: what moves.
    func page(_ c: ShellColors, step: RuntimeSetupStep) -> some View {
        let checks = step == .download ? session.downloads.checks : session.report?.checks(in: step) ?? []
        return VStack(spacing: 0) {
            symbol(step.glyph).font(.system(size: 52)).foregroundStyle(c.accent).frame(width: 64, height: 64)
                .padding(.top, 8).shellTarget("runtime glyph")
            Text(verbatim: step.title).font(.system(size: 26, weight: .bold)).foregroundStyle(c.label)
                .padding(.top, 12).shellTarget("runtime title")
            Text(verbatim: step.summary(machine: session.machine, target: session.choices.target))
                .font(.system(size: 13)).foregroundStyle(c.secondaryLabel).multilineTextAlignment(.center)
                .frame(maxWidth: Self.summaryWidth).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6).shellTarget("runtime summary")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stepContent(c, step: step)
                    if !checks.isEmpty {
                        if step != .target && step != .host { heading("Checks", c) }
                        group(c) { ForEach(Array(checks.enumerated()), id: \.element.id) { pair in
                            if pair.offset > 0 { separator(c) }
                            checkRow(pair.element, c)
                        } }
                        .shellTarget("runtime checks")
                    }
                    if session.report == nil {
                        Text(verbatim: session.isChecking ? "Checking…" : "Not checked yet.").font(.system(size: 13)).foregroundStyle(c.secondaryLabel)
                    }
                    if session.logStep == step, !session.log.isEmpty { logView(c) }
                    Text(verbatim: ExperimentalNotice.runtimes).font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                        .multilineTextAlignment(.center).frame(maxWidth: Self.summaryWidth).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: Self.columnWidth, alignment: .leading)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 20)
            .shellTarget("runtime content")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(c.content)
    }

    /// Shows `s`, moving the page the way the step lies: 0.3 s, or a 0.2 s
    /// crossfade under Reduce Motion.
    func go(to s: RuntimeSetupStep) {
        let steps = session.steps
        let old = shownStep ?? session.step
        guard s != old, steps.contains(s) else { return }
        direction.forward = (steps.firstIndex(of: s) ?? s.rawValue) > (steps.firstIndex(of: old) ?? old.rawValue)
        // One animated transaction for both changes: an update the session's
        // change caused would otherwise carry no animation.
        withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.3)) {
            shownStep = s
            session.show(s)
        }
    }

    /// A step change made elsewhere (the session, a driver): the page follows.
    func follow(_ new: RuntimeSetupStep) {
        guard shownStep != nil, shownStep != new else { return }
        go(to: new)
    }

    func goNext() {
        guard let i = session.steps.firstIndex(of: session.step), i + 1 < session.steps.count else { return }
        go(to: session.steps[i + 1])
    }

    func goBack() {
        guard let i = session.steps.firstIndex(of: session.step), i > 0 else { return }
        go(to: session.steps[i - 1])
    }

    /// Rows in a grouped inset box: radius 10, a quiet fill, hairlines between rows.
    func group<Rows: View>(_ c: ShellColors, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 0) { rows() }
            .frame(width: Self.columnWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(c.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)))
    }

    func separator(_ c: ShellColors) -> some View {
        Rectangle().fill(c.separator).frame(height: 1).padding(.leading, 36)
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

    /// The page dots: one per step, the current one larger, each state its
    /// own shape (ok a filled circle, missing a diamond, unknown a ring, not
    /// applicable a bar); a click jumps to the step.
    func dots(_ c: ShellColors) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(session.steps.enumerated()), id: \.offset) { pair in
                let s = pair.element
                let state = session.state(of: s)
                let label = "Step \(pair.offset + 1) of \(session.steps.count): \(s.title), \(Self.stateWords(state))"
                Button { go(to: s) } label: {
                    dot(state, current: s == session.step, c).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(label)
                .accessibilityLabel(label)
                .shellTarget("runtime dot \(pair.offset)")
            }
        }
        .shellTarget("runtime-steps-panel")
    }

    static func stateWords(_ s: SetupCheckState?) -> String {
        switch s {
        case .ok?: "passed"
        case .missing?: "needs attention"
        case .unknown?: "unknown"
        case .notApplicable?: "not applicable"
        case nil: "not checked"
        }
    }

    @ViewBuilder
    func dot(_ s: SetupCheckState?, current: Bool, _ c: ShellColors) -> some View {
        let d: CGFloat = current ? 10 : 7
        let gray = Color(.sRGB, red: 142 / 255, green: 142 / 255, blue: 147 / 255)
        switch s {
        case .ok?: Circle().fill(c.success).frame(width: d, height: d)
        case .missing?: Rectangle().fill(Color(.sRGB, red: 1, green: 149 / 255, blue: 0)).frame(width: d * 0.88, height: d * 0.88).rotationEffect(.degrees(45))
        case .notApplicable?: Capsule().fill(gray).frame(width: d, height: 2)
        default: Circle().stroke(gray, lineWidth: 1.5).frame(width: d - 1.5, height: d - 1.5)
        }
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
    func stepContent(_ c: ShellColors, step: RuntimeSetupStep) -> some View {
        switch step {
        case .target: targetStep(c)
        case .host: hostStep(c)
        case .prepare: prepareStep(c)
        case .runtimes: runtimesStep(c)
        case .add: addStep(c)
        case .finish: finishStep(c)
        case .download: downloadStep(c)
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
            note(RuntimeSize.convention, c).multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
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
                    .frame(width: 340, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
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
                .frame(maxWidth: Self.columnWidth - 104, alignment: .leading)
        }
    }

    /// A command to run by hand: in a read-only field (it can be selected
    /// there), with a Copy button that puts the whole command on the
    /// clipboard, as the macOS window's.
    func commandLine(_ cmd: String, note words: String, _ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TextField("", text: .constant(cmd))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 380)
                    .shellTarget("runtime command")
                CopyButton(text: cmd, target: "runtime command copy")
            }
            note(words, c)
        }
    }

    func runtimesStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.choices.useHost {
                heading("On \(session.choices.host.hostName.isEmpty ? "the host" : session.choices.host.hostName)", c)
                let host = session.report?.host ?? []
                if host.isEmpty { note(session.report == nil ? "Not checked yet." : "No runtimes on the host yet.", c) } else { runtimeGroup(host, copy: false, c) }
                heading(session.machine.isMac ? "On this Mac" : "On this computer", c)
                if session.copyableRuntimes.isEmpty { note("No runtimes here to copy. Use Add a Runtime to pick a runtime bundle or RuntimeRoot.", c) }
                else { runtimeGroup(session.copyableRuntimes, copy: true, c) }
            } else {
                let local = session.report?.local ?? []
                if local.isEmpty && session.report != nil { note("No runtimes yet.", c) }
                if !local.isEmpty { runtimeGroup(local, copy: false, c) }
            }
        }
    }

    func runtimeGroup(_ rs: [SimRuntimeRecord], copy: Bool, _ c: ShellColors) -> some View {
        group(c) { ForEach(Array(rs.enumerated()), id: \.element.id) { pair in
            if pair.offset > 0 { separator(c) }
            runtimeRow(pair.element, copy: copy, c)
        } }
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
                    .fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                Button("Go to Get a Runtime") { go(to: .download) }.buttonStyle(.bordered).shellTarget("runtime go download")
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
            group(c) { ForEach(Array(SimPlatform.allCases.filter { session.choices.platforms.contains($0) }.enumerated()), id: \.element) { pair in
                let p = pair.element
                if pair.offset > 0 { separator(c) }
                HStack(spacing: 8) {
                    mark(ready.contains(p) ? .ok : .missing, c)
                    Text(verbatim: ready.contains(p) ? "\(p.title) simulators run \(whereText)." : "\(p.title): no runtime yet.")
                        .font(.system(size: 13)).foregroundStyle(c.label)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } }
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .shellTarget("runtime check \(check.id)")
    }

    @ViewBuilder
    func fixView(_ fix: RuntimeFix, _ check: RuntimeCheck, _ c: ShellColors) -> some View {
        switch fix {
        case .command(let cmd): commandLine(cmd, note: "Run this yourself in your terminal.", c)
        case .instructions(let words): Text(verbatim: words).font(.system(size: 12)).foregroundStyle(c.label).fixedSize(horizontal: false, vertical: true)
        case .step(let s): Button("Go to \(s.title)") { go(to: s) }.buttonStyle(.bordered).controlSize(.small)
        case .action(let a):
            Button({ if case .remove = a { "Remove…" } else if case .provisionApply = a { "Apply…" } else if case .installDecryptor = a { "Set Up…" } else { "Fix…" } }()) {
                session.request(a)
            }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    func logView(_ c: ShellColors) -> some View {
        ScrollView {
            Text(verbatim: String(session.log.suffix(6000))).font(.system(size: 10, design: .monospaced)).foregroundStyle(c.label)
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .frame(width: Self.columnWidth, height: 140)
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

    // MARK: Footer

    /// Back at the leading side (hidden on the first step), the status, then
    /// Close, Re-check and the default Continue (Done on the last step).
    func footer(_ c: ShellColors) -> some View {
        HStack(spacing: 8) {
            if !session.isFirstStep {
                Button("Back") { goBack() }.buttonStyle(.bordered).shellTarget("runtime back")
            }
            if session.isChecking || session.running != nil { ProgressView().controlSize(.small) }
            Text(verbatim: session.running ?? session.status ?? (session.isChecking ? "Checking…" : ""))
                .font(.system(size: 11)).foregroundStyle(c.secondaryLabel).lineLimit(2).shellTarget("runtime status")
            Spacer()
            Button("Close") { app.closeRuntimeSetup() }.keyboardShortcut(.cancelAction).buttonStyle(.bordered).shellTarget("runtime close")
            Button("Re-check") { session.recheck() }.buttonStyle(.bordered).disabled(session.isChecking).shellTarget("runtime recheck")
            Button(session.isLastStep ? "Done" : "Continue") {
                if session.isLastStep { app.closeRuntimeSetup() } else { goNext() }
            }
            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).shellTarget("runtime continue")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

/// The way the page moves, shared by the page entering and the page leaving
/// (a leaving page's transition is read when it leaves, so both agree).
@MainActor
final class PageDirection {
    var forward = true
}

/// Pushes the new page in from the trailing edge going forward (the leading
/// edge going back) while the old one leaves the other way.
struct PageTurn: Transition {
    let direction: PageDirection
    let distance: CGFloat

    func body(content: Content, phase: TransitionPhase) -> some View {
        let sign: CGFloat = direction.forward ? 1 : -1
        let x: CGFloat = switch phase {
        case .willAppear: sign * distance
        case .identity: 0
        case .didDisappear: -sign * distance
        }
        return content.offset(x: x)
    }
}
