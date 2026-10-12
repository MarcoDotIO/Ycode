# Spec: how `dyld_sim` loads the macOS host libraries

Status: **reference** for stage 3a-ii of `docs/SIMULATOR-LINUX.md` (Ycode's
own `libsystem_kernel`, `libsystem_platform`, and `libsystem_pthread`). It
answers why `dyld_sim` stops with "Library not loaded:
/usr/lib/system/libsystem_platform.dylib" (`stage3-contract.md` §12) and what
a replacement file must look like so that `dyld_sim` accepts it.

Every fact in §1–§5 comes from Apple's open-source `dyld` (evidence level 1),
read at tag **`dyld-1378`**, as compiled with `TARGET_OS_SIMULATOR` set
(that is, as `dyld_sim`). Flag and constant values come from the public macOS
SDK headers. This spec restates behavior, names, error strings, and values.
It contains no Apple source code. §6 is Ycode's checklist, derived from §1–§5.

Terms:

- **host library**: one of the macOS libraries that a simulator process
  takes from the Mac instead of from the simulator runtime (§1.1).
- **stub**: the small placeholder image that the simulator shared cache
  holds at a host library's path (§1.3).
- **sim root**: the value of `DYLD_ROOT_PATH` (`dyld-sim-handoff.md` §5).
- **override** (dyld calls it a *root*): a file on disk that `dyld_sim` loads
  in place of an image that is in the shared cache. `dyld_sim` then rewrites
  the cache's uses of the cached image to point into the file (§3.5).

## 1. Path search

### 1.1 The fixed list of host-library paths

`dyld` has one hard-coded list of "simulator support" paths. These are the
only paths for which a macOS-platform image is acceptable in a simulator
process. The comparison is an **exact, whole-string match**. It is not a
prefix match.

| # | Path |
|---|---|
| 1 | `/usr/lib/system/libsystem_kernel.dylib` |
| 2 | `/usr/lib/system/libsystem_platform.dylib` |
| 3 | `/usr/lib/system/libsystem_pthread.dylib` |
| 4 | `/usr/lib/system/libsystem_platform_debug.dylib` |
| 5 | `/usr/lib/system/libsystem_pthread_debug.dylib` |
| 6 | `/usr/lib/system/host/liblaunch_sim.dylib` |

Entries 4 and 5 are the `_debug` variants that `DYLD_IMAGE_SUFFIX=_debug`
selects. Entry 6 is not needed until `launchd_sim` runs.

The same list is used in two places:

- the path search (§1.4, case B), where it decides whether a disk file may
  replace the cache stub;
- the platform check (§2), where it decides whether a macOS image is
  accepted.

### 1.2 The order of candidate paths

For an absolute load path such as `/usr/lib/system/libsystem_platform.dylib`,
`dyld_sim` tries candidate paths in the order below. It stops at the first
candidate that produces an image. Each candidate's type name is what
`DYLD_PRINT_SEARCHING=1` prints as `possible path(<type>)`.

| Order | Candidate | Type name | Present when |
|---|---|---|---|
| 1 | `<dir>/<leaf>` for each directory in `DYLD_LIBRARY_PATH` (for a framework path: `DYLD_FRAMEWORK_PATH`) | `DYLD_FRAMEWORK/LIBRARY_PATH` | that variable is set |
| 2 | the `DYLD_VERSIONED_*` override for this install name | `DYLD_VERSIONED_FRAMEWORK/LIBRARY_PATH` | a versioned override matches |
| 3 | `$DYLD_OVERLAY_PATH` + path | `DYLD_OVERLAY_PATH` | that variable is set |
| 4 | **sim root + path**, for example `<DYLD_ROOT_PATH>/usr/lib/system/libsystem_platform.dylib` | `simulator prefix` | `DYLD_ROOT_PATH` is set and the path does not start with `@` |
| 5 | cryptex variants | `cryptex prefix` (and an on-disk-only `original path on disk` first) | only if a cryptex root path is configured; the Catalyst (`/System/iOSSupport`) variants never apply to an iOS-simulator process |
| 6 | **the path itself**, `/usr/lib/system/libsystem_platform.dylib` | `original path` | always |
| 7 | fallback directories | `DYLD_FRAMEWORK/LIBRARY_FALLBACK_PATH` | only if `DYLD_FALLBACK_LIBRARY_PATH` (or the framework variant) is set |

Notes:

- When `DYLD_IMAGE_SUFFIX` is set, each candidate is first tried with each
  suffix inserted before the extension. The type of those attempts is
  `DYLD_IMAGE_SUFFIX`. Then the plain candidate is tried.
- There are **no default fallback directories** for an iOS-simulator
  process. The default list (`/usr/local/lib`, `/usr/lib`) exists only for
  macOS and the device platforms, and only for importers built before the
  2022 SDKs. The simulator platforms are not on that list. This is why the observed error lists
  exactly two paths.
- If every candidate fails, and the path does not start with `@`, `dyld_sim`
  calls `realpath` on the original path (helper `realpath`). If the result
  is a different string, and the original is not just a shortened form of
  it, `dyld_sim` searches again with the result.
