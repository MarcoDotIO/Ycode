import Security
import SwiftUI

/// Uses the app's entitlements (specs/ide/signing.md §4): stores and reads
/// a keychain item in the shared keychain group and asks for the app
/// group's container. Prints one line for the run log, then shows it.
@main
struct KeychainGroupsApp: App {
    static let report: String = {
        let account = "ycode-signing-sample"
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.ycode.samples.signing",
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data("shared".utf8)
        let added = SecItemAdd(add as CFDictionary, nil)
        var query = base
        query[kSecReturnAttributes as String] = true
        var found: CFTypeRef?
        let read = SecItemCopyMatching(query as CFDictionary, &found)
        let group = (found as? [String: Any])?[kSecAttrAccessGroup as String] as? String ?? "-"
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.org.ycode.samples.signing")
        return "YCODE-SIGNING-SAMPLE keychain add=\(added) read=\(read) group=\(group) appGroupContainer=\(container == nil ? "none" : "yes")"
    }()

    init() { FileHandle.standardError.write(Data((Self.report + "\n").utf8)) }
    var body: some Scene {
        WindowGroup { Text(Self.report).padding() }
    }
}
