import Foundation

/// What the File inspector shows about a file beyond its path: the git
/// working copy and the project's targets (`specs/ide/reference-ui-5.md` §7.3).
public struct FileInspectorInfo: Equatable {
    /// The repository's top-level folder, and the file's path inside it;
    /// nil outside git.
    public var workingCopy: String?
    public var relativePath: String?
    /// Every target with whether it includes the file (empty: no targets).
    public var memberships: [TargetMembership]
    /// The file sits inside a synchronized folder: its location is the
    /// folder's (reference-ui-6.md §6, I1).
    public var inSynchronizedFolder: Bool
    /// A file of a Swift package: only Identity and Type and Text Settings.
    public var isPackageFile: Bool
    public init(workingCopy: String? = nil, relativePath: String? = nil, memberships: [TargetMembership] = [],
                inSynchronizedFolder: Bool = false, isPackageFile: Bool = false) {
        self.workingCopy = workingCopy
        self.relativePath = relativePath
        self.memberships = memberships
        self.inSynchronizedFolder = inSynchronizedFolder
        self.isPackageFile = isPackageFile
    }
}
