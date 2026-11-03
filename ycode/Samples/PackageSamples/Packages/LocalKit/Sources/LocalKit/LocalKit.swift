import Foundation

/// A greeting read from the package's resource bundle (`Bundle.module`).
public enum LocalKit {
    public static var greeting: String {
        guard let url = Bundle.module.url(forResource: "greeting", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "missing resource" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
