import AppKit
import YcodeCompletion
import YcodeIDECore

/// What the activity view showed before predictive completion's notice.
struct PredictionActivityState {
    var text: String
    var savedStatus: String
}

/// Predictive completion in the workspace window
/// (specs/ide/predictive-completion.md §3.4): editors get the other open
/// files and workspace-relative paths; a backend that cannot be used is
/// named once, quietly, in the activity view (no alert), and the notice
/// goes when suggestions work again.
extension WorkspaceWindowController {
    func wirePrediction(_ e: SourceEditorController) {
        e.predictionOtherFiles = { [weak self, weak e] in
            guard let self else { return [] }
            return self.editorArea.allEditors.compactMap { o in
                guard o !== e, let u = o.fileURL else { return nil }
                return (path: u.path, text: o.text)
            }
        }
        e.predictionPath = { [weak self] url in
            guard let self else { return url.lastPathComponent }
            let root = Self.workspaceFolder(self.session.model.url).path + "/"
            return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.lastPathComponent
        }
        e.onPredictionStatus = { [weak self] s in self?.showPredictionStatus(s) }
    }

    /// The folder a workspace or project file sits in (a package's own folder).
    static func workspaceFolder(_ url: URL) -> URL {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isDir && !["xcodeproj", "xcworkspace"].contains(url.pathExtension) ? url : url.deletingLastPathComponent()
    }

    /// The activity text for a status, or nil (nothing to say).
    public static func predictionActivityText(_ s: PredictionSession.Status) -> String? {
        guard case .unavailable(let message, _) = s else { return nil }
        return "Predictive completion: \(message)"
    }

    func showPredictionStatus(_ s: PredictionSession.Status) {
        if let text = Self.predictionActivityText(s) {
            // A build, run or preview owns the activity view: say nothing.
            guard !session.isBusy, previewActivityState == nil else { return }
            if predictionActivity == nil { predictionActivity = PredictionActivityState(text: text, savedStatus: activityView.status) }
            predictionActivity?.text = text
            activityView.status = text
            if case .unavailable(_, let hint) = s { activityView.toolTip = hint }
        } else if case .requesting = s {
            return
        } else if let saved = predictionActivity {
            predictionActivity = nil
            if activityView.status == saved.text { activityView.status = saved.savedStatus }
            activityView.toolTip = nil
        }
    }

    /// The notice the activity view shows (tests).
    public var predictionActivityNotice: String? { predictionActivity?.text }
}
