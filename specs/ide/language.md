# Language services

Ycode modules: `YcodeLanguage` (`LSPClient`, `BuildServerLaunch`),
`YcodeBuildServer` (the build server, §Build server), wired into the
window by `YcodeIDECore` (`LanguageService`, the session's start of the
language server) and `YcodeUI` (editor completion popup). The server is
sourcekit-lsp, Apple's open-source Language Server Protocol server for Swift
and C-family languages.

## Locating the server

`YCODE_SOURCEKIT_LSP`, else `xcrun -f sourcekit-lsp` (macOS), else
`sourcekit-lsp` on PATH. One server per workspace window, started when the
window opens. The root is the package folder. For a project or workspace
it is a private folder that connects sourcekit-lsp to Ycode's build server
(§Build server); with the build server off or not found, it is the folder
that contains the project or workspace.

## Protocol

JSON-RPC 2.0 messages with the same `Content-Length` framing as DAP
(`specs/ide/debug.md`). Requests have numeric ids 1, 2, 3, …; errors become
`ResponseError(code, message)`. Server-to-client requests are answered at
once: `workspace/configuration` with one `null` per item, others with
`null`.

Sequence: `initialize` (processId, rootUri, workspaceFolders, clientInfo
"Ycode", capabilities: didSave, completion with snippet support (snippet
placeholders become editor placeholders), definition,
publishDiagnostics with related information, workspace configuration) →
`initialized`. Closing: `shutdown` → `exit`.

Documents: `didOpen` when the editor opens a file (languageId from the
extension: swift, objective-c, objective-cpp, cpp, c); `didChange` with
the full text and an increasing version on every edit; `didSave` after
the editor writes the file; `didClose` when no editor shows the file any
more.

Positions are 0-based lines and UTF-16 code-unit columns; the editor's
line index converts both ways (clamping columns to the line).

## Features

- Live issues: `textDocument/publishDiagnostics` replaces that file's live
  issues. Severity 1 → error, 2 → warning; information and hints are
  dropped. Lines and columns become 1-based. The issue navigator, editor
  annotations and activity-view counts show build issues plus live issues,
  without duplicates.
- Completion: Show Completions (⌃Space), or typing `.` in a Swift file,
  sends `textDocument/completion` at the insertion point. The popup sits
  below the word being completed, shows up to 8 rows (kind letter, label,
  detail), and filters as the user types (prefix matches first, then
  substring matches). Placement: the popup's top edge is 2 pt below the
  line of the word being completed, and its label column starts at the
  word's first character; the caret rectangle comes from TextKit 2 line
  fragment geometry (laid out on demand after edits). Height: 20 pt per row
  (at most 8 rows, then it scrolls) plus 3 pt padding top and bottom, plus a
  22 pt documentation line when the selected item has `documentation`
  (plain text or MarkupContent value, shown on one line). The popup is
  hosted above the editor's scroll view. Up/Down move; Return, Enter or Tab insert (replacing
  from the item's `textEdit` start, else from the word start); Escape or
  moving before the word closes it. Double-click inserts.
- Jump to Definition (⌃⌘J): `textDocument/definition` at the insertion point;
  the first `Location`/`LocationLink` is opened and the insertion point
  placed at its start.

- Quick Help: ⌥-click on a symbol sends `textDocument/hover` at that
  position; the result (MarkupContent value, MarkedString, or an array of
  them, joined by blank lines) is shown as plain text — code fences
  dropped, rules as blank lines, backticks removed — in a popover at the
  symbol. The Quick Help inspector (⌥⌘3) parses the same result as Swift
  Markup and shows sections in the order of `reference-ui-4.md` §7: title
  and summary, declaration box, defining file link, Parameters, Return
  Value, Throws, Discussion, boxed callouts, "Open in Developer
  Documentation" (opens a developer.apple.com search). While the Quick Help
  inspector is showing, moving the insertion point refreshes it.
- ⌘-click on a symbol places the insertion point there and does Jump to
  Definition.

### The Linux IDE

`ycode-ide` has the same features through the shell model
(`WorkspaceShellModel+Language.swift`, `YcodeIDEShell`) over the
session's language service; the requests and their mappings are the
core's (`YcodeIDECore/Session/LanguageNavigation.swift`), shared with the
macOS window:

