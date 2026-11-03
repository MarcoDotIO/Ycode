import AppKit
import YcodeIDECore

/// Editor ▸ Authors (⌃⇧⌘A): the gutter's blame column
/// (`specs/ide/source-control.md`, "Ycode implementation"). The blame is
/// read in the background on open, save and after an edit's pause; a read
/// that a later one replaced is dropped.
extension SourceEditorController {
    /// Whether this editor shows the Authors column.
    public var showsAuthors: Bool {
        get { gutter.showsAuthors }
        set {
            guard newValue != gutter.showsAuthors else { return }
            gutter.showsAuthors = newValue
            refreshBlame()
        }
    }

    /// The blame blocks shown (tests).
    public var authorBlocks: [GitBlame.Block] { gutter.authorBlocks }

    /// Re-reads the blame when the column is shown; clears it otherwise.
    func refreshBlame() {
        blameGeneration += 1
        guard gutter.showsAuthors, let url = fileURL, let load = blameLoader else {
            blameLoading = nil
            gutter.authorBlocks = []
            return
        }
        let generation = blameGeneration
        let contents = isDirty ? textView.string : nil
        blameLoading = Task { [weak self] in
            let commits = await load(url, contents)
            guard let self, generation == self.blameGeneration else { return }
            self.blameLoading = nil
            guard self.fileURL == url else { return }
            self.gutter.authorBlocks = commits.map(GitBlame.blocks) ?? []
        }
    }

    /// Waits for the blame read (tests).
    public func authorsIdle() async {
        while let t = blameLoading { await t.value }
    }
}
