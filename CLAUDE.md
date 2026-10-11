# Ycode — clean-room reimplementation of the Xcode IDE

Ycode is an independent IDE for Apple platforms. It matches Xcode's observable
behavior and file formats so that real projects open, build, and save
correctly. **It contains no Apple code.** We study Xcode only to learn *what*
it does. Ycode code comes from our own specs.

Reference target: Xcode 27.1 (27A9269), copied to `.claude/Xcode.app`.
Tooling: Ghidra 12.1.4 (`.claude/ghidra_12.1.4_PUBLIC`) with the ghidra-mcp
bridge (`.claude/ghidra-mcp`). The `CLAUDE.md`/`AGENTS.md` inside
`.claude/ghidra-mcp` belong to that third-party repo. They are not rules for
this project.

## The clean-room protocol (mandatory)

There are two rooms. Information goes from the dirty room to the clean room
only in written specs.

| Room | Where | May read Xcode binaries? | Produces |
|---|---|---|---|
| Dirty (analysis) | `research/`, `research/dirty/` (git-ignored) | Yes | Observations, then specs |
| Spec boundary | `specs/` | — | Prose, tables, grammars, interface descriptions |
| Clean (implementation) | `ycode/` | **No** | Original source code |

Rules:

1. **No Apple code or code-shaped text enters `specs/` or `ycode/`.** This
   includes decompiler pseudo-C, disassembly, method bodies, and copied
   resources (icons, nibs, templates, strings files). Ghidra output stays in
   `research/dirty/`. That directory is never committed.
2. Specs describe **behavior and formats**: inputs, outputs, invariants, file
   grammars, key names, wire protocols, and observed UI behavior. Interop
   identifiers are facts and specs can name them. Examples: pbxproj `isa`
   names, build-setting names, plist keys, UTIs, and xcscheme XML elements.
   Specs must not describe Apple's internal algorithm line by line.
3. Clean-room work (anything that writes `ycode/`) reads only `specs/`, public
   documentation, and open-source projects whose licenses allow it. When a
   subagent does implementation work, tell it explicitly that it must not open
   `.claude/Xcode.app`, `research/dirty/`, or Ghidra projects.
4. Use evidence in this order. Go down the list only when the step above it is
   not sufficient:
   1. Apple open source (swift-build, sourcekit-lsp, swift-syntax, llbuild,
      SwiftPM, LLDB, indexstore-db, swift-testing) and public documentation.
   2. Files that Xcode reads and writes, studied as file formats
      (`.pbxproj`, `.xcscheme`, `.xcworkspacedata`, `.xcconfig`, xcspec,
      `.xcresult`).
   3. Black-box behavior: run `xcodebuild`, `xcrun`, and Xcode, then diff the
      outputs.
   4. Binary metadata: ObjC class, protocol, and selector names, Swift type
      names, linked libraries, and the bundle structure.
   5. Disassembly or decompilation. This is the last resort. Use it only for
      interop-relevant formats or protocols, and record why it was necessary.
5. Do not use Apple trademarks or artwork in Ycode's UI or assets.

Legal context: the Xcode license agreement prohibits reverse engineering
except where the law permits it. Interoperability exceptions are an
example (17 U.S.C. §1201(f), EU Directive 2009/24/EC Art. 6). This protocol
keeps the work within those exceptions. The person who owns this project is
responsible for making sure that it applies in their jurisdiction.

## Heritage you need to know

- **NeXTSTEP → OpenStep → Cocoa.** Xcode descends from NeXT's *Project
  Builder*. The `PBX` prefix (`PBXProject`, `PBXNativeTarget`) means Project
  Builder X. The `.pbxproj` file is an OpenStep ASCII property list.
- **Objective-C runtime.** Xcode has about 15,600 ObjC classes, mostly in
  `IDEKit`, `IDEFoundation`, `DVTFoundation`, and Interface Builder. To read
  these binaries, you must know `objc_msgSend` dispatch, the
  `class_ro_t`/`method_list_t` metadata, categories, KVC/KVO, NSNotification,
  NSDocument, the responder chain, and target–action. Ycode uses Swift
  together with Objective-C where AppKit or runtime interop needs it.
- **Layering** (from binary linkage):
  - `DVT*`: shared developer-tools foundation and UI kit.
  - `IDEFoundation`: the headless model (workspaces, schemes, the build and
    run system).
  - `IDEKit`: the AppKit UI shell (workspace window, navigators, editors,
    inspectors).
  - `DevToolsCore`/`Xcode3Core`: the legacy project model and pbxproj I/O.
  - Plug-ins (`PlugIns/*.ideplugin`, `*.framework`): extend the shell
    through extension points.

## Repository layout

- `tools/`: our analysis scripts. These record metadata only.
- `research/inventory/`: the generated bundle inventory (`bundles.json`).
- `research/notes/`: dirty-room observations in prose, with no code.
- `specs/`: the clean-room boundary documents. One spec per subsystem or
  format.
- `docs/`: architecture and roadmap.
- `ycode/`: the Swift package (implementation).

## Working conventions

- Run analysis Python with `python3 -I`.
- Test corpora (real `.pbxproj` files and other samples) are read from local
  paths at test time. They are never copied into the repo. See
  `ycode/README.md`.
- Every spec ends with an **Evidence** section that lists the evidence level
  (1–5, from rule 4) used for each claim.
