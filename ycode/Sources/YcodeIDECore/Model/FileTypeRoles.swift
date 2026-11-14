import Foundation
import YcodeProject

/// What a file's type decides outside its editor, shared by both IDEs
/// (council round 9, rows 228–230; `language.md` §Features,
/// `reference-ui-5.md` §7):
///
/// - only Swift and C-family sources go to the language service, so a
///   Markdown, JSON, property-list, text or image file never gets a
///   server diagnostic or adds to the issue counts (row 228);
/// - the File inspector's Type reads "Default - " and the type's name
///   (row 229);
/// - a resource (a file a target copies rather than compiles: Markdown,
///   JSON, an image) gets the "Tags" field and the Localization section
///   (row 230).
///
/// The type is the project file's recorded type for a file reference, else
/// the one its extension implies (`BuildFileTypes`, the vocabulary of
/// `lastKnownFileType`).
public enum FileTypeRoles {
    /// Extensions of Swift and C-family sources and headers.
    static let languageServiceExtensions: Set<String> = [
        "swift", "c", "h", "m", "mm", "cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++",
    ]

    /// Whether the language service gets this document (row 228).
    public static func usesLanguageService(_ url: URL) -> Bool {
        languageServiceExtensions.contains(url.pathExtension.lowercased())
    }

    /// The file's type: the recorded one when there is one, else by extension.
    public static func type(of url: URL, recorded: String? = nil) -> String {
        if let recorded, !recorded.isEmpty { return recorded }
        return BuildFileTypes.type(forPath: url.path)
    }

    /// Whether the file is a resource: in a synchronized folder it joins
    /// the target's resources phase (`BuildFileTypes.phase`), not its
    /// sources, headers or nothing (row 230). Folders that are not file
    /// wrappers and project files are never resources.
    public static func isResource(_ url: URL, recorded: String? = nil) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !["xcodeproj", "xcworkspace", "swiftpm"].contains(ext) else { return false }
        let t = type(of: url, recorded: recorded)
        return BuildFileTypes.phase(forType: t, path: url.path) == "resources"
    }

    /// The type's name after "Default - " in the File inspector's Type
    /// pop-up (row 229), or nil when Ycode has no name for it.
    public static func typeName(ofType type: String) -> String? {
        switch type {
        case "sourcecode.swift": "Swift Source"
        case "sourcecode.c.objc": "Objective-C Source"
        case "sourcecode.c.h": "C Header"
        case "sourcecode.c.c": "C Source"
        case "text.plist.xml": "Property List"
        case "text.xcconfig": "Configuration Settings File"
        case "image.png": "PNG Image"   // editor-area.md §C.6
        case "image.jpeg": "JPEG Image"
        case "image.gif": "GIF Image"
        case "image.tiff": "TIFF Image"
        case "image.heic": "HEIC Image"
        case "net.daringfireball.markdown": "Markdown"   // fidelity-council.md row 229
        case "text.json": "JSON"
        default: nil
        }
    }
}