- Quick Help: ⌥-click on a symbol, or Help ▸ Show Quick Help for Selected
  Item (⌃⌘?) at the insertion point, shows the hover in a 420-point
  popover under the symbol (the sections of `reference-ui-4.md` §7, the
  same `QuickHelpDocument` as the inspector). Moving the insertion point,
  Escape, typing or scrolling closes it. The inspector's Quick Help tab
  (⌥⌘3) follows the insertion point 0.35 s after it stops.
- Jump to Definition: ⌃⌘J, Navigate ▸ Jump to Definition, or a click with
  Ctrl or the Super key (⌘) held. The file opens as a new history entry
  and the symbol's name is selected (a definition without a range selects
  the identifier there). Navigate ▸ Jump to Original Source asks for the
  declaration first.
- A request with no answer leaves a short notice at the top of the editor
  ("No definition found", "No Quick Help", "Can't rename this symbol") for
  two seconds. Every request gives up after 5 s (references and callers:
  15 s, they read the index).
- The jump bar's last component is the declaration the insertion point is
  in (`DocumentSymbols.enclosing`, as the macOS jump bar), with its letter
  badge; a click lists the file's declarations, indented by nesting, and
  goes to the one chosen.

A server request runs only on an editable file the server has open; the
server gets the editor's text first. The commands are disabled without a
running server.


## Build server

sourcekit-lsp knows packages; for a project or workspace it needs a build
server that says which files belong to which target and how each file is
compiled. Ycode has one: module `YcodeBuildServer` (portable), executable
`ycode-bsp` (also `ycode bsp`). It speaks the Build Server Protocol (BSP)
with sourcekit-lsp's extensions.

### Connection

sourcekit-lsp looks for a connection file in the folder it opens:
`<folder>/.bsp/*.json` (the first by name whose `languages` include a
Swift or C-family language), else `<folder>/buildServer.json`. The file:

```json
{"name": "Ycode", "version": "0.1", "bspVersion": "2.2.0",
 "languages": ["swift", "c", "objective-c", "cpp", "objective-cpp"],
 "argv": ["<path>/ycode-bsp", "serve", "<container>", "--scheme", "S", "--destination", "D"]}
```

sourcekit-lsp starts `argv` and talks JSON-RPC over its standard input and
output (the same `Content-Length` framing as LSP).

