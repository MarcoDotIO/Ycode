# Spec: `project.pbxproj`

Status: **implemented** in `ycode/Sources/YcodeProject`. 22 of 22 Xcode-written
corpus files round-trip byte for byte (objectVersion 46, 70, 77, 90, 110).

## Container

`Name.xcodeproj/` is a directory. It contains `project.pbxproj` and the
optional `project.xcworkspace/`, `xcshareddata/` (shared schemes) and
`xcuserdata/` (per-user state). This spec covers only `project.pbxproj`.

## Syntax

The file is an OpenStep plist (see `openstep-plist.md`). Its first line is
`// !$*UTF8*$!`, which marks the encoding.

The top-level dictionary has these keys, written in sorted order:

| Key | Meaning |
|---|---|
| `archiveVersion` | Always `1` |
| `classes` | Always empty |
| `objectVersion` | Format version (46 = Xcode 3.2 compatible, 77 = Xcode 16, 90 = Xcode 26/27 default for new projects, 110 seen with `preferredProjectObjectVersion = 77`) |
| `objects` | Map from object ID to object dictionary |
| `rootObject` | ID of the `PBXProject` |

An object ID is a string of 24 uppercase hex digits. Each object has an `isa`
key that holds the class name.

## Canonical layout (what Xcode writes)

1. Line 1: `// !$*UTF8*$!`. Line 2: `{`. Each top-level key is written as
   `\tkey = value;`.
2. `objects` is written as `\tobjects = {` and then one section for each
   distinct `isa`. Sections are sorted by class name in literal code-unit
   order. Each section is:

       <empty line>
       /* Begin ISA section */
       \t\tID /* comment */ = {...};
       /* End ISA section */

   Objects in a section are sorted by ID. After the last section comes
   `\t};`. There is no empty line before it.
3. Object bodies are written on multiple lines. `isa` is first, and the other
   keys follow in sorted order. Each nesting level adds one tab. Arrays are
   written as `(` + `item,` lines + `)`. Dictionaries are written as `{` +
   `key = value;` lines + `}`. Empty containers are `(\n<tabs>)` and
   `{\n<tabs>}`.
4. **Single-line classes:** `PBXBuildFile` and `PBXFileReference`. Older
   writers (the Xcode 16 era, objectVersion 70) also write
   `PBXFileSystemSynchronizedRootGroup` on one line. The inline forms are
   `{k = v; k2 = v2; }`, `(a, b, )`, and the empty forms `{}` and `()`.
5. Nested dictionaries also have sorted keys. Arrays keep their order.
6. The file ends with `\trootObject = ID /* Project object */;\n}\n`.

## String quoting

A string is written without quotes only if all of these are true:

- It is not empty.
- Every character is in `[A-Za-z0-9_$/:.]`.
- It does not contain `//`.
- It does not contain `___`.

Otherwise the string is written in double quotes with these escapes:
`\\`, `\"`, `\n`, `\t`, `\r`, `\a`, `\b`, `\f`, `\v`. Other control characters
are written as `\UXXXX`. Non-ASCII characters are written as raw UTF-8.

`-` and `+` always cause quoting, so the bundle identifier
`org.example.Hello-World` is written in quotes.

## Reference comments

When a string value (or an array element) is the ID of an object in the
table, it is written as `ID /* comment */`. Exception: the values of
`remoteGlobalIDString` and `TestTargetID` never get a comment. If the comment
for an object is *none*, the bare ID is written. Example: the main group,
which has no name or path.

| isa | Comment |
|---|---|
| `PBXProject` | `Project object` |
| `PBXBuildFile` | `<comment of fileRef, or of productRef> in <comment of the build phase that lists it>` |
| `PBXFileReference`, `PBXGroup`, `PBXVariantGroup`, `XCVersionGroup`, `PBXReferenceProxy`, `PBXFileSystemSynchronizedRootGroup`, targets | `name`, otherwise `path`, otherwise none |
| Build phases | `name`, otherwise the default: Sources, Frameworks, Resources, Headers, CopyFiles, ShellScript, Rez, AppleScript |
| `XCConfigurationList` | `Build configuration list for <owner isa> "<owner name>"`. When the owner is the `PBXProject`, the name is the `.xcodeproj` file name without the extension. The project's name is not stored anywhere in the file. |
| `XCBuildConfiguration` | *Newer writers:* `<name> configuration for <owner isa> "<owner name>"`. *Older writers:* `<name>` |
| `PBXContainerItemProxy`, `PBXTargetDependency` | the class name |
| `XCSwiftPackageProductDependency` | `productName` |
| `XCRemoteSwiftPackageReference` | `XCRemoteSwiftPackageReference "<last URL path component without .git>"` |
| `XCLocalSwiftPackageReference` | `XCLocalSwiftPackageReference "<relativePath>"` |
| `PBXFileSystemSynchronizedBuildFileExceptionSet` | *Newer:* `Exceptions for "<owning group comment>" folder in "<target comment>" target`. *Older:* the class name |

### Writer generations

The comment style depends on the Xcode release that last saved the file.
Neither `objectVersion` nor `compatibilityVersion` records it. Ycode detects
the style when it loads a file (`PBXProj.FormatStyle.detect`) and uses that
style when it saves, so that untouched projects produce no diff. New projects
use the current style.

## Files edited by other tools

Generators and hand edits can produce files that are not in canonical order:
unsorted sections, unsorted IDs, or unsorted `buildSettings` keys. Ycode loads
these files without losing data and writes them in canonical order, as Xcode
does on its next save.

## Open questions

- The exact comment format of
  `PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet`. The current
  implementation is a guess. A corpus sample is needed.
- The comment for a `PBXBuildFile` whose phase cannot be found. The current
  implementation writes `(null)`.
- The meaning of `objectVersion = 110`.

## Evidence

- Syntax, layout, quoting, and comments: level 2 (study of the file format
  across a 27-file corpus, plus round-trip diffs).
- The writer-generation split: level 2 (files with the same objectVersion
  but different comment styles).
- No binary analysis was used.