- Before the search, if the load path names an image in the shared cache
  (through the cache's path trie, which includes aliases), `dyld_sim`
  substitutes the cache's canonical path string. §1.4 depends on this.

### 1.3 The simulator shared cache holds stubs for the host libraries

Facts from the cache builder in the same tag:

- The builder accepts the three host-library paths (1–3 in §1.1) **without
  file data** when it builds a simulator cache. The builder makes stub
  images for them. Every other input must have data.
- For B&I-built simulator caches, the builder skips the thread-local-variable
  optimization. Its comment states that the cache uses a stub for
  `libsystem_pthread.dylib`, and that the stub is **patched into the cache
  at the launch of each simulator process**. The static key range of the
  real library depends on the host Mac.
- Simulator caches are always built as the **development** kind. The cache
  header field `cacheType` is 0 (`kDyldSharedCacheTypeDevelopment`).
- When a cache is built for macOS, the three host libraries (1–3 in §1.1)
  are kept on disk even though they are also in the macOS cache. They are
  kept so that simulator processes can load them as files.

`stage3-contract.md` §12 agrees: the runtime's cache has small
macOS-platform images at these paths. So, in the runtime, the load path
`/usr/lib/system/libsystem_platform.dylib` is **in the dyld cache** (as a
stub), and that cache's `dylibsExpectedOnDisk` header bit is clear. (The
bit is set only for caches built on the Mac by
`update_dyld_sim_shared_cache`.) Confirming both facts for the iOS 27.1
cache is open question 1.

### 1.4 What `dyld_sim` does with each candidate

Preconditions, as established in §1.3:

- a cache is mapped;
- the cache is the development kind, so dyld's `customerCache` flag is false;
- `dylibsExpectedOnDisk` is false;
- the load path is in the cache, as a stub.

Before the cases below, `dyld_sim` checks three things for each candidate:

- whether the candidate path matches an already-loaded image (by path or by
  install name);
- whether it is a relative path in a hardened process (it is rejected);
- whether it is a cache alias of an already-loaded image.

**Case A: the `simulator prefix` candidate** (`<root>/usr/lib/system/X`).
This candidate is a different string from the load path, so the special
simulator branch in case B does not apply. The general development-cache
rule applies:

1. `dyld_sim` calls `stat` on the candidate. A file exists only if `stat`
   succeeds **and** the file is a regular file (`S_ISREG`). For any other
   file type the reason is recorded as "not a file".
2. `dyld_sim` checks whether the candidate string is itself a cache path.
   It is not.
3. "Overrides cache" = the file exists **and** the original load path is in
   the cache. With the stub in the cache, a file found here is an override.
4. The simulator post-check: the candidate starts with the sim root, so
   `dyld_sim` strips the root and looks the rest up in the cache. A match
   whose stripped path starts with `/usr/lib/system/` is **ignored**. The
   source comment says that this avoids using the stub for the
   host-library paths. So the stub is never chosen through this candidate.

**Case B: the `original path` candidate** (`/usr/lib/system/X`). The
candidate is the same string as the load path, the original path is in the
cache, and `dylibsExpectedOnDisk` is false. This is the simulator-only
branch:

- If the path is on the §1.1 list, `dyld_sim` calls `stat` on the bare host
  path. If a regular file exists, it is used as an **override of the cache
  stub**. If there is no file, the candidate fails. The stub in the cache is
  **not** used as a fallback.
- If the path is not on the list, the image in the simulator cache is used
  and the disk is not consulted.

**When a candidate fails** (no file, and not usable from the cache),
`dyld_sim` appends to the reason text:

- the first failure starts with `tried: `, and later ones are separated by
  `, `;
- each entry is `'<candidate>' (<reason><cache-note>)`;
- `<reason>` is `no such file` for `ENOENT`, `not a file`, `blocked by
  sandbox`, `cannot override a protected system dylib`, or `errno=<n>`;
- `<cache-note>` is `, not in dyld cache` when a cache is mapped and
  `, no dyld cache` when none is mapped. It is added only when the candidate
  **starts with** `/usr/lib/`, `/System/Library/`,
  `/System/iOSSupport/usr/lib/`, `/System/iOSSupport/System/Library/`, or
  `/System/DriverKit/`.

The cache note is a **prefix heuristic**. It does not mean that a cache
lookup failed. In the observed error, ", not in dyld cache" appears on the
bare host path even though a stub exists at that path. It does not appear on
the sim-root path because that path does not start with any of the listed
prefixes.

When a candidate's file is found but cannot be loaded (§2, §3), the entry
is `'<candidate>' (<loader error>)`.

The final message, raised by the image whose dependency failed, has three
lines:

- `Library not loaded: <load path>`
- `Referenced from: <<importer UUID>> <importer path>`, plus an optional
  "built for … which is newer than running OS" note
- `Reason: <the tried list>`

### 1.5 Answers to question 1

