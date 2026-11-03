# Ycode documentation

New here? Start with the [README](../README.md). It says what Ycode is, what works and how to install it.

## Guides

| Page | Read it for |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the IDE is put together: what is reused, what is rebuilt, the modules, the milestones |
| [PARITY.md](PARITY.md) | The feature-by-feature audit against Xcode 27.1 and its developer tools, and the Linux IDE's plan |
| [FUTURE.md](FUTURE.md) | The roadmap |
| [SIMULATOR.md](SIMULATOR.md) | The simulator: where it stands, what it needs, and why it works the way it does |
| [SIMULATOR-LINUX.md](SIMULATOR-LINUX.md) | The simulator's design, and how to build and run it on arm64 Linux |
| [SCENE-COMPOSER.md](SCENE-COMPOSER.md) | The design of the Scene Composer |

## Background

These pages record one piece of work at one date. They aren't kept up to date.

| Page | What it is |
|---|---|
| [postmortem-kvm-sve.md](postmortem-kvm-sve.md) | How a lost-writes bug in the simulator was traced to a host kernel bug |
| [native-loader-evaluation.md](native-loader-evaluation.md) | An evaluation of open-source Mach-O loaders as a basis for a native mode |

## Elsewhere in the repository

| Page | Read it for |
|---|---|
| [CONTRIBUTING.md](../CONTRIBUTING.md) | How to contribute, and the clean-room rules |
| [AGENTS.md](../AGENTS.md) | The full clean-room protocol, for people and for AI coding agents |
| [ycode/README.md](../ycode/README.md) | Developing Ycode: tools, tests, test inputs |
| [frameworks/README.md](../frameworks/README.md) | The open framework packages |
| [composer/README.md](../composer/README.md) | The Scene Composer's core and command line |
| [packaging/README.md](../packaging/README.md) | How the disk image and the Flatpak are built, and the Flatpak's permissions |
| [CHANGELOG.md](../CHANGELOG.md) | What changed in each release |

## The top-level folders

The folders follow the clean-room protocol: analysis on one side, code on the other, and written specs between them.

| Folder | Room | What it holds |
|---|---|---|
| `ycode/` | Clean | The Swift package with the IDE, the command-line tools and the simulator. This is where most code lives. |
| `frameworks/` | Clean | Open implementations of Apple frameworks, one Swift package each, including OpenViews (SwiftUI), which draws the Linux IDE. |
| `composer/` | Clean | The Scene Composer's core and its `ycode-scene` tool. |
| `specs/` | Boundary | One specification per subsystem or format: behaviour, not code. Each ends with its evidence. This is the only path from analysis to code. |
| `research/` | Dirty | Our own probes and experiments, their results, and observations written in prose. Clean-room work doesn't read it. |
| `tools/` | Dirty | Analysis scripts. They record metadata only. |
| `packaging/` | Neither | Packaging for the disk image and the Flatpak, and the app icon. |
| `docs/` | Neither | The pages above. `docs/images/` holds the README's logo and screenshots: replace `hero-dark.png`, `hero-light.png` or `logo.svg` under the same names to update them. |
| `.github/` | Neither | CI and release workflows, their scripts, and the issue and pull-request templates. |
