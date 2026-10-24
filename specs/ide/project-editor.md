# Project editor

Ycode modules: `YcodeProject` (typed mutations), `YcodeSettings` (levels),
`YcodeUI` (`ProjectEditorController`).

Selecting a project's row in the project navigator opens the project in the
editor area (instead of a text file).

**Correction (2026-10-19).** The layout, tabs, sections and defaults in
`reference-ui-3.md` §1 supersede this file wherever they differ:

- the editor opens on the first target;
- project tabs are Info, Build Settings and Package Dependencies;
- target tabs include Resource Tags;
- General has eight sections;
- there is **no deployment target at project level**;
- the Build Settings bar defaults to Basic, Combined, Titles and Values,
  and customized settings are bold;
- Build Phases has "(N items)" titles and the "+" phase menu;
- Build Rules has Process / Using lines and Copy to Target.

`reference-ui-5.md` §11.1 lists what Ycode still lacks (left-column
footer, real controls on Resource Tags / Build Rules / Project Info /
Package Dependencies, Run Build Tool Plug-ins, Info's readable names). The
sections below keep the setting and mutation rules, which stay valid.

## Layout

Left: a list with the headers PROJECT (the project) and TARGETS (each
target, in the project's order). Right: a tab bar for the selection, then
the tab's content.

| Selection | Tabs |
|---|---|
| project | Info, Build Settings |
| target | General, Signing & Capabilities, Info, Build Settings, Build Phases, Build Rules |

A configuration pop-up (the target's configurations; default the list's
`defaultConfigurationName`) chooses which configuration values are shown.

### Project ▸ Info
macOS Deployment Target (`MACOSX_DEPLOYMENT_TARGET` at project level),
Configurations (names of the project's configuration list, the default
one marked), Localizations (`knownRegions`, development region marked).

### Target ▸ General
Identity: Display Name (`INFOPLIST_KEY_CFBundleDisplayName`), Bundle
Identifier (`PRODUCT_BUNDLE_IDENTIFIER`), Version (`MARKETING_VERSION`),
Build (`CURRENT_PROJECT_VERSION`). Deployment: macOS
(`MACOSX_DEPLOYMENT_TARGET`). Frameworks and Libraries: the files of the
frameworks phase, each with "Embed" (`Embed & Sign` when the same file
also appears in a copy-files phase to Frameworks with `CodeSignOnCopy`,
"Do Not Embed" otherwise). Text fields write the setting at target level
in every configuration of the target (empty removes it).

### Target ▸ Signing & Capabilities
Signing: "Automatically manage signing" checkbox (writes `CODE_SIGN_STYLE`
= `Automatic` / `Manual`), Team (a combo box of the `DEVELOPMENT_TEAM`
values found in the project's configurations — no account sign-in;
typing or choosing writes `DEVELOPMENT_TEAM`), Bundle Identifier
(`PRODUCT_BUNDLE_IDENTIFIER`), Signing Certificate (display: the resolved
`CODE_SIGN_IDENTITY`; `-` shows "Sign to Run Locally", empty "None").

Capabilities: the capabilities present (all their keys/settings set), each
with Remove; "+ Capability" opens a sheet listing the ones not present.

| Capability | Entitlement (Boolean true) | Build setting |
|---|---|---|
| App Sandbox | `com.apple.security.app-sandbox` | — |
| Hardened Runtime | — | `ENABLE_HARDENED_RUNTIME = YES` |
| Outgoing Connections (Client) | `com.apple.security.network.client` | — |
| Incoming Connections (Server) | `com.apple.security.network.server` | — |
| User Selected File (Read Only) | `com.apple.security.files.user-selected.read-only` | — |
| User Selected File (Read/Write) | `com.apple.security.files.user-selected.read-write` | — |

The four sandbox sub-capabilities add App Sandbox when missing; removing
App Sandbox removes them. Entitlements go into the file named by
`CODE_SIGN_ENTITLEMENTS`; when there is none, `<Target>/<Target>.entitlements`
is created (an XML property list), referenced from the main group, and
`CODE_SIGN_ENTITLEMENTS` is set for every configuration of the target.

### Target ▸ Info
Rows Key | Type | Value from the target's Info.plist file
(`INFOPLIST_FILE`, resolved against the project directory) followed by
`INFOPLIST_KEY_<Key>` build settings (type String). Read-only here; the
plist editor edits the file.

### Build Settings
Filters **Basic** (a fixed list of common settings), **Customized**
(settings assigned at target or project level or in their xcconfig
files), **All** (every setting with an assignment at any level,
including defaults). Views **Combined** (Setting | Value, the resolved
value) and **Levels** (Setting | Resolved | Target | Project |
xcconfig | Defaults, each level's own assignment). A search field
filters by setting name (case-insensitive substring). Editing a value in
the Combined view or the Target column writes the setting at target level
in every configuration (project level for the project's own settings);
an empty value removes the assignment. Values are resolved with
YcodeSettings for the chosen configuration.

Levels view details: columns Setting | Resolved | <target> | Target
xcconfig | <project> | Project xcconfig | Defaults (the target columns only
when a target is selected). Long values truncate in the middle; the
tooltip shows the full value. The cell of the level that provides the
resolved value — the first assigned level in the order target, target
xcconfig, project, project xcconfig, defaults — is tinted green.

**Defaults source.** When the `ycode-swb` helper is available (`YCODE_SWB`,
`PATH`), the Defaults column is swift-build's exported value for a copy of
the project in which every configuration keeps only `SDKROOT` and
`SUPPORTED_PLATFORMS` (no xcconfig files): with nothing else assigned, the
build system's specifications provide every value. Paths under the copy's
folder are mapped back to the project's folder. Results are cached per
(target, configuration). A setting not assigned at any project level then
resolves to its default, and the All filter lists every exported setting.
Without the helper the column shows YcodeSettings' `defaults` level
(empty unless a defaults table is loaded).

### Build Phases
Sections: Target Dependencies (dependency target names), then each build
phase in the target's order — Compile Sources, Link Binary With
Libraries, Copy Bundle Resources, Headers, Copy Files, Run Script (with
its shell and script text) — each listing its files. "+" adds a file to a
phase (creating a file reference in the main group when needed) and "−"
removes the selected build file.

### Build Rules
Each `PBXBuildRule`: file type / pattern, compiler or script; read-only.

## Mutations (YcodeProject)

All edits change the object graph through typed functions; the writer
then serializes the whole file, and untouched objects keep their exact
bytes (sections and order are deterministic).

| Mutation | Effect |
|---|---|
| `setBuildSetting(_:_:configuration:)` | sets or removes a key in one `XCBuildConfiguration`'s `buildSettings` (keys stay in their order; a new key is appended) |
| `setBuildSetting(_:_:inListOf:)` | the same for every configuration of a target or project |
| `addFileReference(path:to:)` | new `PBXFileReference` (`lastKnownFileType` from the extension, `sourceTree` `<group>`), appended to the group's `children` |
| `addBuildFile(fileReference:to:)` | new `PBXBuildFile`, appended to the phase's `files` |
| `removeBuildFile(_:)` | removes the build file from its phase and from `objects` |
| `removeFileReference(_:)` | removes the reference, its build files, and its entries in groups |

New object IDs are 24 uppercase hex digits not already used.

## Evidence

- Correction 2026-10-19: layout, tabs and defaults per `reference-ui-3.md` §1 (level 3); remaining gaps per `reference-ui-5.md` §11.1.
- Editor structure, tab names, Build Settings filters and Combined/Levels
  views, Build Phases sections: Apple's public Xcode Help ("Configure the
  build settings", "Customizing the build phases of a target", "Add a
  capability") (level 1).
- Setting names: `specs/build-settings.md` (levels 1–3).
- Object layout and serialization: `specs/formats/pbxproj.md` (level 2);
  byte-exact round trips after edits are tested.
- Entitlement keys and `ENABLE_HARDENED_RUNTIME`: Apple's public
  entitlement and Hardened Runtime documentation (level 1).
- OPEN QUESTION: whether the reference IDE also sets `ENABLE_APP_SANDBOX`
  or other settings for App Sandbox, where it creates the entitlements
  file, and its capability list layout.
- OPEN QUESTION: which settings the Basic filter shows, per-configuration
  value expansion, the exact General-tab sections, the Embed choices, and
  where a new file reference goes (Xcode uses the selected group).