- **`DYLD_ROOT_PATH`** adds one candidate, sim root + path, which is tried
  **before** the bare path. For the host-library paths, the stub that
  `dyld_sim` finds through that candidate is deliberately ignored. A real
  file at `<root>/usr/lib/system/X` is still a valid override, but only for
  an iOS-simulator-platform image (§2.2).
- **The bare host path** is always tried after the sim-root candidate. For
  the §1.1 paths it is checked **only on disk**. The stub in the cache is
  never accepted in its place.
- **"not in dyld cache"** is only a message chosen by path prefix (§1.4).
- **The special list** is exactly the 6 paths of §1.1, compared as whole
  strings. There is no wildcard such as `libsystem_*`.
- **A plain file on disk is acceptable**: any regular, non-empty file
  (§3.1). Symbolic links are followed by `stat`. A universal (fat) file is
  acceptable if it has a compatible slice.

## 2. Platform checks

### 2.1 The rule

The process platform is the platform of the main executable. For an iOS
simulator app it is `iOS-simulator` (`PLATFORM_IOSSIMULATOR` = 7). An image
is loadable when either rule holds:

1. **Normal rule:** the image is built for the process platform. This is
   decided from its platform load commands (§2.3). A **zippered** image
   matches each platform it contains.
2. **Host-library exception:** the process platform is a simulator platform,
   **and** the image is built for macOS (`PLATFORM_MACOS` = 1, or zippered
   with macOS), **and** the path is one of the §1.1 paths.

Other exceptions in the same function do not apply here. Some apply only to
macOS or Catalyst processes. Another allows an iOS-simulator process to
load a visionOS-simulator image.

### 2.2 Which path the exception is checked against

For a disk image, the path that is checked is **the candidate path that is
being loaded**, not the install name and not the load path:

| Image platform | Found at bare `/usr/lib/system/X` (`original path`) | Found at `<root>/usr/lib/system/X` (`simulator prefix`) |
|---|---|---|
| iOS-simulator (7) | accepted | accepted |
| macOS (1), or zippered with macOS | accepted (exception applies) | **rejected**: the candidate string is not on the list |
| anything else (iOS 2, for example) | rejected | rejected |

### 2.3 How the platform is read

- The platform comes from `LC_BUILD_VERSION` (platform, minos, sdk), or from
  the old `LC_VERSION_MIN_*` commands. `LC_VERSION_MIN_MACOSX` means macOS.
- More than one platform command is allowed only for the macOS + Mac
  Catalyst pair, which is **zippered**. Any other combination fails
  validation with `incompatible platforms: <a> - <b>`.
- An image with **no** platform command has an empty platform. Rule 1 fails,
  and so does the exception.
- **minos and sdk are never compared with the running OS for acceptance.**
  minos is used only for the "newer than running OS" note in the error
  message. The sdk version sets the **enforcement epoch** for the
  structural checks in §3.2.
- No `isHostPlatform` concept exists in this tag. The macOS "unzippered
  twin" logic is compiled only into macOS `dyld` and does not affect
  `dyld_sim`.

### 2.4 The error text

When the platform check fails, the candidate's reason is:

`mach-o file (<candidate path>), but incompatible platform (have '<image platform>', need '<process platform>')`

The platform names are `macOS`, `iOS`, `iOS-simulator`, `macCatalyst` (see
open question 4), and `zippered(macOS/Catalyst)`. In the tried list this
looks like:

`'<candidate>' (mach-o file (<candidate>), but incompatible platform (have 'macOS', need 'iOS-simulator'))`

## 3. Other load-time validation

### 3.1 The sequence for a disk image

For a file chosen in §1, `dyld_sim` does the following. Each step can fail
with the reason shown.

1. **`stat` + open + map.**
   - `stat` the path. A file of size 0 is a **tombstone**: it is treated as
     not loadable, and the reason is empty.
   - `open` the file read-only and `mmap` all of it read-only and private at
     any address (helpers `stat`, `open`, `mmap`).
   - `F_GETPATH` (50) on the descriptor gives the **real path**. That string
     becomes the loaded image's path.
   - The `stat` result gives a file ID: inode, device, and mtime, always
     marked valid.
