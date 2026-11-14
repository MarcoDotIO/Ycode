import SwiftUI
import YcodeIDECore

/// The merge sheet's path (council round 10, row 240), as the main jump
/// bar draws its components and as the macOS sheet's `MergeJumpBarView`:
/// the project's Ycode mark in its 13-point slot, a group's folder, the
/// file's glyph, each name in 11-point type 6 after its icon's slot, the
/// main jump bar's 3 × 10 chevron 7 after a name, the next icon 9.5 after
/// it and "No Selection" 8.5 after the last.
struct MergePathComponents: View {
    var path: [String]
    /// The current file's name or path.
    var fileName: String
    var label: Color
    @Environment(\.colorScheme) private var scheme

    typealias L = JumpBarPathLayout

    var body: some View {
        let name = (fileName as NSString).lastPathComponent
        HStack(spacing: 0) {
            ForEach(Array(path.enumerated()), id: \.offset) { pair in
                let i = pair.offset
                let role = L.iconRole(index: i, count: path.count)
                let symbol = i == 0 ? "shippingbox" : i == path.count - 1 ? WorkspaceChrome.fileSymbol(name) : "folder.fill"
                let glyph = FileGlyphs.jumpBarGlyph(symbol: symbol, role: role, fileName: name)
                Group {
                    if glyph == .ycodeMark {
                        YcodeSmallMark(size: CGFloat(FileGlyphs.jumpBarBox(.ycodeMark).width))
                    } else if let g = glyph, let d = FileGlyphs.jumpBarDrawing(g) {
                        FileGlyphView(drawing: d, color: FileGlyphs.jumpBarGlyphTint(g, fileName: name)
                            .map { FileGlyphView.color($0, dark: scheme == .dark) } ?? ShellColors(scheme).accent)
                    } else {
                        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(ShellColors(scheme).accent)
                    }
                }
                .frame(width: CGFloat(L.iconSlot(role)))
                .shellTarget("merge path icon \(i)")
                Text(verbatim: pair.element).font(.system(size: 11)).foregroundStyle(label).lineLimit(1).fixedSize()
                    .padding(.leading, CGFloat(L.iconToTitle))
                    .shellTarget("merge path title \(i)")
                JumpBarChevron(active: true)
                    .padding(.leading, CGFloat(L.titleToChevron))
                    // From the 2-wide frame's end (the 3-wide ink takes its
                    // extra point from this gap, row 217).
                    .padding(.trailing, CGFloat(i == path.count - 1 ? L.chevronToTitle : L.chevronToIcon))
            }
            if !path.isEmpty {
                Text(verbatim: MergeSheetText.noSelection).font(.system(size: 11)).foregroundStyle(label).lineLimit(1).fixedSize()
            }
        }
    }
}
