# Spec: Xcode XML documents (`.xcscheme`, `contents.xcworkspacedata`)

Status: **implemented** in `ycode/Sources/YcodeWorkspace`. 49 of 49
Xcode-written corpus files round-trip byte for byte. One more corpus file,
which a tool wrote in compact XML, parses correctly and is rewritten in
canonical form.

## Serialization layout

    <?xml version="1.0" encoding="UTF-8"?>
    <Element
       attr1 = "value"
       attr2 = "value">
       <Child>
       </Child>
    </Element>

- Indentation is 3 spaces per depth.
- Each attribute goes on its own line, indented one level deeper than its
  element, written as `name = "value"`. The `>` closes the last attribute
  line.
- An element without attributes is written as `<Name>` on one line.
- **Every element has an explicit end tag** on its own line. Xcode never
  writes self-closing tags.
- Attribute order is significant and Ycode preserves it. Xcode writes a fixed
  per-element order. It is not alphabetical.
- Attribute escaping: `&amp; &lt; &gt; &quot;`, and newline as `&#10;`. Tab
  is written as `&#9;` and CR as `&#13;`; these two are not yet confirmed
  against a sample.

## Workspace (`contents.xcworkspacedata`)

The root is `<Workspace version="1.0">`. Its children are `FileRef` and
`Group` elements. Each has a `location`, and a `Group` also has a `name`.

| Location | Resolves against |
|---|---|
| `group:p` | The enclosing `Group`'s resolved location. At top level, the directory that contains the workspace |
| `container:p` | The directory that contains the workspace |
| `absolute:p` | Nothing (absolute path) |
| `self:` | The `.xcodeproj` that embeds this workspace. A legacy form, `self:Name.xcodeproj`, is relative to that project's directory |
| `developer:p` | The active developer directory |

An `.xcodeproj` without `project.xcworkspace` behaves as if its workspace
had one `FileRef location="self:"`.

## Scheme (`.xcscheme`)

The root is `<Scheme LastUpgradeVersion="NNNN" version="1.x">`. Its children
can appear in this order: `BuildAction`, `TestAction`, `LaunchAction`,
`ProfileAction`, `AnalyzeAction`, `ArchiveAction`.

- `BuildAction` has the attributes `parallelizeBuildables` and
  `buildImplicitDependencies`, and contains
  `BuildActionEntries/BuildActionEntry`.
  - A `BuildActionEntry` has the YES/NO attributes `buildForTesting`,
    `buildForRunning`, `buildForProfiling`, `buildForArchiving`, and
    `buildForAnalyzing`.
  - It contains one `BuildableReference`.
- `BuildableReference` has the attributes `BuildableIdentifier` (usually
  `primary`), `BlueprintIdentifier` (the target's object ID),
  `BuildableName` (the product file name), `BlueprintName` (the target
  name), and `ReferencedContainer` (`container:App.xcodeproj`).
- `TestAction` has `buildConfiguration`, and contains
  `Testables/TestableReference[skipped]/BuildableReference` or
  `TestPlans/TestPlanReference[reference, default]`.
- `LaunchAction` has `buildConfiguration`. It contains a
  `BuildableProductRunnable/BuildableReference` (or `MacroExpansion`),
  `CommandLineArguments/CommandLineArgument[argument, isEnabled]`, and
  `EnvironmentVariables/EnvironmentVariable[key, value, isEnabled]`.
- When `buildConfiguration` is missing, the defaults are Debug for the test,
  launch, and analyze actions, and Release for the profile and archive
  actions.
- Discovery: shared schemes are in `<container>/xcshareddata/xcschemes`.
  User schemes are in `<container>/xcuserdata/<user>.xcuserdatad/xcschemes`.
  `xcodebuild -list` adds two more sources:
  - the shared schemes of projects referenced through the project's
    `projectReferences` (sub-projects). *Implemented.*
  - auto-generated schemes for local Swift packages (one per product or
    target, as the corpus shows). *Not yet implemented. Needs the package
    graph (M3).*
  On 10 corpus projects, Ycode matches `xcodebuild -list` exactly for 6. The
  other 4 differ only by local-package schemes.

## Open questions

- The exact attribute set and order of the schemes that Xcode autocreates.
  Ycode currently writes a minimal set.
- The ordering and visibility state in `xcschememanagement.plist`.

## Evidence

- Format: level 2 (file-format study across 50 corpus files).
- Discovery: level 3 (black-box comparison with `xcodebuild -list -json`).
