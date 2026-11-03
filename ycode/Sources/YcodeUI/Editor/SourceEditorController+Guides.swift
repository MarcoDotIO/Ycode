import AppKit
import YcodeIDECore

/// Editor ▸ Scope Guides and Editor ▸ Invisibles (`specs/ide/source-editor.md`,
/// "Ycode implementation"): drawn under the text from the structure model
/// and the laid-out line fragments.
extension SourceEditorController {
    /// Recomputes the scope guides' blocks (with the folds: after typing
    /// pauses in large files).
    func updateScopeGuides() {
        guard Preferences.shared.scopeGuides != .none, fileURL != nil else {
            if !syntax.scopeBlocks.isEmpty { syntax.scopeBlocks = [] }
            return
        }
        syntax.scopeBlocks = syntaxDocument.blocks().filter { $0.endLine - $0.startLine >= 2 }
        textView.needsDisplay = true
    }

    /// The blocks the scope guides draw (0-based lines; tests).
    public var scopeGuideBlocks: [SyntaxBlock] { syntax.scopeBlocks }
}

extension SourceTextView {
    func drawEditorGuides(in rect: NSRect) {
        let p = Preferences.shared
        if p.scopeGuides != .none, let blocks = owner?.syntax.scopeBlocks, !blocks.isEmpty { drawScopeGuides(blocks, in: rect) }
        if p.showInvisibles { drawInvisibles(in: rect) }
    }

    /// A thin vertical line from below each block's first line to above
    /// its last, at the column where the first line's text starts.
    func drawScopeGuides(_ blocks: [SyntaxBlock], in rect: NSRect) {
        let width = ("0" as NSString).size(withAttributes: [.font: Theme.font]).width
        let x0 = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let ns = string as NSString
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        for b in blocks {
            // LineIndex lines are 1-based.
            guard let top = lineRect(b.startLine + 1), let bottom = lineRect(b.endLine + 1) else { continue }
            let guide = NSRect(x: 0, y: top.maxY, width: 1, height: bottom.minY - top.maxY)
            guard guide.height > 0, guide.minY < rect.maxY, guide.maxY > rect.minY else { continue }
            guard let r = lineIndex.range(ofLine: b.startLine + 1) else { continue }
            var col = 0
            var i = r.location
            while i < NSMaxRange(r), ns.character(at: i) == 32 || ns.character(at: i) == 9 {
                col = ns.character(at: i) == 9 ? (col / Preferences.shared.tabWidth + 1) * Preferences.shared.tabWidth : col + 1
                i += 1
            }
            NSRect(x: x0 + width * CGFloat(col) + width * 0.5, y: guide.minY, width: 1, height: guide.height).intersection(rect).fill()
        }
    }

    /// `·` for spaces, `→` for tabs, `¬` at line ends, in the visible lines.
    func drawInvisibles(in rect: NSRect) {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let viewport = tlm.textViewportLayoutController.viewportRange else { return }
        let ns = string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: NSColor.tertiaryLabelColor]
        let marks: [UInt16: NSString] = [32: "·", 9: "→", 10: "¬"]
        tlm.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresLayout]) { frag in
            let start = tcm.offset(from: tcm.documentRange.location, to: frag.rangeInElement.location)
            let origin = frag.layoutFragmentFrame.origin
            if origin.y + textContainerOrigin.y > rect.maxY { return false }
            for line in frag.textLineFragments {
                let r = line.characterRange
                for k in r.location..<NSMaxRange(r) {
                    let o = start + k
                    guard o < ns.length, let mark = marks[ns.character(at: o)] else { continue }
                    let p = line.locationForCharacter(at: k)
                    let b = line.typographicBounds
                    mark.draw(at: NSPoint(x: origin.x + b.minX + p.x + textContainerOrigin.x, y: origin.y + b.minY + textContainerOrigin.y), withAttributes: attrs)
                }
            }
            return tcm.offset(from: tcm.documentRange.location, to: frag.rangeInElement.endLocation) < tcm.offset(from: tcm.documentRange.location, to: viewport.endLocation)
        }
    }
}