2. **Slice selection**:
   - a fat file needs a compatible slice ("fat file, but missing compatible
     architecture (have '…', need '…')");
   - the slice must be Mach-O ("slice is not valid mach-o file");
   - the architecture must be in the process's list
     ("mach-o file, but is an incompatible architecture (have '…', need
     '…')").
   For an arm64 process the list is **`arm64`**: `CPU_TYPE_ARM64` with
   subtype `ALL` (0) or `V8` (1). arm64e is not accepted.
3. **Platform** (§2).
4. **File type.** The image must be `MH_DYLIB` (6). Bundles, executables,
   and other types fail ("cannot link against a main executable '…'" or
   "unloadable mach-o file type <n> '…'"). `MH_NO_DYNAMIC_ACCESS` (0x400)
   is rejected only for `dlopen`, not for linked loads.
5. **Deep validation** (§3.2).
6. **Code signature**, only if the image has `LC_CODE_SIGNATURE` with a
   non-zero size:
   - `dyld_sim` calls `fcntl(F_ADDFILESIGS_RETURN = 97)` with the slice
     offset, signature offset, and size.
   - If the call fails, the reason is `code signature invalid in <<uuid>>
     '<path>' (errno=…) …` for EPERM or EBADEXEC, and `fcntl(fd,
     F_ADDFILESIGS_RETURN) failed with errno=…` otherwise.
   - On success, the value written back into `fs_file_start` must be ≥ the
     signature offset. Otherwise the reason is `code signature does not
     cover entire file up to signature …`.
   - `dyld_sim` then unmaps the file and maps it again.
   - **With no `LC_CODE_SIGNATURE`, no signature call is made.** `dyld_sim`
     itself does not check signature contents or cdhashes for these images.
     The cdhash comparison in dyld's file validation is compiled out of
     `dyld_sim`.
7. **Mapping the segments.**
   - The descriptor's `fstat` must give **the same inode and mtime** as the
     `stat` in step 1. Otherwise the reasons are "file inode changed …" and
     "file mtime changed …".
   - The signature is registered again (if present).
   - **`fcntl(F_CHECK_LV = 98)` is always called, even on unsigned files**.
     A return of −1 fails the load with `code signature in <<uuid>> '<path>'
     not valid for use in process: <message>`.
   - `dyld_sim` reserves the whole VM span with `vm_allocate(ANYWHERE)`.
   - Each segment with file content is mapped with `mmap(MAP_FIXED |
     MAP_PRIVATE)` at reserve base + segment offset, with the segment's
     protections. The file offset is slice offset + segment `fileoff`.
     Zero-fill-only segments are not mapped and stay as zero memory from
     `vm_allocate`.
   - An `mmap` EPERM gives "code signing blocked mmap() of '…'" (unless the
     sandbox helper says that the sandbox blocked it). Other errors give
     "mmap(addr=…, size=…) failed with errno=…".
   - The first mapped segment must start with a valid Mach-O header.
8. **Already loaded?** Before step 1, if an already-loaded image has an
   **equal file ID** (inode, device, mtime, all valid), `dyld_sim` returns
   that image instead of loading the file again.
9. **Fixups.** Page-in linking is compiled out of `dyld_sim`, so fixups are
   applied eagerly when the image is linked. Either encoding is accepted:
   - `LC_DYLD_CHAINED_FIXUPS`. The arm64 non-PAC pointer formats are
     `DYLD_CHAINED_PTR_64` (2) and `DYLD_CHAINED_PTR_64_OFFSET` (6).
   - Opcode fixups (`LC_DYLD_INFO_ONLY`).

There is **no compatibility-version check**. The importer's
`LC_LOAD_DYLIB` compatibility version and current version are read and
ignored. There is also **no check that the install name equals the load
path**. The install name matters in three other ways (§3.4).

### 3.2 Structural validation (deep validation)

The checks run in the order below. Each failure aborts the load with the
quoted message. "SDK ≥ X" means that the image's `LC_BUILD_VERSION` sdk
falls in that release epoch or later. For macOS, version 26.x is fall 2025,
15.4–15.x is spring 2025, and 15.0–15.3 is fall 2024.

| Check | Message on failure | Applies |
|---|---|---|
| file ≥ header size, MH magic | "file is too small …" / "not a mach-o file …" | always |
| header + `sizeofcmds` ≤ file size | "load commands length … exceeds length of file …" | always |
| known file type | "unknown filetype <n>" | always |
| string offsets inside each dylib, rpath, and sub-* command | "load command #<i> string …" | always |
| exact sizes of `LC_SYMTAB`, `LC_DYSYMTAB`, `LC_UUID`, `LC_DYLD_INFO(_ONLY)`, `LC_DYLD_CHAINED_FIXUPS`, `LC_DYLD_EXPORTS_TRIE`, `LC_FUNCTION_STARTS`, `LC_BUILD_VERSION` (+ 8 bytes per tool), `LC_SEGMENT_64` (+ 80 bytes per section) | "load command #<i> … size wrong" | always |
| no unknown command that has `LC_REQ_DYLD` (0x80000000) set | "unknown required load command 0x…" | always |
| platform valid, at most the zippered pair | "unknown platform" / "incompatible platforms: …" | always |
| at most one `LC_UUID` | "too many LC_UUID load commands" | always |
| an `LC_UUID` is present | "missing LC_UUID load command" | SDK ≥ fall 2021 |
| exactly one `LC_ID_DYLIB` in a dylib | "MH_DYLIB is missing LC_ID_DYLIB" / "multiple LC_ID_DYLIB found" | always |
| links at least one dylib, **unless the install name starts with `/usr/lib/system/`** | "missing LC_LOAD_DYLIB (must link with at least libSystem.dylib)" | SDK ≥ spring 2025 |
| no duplicate linked dylib / no duplicate `LC_RPATH` | "duplicate linked dylib '…'" / "duplicate LC_RPATH '…'" | SDK ≥ fall 2025 |
| segment inside the file; filesize ≤ vmsize (except a non-mapped segment with vmsize 0 and initprot 0) | "segment '…' load command content extends beyond end of file" / "… filesize exceeds vmsize" | always |
| initprot uses only bits 0–2 | "… segment permissions has invalid bits set …" | always |
| `__TEXT` is `r-x` | "__TEXT segment permissions is not 'r-x'" | SDK ≥ fall 2019 |
| `__LINKEDIT` is `r--` | "__LINKEDIT segment permissions is not 'r--'" | SDK ≥ fall 2015 |
| `__DATA` is `rw-`; `__DATA_CONST` is `rw-` | "__DATA segment permissions is not 'rw-'" / "__DATA_CONST …" | SDK ≥ fall 2025 |
| `__DATA_CONST` has `SG_READ_ONLY` (0x10) | "__DATA_CONST segment missing SG_READ_ONLY flag" | SDK ≥ spring 2025 (this check also needs the fall 2025 permission check to be active; split-seg dylibs are exempt) |
| sections inside their segment | "section '…' end address … is beyond …" | SDK ≥ fall 2020 |
| `__TEXT` exists, its `fileoff` is 0, and it covers header + load commands in both file and VM size | "missing __TEXT segment" / "__TEXT segment fileoffset is not zero" / "load commands do not fit in __TEXT segment …" | always |
| no two segments overlap in VM or in file range | "vm range of segment '…' overlaps …" / "file range …" | always |
| segment names are unique | "duplicate segment name '…'" | SDK ≥ fall 2025 |
| segment order in load commands = file order = VM order | "segment '…' file offset out of order" / "… vm address out of order" | SDK ≥ fall 2019 (dylibs) |
| `LC_LINKER_OPTION` well formed | "malformed LC_LINKER_OPTION command" | always |

None of these checks reads the `MH_*` header flags. `dyld_sim` makes no load
decision from `MH_TWOLEVEL`, `MH_NO_REEXPORTED_DYLIBS`,
`MH_APP_EXTENSION_SAFE`, or `MH_SIM_SUPPORT`:

- `MH_TWOLEVEL` changes only how an *importer's* classic nlist binds are
  interpreted: without it, every import is a flat lookup.
- `MH_SIM_SUPPORT` (0x08000000) is used only by the static linker. Its
  header comment says that it allows macOS and simulator platform commands.
- `MH_DYLIB_IN_CACHE` (0x80000000) relaxes several checks for cache images.
  A disk file must **not** set it.

### 3.3 Page size and alignment

`dyld_sim` itself checks no page size. Alignment is the kernel's
requirement for `mmap(MAP_FIXED)`, and on Ycode the guest kernel requires
16 KiB alignment (`stage3-contract.md` §12). Therefore:

- every mapped segment's `vmaddr` (relative to `__TEXT`) and `fileoff` must
  be multiples of **0x4000**;
- every segment's `filesize` except `__LINKEDIT`'s should be a multiple of
  0x4000, so that no page that `mmap` maps from the file contains bytes that
  belong to the next segment. Ycode's mapping zero-fills only past end of
  file;
- the reservation size is the image's total VM span, from the lowest to the
  highest segment address.

### 3.4 Where the install name and file ID are used

- **Matching already-loaded images.** An image matches a load path when the
  path equals the image's recorded path (the `F_GETPATH` result) or, if that
  differs, its install name.
- **Initializer order.** An image whose install name starts with
  `/usr/lib/system/lib` is marked **below libSystem**.
  - At launch, `dyld_sim` first runs the initializers of the image whose
    install name is `/usr/lib/libSystem.B.dylib`.
  - Then it runs the initializers of every below-libSystem image, in load
    order.
  - Only then does it run all other images, bottom-up.
- **libSystem and libdyld identification.** These are identified by install
  name (`/usr/lib/libSystem.B.dylib`, `/usr/lib/system/libdyld.dylib`). In
  the simulator, both are images in the simulator cache, not host libraries.
- **File ID.** Image identity across symlinks and hard links uses
  (inode, device, mtime). Two different files with the same triple are
  treated as **the same image**.

### 3.5 What happens after the override loads: cache patching

Because the host library is an override of a cache stub (§1.4):

- `dyld_sim` builds a patch table for the override. For each **patchable
  export** that the cache's patch table lists for the stub, it looks the
  name up in the override, following re-exports (§4).
- During fixups, each cache image that uses the stub, and each uniqued GOT
  entry in the cache, is rewritten to the override's address plus the
  recorded addend. This makes cache `__DATA_CONST` temporarily writable
  (`mprotect`).
- **A listed export that the override lacks is not an error at load time.**
  - Weak-import uses become 0.
  - All other uses become the marker value **`0xbad4007`**
    (`DYLD_BADROOT_MARKER`).
  - A later call through such a use faults at `0xbad4007`. Ycode's VMM
    should report that address as "missing export in a host-library
    replacement".
- Before the cache images' fixups run, `dyld_sim` loads every image in the
  closure as a just-in-time loader. `dyld_sim` has no prebuilt-loader
  support at all.

### 3.6 Special symbols `dyld_sim` needs from these three libraries

- **None by name.** `dyld_sim` never looks up a symbol in
  `libsystem_kernel`, `libsystem_platform`, or `libsystem_pthread` by name.
  Its only special treatment of them is the path list (§1.1), the stub
  rule (§1.4), and the below-libSystem install-name prefix (§3.4).
- **System calls.** `dyld_sim` does not call into them for its own system
  calls. It uses the host helpers table (`dyld-sim-handoff.md` §3) and its
  own statically linked trap stubs.
- **Locks and threads.** `dyld_sim`'s lock, thread, and TLV callbacks go
  through the "libSystem helpers" object. That object lives in the
  simulator cache's `libdyld.dylib` and is located through a section of
  that image. The helpers in turn call `os_unfair_lock`, `pthread_key_*`,
  and similar functions. Those calls are ordinary binds from cache images,
  and they reach the host libraries through the patching in §3.5.
- **Which symbols the replacements need.** The required set is
  data-defined:
  1. the stub's patchable-export list in the cache patch table;
  2. the symbols that non-cache images (the app, test tools) import through
     the re-export chain;
  3. the functions that `libSystem.B`'s initializer calls in these
     libraries.
  This tag of `dyld` does not name the third set. See open questions 2 and
  3.

## 4. Symbol resolution through the re-export chain

- **Two-level binding.** Each import names a dependent by ordinal. For
  example, an app's import of `_pthread_self` names `libSystem.B.dylib`.
  `dyld_sim` searches that dependent in *static-link* mode:
  1. Walk the dependent's own export trie (from `LC_DYLD_EXPORTS_TRIE` or
     the export part of `LC_DYLD_INFO`). If the image has no trie, use the
     global defined symbols in its nlist table (`N_SECT` | `N_EXT`).
  2. If the dependent does not have the symbol, search **only its
     re-exported dependents** (`LC_REEXPORT_DYLIB`, or the re-export
     attribute of the newer dylib-use command), depth first, in load-command
     order. Each image is visited at most once.
