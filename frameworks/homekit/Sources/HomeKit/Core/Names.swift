// Name rules for homes, rooms, zones, service groups, action sets, triggers,
// accessories and services (errors.md §1 codes 31–36, 60; plan.md HK-A01/A02).
//
// The exact rules are not observed yet (they need the account-enabled probes,
// plan.md §3). Ycode's reading, listed in the README:
//   * leading/trailing white space is trimmed before anything else;
//   * an empty name, or one whose first character is not a letter or digit: 36;
//   * a control, format or line-separator character anywhere: 35;
//   * a last character that is not a letter, digit or one of . ) ] ' " ! ? ’: 60;
//   * names compare case-, diacritic- and width-insensitively with runs of
//     white space collapsed ("similar" names, codes 31/32/33).

import Foundation

public enum YcodeNameRules {
    static let allowedLast: Set<Character> = [".", ")", "]", "'", "\"", "!", "?", "\u{2019}"]

    /// The trimmed name, or the name-validation error.
    public static func validate(_ name: String) -> Result<String, HMError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return .failure(HMError(.nameDoesNotStartWithValidCharacters)) }
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                || scalar.properties.generalCategory == .format {
                return .failure(HMError(.nameContainsProhibitedCharacters))
            }
        }
        if !(first.isLetter || first.isNumber) { return .failure(HMError(.nameDoesNotStartWithValidCharacters)) }
        let last = trimmed.last!
        if !(last.isLetter || last.isNumber || allowedLast.contains(last)) {
            return .failure(HMError(.nameDoesNotEndWithValidCharacters))
        }
        return .success(trimmed)
    }

    /// The comparison key for "similar" names.
    public static func key(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func similar(_ a: String, _ b: String) -> Bool { key(a) == key(b) }
}
