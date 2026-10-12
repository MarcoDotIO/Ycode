# Spec: image lookup for the simulator loader

Status: §1 is **implemented** (`YcodeMachO.DependencyClosure`). Mapping and
fixups are not yet implemented.

## 1. Resolving a load command's path

Inputs: a load-command path, the loading image's directory (guest path),
the executable's directory, and the accumulated `LC_RPATH` list.

1. **Expand the prefix:**
   - `@rpath/X` becomes each rpath plus `/X`, tried in order. The rpath
     list is the executable's rpaths followed by each loader's own, in
     load order.
   - `@loader_path/X` becomes the loader's directory plus `/X`.
   - `@executable_path/X` becomes the executable's directory plus `/X`.
   - In `LC_RPATH` entries, `@loader_path` and `@executable_path` are
     expanded the same way.
2. **Look up each candidate guest path:**
   1. first in the shared cache's image list (exact install path);
   2. then as a file at `<RuntimeRoot>` plus the path. A path that is
      already inside the root is used as is.
3. **If nothing matches:** a weak reference (`LC_LOAD_WEAK_DYLIB`) is
   allowed to be missing. Any other reference is a fatal error.
4. **Re-exports:** `LC_REEXPORT_DYLIB` images are loaded like normal
   dependencies. Umbrellas such as `UIKit` re-export `UIKitCore` and four
   others.

This mirrors the behavior that `DYLD_ROOT_PATH` and `DYLD_SHARED_CACHE_DIR`
produce on macOS (`research/notes/simulator-observations.md`).

## 2. Measured closures (iOS 27.1 runtime 24A94401)

| Executable | Images | From the cache | Missing (weak) | Missing (required) |
|---|---:|---:|---:|---:|
| `sbin/launchd_sim` | 57 | 57 | 1 (`libobjc-env.dylib`) | 0 |
| Probe UIKit app | 526 | 526 | 7 | 0 |

**Open question:** at `didFinishLaunching`, the probe app reported **506**
loaded images (`_dyld_image_count`), 20 fewer than the static closure of
526 + 1. Possible causes:

- lazily loaded or dead-stripped links;
- install-path aliases that collapse into one image;
- images the cache marks as not needing to be loaded.

To resolve it, dump the full image list from the probe app at run time and
diff it against the closure.

## Evidence

- Level 1: dyld's documented `@rpath`/`@loader_path`/`@executable_path`
  semantics (`man dyld`).
- Level 3: the probe app's run-time image count, and the environment
  variables observed on macOS.
