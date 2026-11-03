# Ycode Scene Composer (core and CLI)

The platform-neutral core of the Ycode Scene Composer, a scene editor for
RealityKit content that runs on Linux and macOS, and its command-line tool
`ycode-scene`. Design: `docs/SCENE-COMPOSER.md`; Ycode decisions:
`specs/tools/scene-composer/ycode-design.md`. Clean-room code: behaviour of
the reference comes only from `specs/tools/scene-composer/`.

Depends on `../frameworks/usd` (package `ycode-usd`) by path; no other
dependencies.

## Modules

| Module | Content |
|---|---|
| `SceneComposerCore` | `SceneDocument` (edit target layer, composed stage, selection, undo/redo of spec deltas, grouping, change observers, open/save), edits (create, delete/deactivate, rename, reparent, duplicate, copy/paste, attributes and time samples, metadata, transforms, references, variant selections, material binding, components), `Xform`/`TRS`/`Matrix4`/`Quat` (USD conventions), `ComponentCatalogue` + `RealityKitComponentStorage`, `SceneValidator` |
| `SceneComposerCLI` | the `ycode-scene` commands, callable from tests |
| `ycode-scene` | the executable |

## `ycode-scene`

    ycode-scene info <file>
    ycode-scene tree <file> [--layer] [--all] [--components]
    ycode-scene cat <file> [--flatten] [--sorted]
    ycode-scene convert <input> <output> [--flatten] [--format usda|usdc|usdz]
    ycode-scene validate <file> [--strict]
    ycode-scene edit <file> [-o <output>] <operation>...
    ycode-scene components

Example:

    ycode-scene edit Scene.usda \
        --add-prim /Root/Ball Sphere --set /Root/Ball.radius double 0.25 \
        --translate /Root/Ball 0 1 0 --add-component /Root/Ball RealityKit.Collider
    ycode-scene validate Scene.usda && ycode-scene convert Scene.usda Scene.usdz

## Tests

`swift build && swift test` — 22 tests (core 16, CLI 6).

| Round 1 results | macOS (arm64) | Linux x86-64 (Ubuntu 26.04) | Linux arm64 (Thor, Ubuntu 24.04) |
|---|---|---|---|
| `frameworks/usd` | 44 passed | 44 passed | 44 passed |
| `composer` | 22 passed | 22 passed | 22 passed |

Transform tests carry matrices computed by usd-core (OpenUSD) for the same
layer.

## Not done yet

The editor UI and viewport, content-package projects, the compiler front
end, Shader Graph editing with RealityKit nodes, timelines, particles and
audio: see the rounds in `docs/SCENE-COMPOSER.md` §6.
