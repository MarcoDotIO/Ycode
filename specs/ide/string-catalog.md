# String Catalog editor

Ycode modules: `YcodeStrings` (`StringCatalog`, `OrderedJSON`, the
compiler, extractor and converter; portable), `YcodeUI`
(`StringCatalogEditorController`). Selecting a `.xcstrings` file opens it
(file type `text.json.xcstrings` when added to a project).

## Format (from Apple's public description)

A JSON object: `sourceLanguage` (a language code), `strings` (an object
keyed by the string key), `version` (`"1.0"`). Each entry may have:

- `comment` (string), `extractionState` (`manual`, `stale`, …),
  `shouldTranslate` (`false` = don't translate);
- `localizations`: by language code, either `stringUnit` (`state`,
  `value`) or `variations` (`plural` → `zero`/`one`/`two`/`few`/`many`/
  `other`, `device` → `iphone`/`mac`/…, each holding a `stringUnit`).

`state` values: `translated`, `needs_review`, `new`, `stale`.

## Layout written

Two-space indentation, `"key" : value` separators, one member per line,
empty objects and arrays as `{`, an empty line, then `}` at the
container's indentation. Slashes and non-ASCII characters are not escaped;
`"`, `\`, and control characters are. Object members keep the order they
were read in; members Ycode adds are inserted in code-unit order (the
order catalogs are written in). Numbers keep their spelling. A final
newline is kept if the file had one.

Invariant (tested): reading and writing an untouched catalog gives the
same bytes; adding a translation and then removing it gives the original
bytes back.

## Editor

- Sidebar: the languages: the source language first, marked "(Source)",
  then the other languages that have a localization or were added, by
  code, each with its percentage translated (keys marked don't translate
  are left out; plural/device variations count as translated). The + pull-down
  adds a language from a fixed list of common codes; a language with no
  strings yet is not written to the file.
- Table: Key, Default Localization (the source `stringUnit` value, else the
  key), Comment (editable), the selected language's translation (editable;
  hidden for the source language), State: Translated, Needs Review, New
  (no unit), Stale (`extractionState = stale`), Don't Translate, Varies
  (variations present: shown read-only as `plural.one: …; plural.other: …`).
- Editing a translation writes `stringUnit` `{state: translated, value}`;
  clearing it removes the language's localization (and `localizations`
  when it becomes empty). Add Key adds an entry with
  `extractionState = manual`. Every edit is saved at once.

Linux IDE (1.0.0-beta.2): `ycode-ide` has the same editor
(`YcodeIDEShell/StringCatalogEditorModel.swift`,
`ycode-ide/StringCatalogEditorView.swift`), plus a filter over key, value,
comment and translation, sorting by any column header (the view only),
editing the Default Localization (the source language's unit), Mark for
Review / Mark as Reviewed and Delete in a row's context menu, and Refresh
from Source with a summary of what changed.

## Ycode implementation (RES-STRINGS, 2026-10-31)

Clean-room implementation from this spec, Apple's public documentation
(String Catalogs, `.strings` and `.stringsdict` files, `String(localized:)`,
`LocalizedStringResource`, `LocalizedStringKey`, `NSLocalizedString`) and
open source: swift-build `release/6.4.x` (Apache-2.0: the `XCStrings.xcspec`
command line, `XCStringsCompiler.swift`, `StringCatalogCompilerOutputParser`,
`CopyStringsFile`, the executable search path in `Settings.swift`) and
SwiftGen's stringsdict documentation (MIT, format examples). No Apple tool
was run and no Apple binary was inspected. Module `YcodeStrings` (Foundation
and swift-syntax; macOS and Linux), command `ycode strings`.

### C.1 Compiling (`ycode strings compile`)

swift-build's command line is accepted as it is:
`compile [--dry-run] [-l <lang>]… [--force-build-all-strings]
--output-directory <dir> <file.xcstrings>…`. `--dry-run` prints the
absolute paths of the files a compile writes, one per line (swift-build
declares them as the task's outputs). Diagnostics go to standard error as
`<file>: error|warning: <message> (<language>: <key>)`, the form swift-build
parses; an error exits 1 and writes nothing for that catalog. Unknown
options exit 2. Ycode's own option: `--strings-encoding utf-8|utf-16`.

Outputs: `<dir>/<language>.lproj/<table>.strings` and `.stringsdict`, the
table being the catalog's file name; a file only when it has an entry.

| Rule | Ycode |
|---|---|
| Languages | the source language, then every language with a localization (code order); `-l` restricts to those given |
| Source language | every key: its `stringUnit` value, else the key itself |
| Other languages | keys with a localization; `shouldTranslate = false` keys never |
| States | units in state `new` are left out of other languages unless `--force-build-all-strings`; `translated`, `needs_review`, `stale` and units with no state are compiled; `extractionState` does not matter |
| Empty key | never written |
| Plain unit | `.strings`: `"key" = "value";`, UTF-8 without a byte-order mark (`--strings-encoding utf-16`: UTF-16LE with one); escapes `\"`, `\\`, `\n`, `\t`, `\r`, other C0 controls and DEL as `\UXXXX`; everything else, non-BMP characters included, as itself |
| `variations.plural` | `.stringsdict`: `NSStringLocalizedFormatKey` = `%#@count@` (`%N$#@count@` when the `other` case's first numeric specifier is positional; `count2`… when a substitution has that name); the variable: `NSStringFormatSpecTypeKey` `NSStringPluralRuleType`, `NSStringFormatValueTypeKey` = that specifier's length and conversion (`lld` when none), then the categories present in CLDR order; `other` is required (error otherwise) |
| `variations.device` | `NSStringDeviceSpecificRuleType` with one entry per device in the order `iphone`, `ipad`, `ipod`, `mac`, `applewatch`, `appletv`, `applevision`, `other` |
| device, then plural | each device entry is itself a format dictionary (`NSStringLocalizedFormatKey` and its variable) |
| `substitutions` | `NSStringLocalizedFormatKey` = the unit's value; one variable per `%#@name@` named, with `NSStringFormatValueTypeKey` = `formatSpecifier` (`lld` when absent) and the plural cases, `%arg` replaced by the substitution's own specifier. The argument is `argNum`, else the position written in the token, else the token's place among the specifiers. When the format uses positions or the argument is not the one the token takes in order, the token becomes `%N$#@name@` and the cases use `%N$<spec>`; otherwise both stay non-positional. An undefined substitution is an error ("Referencing undefined substitution 'name'"); an unused one, a warning; only plural substitutions compile |
| More than one variation kind at one level | the first is compiled, with a warning |

`.stringsdict` files are XML property lists (tab indentation), entries in
catalog order; characters XML 1.0 cannot hold are dropped.

Checked with Foundation (public API, `Bundle.localizedString` and
`String(format:locale:)`, `CompiledTablesRuntimeTests`): plural selection,
the positional substitution (`Ann has 1 apple`, `Bob has 3 apples`), the
device rule (`mac`) and the nested device-then-plural dictionary all format
as intended.

### C.2 Symbols (`ycode strings generate-symbols`)

swift-build runs `xcstringstool generate-symbols --language swift
--output-directory $(DERIVED_SOURCES_DIR) <file>` when
`STRING_CATALOG_GENERATE_SYMBOLS = YES` and expects
`GeneratedStringSymbols_<table>.swift`. Ycode's file (its own design):
for each key with `extractionState = manual`, a static member of
`LocalizedStringResource` (`@available(macOS 13, iOS 16, tvOS 16,
watchOS 9, *)`) named in lower camel case from the key's words (format
specifiers dropped, `_` before a leading digit, keywords in backticks,
`2`, `3`… on collisions). A key without arguments is a property; one with
arguments a function whose parameters are `argN` (or the substitution's
name) typed from the specifier (`@` String, `d`/`i` Int, `u`/`x`/`o` UInt,
`f`/`e`/`g`/`a` Double; a key with other specifiers gets no symbol). The
body is `LocalizedStringResource("<key>", defaultValue: "<source value with
interpolations>", table: "<table>", bundle: .forClass(<a private class>))`.
The file is rewritten only when it changes. Its own comment names Ycode.

### C.3 Extraction (`ycode strings extract`, Refresh from Source)

Swift, with swift-syntax (`SwiftParser`):

- `String(localized:defaultValue:table:comment:)`,
  `AttributedString(localized:…)`;
- `LocalizedStringResource("…", defaultValue:table:comment:)`,
  `String.LocalizationValue("…")`, `LocalizedStringKey("…")`;
- `let x: LocalizedStringKey = "…"` (also `LocalizedStringResource`,
  `String.LocalizationValue`);
- `NSLocalizedString("…", tableName:bundle:value:comment:)` and the names of
  `LOCALIZED_STRING_MACRO_NAMES` (`--macro`);
- SwiftUI (`LOCALIZED_STRING_SWIFTUI_SUPPORT`, on by default; `--no-swiftui`):
  a string literal as the first unlabeled argument of `Text`, `Button`,
  `Label`, `Toggle`, `TextField`, `SecureField`, `Picker`,
  `NavigationLink`, `Section`, `Link`, `Menu`, `Stepper`, `DatePicker`,
  `ColorPicker`, `LabeledContent` and the other initializers listed in
  `StringExtractor.swiftUIInitializers` (`SwiftUI.Text` too), or of the
  modifiers `navigationTitle`, `help`, `alert`, `confirmationDialog`,
  `accessibilityLabel` and the others in `swiftUIModifiers`;
  `Text(verbatim:)` and non-literal arguments are not localized. `tableName:`
  and `comment:` are read where the initializer has them.

Keys: the literal's value (escapes and raw strings decoded). An interpolated
literal becomes a format: `\(x)` is `%lld` for `Int` (and the other signed
integers), `%llu` for unsigned ones, `%lf` for `Double`/`CGFloat`, `%f` for
`Float`, `%@` otherwise; the type comes from integer, float and string
literals, `.count`, and the declared type or literal initializer of a name
declared in the same file. Literal `%` becomes `%%` in an interpolated key.
(Xcode can use the compiler for this, `SWIFT_EMIT_LOC_STRINGS`; Ycode's
syntactic guess is a known limit.) Results are in source order.

Objective-C and C (a tokenizer that skips comments, character literals and
`#if 0` blocks, `LOCALIZED_STRING_CODE_COMMENTS` = NO): `NSLocalizedString`,
`…FromTable`, `…FromTableInBundle`, `…WithDefaultValue` and the
`CFCopyLocalizedString` family (key, table, value, comment at their
documented positions), with `@"…"`, `"…"` and `CFSTR("…")` literals and
adjacent literals joined; an argument that is not a literal counts as none.

Without `--catalog`, `ycode strings extract` lists what it finds (`--json`).

### C.4 Merging

`StringCatalog.merge(extracted:)`, for the strings of the catalog's table:

| Case | Result |
|---|---|
| New key | added; no `extractionState`; `comment` from code. With a default value from code: `extractionState = extracted_with_value` and a source unit `{state: new, value}` |
| Key found, catalog state `stale` or `migrated` | `extractionState` removed (extracted again) |
| Key found, `manual` | kept manual; only the comment follows code |
| Key found with a default value | the source unit's value follows code while that unit is missing or `new` |
| Comment | replaced by the code's comment when code has one; kept otherwise |
| Key not found, extracted (`extractionState` absent or `extracted_with_value`) | `extractionState = stale` |
| Key not found, `manual`, `migrated` or `stale` | unchanged |

A key found more than once takes the first comment and default value.
Merging the same strings twice changes nothing (byte-identical file).

### C.5 Conversion (Edit ▸ Convert ▸ To String Catalogs…, `ycode strings convert`)

`StringCatalogConverter`: one table (`<lang>.lproj/<table>.strings` and
`.stringsdict` in one folder) becomes one catalog with the project's
`developmentRegion` (default `en`) as source language; `Base.lproj` counts
as the source language. Every key gets `extractionState = migrated`; its
comment comes from the first file (source language first) that has one,
except genstrings' "No comment provided by engineer.". A `.strings` value
becomes `{state: translated, value}`. A `.stringsdict` entry whose format is
exactly one plural variable becomes `variations.plural`; otherwise a unit
with the format and `substitutions` (`argNum` = the token's position or
place, `formatSpecifier` = `NSStringFormatValueTypeKey`, plural cases with
the variable's own specifier rewritten to `%arg`); a device rule becomes
`variations.device`. A key in both files of a language takes the
`.stringsdict` form. Members are written in code-unit order. Compiling the
result gives tables equivalent to the originals (tested).

In the IDE the command lists the project's tables in a sheet: variant
groups named `<table>.strings`/`.stringsdict` (strings of Interface Builder
files are not offered) and `.lproj` tables inside synchronized folders,
grouped by folder and name, each row "Localizable in App (de, en) —
App" with a checkbox (all checked; Convert is disabled with none). Convert
writes `<folder>/<table>.xcstrings`, removes the variant groups (and their
build files), adds a reference where the first group was, in the same
targets, and moves the old files, and `.lproj` folders left empty, to the
Trash: one undoable edit ("Convert to String Catalog(s)"). An existing
catalog of the same name refuses the conversion. The command is enabled
when the project has a table.

### C.6 Refresh from Source

The String Catalog editor's Refresh from Source extracts from the Swift,
Objective-C and C sources of the targets that hold the catalog (their
Sources phases and synchronized folders; the catalog's folder when it is
in no target), keeps the strings of the catalog's table, merges (C.4) and
saves when something changed.

### C.7 Builds

`YcodeBuild.StringsCompilerHook`: `YCODE_STRINGS_COMPILER` = `xcstringstool`
| `ycode` (build setting on the command line, or environment). Default:
`ycode` off macOS; on macOS `xcstringstool` when the selected Xcode
(`DEVELOPER_DIR`, else the `xcode-select` link, else
`/Applications/Xcode.app`) has `usr/bin/xcstringstool` or
`Toolchains/XcodeDefault.xctoolchain/usr/bin/xcstringstool`, else `ycode`.
swift-build has no setting for this tool's path (its command line starts
with the bare name, looked up in the executable search paths); the first
of those paths come from the client's `__XCODE_BUILT_PRODUCTS_DIR_PATHS`
environment variable. With `ycode`, the IDE's swift-build engine and
ycodebuild write a wrapper `xcstringstool` (`exec ycode strings "$@"`) in
`<derived data>/YcodeStringsCompiler` (ycodebuild: its work folder) and
start `swbuild`/`ycode-swb` with that folder first in the variable.
`YCODE_STRINGS_TOOL` names the `ycode` binary (else the one
`AssetCompilerHook` finds). Off macOS swift-build cannot detect a
`.strings` file's encoding, so the hook also sets
`STRINGS_FILE_INPUT_ENCODING = $(InputFileTextEncoding:default=utf-8)`
(unless given): files with their own encoding keep it, compiled tables
are read as UTF-8. swift-build's CopyStringsFile then writes the tables
into the product (binary property lists for iOS).

Results (macOS, level 3, Ycode only): `ycode/Samples/StringsSamples` (an iOS
app with a catalog: plain strings with a non-BMP character, plurals, a
device variation, a positional substitution and a manual key with
`STRING_CATALOG_GENERATE_SYMBOLS = YES`) built with `ycode build --engine
swift-build YCODE_STRINGS_COMPILER=ycode` for the iOS Simulator and with
`ycodebuild … YCODE_STRINGS_COMPILER=ycode build`: swift-build ran
GenerateStringSymbols and CompileXCStrings through Ycode's tool, compiled
`GeneratedStringSymbols_Localizable.swift` into the app (`Text(.welcomeTitle)`),
and `StringsApp.app` holds `en.lproj` and `de.lproj`, each with
`Localizable.strings` and `Localizable.stringsdict`.

x86-64 Linux (level 3, Ycode only): the same sample built for the iOS
Simulator (arm64) with `ycode build --engine swift-build` and the
`ycode-swb` helper, the default compiler choice (`ycode`, no setting
given), and a copy of the user's own iPhoneSimulator SDK and toolchain
resources (never committed, never redistributed): swift-build ran
GenerateStringSymbols and CompileXCStrings through Ycode's tool, and
CopyStringsFile turned the tables into binary property lists in
`StringsApp.app/en.lproj` and `de.lproj` (`Localizable.strings` and
`.stringsdict`, the plural, device and positional-substitution entries
as on macOS); the app's executable is an arm64 Mach-O. The rest of that
build is not String Catalog work, and is recorded here for the task that
makes iOS builds on Linux a supported path (PARITY gap 9, "User SDK in
place"): the developer folder holds `Platforms/iPhoneSimulator.platform`
(its `Info.plist` and SDK) and `Toolchains/XcodeDefault.xctoolchain` (its
`ToolchainInfo.plist`, `usr/lib/swift/{iphonesimulator,apinotes,swiftToCxx,clang}`
and `usr/lib/clang/<v>/lib/darwin`); the run sets `DEVELOPER_DIR` to it,
`XCODE_EXTRA_PLATFORM_FOLDERS=$DEVELOPER_DIR/Platforms` (swift-build loads
no Xcode platforms for a Swift toolchain otherwise; the swift-build that
`Tools/ycode-swb` pins since beta 2 registers them itself and fails the
session with "platform … already registered", so
`scripts/ycode-ios-build-linux` then builds again without it, B3-SIMDEBUG,
2026-11-05), the Swift
toolchain's real `usr/bin` first on `PATH` (swift-build rejects swiftly's
proxy folder), and the settings `SDKROOT=iphonesimulator`, `ARCHS=arm64`,
`OTHER_SWIFT_FLAGS=-resource-dir <that toolchain>/usr/lib/swift` (the
Linux resource folder's `dispatch` module map clashes with the SDK's),
`OTHER_LDFLAGS=-fuse-ld=lld --ld-path=<upstream ld64.lld> <…>/libclang_rt.iossim.a`
(swift.org's `lld` refuses Apple platforms by a downstream change; the
distribution's LLVM 21 `ld64.lld` links), `DONT_RUN_SWIFT_STDLIB_TOOL=YES`
(swift-build's tool cannot read Mach-O off macOS) and
`LM_SKIP_METADATA_EXTRACTION=YES` (no `appintentsmetadataprocessor`), with
`CODE_SIGNING_ALLOWED=NO`.

### C.8 Open questions (for an OBS agent)

- Which states `xcstringstool compile` leaves out (Ycode: `new` in
  non-source languages) and what `--force-build-all-strings` adds.
- Whether the source language's table repeats keys whose value is the key,
  and whether keys marked don't translate appear in other languages.
- The variable names, value types and positional rewriting `xcstringstool`
  writes in `.stringsdict` files; whether it writes device-then-plural as
  nested format dictionaries; its `.strings` encoding and escapes; whether
  it writes empty tables.
- The extraction state the reference gives migrated keys (Ycode:
  `migrated`, as seen in published catalogs), what happens to the old files
  and which tables its migration offers.
- The shape and naming of the reference's generated symbols.
- The reference's merge rules beyond those in C.4 (for example
  `isCommentAutoGenerated`, and comments of manual keys).

## Evidence

- Keys and values: Apple's public documentation for String Catalogs and
  localization (level 1); the layout matches files studied as a format
  (level 2).
- OPEN QUESTION: the exact sort the reference uses for new keys (Ycode uses
  code-unit order); whether it writes a final newline; the reference's
  column titles and state icons; editing plural/device variations and
  substitutions (read-only in Ycode).
- Adding a language also appends its code to the project's `knownRegions`
  (once) when the catalog is in a project: Apple's localization
  documentation (level 1).
- Ycode implementation (C.1–C.7): Apple's public documentation for String
  Catalogs, `.strings`, `.stringsdict`, `String(localized:)`,
  `LocalizedStringResource` and `NSLocalizedString` (level 1);
  swift-build's open source for the tool's command lines, output parsing
  and search paths (level 1, Apache-2.0); SwiftGen's documentation for
  `.stringsdict` examples (MIT, level 1); swiftlang/llvm-project's
  `lld/MachO/InputFiles.cpp` (Apache-2.0 with LLVM exception) for the
  linker's refusal on Linux; black-box runs of Ycode's own
  outputs through Foundation and swift-build (level 3, Ycode only).
