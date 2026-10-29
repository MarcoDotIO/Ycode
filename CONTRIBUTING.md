# Contributing to Ycode

Thank you for your interest. Ycode is **extremely experimental**: expect large
refactors, moving interfaces, and work in progress everywhere. Please open an
issue to discuss a change before you invest a lot of time in it.

## 1. The clean-room rules (mandatory)

Ycode can only stay independent and releasable if every contribution follows
the clean-room protocol in [AGENTS.md](AGENTS.md). In short:

1. **Never contribute Apple material.** That covers code, decompiler
   pseudo-code, disassembly, method bodies, binaries, resources (icons, nibs,
   templates, strings files, artwork), and files copied from Xcode or from a
   simulator runtime. This applies to every directory, including `research/`.
2. **Implementation (`ycode/`, `frameworks/`) comes from specs.** When you
   write or change code there, work only from `specs/`, public
   documentation, and open source whose license allows it (for example
   Apple's open-source projects: swift-build, SwiftPM, sourcekit-lsp, LLDB,
   XNU headers). Do not open Xcode's binaries or a disassembler while you
   write Ycode code.
3. **New behavior is specified first.** If the code needs a fact about Xcode's
   behavior or file formats that no spec states yet, add or extend a spec in
   `specs/` first. Then implement from the spec.
4. **Specs describe behavior and formats, not algorithms.** Write prose,
   tables, grammars, key names and wire layouts. Interop identifiers are fine:
   `isa` names, build-setting names, plist keys, XML element names, Mach trap
   numbers. Every spec ends with an **Evidence** section that gives the
   evidence level (1–5, defined in AGENTS.md, rule 4) for each claim. Prefer
   the lowest level that works: open source and documentation, then file
   formats, then black-box behavior. Binary metadata comes after that, and
   disassembly only as a documented last resort for interop.
5. **Never commit Apple's software.** No Xcode, no simulator runtimes, no
   IPSWs or firmware. Tests that need real projects or a runtime read them
   from local paths at test time (see [ycode/README.md](ycode/README.md)).
6. **No Apple trademarks or artwork in Ycode's own UI or assets.**

If you are unsure whether something is allowed, ask in an issue first.
Pull requests that break these rules will be closed.

## 2. Practical notes

- Swift 6.4. `cd ycode && swift build && swift test` must pass on macOS. If
  you touch shared code, it must also pass on Linux.
- Each package in `frameworks/` builds and tests on its own, on macOS and on
  Linux (`frameworks/README.md`).
- Lint with `ycode/scripts/lint.sh` (needs [SwiftLint](https://github.com/realm/SwiftLint)).
  It checks `ycode/` and `frameworks/` against `.swiftlint.yml` and must
  report no violations. If a rule is wrong for one line, disable it for that line
  with a reason: `// swiftlint:disable:next force_cast - <why it is safe>`.
- Public declarations in shared libraries carry `///` doc comments: what
  and why, not the name again, with the spec section they implement.
- Simulator work needs arm64 Linux with KVM and a Vulkan driver. Read
  [docs/SIMULATOR-LINUX.md](docs/SIMULATOR-LINUX.md) and the stage contracts
  in `specs/simulator/` before you start.
- Keep machine-specific hostnames, user names and paths out of the
  repository. Specs and scripts refer to the data directory as `$YCODE_DATA`.
- Match the style of the surrounding code: its naming, its comment density,
  and its references from code comments to spec sections.
- Keep each commit to one change, with a message that says what changed and why.
