import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The merge sheet (`specs/ide/merge-sheet.md` §2–§9), drawn from the
/// core's `ConflictEditorState` as the AppKit `MergeSheetController` draws
/// it: white, corner radius 16, a soft shadow; one bordered content box 20
/// inside its sides and 11.5 below its top holding the file list (198), the
/// jump bar over both panes, the two aligned panes with the gutter between
/// them and the ruler, and the footer row with the change stepper; then
/// Cancel and Merge, 84 wide, 12 apart, 21.5 below the box.
struct MergeSheetView: View {
    var scm: SourceControlShellModel
    var editor: ConflictEditorShellModel
    /// The sheet is going away: its buttons do nothing more.
    var isClosing: Bool
    @Environment(\.colorScheme) private var scheme

    typealias M = MergeSheetMetrics

    var body: some View {
        let p = MergeSheetPalette.forDark(scheme == .dark)
        let state = editor.state
        GeometryReader { geo in
            let box = M.contentBox(sheet: (Double(geo.size.width), Double(geo.size.height)))
            let mergeWidth = max(CGFloat(M.buttonWidth), CGFloat(state.primaryTitle.count) * 7.5 + 28)
            let buttonY = CGFloat(box.maxY + M.buttonGap)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: CGFloat(M.cornerRadius), style: .continuous)
                    .fill(Color(mergeHex: p.sheet))
                    .shadow(color: Color.black.opacity(scheme == .dark ? 0.55 : 0.28), radius: 16, x: 0, y: 8)
                MergeContentBox(scm: scm, editor: editor, palette: p, width: CGFloat(box.width), height: CGFloat(box.height))
                    .frame(width: CGFloat(box.width), height: CGFloat(box.height))
                    .offset(x: CGFloat(box.x), y: CGFloat(box.y))
                Button { if !isClosing { scm.cancelMerge() } } label: {
                    MergeButtonLabel(title: MergeSheetText.cancel, isDefault: false, palette: p,
                                     width: CGFloat(M.buttonWidth), height: CGFloat(M.buttonHeight))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .offset(x: CGFloat(box.maxX) - mergeWidth - CGFloat(M.buttonSpacing + M.buttonWidth), y: buttonY)
                .shellTarget("merge cancel")
                Button { if !isClosing { Task { await scm.completeMerge() } } } label: {
                    MergeButtonLabel(title: state.primaryTitle, isDefault: state.canMerge, isEnabled: state.canMerge && !editor.isLoading,
                                     palette: p, width: mergeWidth, height: CGFloat(M.buttonHeight))
                }
                .buttonStyle(.plain)
                .disabled(!state.canMerge)
                .keyboardShortcut(.defaultAction)
                .offset(x: CGFloat(box.maxX) - mergeWidth, y: buttonY)
                .shellTarget("merge merge")
                if let error = state.lastError {
                    Text(verbatim: error).font(.system(size: 11)).foregroundStyle(Color(mergeHex: p.badgeLetter)).lineLimit(1)
                        .frame(width: max(0, CGFloat(box.width) - mergeWidth - CGFloat(M.buttonWidth + M.buttonSpacing) - 12), alignment: .leading)
                        .offset(x: CGFloat(box.x), y: buttonY + 4)
                        .shellTarget("merge error")
                }
            }
        }
        .shellTarget("merge sheet")
    }
}

/// The bordered box (§2): a 1-point #BFBFBF border and square corners; the
/// file list, a 1-point rule, then the jump bar, the panes and the footer.
struct MergeContentBox: View {
    var scm: SourceControlShellModel
    var editor: ConflictEditorShellModel
    var palette: MergeSheetPalette
    var width: CGFloat
    var height: CGFloat

    typealias M = MergeSheetMetrics

