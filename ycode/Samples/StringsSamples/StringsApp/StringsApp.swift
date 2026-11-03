import SwiftUI

/// A sample with a String Catalog (Localizable.xcstrings): plain strings,
/// plurals, device variations, a substitution and a generated symbol
/// (STRING_CATALOG_GENERATE_SYMBOLS). It prints one line per language at
/// launch and shows the same strings. See specs/ide/string-catalog.md,
/// "Ycode implementation".
@main
struct StringsApp: App {
    init() {
        print("strings en: " + Self.line(bundle: .main, locale: Locale(identifier: "en")))
        if let path = Bundle.main.path(forResource: "de", ofType: "lproj"), let de = Bundle(path: path) {
            print("strings de: " + Self.line(bundle: de, locale: Locale(identifier: "de")))
        } else {
            print("strings de: no de.lproj")
        }
        print("strings symbol: " + String(localized: .welcomeTitle))
    }

    static func line(bundle: Bundle, locale: Locale) -> String {
        let one = 1, three = 3
        let name = "Ann"
        return [
            String(localized: "Hello, world!", bundle: bundle, locale: locale),
            String(localized: "\(one) files", bundle: bundle, locale: locale),
            String(localized: "\(three) files", bundle: bundle, locale: locale),
            String(localized: "\(name) shared \(three) photos", bundle: bundle, locale: locale),
            String(localized: "Tap to continue", bundle: bundle, locale: locale),
            String(localized: "Welcome title", bundle: bundle, locale: locale),
        ].joined(separator: " | ")
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text(.welcomeTitle).font(.title)
                Text("Hello, world!")
                Text("Tap to continue")
                Text(Self.line(bundle: .main, locale: .current)).font(.footnote)
            }
            .padding()
        }
    }
}
