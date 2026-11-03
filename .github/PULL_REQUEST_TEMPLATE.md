## What and why

<!-- What does this change, and why? Link the issue: "Fixes #123". -->

## How it was tested

<!-- Commands you ran, and on which systems. Say what you could not run. -->

- [ ] `swift build && swift test` on macOS
- [ ] `swift build && swift test` on Linux (needed if this touches shared code)
- [ ] `ycode/scripts/lint.sh` reports no violations
- [ ] The README's feature table and `CHANGELOG.md` are updated, if what works has changed

## Clean-room attestation

Required for every pull request. See [CONTRIBUTING.md](../CONTRIBUTING.md). A pull request that breaks these rules will be closed.

- [ ] This change contains **no Apple code or resources**: no code, binaries, templates, artwork, fonts or strings files, and nothing copied from Xcode, an SDK or a simulator runtime.
- [ ] It contains **no decompiler or disassembler output**, and nothing paraphrased line by line from it.
- [ ] Code in `ycode/`, `frameworks/` or `composer/` was written only from `specs/`, public documentation and suitably licensed open source. I did not study Xcode's binaries, a disassembler or a Ghidra project while writing it.
- [ ] Any new behaviour is specified in `specs/` first, and specs describe behaviour and formats, not Apple's algorithms.
- [ ] New or changed specs end with an **Evidence** section that gives a level (1 to 5) for each claim.
- [ ] Any new dependency has a licence that allows this use, and is recorded.
- [ ] There are no host names, user names, machine paths or secrets in this change.

**Evidence levels used** (delete if there are no spec changes):