    var body: some View {
        let p = palette
        let c = M.columns(boxWidth: Double(width))
        let left = CGFloat(c.left.start), span = CGFloat(c.right.end - c.left.start)
        let jumpH = CGFloat(M.jumpBarHeight) + 1, footerH = CGFloat(M.footerHeight) + 1
        let paneTop = 1 + jumpH, paneH = max(0, height - 1 - footerH - paneTop)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(mergeHex: p.boxBorder))
            Rectangle().fill(Color(mergeHex: p.sheet)).frame(width: width - 2, height: height - 2).offset(x: 1, y: 1)
            MergeFileList(editor: editor, palette: p)
                .frame(width: CGFloat(c.fileList.length), height: height - 2)
                .offset(x: CGFloat(c.fileList.start), y: 1)
            Rectangle().fill(Color(mergeHex: p.columnRule)).frame(width: 1, height: height - 2)
                .offset(x: CGFloat(c.fileList.end), y: 1)
            MergeJumpBar(editor: editor, palette: p, gutterX: CGFloat(c.gutter.start) - left)
                .frame(width: span, height: jumpH)
                .offset(x: left, y: 1)
            if editor.state.document != nil {
                MergeComparisonView(editor: editor, palette: p, leftWidth: CGFloat(c.left.length), rightWidth: CGFloat(c.rightText.length),
                                    height: paneH)
                    .frame(width: span, height: paneH)
                    .offset(x: left, y: paneTop)
            } else {
                Text(verbatim: editor.state.files.isEmpty && !editor.isLoading ? MergeSheetText.noEditor : MergeSheetText.loading)
                    .font(.system(size: 15)).foregroundStyle(Color(mergeHex: p.secondaryLabel))
                    .frame(width: span, height: paneH)
                    .offset(x: left, y: paneTop)
            }
            MergeFooter(editor: editor, palette: p, gutterX: CGFloat(c.gutter.start) - left, rightX: CGFloat(c.right.start) - left)
                .frame(width: span, height: footerH)
                .offset(x: left, y: height - 1 - footerH)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// Ycode's own glyphs for the sheet (no system artwork): a Swift file's
/// orange, a folder's blue.
enum MergeGlyphs {
    static let swiftOrange: UInt32 = 0xF26B33

    static func fileTint(_ name: String, _ p: MergeSheetPalette) -> UInt32 {
        URL(fileURLWithPath: name).pathExtension == "swift" ? swiftOrange : p.accent
    }
}

/// A small right-pointing chevron, the path separator (§4.1, §8).
struct MergePathSeparator: View {
    var color: Color

    var body: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 3, y: 3.5))
            path.addLine(to: CGPoint(x: 0, y: 7))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        .frame(width: 3, height: 7)
    }
}

// MARK: - File list (§3)

/// "Hierarchical | Flat", 24-point rows with a flush full-width selection
/// (#0064E1), the red "C" badge in a white square, and the Filter field at
/// the bottom. A file row's context menu has Mark as Resolved (Ycode's
/// choice).
struct MergeFileList: View {
    @Bindable var editor: ConflictEditorShellModel
    var palette: MergeSheetPalette

    typealias M = MergeSheetMetrics

