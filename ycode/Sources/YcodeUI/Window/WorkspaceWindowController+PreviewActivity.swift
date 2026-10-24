import AppKit
import YcodeBuild

/// What the activity view showed before a preview build's text.
struct PreviewActivityState {
    var text: String
    var savedStatus: String
    var savedBusy: Bool
    var generation: Int
}

/// The preview build's activity text, "Preparing <family> Simulator"
/// (`reference-ui-5.md` §11.6, P15).
extension WorkspaceWindowController {
    /// The device family a preview of a `platform` product uses: the run
    /// destination's when it is a simulator of that platform, else the
    /// first simulator of the platform in menu order. The family is the
    /// leading part of the simulator's name as the simulator list gives
    /// it; without a simulator, the platform's name. Nil for the Mac (no
    /// simulator is prepared).
    public static func previewFamily(platform: String?, destination: Destination?, simulators: [Destination]) -> String? {
        guard let platform, platform != "macOS" else { return nil }
        let sims = DestinationMenuModel.orderedSimulators(simulators.filter { $0.kind == .simulator && $0.platform == platform })
        let chosen = destination.flatMap { d in d.kind == .simulator && d.platform == platform ? d : nil } ?? sims.first
        return chosen.flatMap { family(ofDeviceNamed: $0.name) } ?? platform
    }

    /// The family part of a simulator name: the leading words before the
    /// first word with a digit or a model word ("Pro", "Max", "Air",
    /// "mini", "SE", "Ultra", "Series", "e"). "iPhone 17 Pro" → "iPhone";
    /// "Apple Vision Pro" → "Apple Vision".
    static func family(ofDeviceNamed name: String) -> String? {
        let model: Set<String> = ["Pro", "Max", "Air", "mini", "SE", "Ultra", "Series", "Plus", "e"]
        var words: [Substring] = []
        for w in name.split(separator: " ") {
            if w.contains(where: \.isNumber) || model.contains(String(w)) || w.hasPrefix("(") { break }
            words.append(w)
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The text a preview build shows in the activity view, or nil (a Mac
    /// or package product).
    public var previewActivityText: String? {
        guard session.model.kind != .package else { return nil }
        let simulators = session.model.destinationGroups.flatMap(\.destinations)
        return Self.previewFamily(platform: productPlatform.platform, destination: session.destination, simulators: simulators)
            .map { "Preparing \($0) Simulator" }
    }

    /// Shows the preview build's text unless a build or run already owns
    /// the activity view; returns the token `endPreviewActivity` takes.
    func beginPreviewActivity() -> Int? {
        guard let text = previewActivityText, !session.isBusy else { return nil }
        previewActivityGeneration += 1
        let g = previewActivityGeneration
        if var s = previewActivityState {
            s.text = text
            s.generation = g
            previewActivityState = s
        } else {
            previewActivityState = PreviewActivityState(text: text, savedStatus: activityView.status, savedBusy: activityView.isBusy, generation: g)
        }
        activityView.status = text
        activityView.isBusy = true
        return g
    }

    /// Puts back what the activity view showed, when the latest preview
    /// build ends and nothing else has replaced its text meanwhile.
    func endPreviewActivity(_ token: Int?) {
        guard let token, let s = previewActivityState, s.generation == token else { return }
        previewActivityState = nil
        guard activityView.status == s.text else { return }
        activityView.status = s.savedStatus
        activityView.isBusy = s.savedBusy || session.isBusy
    }
}
