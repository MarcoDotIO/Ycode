import Foundation

/// Settings ▸ Accounts (`specs/ide/settings.md` §Accounts), shared by the
/// macOS IDE (`AccountsSettingsPane` in YcodeUI) and the Linux IDE
/// (`ycode-ide`'s `SettingsPaneAccounts.swift`): an account list, empty
/// today, and +, which explains that Ycode does not sign in. Ycode never
/// asks for or stores passwords, and this page stores nothing.
public enum AccountsPage {
    public static let title = "Accounts"
    /// Shown beside the list while it is empty.
    public static let emptyText = "No Accounts"
    /// The + button's accessibility label.
    public static let addLabel = "Add account"
    /// The sheet + shows.
    public static let sheetTitle = "Accounts Are Not Supported"

    /// The sheet's text. On macOS signing uses the keychain's identities; on
    /// Linux there is no keychain, so the identities are the ones Ycode
    /// finds on the computer (certificate and key files the user keeps,
    /// `specs/ide/signing.md` §8).
    public static func explanation(keychain: Bool) -> String {
        let source = keychain ? "identities already in your keychain" : "identities Ycode finds on this computer"
        return "Ycode does not sign in to accounts. Signing uses \(source); Ycode never asks for or stores passwords."
    }

    /// The explanation for the platform Ycode runs on.
    public static var explanation: String {
        #if os(macOS)
        explanation(keychain: true)
        #else
        explanation(keychain: false)
        #endif
    }

    /// One row of the account list.
    public struct Row: Hashable, Sendable {
        public var title: String
        public var detail: String

        public init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    /// The list's rows: one per App Store Connect API key the store knows.
    /// Ycode stores none yet, so with `NoAppStoreConnectKeys` (the only
    /// store today) the list is empty.
    public static func rows(from store: any AppStoreConnectKeyStore) -> [Row] {
        store.keys().map { Row(title: "App Store Connect API Key", detail: $0.keyID) }
    }
}

/// An App Store Connect API key (Apple's public App Store Connect REST API),
/// the one kind of account Ycode plans to list (issue #43: automatic
/// profiles and notarization). The private key (`.p8`) stays where the user
/// keeps it: Ycode records only its path, the key ID and the issuer ID.
/// Where a secret is needed it goes to the system's secret store (the
/// keychain on macOS, the Secret Service on Linux), never to the user
/// defaults or a project.
public struct AppStoreConnectAPIKey: Hashable, Sendable, Codable {
    /// The key's ID (10 characters, as App Store Connect shows it).
    public var keyID: String
    /// The issuer ID (a UUID) of the team that owns the key.
    public var issuerID: String
    /// The `.p8` file, where the user keeps it.
    public var keyFile: URL

    public init(keyID: String, issuerID: String, keyFile: URL) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.keyFile = keyFile
    }
}

/// Where the Accounts page reads App Store Connect API keys from. The seam
/// for issue #43: adding and removing keys (and their UI) comes with it.
public protocol AppStoreConnectKeyStore: Sendable {
    /// The keys, in the order the list shows them.
    func keys() -> [AppStoreConnectAPIKey]
}

/// The store Ycode uses until #43: no keys, nothing read or written.
public struct NoAppStoreConnectKeys: AppStoreConnectKeyStore {
    public init() {}
    public func keys() -> [AppStoreConnectAPIKey] { [] }
}

/// The Settings window's panes in order (`specs/ide/settings.md` §Window).
public enum SettingsPaneOrder {
    /// The sidebar's panes: the reference's twelve in its order (Ycode's
    /// names for Accounts and Coding Assistant). At most twelve rows fit
    /// the window with no scroller (council round 4, R4.2).
    public static let all = ["General", "Appearance", "Accounts", "Coding Assistant", "Behaviors", "Navigation", "Notifications",
                             "Editing", "Shortcuts", "Source Control", "Components", "Locations"]
    /// Pages with no sidebar row, and the pane that leads to each: Ycode's
    /// own Simulators page (macOS only) is a navigation row of Components,
    /// next to the simulator runtimes it runs (R4.2).
    public static let subPages = ["Simulators": "Components"]
    /// The pages the Linux IDE does not offer.
    public static let notOnLinux: Set = ["Simulators"]
    /// The Linux IDE's panes: the same order.
    public static var linux: [String] { all.filter { !notOnLinux.contains($0) } }
}