    var body: some View {
        let p = palette
        let rows = editor.fileRows
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                segment(MergeSheetText.hierarchical, width: 74.5, on: !editor.isFlat) { editor.isFlat = false }
                segment(MergeSheetText.flat, width: 40.5, on: editor.isFlat) { editor.isFlat = true }
            }
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(M.fileListHeader))
            Rectangle().fill(Color(mergeHex: p.bandRule)).frame(height: 1)
            if rows.isEmpty, editor.state.files.isEmpty, editor.isLoading {
                Text(verbatim: MergeSheetText.loading).font(.system(size: 12)).foregroundStyle(Color(mergeHex: p.secondaryLabel))
                    .padding(.leading, 12).padding(.top, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                        row(pair.element, p)
                    }
                }
            }
            .scrollIndicators(.hidden)
            filter(p)
        }
        .shellTarget("merge files")
    }

    func segment(_ title: String, width: CGFloat, on: Bool, action: @escaping () -> Void) -> some View {
        let p = palette
        return Button(action: action) {
            Text(verbatim: title).font(.system(size: 11))
                .foregroundStyle(Color(mergeHex: on ? p.accent : p.label))
                .frame(width: width, height: CGFloat(M.segmentHeight))
                .background { if on { Capsule(style: .continuous).fill(Color(mergeHex: p.segmentPill)) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shellTarget("merge \(title.lowercased())")
    }

    func row(_ r: ConflictEditorState.FileRow, _ p: MergeSheetPalette) -> some View {
        let selected = r.path != nil && r.path == editor.state.currentFile
        let ink = selected ? Color.white : Color(mergeHex: p.label)
        let indent = CGFloat(r.depth) * 15
        return HStack(spacing: 0) {
            if r.kind == .folder {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color(mergeHex: p.secondaryLabel))
                    .frame(width: 15)
                Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(selected ? Color.white : Color(mergeHex: p.folder))
                    .frame(width: 16)
                    .padding(.leading, 1)
                Text(verbatim: r.title).font(.system(size: 13)).foregroundStyle(ink).lineLimit(1)
                    .padding(.leading, 5)
            } else {
                Image(systemName: WorkspaceChrome.fileSymbol(r.title)).font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white : Color(mergeHex: MergeGlyphs.fileTint(r.title, p)))
                    .frame(width: 14.5)
                    .padding(.leading, CGFloat(M.fileIconX) - 15 + indent)
                Text(verbatim: r.title).font(.system(size: 13)).foregroundStyle(ink).lineLimit(1)
                    .padding(.leading, CGFloat(M.fileNameX - M.fileIconX) - 14.5)
            }
            Spacer(minLength: 4)
            if r.isConflicted {
                Text(verbatim: "C").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(mergeHex: p.badgeLetter))
                    .frame(width: CGFloat(M.badgeSize), height: CGFloat(M.badgeSize))
                    .background { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(mergeHex: p.badge)) }
                    .padding(.trailing, CGFloat(M.badgeTrailing))
            }
        }
        .frame(height: CGFloat(M.fileRowHeight))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if selected { Rectangle().fill(Color(mergeHex: p.selection)) } }
        .contentShape(Rectangle())
        .onTapGesture { if let path = r.path { editor.showFile(path) } }
        .contextMenu {
            if let path = r.path {
                Button("Mark as Resolved") {
                    Task {
                        await editor.show(file: path)
                        await editor.markResolved()
                    }
                }
                .disabled(!editor.state.isDecided(file: path))
            }
        }
        .shellTarget("merge file \(r.title)")
    }

    func filter(_ p: MergeSheetPalette) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 12)).foregroundStyle(Color(mergeHex: p.filterPlaceholder))
                .frame(width: 13)
            TextField(MergeSheetText.filter, text: $editor.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .shellTarget("merge filter")
        }
        .padding(.leading, 4.5)
        .padding(.trailing, 6)
        .frame(height: CGFloat(M.filterHeight))
        .background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(mergeHex: p.filterFill)) }
        .padding(.horizontal, 5.5)
        .padding(.bottom, CGFloat(M.filterBottom))
        .padding(.top, 4)
    }
}

// MARK: - Jump bar (§4.1)

/// One bar over both panes: the grid symbol, a divider, back and forward,
/// the path to the file and "No Selection"; at the right end, over the
/// right pane, the conflict navigator (previous, the conflict mark, next).
struct MergeJumpBar: View {
    var editor: ConflictEditorShellModel
    var palette: MergeSheetPalette
    var gutterX: CGFloat

    var body: some View {
        let p = palette
        let ink = Color(mergeHex: p.secondaryLabel), label = Color(mergeHex: p.label)
        let path = editor.jumpPath
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 11)).foregroundStyle(ink).frame(width: 13)
                        .padding(.leading, 13)
                    Rectangle().fill(Color(mergeHex: p.columnRule)).frame(width: 1, height: 16).padding(.leading, 9)
                    Image(systemName: "chevron.left").font(.system(size: 10)).foregroundStyle(ink).frame(width: 6.5).padding(.leading, 8.5)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(ink).frame(width: 6.5).padding(.leading, 13)
                    HStack(spacing: 6) {
                        ForEach(Array(path.enumerated()), id: \.offset) { pair in
                            let i = pair.offset
                            let symbol = i == 0 ? (editor.isPackage ? "shippingbox" : "folder.badge.gearshape")
                                : i == path.count - 1 ? WorkspaceChrome.fileSymbol(editor.state.currentFile ?? "") : "folder.fill"
                            let tint: UInt32 = i == 0 ? p.accent : i == path.count - 1 ? MergeGlyphs.fileTint(editor.state.currentFile ?? "", p) : p.folder
                            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Color(mergeHex: tint))
                            Text(verbatim: pair.element).font(.system(size: 12)).foregroundStyle(label).lineLimit(1)
                            MergePathSeparator(color: ink)
                        }
                        if !path.isEmpty {
                            Text(verbatim: MergeSheetText.noSelection).font(.system(size: 12)).foregroundStyle(label).lineLimit(1)
                        }
                    }
                    .padding(.leading, 11.5)
                    Spacer(minLength: 0)
                }
                // The conflict navigator, ending 16 before the box's edge.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Button { editor.previousHunk() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 10)).foregroundStyle(ink).frame(width: 14, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Previous Conflict")
                    .shellTarget("merge navigator previous")
                    ZStack {
                        Circle().fill(Color(mergeHex: p.badgeLetter))
                        Image(systemName: "xmark").font(.system(size: 6, weight: .bold)).foregroundStyle(Color.white)
                    }
                    .frame(width: 11, height: 11)
                    .padding(.horizontal, 2)
                    Button { editor.nextHunk() } label: {
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(ink).frame(width: 14, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Next Conflict")
                    .shellTarget("merge navigator next")
                }
                .padding(.trailing, 12)
            }
            .frame(height: CGFloat(MergeSheetMetrics.jumpBarHeight))
            Rectangle().fill(Color(mergeHex: p.bandRule)).frame(height: 1)
        }
        .background(Color(mergeHex: p.sheet))
        .shellTarget("merge jump bar")
    }
}