The IDE (`BuildServerLaunch` in `YcodeLanguage`): for a `.xcodeproj` or
`.xcworkspace`, with the setting on (`Ycode.buildServer`,
`specs/ide/settings.md`) and `ycode-bsp` found (`YCODE_BSP`, next to the
running executable, the app's `Contents/Helpers`, then `PATH`), it writes
`.bsp/ycode.json` into a private folder,
`~/Library/Caches/Ycode/BuildServer/<name>-<hash of the container path>`
(Linux: `$XDG_CACHE_HOME/ycode/build-server/…`), and opens sourcekit-lsp
on that folder with the window's scheme and destination in `argv`.
**Decision:** a private folder, so that nothing is written into the
user's project; sourcekit-lsp assigns files to the workspace by the
build server's sources, not by folder, so sources outside the folder are
served. External editors can use `ycode-bsp config <container>`, which
writes `.bsp/ycode.json` next to the container.

Workspace trust: sourcekit-lsp 6.4 as shipped with the toolchain asks the
client (`window/showMessageRequest`) whether to trust a folder with
workspace-scoped configuration (`.bsp/`, `.sourcekit-lsp/`) before it
starts anything named there; an unanswered or declined request means no
build server. Ycode wrote the folder and its connection file itself, so
it passes `initializationOptions: {"bypassWorkspaceTrust": true}` in
`initialize` for that folder only. Servers without the feature ignore the
key.

### Requests

| Message | Ycode's answer |
|---|---|
| `build/initialize` | `displayName` "Ycode", `bspVersion` "2.2.0", `capabilities.buildTargetChangedProvider` true, `dataKind` "sourceKit", `data` {`indexStorePath`, `indexDatabasePath`, `prepareProvider` true, `sourceKitOptionsProvider` true, `watchers` [`**/*.pbxproj`, `**/*.xcconfig`, `**/contents.xcworkspacedata`, `**/*.xcscheme`]} |
| `build/initialized` | — (changes are reported from now on) |
| `workspace/buildTargets` | one target per native target of every project: `id.uri` `ycode-target:<project path>/<object id>?name=<target>`, `displayName`, `baseDirectory` (the project folder), `tags` (`application` for apps and tools, `test` for test bundles, else `library`), `languageIds`, `dependencies`, `dataKind` "sourceKit" |
| `buildTarget/sources` | the target's compiled sources and its headers, each `{uri, kind: 1, generated: false, dataKind: "sourceKit", data: {language, kind: "source"\|"header"}}` |
| `textDocument/sourceKitOptions` | `{compilerArguments, workingDirectory}` (the project folder), or null for a file the target does not have |
| `buildTarget/prepare` | prepares the targets (below), then null; a failed module emission is reported with `build/logMessage` (type 2) |
| `workspace/waitForBuildSystemUpdates` | re-reads changed files first, then null |
| `workspace/didChangeWatchedFiles` | re-reads changed files |
| `build/shutdown`, `build/exit` | null; exit |
| anything else | error −32601 |

Targets: native targets (`PBXNativeTarget`); aggregate and legacy targets
are left out. Sources: the Sources phase's file references, plus the
compiled files the target takes from synchronized folders, with their
per-file compiler flags (the members the PIF gets, `build-pif.md`
§Synchronized folders: membership exceptions, files taken from folders
the target does not list, `/Localized:` keys). Headers: the Headers phase
(visibility from `ATTRIBUTES` Public/Private, else project), plus headers
in synchronized folders (public or private when listed in the exception
set's `publicHeaders`/`privateHeaders`; a target without a Headers phase
lists its folders' headers as project headers). The folders' `.lproj`
sub-folders are watched with the others. Dependencies: `PBXTargetDependency`
(same project, or another project through the proxy's container portal),
plus implicit ones: a file in a Frameworks or Copy Files phase that is
another target's product (its product reference, a reference proxy, or a
product of the same file name).

Changes: every 2 s, and on `workspace/didChangeWatchedFiles` and
`waitForBuildSystemUpdates`, the server compares the modification time and
size of the project files, the workspace's contents file, the xcconfig
files the projects reference and the folders of synchronized groups. When
one changed it reloads, compares each target's sources, headers,
dependencies and settings, and sends `buildTarget/didChange` with
`{target, kind: 2}` for each target that differs (added and removed
targets included).

### Settings

Each target's settings come from Ycode's own engine (`YcodeSettings`,
`specs/build-settings.md`): the project's levels over a defaults level
the arguments need, values from swift-build's open-source
specifications:

| Setting | Default |
|---|---|
| `PRODUCT_NAME` | `$(TARGET_NAME)` |
| `PRODUCT_MODULE_NAME` | `$(PRODUCT_NAME:c99extidentifier)` |
| `SWIFT_MODULE_NAME` | `$(PRODUCT_MODULE_NAME)` |
| `SWIFT_OBJC_INTERFACE_HEADER_NAME` | `$(SWIFT_MODULE_NAME)-Swift.h` |
| `SYMROOT`, `OBJROOT` | `<index root>/Build/Products`, `<index root>/Build/Intermediates.noindex` |
| `BUILD_DIR` | `$(SYMROOT)` |
| `CONFIGURATION_BUILD_DIR`, `BUILT_PRODUCTS_DIR` | `$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)` |
| `PROJECT_TEMP_DIR` | `$(OBJROOT)/$(PROJECT_NAME).build` |
| `TARGET_TEMP_DIR` | `$(PROJECT_TEMP_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/$(TARGET_NAME).build` |
| `OBJECT_FILE_DIR_normal` | `$(TARGET_TEMP_DIR)/Objects-normal` |
| `DERIVED_FILE_DIR` | `$(TARGET_TEMP_DIR)/DerivedSources` |
| `PLATFORM_NAME`, `EFFECTIVE_PLATFORM_NAME` | the chosen SDK; `-<sdk>` except macOS (empty) |
| `CURRENT_ARCH`, `ARCHS` | the destination's `arch=`, else the host's |
| `DEVELOPER_DIR`, `TOOLCHAIN_DIR`, `PLATFORM_DIR`, `SDK_VERSION` | from the active developer folder and the SDK |

With `--settings swift-build` and the `ycode-swb` helper
(`specs/xcodebuild/show-build-settings.md`), swift-build evaluates every
setting instead, for the same SDK and with the index arena; the
arguments below read the same names (and swift-build's
`LLVM_TARGET_TRIPLE_*` when present).

Configuration: `--configuration`, else the scheme's Run configuration,
else Debug if the project has it, else the project's default.

Destination: a target is indexed for one SDK. From `SDKROOT` (when `auto`
or empty, the first of `SUPPORTED_PLATFORMS`); a destination's SDK
(`platform=iOS Simulator` → `iphonesimulator`, …, or `sdk=`) replaces it
when it is on a platform family the target supports (`iphoneos` and
`iphonesimulator` are one family); otherwise a device SDK becomes its
simulator (`iphoneos` → `iphonesimulator`, `appletvos`, `watchos`, `xros`
likewise). **Decision:** simulators by default, as indexing needs no
device. On Linux there is no SDK: Swift compiles for the host triple.

Index locations: `<derived-data root>/<name>-<hash>/Index.noindex`, the
root `~/Library/Developer/Ycode/DerivedData` (Linux:
`$XDG_CACHE_HOME/ycode/DerivedData`) or `--derived-data`, the folder name
as ycodebuild's (`DerivedDataName`). Index store `…/DataStore`; index
database `…/ycode-index-db`. Index products are kept apart from build
products so that the editor's module-only builds never mix with real ones.

### Compiler arguments

Without the compiler executable. Relative paths are made absolute from
the project folder; search-path settings split into words (quotes group,
`\` escapes) and `dir/**` adds every folder below `dir` (at most 512).

Swift (one list for every Swift file of the target, then per file):

| From | Arguments |
|---|---|
| — | `-module-name <PRODUCT_MODULE_NAME>`, every Swift source of the target |
| `SDKROOT` (a path) | `-sdk <path>` (not on Linux) |
| platform | `-target <arch>-apple-<os><deployment target>[-simulator]`; os and setting: macos `MACOSX_DEPLOYMENT_TARGET`, ios `IPHONEOS_…`, tvos `TVOS_…`, watchos `WATCHOS_…`, xros `XROS_…`, driverkit `DRIVERKIT_…`; the SDK version when unset; Linux `<arch>-unknown-linux-gnu` (`arm64` → `aarch64`) |
| `SWIFT_VERSION` | `-swift-version` (`5.0` → `5`, `6.0` → `6`, `4.2` stays) |
| `SWIFT_OPTIMIZATION_LEVEL` | the value (`-Owholemodule` → `-O`) |
| `SWIFT_ENABLE_TESTABILITY`, else `ENABLE_TESTABILITY` | `-enable-testing` |
| `SWIFT_ENABLE_APP_EXTENSION`, else `APPLICATION_EXTENSION_API_ONLY` | `-application-extension` |
| `SWIFT_LIBRARIES_ONLY`, or exactly one Swift file not named `main.swift` (unless `SWIFT_DISABLE_PARSE_AS_LIBRARY`) | `-parse-as-library` |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `-D <word>` each |
| `SWIFT_STRICT_CONCURRENCY` | `targeted` → `-strict-concurrency=targeted`; `complete` → `-enable-upcoming-feature StrictConcurrency` |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` = MainActor | `-default-isolation=MainActor` |
| `SWIFT_STRICT_MEMORY_SAFETY` = YES | `-strict-memory-safety` |
| `SWIFT_ENABLE_BARE_SLASH_REGEX` (not NO), Swift < 6 | `-enable-bare-slash-regex` |
| `SWIFT_UPCOMING_FEATURE_<NAME>` = YES | `-enable-upcoming-feature <Feature>` (18 settings) |
| `SWIFT_APPROACHABLE_CONCURRENCY` = YES | upcoming features InferIsolatedConformances, NonisolatedNonsendingByDefault; in Swift < 6 also DisableOutwardActorInference, GlobalActorIsolatedTypesUsability, InferSendableFromCaptures |
| `SWIFT_OBJC_INTEROP_MODE` = objcxx | `-cxx-interoperability-mode=default` |
| `BUILT_PRODUCTS_DIR`, `SWIFT_INCLUDE_PATHS` | `-I` each |
| test bundles | `-I $(PLATFORM_DIR)/Developer/usr/lib` |
| `BUILT_PRODUCTS_DIR`, `FRAMEWORK_SEARCH_PATHS`, test bundles' `$(PLATFORM_DIR)/Developer/Library/Frameworks` | `-F` each (Apple platforms) |
| `SYSTEM_FRAMEWORK_SEARCH_PATHS` | `-Fsystem` each |
| `$(BUILT_PRODUCTS_DIR)/include`, `HEADER_SEARCH_PATHS` | `-Xcc -I -Xcc <path>` |
| the target's include folder, the project's header folders, `USER_HEADER_SEARCH_PATHS` | `-Xcc -iquote -Xcc <path>` |
| `SYSTEM_HEADER_SEARCH_PATHS` | `-Xcc -isystem -Xcc <path>` |
| `GCC_PREPROCESSOR_DEFINITIONS` | `-Xcc -D<word>` |
| `SWIFT_OBJC_BRIDGING_HEADER` | `-import-objc-header <path>` |
| a framework or library with public or private headers (or `DEFINES_MODULE` and headers) | `-import-underlying-module` |
| `OTHER_SWIFT_FLAGS` | the words |
| per file | `-index-unit-output-path <OBJECT_FILE_DIR_normal>/<arch>/<base>.o`; the build file's `COMPILER_FLAGS` |

Clang (per file; a header gets its target's arguments, Objective-C, or
Objective-C++ when the target has `.mm` files, and no output):

| From | Arguments |
|---|---|
| language | `-x c` / `objective-c` / `c++` / `objective-c++` |
| platform, `SDKROOT` | `-target <triple>`, `-isysroot <path>` |
| `CLANG_ENABLE_MODULES` | `-fmodules`; `-fmodule-name=<module>` for a target with its own Clang module |
| `CLANG_ENABLE_OBJC_ARC`, `CLANG_ENABLE_OBJC_WEAK`, `GCC_ENABLE_OBJC_EXCEPTIONS` = NO (Objective-C) | `-fobjc-arc`, `-fobjc-weak`, `-fno-objc-exceptions` |
| `GCC_C_LANGUAGE_STANDARD` (C, Objective-C) | `-std=<value>`; `ansi` → `-ansi`; `compiler-default` → none |
| `CLANG_CXX_LANGUAGE_STANDARD`, `CLANG_CXX_LIBRARY` (C++) | `-std=` (`c++0x` → `c++11`), `-stdlib=` (not `compiler-default`, `libstdc++`) |
| `GCC_OPTIMIZATION_LEVEL` | `-O<value>` |
| `ENABLE_NS_ASSERTIONS` = NO | `-DNS_BLOCK_ASSERTIONS=1` |
| `GCC_PREPROCESSOR_DEFINITIONS` | `-D<word>` |
| quoted-include folders (as for Swift) | `-iquote` each |
| header, system header, framework, system framework paths (as for Swift) | `-I`, `-isystem`, `-F`, `-iframework` |
| `GCC_PREFIX_HEADER` | `-include <path>` |
| `WARNING_CFLAGS`; `OTHER_CFLAGS` (C++: `OTHER_CPLUSPLUSFLAGS` when set) | the words |
| per file | `COMPILER_FLAGS`; `-c <file> -o <OBJECT_FILE_DIR_normal>/<arch>/<base>.o` |

The project's header folders: the folders of every header of the
project's targets and file references. **Decision:** they stand in for
the build system's header maps, which let a quoted include find any
header of the project by name.

### Preparation

`buildTarget/prepare` makes a target's dependencies importable. For the
target's dependencies (transitively, dependencies first) and then the
target itself:

1. Folders: the products folder and the object folder.
2. Headers: public and private headers are linked (symbolic links) into
   `<products>/include/<Module>/`, so `#import <Module/Header.h>` resolves
   through `-I <products>/include`; links to headers that left the target
   are removed.
3. Module map, for a target with its own Clang module,
   `<products>/include/<Module>/module.modulemap`: `module <Module> {
   umbrella header "<Module>.h"; exclude header "<Module>-Swift.h"; export
   *; module * { export * } }` when the target has a public `<Module>.h`
   (the exclusion once the generated header exists), else `header "<h>"`
   per public header and `export *`. Clang finds it by the module's name in
   the include folder; Swift through the same `-I`.
4. Swift module, for each dependency with Swift sources, and for the
   target itself when it also has C-family sources (its generated header):
   `swiftc <the target's Swift arguments> -emit-module -emit-module-path
   <products>/<Module>.swiftmodule -experimental-skip-non-inlinable-function-bodies`
   plus, on Apple platforms, `-emit-objc-header -emit-objc-header-path
   <products>/include/<Module>/<SWIFT_OBJC_INTERFACE_HEADER_NAME>`. Skipped
   when the module exists, was emitted with the same arguments (kept in
   `<Module>.swiftmodule.ycode-args`) and is newer than the target's
   sources, headers, bridging header and dependency modules.

`swiftc`: `YCODE_SWIFTC`, else `xcrun --find swiftc` (macOS), else `PATH`.
Preparations run one at a time, apart from other requests.
**Decision:** a module-only build of Ycode's own rather than a full build
through xcodebuild or swift-build: it needs no link, signing or resources,
takes about a second for a small framework, works on Linux, and writes
only into the index arena.

### Package products

Targets that use Swift package products (`packageProductDependencies`)
take them from the PIF swift-build builds the container with
(`XcodePIFSource().makePIF(for:)`, `build-pif.md` §Package products): the
package graph from SwiftPM, with the IDE's `SourcePackages` folder. Code:
`YcodeBuildServer/PackageProducts.swift`.

- **Arguments.** The products a target's PIF target depends on, and their
  package targets transitively (products first), give the settings their
  `impartedBuildProperties` hand to clients for the configuration:
  `FRAMEWORK_SEARCH_PATHS`, `HEADER_SEARCH_PATHS`, `SWIFT_INCLUDE_PATHS`,
  `OTHER_CFLAGS`, `OTHER_SWIFT_FLAGS` (without `$(inherited)`). They are
  added after the target's own values and become flags as in the tables
  above. Expressions are expanded with the target's settings;
  `GENERATED_MODULEMAP_DIR` is swift-build's default
  `$(OBJROOT)/GeneratedModuleMaps$(EFFECTIVE_PLATFORM_NAME)`. A search
  path that cannot be expanded is dropped; so is a whole flag list with
  such a word. Host-built tools pass on nothing of their own; a macro (one
  with `SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES`) adds
  `-load-plugin-executable $(BUILD_DIR)/$(CONFIGURATION)/<tool>#<modules>`.
  Swift modules of package targets need no flag: they land in the
  products folder, which `-I` already names.
- **Preparation.** Before the Swift modules of a target and its
  dependencies, the product targets they use are built by swift-build
  (`ycode-swb build`, the same PIF) into the index arena (derived data
  `Index.noindex`: products and intermediates where the index arguments
  point, index data into its `DataStore`), with the client's
  configuration, its platform and architecture as the run destination
  (host tools build for the host) and `CODE_SIGNING_ALLOWED = NO`. Without
  the helper (`YCODE_SWB`, `PATH`, next to `ycode-bsp`) products are not
  built and the log says so. swift-build's own up-to-date checks keep
  later preparations short.
- Not covered: sources a build-tool plug-in generates for a project target
  (as other generated sources).

### Command line

```
ycode-bsp [serve] <container> [--scheme S] [--configuration C] [--destination D]
          [--derived-data DIR] [--settings resolver|swift-build] [--log FILE]
ycode-bsp config <container> [--output DIR] …    # writes DIR/.bsp/ycode.json
ycode-bsp targets <container> …                  # targets, sources, headers, dependencies
ycode-bsp args <container> <file> [--target T] … # the file's arguments, one per line
ycode-bsp prepare <container> <target>… …        # emits the modules
ycode-bsp sample <dir> [ios|portable]            # the sample project of the tests
```

### Context changes

The build server reads the scheme and the destination from its command
line, so they are fixed for the life of one server. When the window's
scheme or destination changes (any part of the destination's specifier),
the session (`WorkspaceSession+LanguageContext.swift`, shared by the macOS
window and the Linux shell) restarts the language server for the new
context:

1. A change only counts when the running server serves a context: a
   project or workspace opened through the build server. Packages, and
   servers started without the build server (the setting off, `ycode-bsp`
   not found), are left alone.
2. The restart waits 0.3 s after the last change, so that a scheme switch
   that also picks a new destination restarts once.
3. The old server gets `shutdown` and `exit`; the connection file is
   written again with the new `--scheme` and `--destination`, and
   sourcekit-lsp is started on the same folder, which starts the build
   server again.
4. Every document the old server had open is opened in the new one with
   the text last sent (`didOpen`, version 1); the window's handler for
   `workspace/applyEdit` carries over. Live issues of the old server are
   dropped at once; the new server publishes its own.
5. A change made while the server is starting is noticed when it has
   started, and restarts it.

**Decision:** a restart rather than a notification to the build server.
BSP has no request for a client to change the build server's settings,
and sourcekit-lsp starts the build server itself; a new server is the one
path that reaches every cached compiler argument. A restart of a small
project takes about a second; live issues reappear when the new server
has prepared the open files' targets.

### Status

- Covered: app, framework, static/dynamic library, tool and test targets;
  Swift, C, Objective-C, C++ and mixed targets; bridging headers; a
  framework's own Clang module under its Swift code; synchronized folders;
  cross-project dependencies; xcconfig-based settings; project-file,
  xcconfig and synchronized-folder changes.
- Swift package products used by a target (`packageProductDependencies`,
  §Package products): local and remote packages, static and dynamic
  products, C targets' module maps and macros. Needs the swift-build helper
  to build them.
- Not yet: build rules and script phases that generate sources; Mac
  Catalyst; header maps proper; `buildTarget/outputPaths`.

## Evidence

- LSP messages, positions and capabilities: the Language Server Protocol
  specification (Microsoft, open) and sourcekit-lsp's open-source
  documentation (level 1).
- Black-box runs of the public `sourcekit-lsp` tool on a small package
  (level 3): a semantic error was published for a file opened without
  building; completion after `g.` listed members; definition returned
  the declaration line.
- Shortcuts ⌃Space and ⌃⌘J: Apple's public Xcode shortcut reference
  (level 1).
- Quick Help gestures (⌥-click, Quick Help inspector) and ⌘-click: Xcode
  Help (level 1); hover verified against sourcekit-lsp: the hover for a
  struct included its declaration and doc comment (level 3).
- Quick Help inspector sections: `reference-ui-4.md` §7 (level 3).
- Build server: the Build Server Protocol specification (open, level 1);
  sourcekit-lsp's open-source build-server support (Apache-2.0,
  swiftlang/sourcekit-lsp `release/6.4.x`: the connection-file search,
  the requests it sends, its index and preparation use) and the BSP
  message types in swiftlang/swift-tools-protocols (Apache-2.0)
  (level 1).
- Workspace trust and `bypassWorkspaceTrust`: sourcekit-lsp maintainers'
  public answer on the Swift Forums ("Is SourceKit-LSP of Swift 6.4 asking
  for workspace trust?") (level 1); seen with the toolchain's
  sourcekit-lsp, which answered the prompt before starting the server and
  started it with the option (level 3).
- Setting names, their defaults and their compiler flags (tables in
  §Build server): swift-build's open-source specifications
  (`CoreBuildSystem.xcspec`, `Swift.xcspec`, `Clang.xcspec`) and its Swift
  compiler specification's rule for a lone file and `-parse-as-library`
  (Apache-2.0, swiftlang/swift-build `release/6.4.x`) (level 1).
- Black-box runs (level 3): every file of the sample iOS project
  (framework with Swift and Objective-C, app with a bridging header, test
  bundle) type-checked with `swiftc -typecheck` / `clang -fsyntax-only`
  and the generated arguments after preparation; sourcekit-lsp through
  Ycode's client gave the diagnostic, completion and cross-target
  definition the tests check, on macOS (iOS Simulator SDK) and on x86-64
  Linux (the portable sample).
- Package products (§Package products): SwiftPM's PIF and its
  `impartedBuildProperties`, swift-build's `GENERATED_MODULEMAP_DIR`
  default (`CoreBuildSystem.xcspec`) and its run-destination
  specialization of package targets (open source, Apache-2.0, level 1);
  on `Samples/PackageSamples` the local, remote and macro apps type-check
  with the generated arguments after preparation and sourcekit-lsp
  completes `LocalKit.` in `LocalPackageApp` (level 3, our code).
- OPEN QUESTION: the reference IDE's own index arguments (its header maps,
  VFS overlays and module maps for mixed targets) are not matched; Ycode's
  layout is its own.
- OPEN QUESTION: whether Xcode's ⌥-click popover uses the same sections
  (ours is plain text).
- OPEN QUESTION: Xcode's completion popup layout (icons, detail column,
  documentation pane), when it opens automatically, and how live issues
  and build issues are distinguished in the issue navigator.
- Context changes (restart on a scheme or destination change) and the Linux
  IDE's Quick Help popover, notices and jump bar symbol: Ycode's own design
  over the LSP and BSP specifications (level 1); nothing observed.
