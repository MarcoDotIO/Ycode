# xcodebuild: archive and -exportArchive

Ycode: `YcodeXcodebuild` (`Archives`, `Plan.archiveLocations`), helper
`ycode-swb build` (`schemeCommand`, `debuggable`). Scope: macOS
application and command-line tool targets, signed ad hoc ("Sign to Run
Locally", `CODE_SIGN_IDENTITY = -`); export limited to ad hoc signing.

## 1. The archive action

Requires a scheme (without one, the reference tool runs an ordinary
build of the target with action `archive` into the project's `build`
folder and reports `ARCHIVE SUCCEEDED`; ycodebuild does the build the
same way but writes no archive). Targets: the scheme's build entries for
archiving; configuration: the `ArchiveAction` configuration (`Release` in
autocreated schemes). Destination: the generic "Any Mac", listed first in
the `Using the first of multiple matching destinations` warning (`{
platform:macOS, name:Any Mac }`, then My Mac per architecture); every
standard architecture is built (`ONLY_ACTIVE_ARCH` has no effect). The
build uses swift-build action `archive` with the scheme command `archive`
(which enables the archive validations, e.g. the macOS "No App Category"
warning) and signs without `com.apple.security.get-task-allow`.

## 2. Build locations

`<base>` = `<Build/Intermediates.noindex>/ArchiveIntermediates/<scheme>`.
Added for the archive action (also in `-showBuildSettings … archive`):

| Setting | Value |
|---|---|
| `DSTROOT` | `<base>/InstallationBuildProductsLocation` |
| `OBJROOT` | `<base>/IntermediateBuildFilesPath` |
| `SYMROOT` | `<base>/BuildProductsPath` |
| `SHARED_PRECOMPS_DIR` | `<base>/PrecompiledHeaders` |
| `ASSET_PACK_FOLDER_PATH` | `$(DSTROOT)/OnDemandResources` |
| `ASSETCATALOG_COMPILER_FLATTENED_APP_ICON_PATH` | `$(SYMROOT)/ProductIcon.png` |
| `MESSAGES_APPLICATION_EXTENSION_SUPPORT_FOLDER_PATH`, `MESSAGES_APPLICATION_SUPPORT_FOLDER_PATH`, `SIGNATURE_METADATA_FOLDER_PATH`, `SWIFT_STDLIB_TOOL_UNSIGNED_DESTINATION_DIR`, `WATCHKIT_2_SUPPORT_FOLDER_PATH` | `$(SYMROOT)/MessagesApplicationExtensionSupport`, `…/MessagesApplicationSupport`, `…/Signatures`, `…/SwiftSupport`, `…/WatchKitSupport2` |
| `ENABLE_SIGNATURE_AGGREGATION` | `YES` |
| `INDEX_ENABLE_DATA_STORE` | `NO` |

(The build system derives `DEPLOYMENT_LOCATION`/`DEPLOYMENT_POSTPROCESSING
= YES`, `INSTALL_DIR`, `TARGET_BUILD_DIR` under `DSTROOT`, `BUILT_PRODUCTS_DIR
= $(SYMROOT)/<configuration>` and the rest from these.)

## 3. The `.xcarchive` bundle

Path: `-archivePath` (made absolute; `.xcarchive` appended when missing),
else `~/Library/Developer/Xcode/Archives/<yyyy-MM-dd>/<scheme> <M-d-yy,
h.mm a>.xcarchive` (e.g. `Hello 10-16-26, 9.58 PM.xcarchive`). An existing
archive at the path is replaced.

    <name>.xcarchive/
        Info.plist
        Products/       the contents of DSTROOT (Applications/X.app, usr/local/bin/tool, …)
        dSYMs/          the *.dSYM bundles next to the built products (may be empty)

`Info.plist` (XML): `ArchiveVersion` (2), `CreationDate` (date), `Name`
(scheme name), `SchemeName`; for an archive holding an application under
`Products/Applications`, `ApplicationProperties`: `ApplicationPath`
(`Applications/X.app`), `Architectures` (from the executable's Mach-O
header, in file order, e.g. `[x86_64, arm64]`), `CFBundleIdentifier`,
`CFBundleShortVersionString`, `CFBundleVersion` (from the application's
`Info.plist`), `SigningIdentity` and `Team` (empty strings for ad hoc
signatures). Tool archives have no `ApplicationProperties`.

Log: the build log (`build-actions.md`), then (with `-resultBundlePath`)
`Result bundle written to path:` lines, then `** ARCHIVE SUCCEEDED **` and
a blank line. The result bundle records `archive.path` (`result-bundle.md`).

## 4. -exportArchive

`xcodebuild -exportArchive -archivePath <a> -exportPath <dir>
-exportOptionsPlist <plist>`. No "Command line invocation" header. Checks,
in order, each failure printing `** EXPORT FAILED **` and a blank line on
stdout and the error on stderr (`error: <message>` and a blank line):

| Situation | stderr message | Exit |
|---|---|---|
| `-archivePath`/`-exportOptionsPlist` missing | the `cli.md` §4 flag errors (`xcodebuild: error:` prefix, no banner) | 64 |
| archive does not exist | `error: archive not found at path '<path>'` (the prefix appears twice) | 65 |
| options plist unreadable | `Couldn't load -exportOptionsPlist <file>: <reason>.` | 70 |
| no `-exportPath` | `The flag -exportPath is required when specifying -exportArchive.` | 64 |
| archive without an application | `exportArchive: …` (the reference: a method error naming `mac-application`) | 70 |
| `method` other than `mac-application` (default `debugging`) and no team | `exportArchive No Team Found in Archive` | 70 |

With `method` = `mac-application` the application is copied to
`<exportPath>/<X>.app` unchanged (an ad hoc signed archive keeps its
signature: the reference export is byte-identical). `signingCertificate`
`-` with `signingStyle` `manual` gives the same result; it re-signs ad hoc
(`codesign --force --sign - --preserve-metadata=identifier,entitlements,flags`)
only an application not already signed ad hoc. Other certificates,
methods with a team, provisioning profiles, upload, notarization: not
supported (exit 70 naming the gap). Success: `Exported <Name> to: <export
path, /private prefix removed>`, `** EXPORT SUCCEEDED **`, blank line;
exit 0. The export folder contains only the application.

## Evidence

- Archive locations and settings: `-showBuildSettings -json archive` of
  the reference tool on a hand-written app project; ycodebuild prints the
  same 565 settings with equal values (level 3).
- Archive layout and `Info.plist` keys, default archive path, destination
  warning order, export output, messages, exit codes, export folder
  contents and signature identity: black-box `xcodebuild` 27.1 runs on a
  hand-written macOS app and tool (level 3); archives studied as files
  (level 2). The archives ycodebuild writes have the same file tree and
  `Info.plist` (creation date masked).
- `archive` action and scheme command in the build system: open-source
  swift-build (`SWBBuildAction`, `SWBSchemeCommand`, product validation)
  (level 1). Mach-O header layout: public `<mach-o/fat.h>`,
  `<mach-o/loader.h>` (level 1).
- OPEN QUESTION: whether the default archive name pads month and day
  (observed only for a two-digit month and day).
- OPEN QUESTION: re-signing with a real identity, provisioning profiles,
  `developer-id`, `app-store-connect`, `.pkg` installers, `ExportOptions.plist`
  and `DistributionSummary.plist` outputs of other methods.
