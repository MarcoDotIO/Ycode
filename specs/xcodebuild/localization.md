# xcodebuild: -exportLocalizations and -importLocalizations

Ycode: `YcodeXcodebuild` (`Localization`, `StringsFile`). Projects only
(`-project` or the one project in the folder). XLIFF is the OASIS XLIFF
1.2 standard; String Catalogs (`.xcstrings`) are JSON
(`specs/ide/string-catalog.md`); `.strings` files are `"key" = "value";`
pairs with `/* comment */` notes.

## 1. Export

`xcodebuild -exportLocalizations -localizationPath <dir> [-project P]
[-exportLanguage <lang>]… [-defaultLanguage <lang>]`. `-derivedDataPath`
without `-scheme` is the usual error (`cli.md` §4). Languages: the
`-exportLanguage` values, else the project's development region only.

Log (stdout; `<time>` is local `yyyy-MM-dd HH:mm:ss`):

    Localization Export started for <project> project
    <time> Started export
    <time> Extracting strings from code
    <blank>
    Building all targets for string extraction
    <blank>
    <build log of every target, build system action `exportloc`, the project's default configuration, DerivedData locations>
    <time> Extracting strings from localizable files
    <time> Copying source language files
    <time> Exporting <source> to <lang>.xliff...        (per source, per language)
    <time> Writing
    <time> An xcloc was created at <dir>/<lang>.xcloc

**Sources**, sorted by path (case-insensitive), paths relative to the
project folder: each target's resources that are String Catalogs; the
development-language file of each localized `.strings` group
(`Loc/en.lproj/Greetings.strings`); for an application target with
`GENERATE_INFOPLIST_FILE = YES`, a generated catalog
`<target folder>/<target>-InfoPlist.xcstrings` (version `1.3`) with
`CFBundleName` (= `PRODUCT_NAME`, comment `Bundle name`, extraction state
`extracted_with_value`, development-language state `new`).

**`<lang>.xcloc`** (a folder):

| Path | Content |
|---|---|
| `contents.json` | `developmentRegion`, `project` (`X.xcodeproj`), `targetLocale`, `toolInfo` {`toolBuildNumber`, `toolID`, `toolName`, `toolVersion`} (Ycode's own values), `version` `1.0` |
| `Localized Contents/<lang>.xliff` | the XLIFF document (below) |
| `Source Contents/<source path>` | each source as the development language sees it: `.strings` copied; catalogs with only their source language's localizations, written as `JSON` with ` : ` separators, sorted keys, two-space indent, no final newline |
| `Notes/` | empty |

**XLIFF**: `<xliff xmlns="urn:oasis:names:tc:xliff:document:1.2"
xmlns:xsi=… version="1.2" xsi:schemaLocation=…>`; per source a `<file
original="<source path>" source-language="<dev>" target-language="<lang>"
datatype="plaintext">` with a `<header><tool …/></header>` and a
`<body>` of `<trans-unit id="<key>" xml:space="preserve">` (keys sorted)
holding `<source>`, an optional `<target>` and `<note>` (the comment;
`<note/>` when there is none). Two-space indentation, one element per line.

| Source | `<source>` | `<target>` |
|---|---|---|
| catalog, target language | the source-language value, else the key | the language's string unit, `state` = `translated` / `needs-review-l10n` (catalog `needs_review`, `stale`) / `new`; absent without a localization |
| catalog, development language | the same | the source-language unit (its state), else the key with `state="new"` |
| `.strings` | the development-language value | the target language's value from `<lang>.lproj/<name>.strings`, without `state`; absent when missing |

Catalog entries with `shouldTranslate: false` are left out.

## 2. Import

`xcodebuild -importLocalizations -localizationPath <X.xcloc | X.xliff>
[-project P]`. The same build runs first. Log:

    Localization Import started for <project> project
    <time> Started import
    <blank>
    Building all targets for string extraction
    <blank>
    <build log>
    <time> Comparing
    <time> Checking for new localizations in the XLIFF for <original>...   (per <file>, sorted by byte order)
    <time> Writing
    <time> Will add generated file '<path>' to target <target>.          (for a generated catalog new to the project)

Per `<file>` (target language ≠ the catalog's source language):

- catalog: each unit with a `<target>` sets the language's string unit
  (`state`: XLIFF `new`/`needs-translation` → `new`; `needs-review-*`,
  `needs-adaptation`, `needs-l10n` → `needs_review`; anything else or none
  → `translated`); the catalog is written in the layout above. Catalog
  keys missing from the `<file>` give the warning
  `--- xcodebuild: WARNING: <original>: Key not found in the XLIFF (Key: "<key>")`
  on stderr. A generated Info.plist catalog is created from its sources,
  updated the same way, and added to its target: a file reference in the
  group of the target's first source file and a build file in the
  target's resources phase (the project file is written with Ycode's
  project writer).
- `.strings`: `<lang>.lproj/<name>.strings` is written: per unit with a
  target, `/* <note> */` (when there is one), the pair, a blank line.

Exit 0.

## Evidence

- Every observable above (log lines, xcloc layout, XLIFF elements,
  attributes, ordering and indentation, states, source copies, the
  generated Info.plist catalog, import results, the warning, the
  `-derivedDataPath` error): black-box `xcodebuild` 27.1 runs on a
  hand-written application with a String Catalog and a localized
  `.strings` file (level 3); exported files and the files the import
  wrote studied as file formats (level 2). The harness compares the XLIFF
  (tool line masked), every source copy, `contents.json` (tool info
  masked) and every imported file: identical (`conformance.md`).
- XLIFF 1.2: the OASIS specification (level 1).
- OPEN QUESTION: strings extracted from code that are not yet in a
  catalog (the reference merges the build's extracted strings into
  catalogs; ycodebuild exports the catalogs as they are), `.stringsdict`,
  Interface Builder files, plural and device variations, other Info.plist
  keys, workspaces and packages.
- OPEN QUESTION: XLIFF `state` values for catalog states not observed
  (`new` in a target language, `stale`).
- OPEN QUESTION: the reference also rewrites the whole project file when
  it adds the generated catalog (and changed `objectVersion` to 60);
  ycodebuild writes it with Ycode's writer and keeps the version.
