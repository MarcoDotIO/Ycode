import Foundation
import YcodeSubprocess
import Observation
import YcodeIDECore

/// What the app wants a person to read in an alert.
public struct ShellNotice: Equatable, Sendable {
    public var title: String
    public var message: String
    public init(_ title: String, _ message: String) {
        self.title = title
        self.message = message
    }
}

/// The Clone sheet of the Linux shell (Welcome ▸ Clone…, Integrate ▸ Clone…):
/// a repository address and the folder to clone into. `git clone` runs off the
/// main actor; the sheet stays up with a message until it ends.
@MainActor
@Observable
public final class CloneShellModel {
    public var address = ""
    /// The folder the clone's folder is made in.
    public var location: String
    public var isFolderDialogShown = false
    public private(set) var isRunning = false
    /// Why the last clone failed.
    public private(set) var error: String?

    /// The git program (tests pass another).
    @ObservationIgnored var git: String
    /// Called with the clone's folder when it succeeds.
    @ObservationIgnored var finished: (URL) -> Void = { _ in }

    public init(location: String? = nil, git: String = HostTool.path("git")) {
        self.git = git
        let home = FileManager.default.homeDirectoryForCurrentUser
        let developer = home.appendingPathComponent("Developer")
        self.location = location ?? (FileManager.default.fileExists(atPath: developer.path) ? developer : home).path
    }

    public var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var canClone: Bool { !trimmedAddress.isEmpty && !location.isEmpty && !isRunning }
    /// Where the clone goes.
    public var destination: URL {
        URL(fileURLWithPath: (location as NSString).expandingTildeInPath).appendingPathComponent(GitRepository.cloneFolderName(for: trimmedAddress))
    }

    /// Clones; on success `finished` gets the folder, on failure `error` says why.
    @discardableResult
    public func clone() -> Task<Void, Never> {
        guard canClone else { return Task {} }
        guard FileManager.default.isExecutableFile(atPath: git) else {
            error = "Git was not found at \(git). Install git, then try again."
            return Task {}
        }
        error = nil
        isRunning = true
        let address = trimmedAddress, destination = destination, git = git
        return Task { [weak self] in
            let failure: String? = await Task.detached {
                do { try GitRepository.clone(address, into: destination, git: git); return nil } catch { return error.localizedDescription }
            }.value
            guard let self else { return }
            self.isRunning = false
            if let failure { self.error = failure } else { self.finished(destination) }
        }
    }
}

extension ShellAppModel {
    /// Welcome ▸ Clone…, Integrate ▸ Clone….
    public func showClone() {
        let m = CloneShellModel()
        m.finished = { [weak self] folder in self?.cloneFinished(folder) }
        clone = m
    }

    public func cancelClone() { clone = nil }

    /// Opens what was cloned; a repository with nothing to open says so.
    func cloneFinished(_ folder: URL) {
        clone = nil
        if let w = Self.workspace(in: folder) {
            open(path: w.path)
        } else {
            notice = ShellNotice("Cloned \(folder.lastPathComponent)", "The repository is in \(folder.path). It has no project, workspace or Package.swift at its top level to open.")
        }
    }

    /// The workspace in a folder: a `.xcworkspace`, else a `.xcodeproj`, else
    /// the folder when it holds a `Package.swift`.
    static func workspace(in dir: URL) -> URL? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        if let w = names.first(where: { $0.hasSuffix(".xcworkspace") }) { return dir.appendingPathComponent(w) }
        if let p = names.first(where: { $0.hasSuffix(".xcodeproj") }) { return dir.appendingPathComponent(p) }
        return names.contains("Package.swift") ? dir : nil
    }

    /// Hands a link to the desktop; if nothing takes it, shows the address.
    public func openLink(_ url: URL) { openExternally(url) }

    public func linkCouldNotOpen(_ url: URL) {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        notice = ShellNotice("Open This Address in a Browser", "No web browser could be opened. The address is \(c?.string ?? url.absoluteString)")
    }

    /// The destination menu's row while no simulator host is paired.
    public func explainSimulator() {
        notice = ShellNotice("Ycode Simulator (\(ExperimentalNotice.label))", "\(ExperimentalNotice.simulator) Pair a host with `ycode sim remote pair`; its devices then show as run destinations.")
    }
}
