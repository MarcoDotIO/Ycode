import Foundation

extension Preferences {
    /// The Find navigator's custom scopes (Custom Scopes…), for every
    /// workspace. See `specs/ide/navigators.md` §Find navigator, "Ycode
    /// implementation".
    public var findCustomScopes: [CustomFindScope] {
        get {
            guard let d = defaults.data(forKey: "Ycode.findCustomScopes"),
                  let s = try? JSONDecoder().decode([CustomFindScope].self, from: d) else { return [] }
            return s
        }
        set { set("findCustomScopes", try? JSONEncoder().encode(newValue)) }
    }
}