// MARK: - Footer (§8)

/// The row under both panes: each side's repository › branch › date,
/// author, short hash ("(HEAD)" on the left), and "‹ n/m ›" centred on the
/// gutter.
struct MergeFooter: View {
    var editor: ConflictEditorShellModel
    var palette: MergeSheetPalette
    var gutterX: CGFloat
    var rightX: CGFloat

    var body: some View {
        let p = palette
        let state = editor.state
        let label = Color(mergeHex: p.label), ink = Color(mergeHex: p.secondaryLabel)
        let stepperX = gutterX + CGFloat(MergeSheetMetrics.gutterWidth) / 2 - CGFloat(MergeSheetMetrics.stepperWidth) / 2
        VStack(spacing: 0) {
            Rectangle().fill(Color(mergeHex: p.footerRule)).frame(height: 1)
            ZStack(alignment: .topLeading) {
                side(state.leftFooter, label, ink)
                    .frame(width: max(0, stepperX - CGFloat(MergeSheetMetrics.footerTextX) - 4), alignment: .leading)
                    .offset(x: CGFloat(MergeSheetMetrics.footerTextX))
                    .shellTarget("merge footer left")
                HStack(spacing: 0) {
                    Button { editor.previousHunk() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 9)).foregroundStyle(label).frame(width: 14, height: 27).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .shellTarget("merge stepper previous")
                    Text(verbatim: state.stepperText).font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(label)
                        .lineLimit(1)
                        .frame(width: CGFloat(MergeSheetMetrics.stepperWidth) - 28)
                        .shellTarget("merge stepper")
                    Button { editor.nextHunk() } label: {
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(label).frame(width: 14, height: 27).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .shellTarget("merge stepper next")
                }
                .frame(width: CGFloat(MergeSheetMetrics.stepperWidth), height: CGFloat(MergeSheetMetrics.footerHeight))
                .offset(x: stepperX)
                side(state.rightFooter, label, ink)
                    .offset(x: rightX + 21.5)
                    .shellTarget("merge footer right")
            }
            .frame(height: CGFloat(MergeSheetMetrics.footerHeight), alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
        }
        .background(Color(mergeHex: p.sheet))
    }

    func side(_ f: MergeSheetFooter?, _ label: Color, _ ink: Color) -> some View {
        HStack(spacing: 4) {
            if let f {
                Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(ink)
                Text(verbatim: f.repository).font(.system(size: 11.5)).foregroundStyle(label).lineLimit(1)
                MergePathSeparator(color: ink).padding(.horizontal, 2)
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(ink)
                Text(verbatim: f.branch).font(.system(size: 11.5)).foregroundStyle(label).lineLimit(1)
                MergePathSeparator(color: ink).padding(.horizontal, 2)
                Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(ink)
                Text(verbatim: f.commitText).font(.system(size: 11.5)).foregroundStyle(label).lineLimit(1)
            }
        }
        .frame(height: CGFloat(MergeSheetMetrics.footerHeight))
    }
}
