# Contributing to Ycode

Thank you for your interest. Bug reports, tests, documentation and code are all welcome. For anything large,
please open an issue first, so that we can agree on the approach before you invest the time.

Everyone follows the [Code of Conduct](CODE_OF_CONDUCT.md). To report a security problem, follow
[SECURITY.md](SECURITY.md) instead of opening an issue.

## The clean-room rules (mandatory)

Ycode can only stay independent and releasable if every contribution follows the clean-room protocol. The
full text is in [AGENTS.md](AGENTS.md), and it applies to every contributor, human or AI. **A pull request
that breaks these rules will be closed, however good the code is.**

There are two rooms, and information crosses between them only in written specs:

| Room | Where | May study Xcode's binaries? | Produces |
|---|---|---|---|
| Dirty (analysis) | `research/`; `research/dirty/` is never committed | Yes | Observations, then specs |
| The boundary | `specs/` | | Prose, tables, grammars, interface descriptions |
| Clean (implementation) | `ycode/`, `frameworks/`, `composer/` | **No** | Original source code |

1. **Never contribute Apple material, anywhere in this repository, `research/` included.** That covers code,
   decompiler pseudo-code, disassembly, method bodies, binaries, and resources (icons, nibs, templates,
   strings files, artwork, fonts), and any file copied from Xcode, an SDK or a simulator runtime.
2. **Code comes from specs.** When you write or change code in the clean room, work only from `specs/`, public
   documentation, and open source whose licence allows it (Apple's own open-source projects are fine:
   swift-build, SwiftPM, sourcekit-lsp, LLDB, XNU headers). Don't open Xcode's binaries, a disassembler or a
   Ghidra project, and don't run Xcode to find out how something behaves, while you do that work.
3. **New behaviour is specified first.** If the code needs a fact about Xcode's behaviour or a file format
   that no spec states, add it to a spec, and then implement from the spec.
4. **Specs describe behaviour and formats, not algorithms.** Write prose, tables, grammars, key names and wire
   layouts. Interop identifiers are facts and may be named: `isa` names, build-setting names, plist keys, XML
   elements, Mach trap numbers.
5. **Never commit Apple's software.** No Xcode, no simulator runtimes, no IPSWs or firmware. Tests that need a
   real project or a runtime read it from a local path at test time ([ycode/README.md](ycode/README.md)).
6. **No Apple trademarks or artwork in Ycode's own UI or assets.** Ycode's features get their own names.

### Evidence levels

Every spec ends with an **Evidence** section that gives a level for each claim. Use the first level that
answers the question, and move down the list only when the one above isn't enough:

1. Apple's open source and public documentation.
2. Files that Xcode reads and writes, studied as file formats.
3. Black-box behaviour: run the tools and compare the outputs.
4. Binary metadata: class and selector names, linked libraries, bundle structure.
5. Disassembly or decompilation. This is the last resort, only for interop-relevant formats or protocols, and
   the spec must record why it was needed. The output itself stays in `research/dirty/`.

If you are unsure whether something is allowed, ask in an issue first.

## Set up

You need Swift 6.4: Xcode 27 on macOS, or the [swift.org release](https://www.swift.org/install/) on Linux.

```sh
cd ycode
swift build
swift test
scripts/lint.sh     # needs SwiftLint
```

[ycode/README.md](ycode/README.md) covers the tools, the tests and the opt-in test inputs.
[docs/README.md](docs/README.md) is a guide to the rest of the repository.

## Before you open a pull request

- **Tests pass.** `swift build && swift test` in `ycode/` must pass on macOS, and on Linux if you touch shared
  code. Each package in `frameworks/`, and `composer/`, builds and tests on its own on both systems. Some tests
  need a GPU, KVM or a simulator runtime; they skip themselves.
- **A flaky test is not a pass.** The tests known to be flaky under load are listed in
  [ycode/README.md](ycode/README.md) and `.github/ci/known-flaky.txt`. Rerun one alone before you report it. CI
  does the same and retries nothing else. Don't add a test to the list to get a change through.
- **Lint is clean.** `ycode/scripts/lint.sh` checks `ycode/`, `frameworks/` and `composer/` against
  `.swiftlint.yml` and must report no violations. If a rule is wrong for one line, disable it for that line and
  give the reason: `// swiftlint:disable:next force_cast - <why it is safe>`.
- **No private details.** Keep host names, user names, machine paths and secrets out of the repository. Specs
  and scripts call the data directory `$YCODE_DATA`. CI scans every change with
  `python3 -I .github/scripts/scan-public.py`, and you can run that yourself.
- **`Package.resolved` follows the dependencies.** A package with remote dependencies commits its
  `Package.resolved`, which is the only record of its transitive pins (today `ycode/`, `ycode/Tools/ycode-swb/`,
  `frameworks/storekit/` and `frameworks/weatherkit/`). A package with none has no `Package.resolved`. When
  `ycode/` or `ycode-swb`'s file changes, run `python3 -I packaging/flatpak/generate-swift-dependencies.py`
  so the Flatpak build gets the same pins.
- **Docs match.** If you change what works, update the feature table in [README.md](README.md) and add a line to
  [CHANGELOG.md](CHANGELOG.md).

## Style

- Match the surrounding code: its naming, its comment density, and its references from comments to spec sections.
- Public declarations in shared libraries carry `///` comments that say what and why, not the name again, and
  name the spec section they implement.
- Keep each commit to one change, with a message that says what changed and why.

## Releases

Cutting a release follows the checklist in [docs/RELEASING.md](docs/RELEASING.md).

## Working on the simulator

Simulator work needs arm64 Linux with KVM and a Vulkan driver. Read
[docs/SIMULATOR-LINUX.md](docs/SIMULATOR-LINUX.md) and the stage contracts in `specs/simulator/` before you start.

## Licence

By contributing, you agree that your contributions are licensed under the [MIT Licence](LICENSE).
