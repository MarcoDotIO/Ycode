import Foundation
import Testing
import YcodeIDECore

/// Settings ▸ Accounts (`specs/ide/settings.md` §Accounts), the part both
/// IDEs share: the texts, the empty list, the App Store Connect key seam
/// and where the page sits in the pane order. Runs on macOS and Linux.
@Suite struct AccountsPageTests {
    @Test func explanationSaysYcodeNeverHandlesPasswords() {
        for keychain in [true, false] {
            let text = AccountsPage.explanation(keychain: keychain)
            #expect(text.hasPrefix("Ycode does not sign in to accounts."))
            #expect(text.hasSuffix("Ycode never asks for or stores passwords."))
        }
        #expect(AccountsPage.explanation(keychain: true).contains("identities already in your keychain"))
        #expect(AccountsPage.explanation(keychain: false).contains("identities Ycode finds on this computer"))
        #if os(Linux)
        #expect(!AccountsPage.explanation.contains("keychain"))
        #else
        #expect(AccountsPage.explanation.contains("keychain"))
        #endif
    }

    @Test func pageTexts() {
        #expect(AccountsPage.title == "Accounts")
        #expect(AccountsPage.emptyText == "No Accounts")
        #expect(AccountsPage.sheetTitle == "Accounts Are Not Supported")
    }

    @Test func listIsEmptyUntilKeysExist() {
        #expect(NoAppStoreConnectKeys().keys().isEmpty)
        #expect(AccountsPage.rows(from: NoAppStoreConnectKeys()).isEmpty)
    }

    /// The seam for #43: a store with a key gives one row naming its key ID;
    /// the key file is only a path.
    @Test func keyStoreSeam() throws {
        struct OneKey: AppStoreConnectKeyStore {
            func keys() -> [AppStoreConnectAPIKey] {
                [AppStoreConnectAPIKey(keyID: "ABC123DEFG", issuerID: "00000000-0000-0000-0000-000000000000",
                                       keyFile: URL(fileURLWithPath: "/keys/AuthKey_ABC123DEFG.p8"))]
            }
        }
        #expect(AccountsPage.rows(from: OneKey()) == [AccountsPage.Row(title: "App Store Connect API Key", detail: "ABC123DEFG")])
        let key = OneKey().keys()[0]
        let decoded = try JSONDecoder().decode(AppStoreConnectAPIKey.self, from: JSONEncoder().encode(key))
        #expect(decoded == key)
    }

    @Test func paneOrder() {
        #expect(SettingsPaneOrder.all.count == 13)
        #expect(Array(SettingsPaneOrder.all.prefix(4)) == ["General", "Appearance", "Accounts", "Coding Assistant"])
        #expect(SettingsPaneOrder.linux == ["General", "Appearance", "Accounts", "Coding Assistant", "Behaviors", "Navigation",
                                            "Notifications", "Editing", "Shortcuts", "Source Control", "Locations"])
    }
}
