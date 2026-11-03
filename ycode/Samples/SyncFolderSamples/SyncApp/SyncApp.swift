import Foundation

// A macOS app whose sources, asset catalog, string catalog, `.lproj` table,
// data file, whole-folder resource and copied extra all come from one
// synchronized folder. Run it to print what the bundle holds.
@main
struct SyncApp {
    static func main() {
        let bundle = Bundle.main
        func text(_ url: URL?) -> String {
            url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "missing"
        }
        let title = String(localized: "sync.title", bundle: bundle)
        let word = bundle.localizedString(forKey: "extra.word", value: "missing", table: "Extra")
        let note = text(bundle.url(forResource: "note", withExtension: "txt"))
        let docs = text(bundle.resourceURL?.appendingPathComponent("Docs/about.txt"))
        let extra = text(bundle.sharedSupportURL?.appendingPathComponent("extra.txt"))
        let assets = bundle.url(forResource: "Assets", withExtension: "car") != nil ? "compiled" : "missing"
        print("YCODE-SYNC-SAMPLE app: \(title); table: \(word); note: \(note); docs: \(docs); extra: \(extra); assets: \(assets)")
    }
}