- **Whole-dylib re-export.** A re-export is the entire exported trie of the
  re-exported image. Nothing is listed per symbol. The chain in the runtime
  is: `libSystem.B` → `libsystem_sim_<x>` → `libsystem_sim_<x>_host` → the
  host library. Each link makes **every** symbol in the host library's trie
  visible to the level above it.
- **Per-symbol re-export.** A trie entry with `EXPORT_SYMBOL_FLAGS_REEXPORT`
  (0x08) names a dependent ordinal and an optional new name. `dyld_sim`
  continues the search in that dependent under that name. An ordinal of 0,
  or one greater than the dependent count, fails with "re-export ordinal …
  out of range for …".
- **Flat and weak lookups** search every loaded image in *shallow* mode
  (the image's own trie, plus per-symbol re-exports). An image loaded with
  `RTLD_LOCAL` is skipped.
- **Resolvers.** `EXPORT_SYMBOL_FLAGS_STUB_AND_RESOLVER` entries run the
  resolver function for binds. Patch-table lookups (§3.5) **do not** run
  resolvers, and use the stub address instead.
- **`$ld$` symbols** (`$ld$hide$…`, `$ld$add$…`, `$ld$install_name$…`) are
  instructions for the static linker. `dyld` has no code that reads them.
  They are neither needed nor harmful in a runtime image.
- **Missing symbol** in a non-cache importer: "Symbol not found:
  <name>\n  Referenced from: <<uuid>> <importer>\n  Expected in: <<uuid>>
  <dependent>". For cache importers, see §3.5.

**Answer to question 4:** yes. An image that exports a symbol in its own
export trie under the exact mangled name (leading underscore included), as
a regular or absolute export with no resolver, satisfies:

- every two-level import that reaches it through the
  `libSystem.B` → `sim_<x>` → `sim_<x>_host` chain;
- every cache patch slot for that name.

## 5. Behavior summary for the observed failure

With the stub in the cache, `dylibsExpectedOnDisk` false, and no file
present:

1. `<root>/usr/lib/system/libsystem_platform.dylib` fails: no such file. The
   stub found by stripping the root is ignored (§1.4 case A).
2. `/usr/lib/system/libsystem_platform.dylib` fails: no such file. The stub
   is never used for a §1.1 path (case B). ", not in dyld cache" is added by
   the prefix heuristic.
3. No fallbacks. `realpath` gives the same path. `libsystem_trial` (the
   first importer reached) raises "Library not loaded".

The same happens for `libsystem_pthread` and `libsystem_kernel`.

## 6. Requirements for Ycode's replacement dylibs

Placement (pick one; A is preferred):

- [ ] **A.** Put the file at the **bare host path** in the guest namespace,
      `/usr/lib/system/libsystem_{kernel,platform,pthread}.dylib`, as a
      regular file of non-zero size. Platform may be macOS (1) or
      iOS-simulator (7).
- [ ] **B.** Or put it at `<DYLD_ROOT_PATH>/usr/lib/system/…`, but then the
      platform **must be iOS-simulator (7)**. A macOS image is rejected
      there (§2.2). B also writes into the runtime tree, which the project
      treats as read-only input, so A is preferred.
- [ ] Do not put a `/usr/lib/system/…` file inside the sim root unless B is
      intended. It is found first.
- [ ] Ycode's VFS: `stat` and `fstat` give `S_IFREG`, the same inode and
      mtime for the path and its descriptor, and a stable device number.
      The (inode, device, mtime) triple is unique across all guest files.
      `F_GETPATH` returns the guest path.

Header and load commands:

- [ ] `MH_MAGIC_64`, `CPU_TYPE_ARM64`, subtype `CPU_SUBTYPE_ARM64_ALL` (0).
      Not arm64e. Not fat (or fat with an arm64 slice).
- [ ] `filetype` = `MH_DYLIB` (6).
- [ ] flags: `MH_NOUNDEFS` (if it imports nothing), `MH_DYLDLINK`, and
      `MH_TWOLEVEL`. `MH_NO_REEXPORTED_DYLIBS` and `MH_SIM_SUPPORT` are
      optional (`dyld_sim` ignores them). Do not set `MH_DYLIB_IN_CACHE`,
      `MH_WEAK_DEFINES`, or `MH_HAS_TLV_DESCRIPTORS`.
- [ ] One `LC_ID_DYLIB` whose name is **exactly** the host path. That name
      gives the below-libSystem initializer order and install-name
      matching.
- [ ] One `LC_BUILD_VERSION`: platform 1 (macOS) with minos/sdk e.g. 26.0,
      or platform 7. `ntools` may be 0. cmdsize = 24 + 8 × ntools.
- [ ] One `LC_UUID` (required once sdk ≥ fall 2021), unique per build.
- [ ] Linked dylibs: none is allowed (the install name is under
      `/usr/lib/system/`, and nothing is synthesized). If the three
      libraries link each other, use the exact host paths and no
      duplicates.
- [ ] Segments, in this order in both file and VM: `__TEXT` (r-x, fileoff
      0, contains header and load commands), optional `__DATA_CONST` (rw-
      with `SG_READ_ONLY`), optional `__DATA` (rw-), `__LINKEDIT` (r--).
      Names are unique. VM and file ranges do not overlap. Sections are
      inside their segments. VM addresses and file offsets are 16 KiB
      aligned (§3.3).
- [ ] An export trie (`LC_DYLD_EXPORTS_TRIE` preferred) that contains
      every required symbol (§3.6) as a regular or absolute export.
      Avoid resolver exports.
- [ ] Fixups: `LC_DYLD_CHAINED_FIXUPS` with pointer format 2 or 6, or none
      if the image is position-independent without pointers.
- [ ] No unknown `LC_REQ_DYLD` commands. Every fixed-size command has its
      exact size.
- [ ] No `LC_CODE_SIGNATURE` (simplest). If one is present, Ycode's
      `F_ADDFILESIGS_RETURN` must succeed and write back an `fs_file_start`
      ≥ the signature offset.
- [ ] No Objective-C, no thread-local variables, and no weak definitions.

VMM services that these loads exercise:

- [ ] The helpers `stat`, `open`, `close`, `mmap` (any address, read-only
      private; and `MAP_FIXED` with protections), and `fcntl`:
      - `F_GETPATH` (50);
      - `F_CHECK_LV` (98), which **must return 0 for unsigned files**;
      - `F_ADDFILESIGS_RETURN` (97), only if signed.
- [ ] `fstat`, `realpath`, and `vm_allocate(ANYWHERE)`.
- [ ] `vm_deallocate` on failure, and `mprotect` on cache `__DATA_CONST`
      for patching.
- [ ] Report a fault at `0xbad4007` as a missing export (§3.5).

## Open questions

1. **Stub facts for iOS 27.1.** Confirm, from the runtime metadata that the
   other agent is collecting:
   - the cache's `cacheType` (expected 0) and the `dylibsExpectedOnDisk` bit
     (expected clear);
   - that the cache path trie holds the three host paths.
   If a stub is **not** in the cache, the file is loaded as a plain dylib
   (not as an override) and no cache patching happens. Cache images would
   then keep whatever the builder bound them to.
2. **Required export lists.** List the patchable exports of each stub from
   the cache patch table (level 2, a file format). Also list the imports
   that the `libsystem_sim_*` and `libsystem_sim_*_host` images and
   `libSystem.B` resolve through the chain. That is the minimum symbol set
   for each replacement.
3. **libSystem initializer calls.** Which entry points in the three host
   libraries the sim `libSystem.B` initializer calls, and with which
   arguments (for example the kernel, platform, and pthread init functions
   and the "late" variants). Candidate source: the open-source `Libsystem`
   (`init.c`) and `libpthread`/`libplatform`/`xnu` `libsyscall` (level 1).
   That is outside this dyld-only study.
4. **Platform name string.** `macCatalyst`'s display name was not checked.
   It does not matter for Ycode.
5. **Version skew.** This spec reads `dyld-1378`. The iOS 27.1 runtime's
   `dyld_sim` may be newer. The behavior here has been stable across recent
   tags, but recheck if a load fails with a reason not listed in §1.4 or
   §3.
6. **`liblaunch_sim`.** `/usr/lib/system/host/liblaunch_sim.dylib` is on the
   same list. It will be needed when `launchd_sim` runs (stage 6) and
   follows the same rules.

## Evidence

All §1–§5 claims are **level 1**. They come from
`apple-oss-distributions/dyld`, tag **`dyld-1378`**, fetched with `gh api`
into the dirty scratchpad and read there:

- `dyld/Loader.cpp`:
  - `getLoader` (candidate loop, the two `TARGET_OS_SIMULATOR` blocks, the
    failure-text format, the `realpath` retry);
  - the shared-cache prefix heuristic, `forEachPath`;
  - `validateFile` and `mapSegments` (`F_CHECK_LV`, `vm_allocate`, segment
    `mmap`, errors);
  - `hasExportedSymbol` and `resolveSymbol` (re-export walk, flat lookup);
  - `applyCachePatchesToOverride` and `applyCachePatches` (the
    `DYLD_BADROOT_MARKER` use).
- `dyld/JustInTimeLoader.cpp`:
  - `makeJustInTimeLoaderDisk` (file type, deep validation, signature
    registration);
  - `makeJustInTimeLoaderDyldCache` (the sim root prefix for cache images);
  - `make` (the below-libSystem install-name prefix, `altInstallName`);
  - `loadDependents` (compatibility version ignored, "Library not loaded"
    format);
  - `makePatchTable` (missing-symbol handling);
  - `matchesPath`.
- `dyld/DyldDelegates.cpp`, `dyld/DyldDelegates.h`: `fileExists`
  (`S_ISREG`, the "not a file" errno), `mapFileReadOnly` (tombstone,
  `F_GETPATH`, file ID), `registerSignature` (`F_ADDFILESIGS_RETURN` and its
  messages), and the `FileID` equality rule.
- `dyld/DyldProcessConfig.cpp`, `.h`:
  - `forEachPathVariant`, `forEachDylibFallback`, and `typeName`;
  - the development flag in the cache setup, `isOverridablePath`, and
    `isProtectedLibSystemPath`;
  - `canonicalDylibPathInCache`, `getMainArchs`.
- `dyld/dyldMain.cpp`: the launch fixup loop that calls `applyCachePatches`.
- `dyld/DyldAPIs.cpp`: libSystem-first initializer order and the
  below-libSystem pass.
- `dyld/DyldRuntimeState.cpp`: identification of libSystem and libdyld by
  install name.
- `dyld/glue.c`: in `dyld_sim`, `fcntl`, `fstat`, and `stat` go through the
  helpers.
- `dyld/SharedCacheRuntime.cpp`: `development` is taken from `cacheType`.
- `mach_o/UnsafeHeader.cpp`:
  - `isSimulatorSupportDylibPath` (the 6-path list) and
    `loadableIntoProcess`;
  - `builtForPlatform`, `platformAndVersions`, `forEachPlatformLoadCommand`;
  - `valid` and its `validStructureLoadCommands`, `validSemantics*`, and
    `validSegment`;
  - `forEachLinkedDylib` (libSystem synthesis rule).
- `mach_o/Policy.cpp`: enforcement-epoch thresholds. `mach_o/Platform.cpp`:
  platform names, version-to-epoch mapping, `libSystemDir`, zip rules.
  `mach_o/GradedArchitectures.cpp`: the arm64 load list.
- `common/MachOFile.cpp`: `compatibleSlice` (architecture and platform
  messages); `MH_TWOLEVEL` uses. `common/DyldSharedCache.cpp`:
  `hasImagePath`, and the macOS-side retention of the three host libraries.
- `cache_builder/mrm_shared_cache_builder.cpp`: null data allowed for the
  host paths ("stubs are instantiated later"), simulator caches are always
  the development kind, and sim-support paths are kept on disk.
  `cache_builder/NewSharedCacheBuilder.cpp`: the stub is "patched into the
  cache at launch" (TLV optimization skipped).
- `include/mach-o/dyld_cache_format.h`: `cacheType` values,
  `dylibsExpectedOnDisk`. `include/mach-o/dyld_priv.h`:
  `DYLD_BADROOT_MARKER` = 0xbad4007.
- **Public macOS SDK** `mach-o/loader.h`: `MH_*` flag values,
  `PLATFORM_MACOS` = 1, `PLATFORM_IOSSIMULATOR` = 7,
  `EXPORT_SYMBOL_FLAGS_REEXPORT` = 0x08, load-command values.
- **Ycode documents (cited):** `stage3-contract.md` §12 (the observed error,
  macOS-platform stubs, the 16 KiB mapping rule), `dyld-sim-handoff.md` §3
  (helper slots and `fcntl` commands).
- §6 is Ycode design, derived from the above.
- **Not used:** no Apple binary, simulator runtime file, `.claude/Xcode.app`
  content, `research/dirty/`, or Ghidra output was consulted.
