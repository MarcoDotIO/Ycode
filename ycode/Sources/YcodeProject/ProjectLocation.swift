import Foundation

extension PBXProj {
    /// Resolves a path to an `.xcodeproj` bundle or the `project.pbxproj`
    /// inside it. Returns the pbxproj file URL and the project's name.
    public static func locate(_ path: String) -> (file: URL, projectName: String) {
        var url = URL(fileURLWithPath: path)
        if url.pathExtension == "xcodeproj" { url.appendPathComponent("project.pbxproj") }
        let bundle = url.deletingLastPathComponent()
        let name = bundle.pathExtension == "xcodeproj" ? bundle.deletingPathExtension().lastPathComponent : bundle.lastPathComponent
        return (url, name)
    }
}
