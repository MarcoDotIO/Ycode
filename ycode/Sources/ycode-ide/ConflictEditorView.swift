import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The conflict editor over the editor area (`specs/ide/comparison.md`,
/// "Conflict editor"), drawn from the core's `ConflictEditorState` as the
/// AppKit `ConflictEditorController` is: "Conflicts in <file>", the file
/// pop-up, the unresolved count, Mark as Resolved, Continue and Abort; the
/// hunk bar (‹ "Change 2 of 5 (conflict)" ›, Left | Right | Left + Right |
/// Right + Left | Base | Edit, and which two versions are compared); the
/// two versions side by side; the hand editor while a change is written by
/// hand; the result, each change tinted (red undecided, green decided,
/// darker when selected).
struct ConflictEditorView: View {
    var editor: ConflictEditorShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let state = editor.state
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                header(state, c)
                Hairline(color: c.separator)
                hunkBar(state, c)
                Hairline(color: c.separator)
                if state.document == nil {
                    Text(verbatim: state.files.isEmpty ? "No Conflicts" : "Reading\u{2026}")
                        .font(Font.system(size: 15)).foregroundStyle(c.secondaryLabel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ConflictComparisonView(state: state, colors: c)
                        .frame(maxHeight: .infinity)
                    if state.isEditing {
                        Hairline(color: c.separator)
                        handEditor(c)
                    }
                    Hairline(color: c.separator)
                    ConflictResultView(editor: editor, colors: c)
                        .frame(height: max(110, geo.size.height * 0.3))
                }
            }
        }
        .shellTarget("conflict editor")
    }

    func header(_ state: ConflictEditorState, _ c: ShellColors) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: state.title).font(ShellFonts.rowBold).foregroundStyle(c.label).lineLimit(1)
                .shellTarget("conflict title")
            if !state.files.isEmpty {
                Menu {
                    ForEach(Array(state.fileNames.enumerated()), id: \.offset) { pair in
                        Button(pair.element) { editor.showFile(at: pair.offset) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: state.currentFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
                            .font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(c.secondaryLabel)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.popUpFill) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .shellTarget("conflict files")
            }
            Spacer(minLength: 8)
            Text(verbatim: state.statusText).font(ShellFonts.small)
                .foregroundStyle(state.lastError != nil ? c.error : c.secondaryLabel).lineLimit(1)
                .shellTarget("conflict status")
            Button("Mark as Resolved") { Task { await editor.markResolved() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!state.canMarkResolved || editor.isLoading)
                .shellTarget("conflict resolve")
            if state.showsIntegrationButtons {
                Button(state.continueTitle) { editor.continueIntegration() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!state.canContinue)
                    .shellTarget("conflict continue")
                Button(state.abortTitle) { editor.abortIntegration() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .shellTarget("conflict abort")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    func hunkBar(_ state: ConflictEditorState, _ c: ShellColors) -> some View {
        HStack(spacing: 6) {
            Button { editor.previousHunk() } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.hasHunks ? c.label : c.tertiaryLabel).frame(width: 18, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.hasHunks)
            .help("Previous Change")
            .shellTarget("conflict previous")
            Text(verbatim: state.hunkLabel).font(ShellFonts.small.monospacedDigit()).foregroundStyle(c.secondaryLabel).lineLimit(1)
                .fixedSize()
                .frame(minWidth: 132)
                .shellTarget("conflict hunk")
            Button { editor.nextHunk() } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.hasHunks ? c.label : c.tertiaryLabel).frame(width: 18, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!state.hasHunks)
            .help("Next Change")
            .shellTarget("conflict next")
            ConflictSegments(titles: ConflictEditorState.choiceTitles, selected: state.selectedSegment, target: "conflict choice",
                             isEnabled: { state.isSegmentEnabled($0) }) { i in
                editor.chooseSegment(i)
            }
            Spacer(minLength: 8)
            if state.hasBase, state.document != nil {
                ConflictSegments(titles: ConflictEditorState.pairTitles, selected: state.pair.rawValue, target: "conflict pair",
                                 isEnabled: { _ in true }) { i in
                    editor.setPair(ConflictEditorState.Pair(rawValue: i) ?? .leftRight)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    func handEditor(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Edited Change").font(ShellFonts.small.weight(.semibold)).foregroundStyle(c.secondaryLabel)
            TextEditor(text: Binding(get: { editor.editedText }, set: { editor.editedText = $0 }))
                .font(Font.system(size: 12, design: .monospaced))
                .frame(height: 84)
                .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                .shellTarget("conflict hand editor")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// The two versions compared, side by side with line numbers: removed and
/// changed lines tinted on the older side, added and changed on the newer.
struct ConflictComparisonView: View {
    var state: ConflictEditorState
    var colors: ShellColors

    var body: some View {
        let c = colors
        let cmp = state.comparison
        let rows = state.comparisonRows
        let start = state.comparisonRow(in: rows)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                title(cmp.oldTitle, c).shellTarget("conflict left title")
                Rectangle().fill(c.separator).frame(width: 1)
                title(cmp.newTitle, c).shellTarget("conflict right title")
            }
            .frame(height: 22)
            Hairline(color: c.separator)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                            HStack(spacing: 0) {
                                side(pair.element.left, tint: leftTint(pair.element.kind), c)
                                Rectangle().fill(c.separator).frame(width: 1)
                                side(pair.element.right, tint: rightTint(pair.element.kind), c)
                            }
                            .frame(height: 16)
                            .id(pair.offset)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .task(id: "\(state.currentFile ?? "")#\(state.currentHunk ?? -1)#\(state.pair.rawValue)") {
                    if let start { proxy.scrollTo(max(0, start - 3), anchor: .top) }
                }
            }
            .shellTarget("conflict comparison")
        }
    }

    func title(_ t: String, _ c: ShellColors) -> some View {
        Text(verbatim: t).font(ShellFonts.small.weight(.semibold)).foregroundStyle(c.secondaryLabel).lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func leftTint(_ k: LineDiff.Row.Kind) -> Color {
        switch k {
        case .removed, .changed: Color.red.opacity(0.14)
        default: Color.clear
        }
    }

    func rightTint(_ k: LineDiff.Row.Kind) -> Color {
        switch k {
        case .added, .changed: Color.green.opacity(0.14)
        default: Color.clear
        }
    }

    func side(_ line: (number: Int, text: String)?, tint: Color, _ c: ShellColors) -> some View {
        let mono = Font.system(size: 11, design: .monospaced)
        return HStack(spacing: 0) {
            Text(verbatim: line.map { String($0.number) } ?? "").font(mono).foregroundStyle(c.tertiaryLabel)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 8)
            Text(verbatim: line?.text.replacingOccurrences(of: "\t", with: "    ") ?? "").font(mono).foregroundStyle(c.label).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line == nil ? c.separator.opacity(0.35) : tint)
    }
}

/// The merged result, read-only: each change tinted, the selected one
/// darker; clicking a change's line selects it.
struct ConflictResultView: View {
    var editor: ConflictEditorShellModel
    var colors: ShellColors

    var body: some View {
        let c = colors
        let state = editor.state
        let lines = state.resultLines
        VStack(alignment: .leading, spacing: 0) {
            Text("Result").font(ShellFonts.small.weight(.semibold)).foregroundStyle(c.secondaryLabel)
                .padding(.horizontal, 12)
                .frame(height: 22)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                            row(pair.offset, pair.element, c)
                                .id(pair.offset)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .task(id: "\(state.currentFile ?? "")#\(state.currentHunk ?? -1)") {
                    if let l = state.resultStartLine { proxy.scrollTo(max(0, l - 2), anchor: .top) }
                }
            }
            .shellTarget("conflict result")
        }
    }

    func row(_ i: Int, _ line: ConflictEditorState.ResultLine, _ c: ShellColors) -> some View {
        let mono = Font.system(size: 11, design: .monospaced)
        let base: Color = line.tint == .unresolved ? Color.red : Color.green
        let tint = line.tint == .none ? Color.clear : base.opacity(line.isSelected ? 0.28 : 0.12)
        return HStack(spacing: 0) {
            Text(verbatim: String(i + 1)).font(mono).foregroundStyle(c.tertiaryLabel)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 8)
            Text(verbatim: line.text.replacingOccurrences(of: "\t", with: "    ")).font(mono).foregroundStyle(c.label).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 16)
        .background(tint)
        .contentShape(Rectangle())
        .onTapGesture { if let h = line.hunk { editor.selectHunk(h) } }
    }
}

/// A capsule of text segments sized to their titles (the choice and pair
/// controls), so all six choices fit beside the pair control.
struct ConflictSegments: View {
    var titles: [String]
    var selected: Int?
    var target: String
    var isEnabled: (Int) -> Bool
    var select: (Int) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { pair in
                let on = pair.offset == selected
                let enabled = isEnabled(pair.offset)
                Button { select(pair.offset) } label: {
                    Text(verbatim: pair.element)
                        .font(on ? ShellFonts.small.weight(.semibold) : ShellFonts.small)
                        .foregroundStyle(enabled ? c.label : c.tertiaryLabel)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background {
                            if on { Capsule(style: .continuous).fill(c.selectorPill) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .shellTarget("\(target) \(pair.offset)")
            }
        }
        .padding(2)
        .background { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
        .fixedSize()
    }
}
