# Organizer and Product ▸ Archive

Ycode modules: `YcodeUI` (`Organizer`, `OrganizerController`), using
`YcodeXcodebuild` read-only through its public `Xcodebuild.run` (no API
changes).

## Archives

- Window ▸ Organizer (⌥⇧⌘O) opens the Organizer window on Archives.
- Archives: every `.xcarchive` directly in
  `~/Library/Developer/Xcode/Archives` or one of its subfolders (the
  dated `yyyy-MM-dd` folders of `specs/xcodebuild/archive.md` §3).
- Each archive is read from its `Info.plist`: `Name`, `SchemeName`,
  `CreationDate`, `Comment` (optional), and `ApplicationProperties`
  (`ApplicationPath`, `CFBundleShortVersionString`, `CFBundleVersion`,
  `CFBundleIdentifier`, `Architectures`). A folder without a readable
  `Info.plist` is skipped.
- List: grouped by application (the `ApplicationPath` file name without
  `.app`; archives without an application group under their `Name`),
  groups by name, archives newest first. Columns: Name, Creation Date,
  Version (`1.0 (7)`), Status.
- Details for the selection: Name, Creation Date, Version, Identifier,
  Type (`macOS App Archive` / `Generic Archive`), Architectures, Status,
  Comment (`No Description` when empty).
- Status: `Archived`; `Exported` after a successful Distribute App in
  this session (not stored).

## Distribute App

Enabled for archives with an application. Ycode offers one method, Copy
App (`mac-application`): a folder is chosen, an options plist
`{method = mac-application}` is written to a temporary file, and
ycodebuild's `-exportArchive -archivePath … -exportPath … -exportOptionsPlist …`
runs in-process; its output and exit status are kept. The result is the
application copied as `<exportPath>/<App>.app`
(`specs/xcodebuild/archive.md` §4).

## Product ▸ Archive

For a project or workspace with a scheme: runs ycodebuild's
`-project|-workspace <path> -scheme <scheme> archive` in-process (default
archive path), then opens the Organizer and selects the archive that
appeared. A failure (non-zero exit) becomes "Archive failed: <last output
line>" in the issue navigator. Not offered for packages.

## Evidence

- Archive bundle layout and `Info.plist` keys: `specs/xcodebuild/archive.md`
  (levels 2–3).
- Organizer layout, grouping by app, Distribute App flow: Apple's public
  documentation on distributing apps and the Organizer (level 1).
- OPEN QUESTION: whether the reference stores the comment as `Comment` in
  `Info.plist`; how status is recorded; the other distribution methods
  (App Store Connect, Developer ID, Direct Distribution); the archive
  icon; editing comments.
