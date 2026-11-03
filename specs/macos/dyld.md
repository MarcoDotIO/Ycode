# Spec: Ycode's dynamic linker for macOS processes

Status: **implemented for Milestone A** (`ycode/MacUserland/dyld/`).
Ycode design, clean room. Sources: the public Mach-O format headers
(`<mach-o/loader.h>`, `<mach-o/fixup-chains.h>`, `<mach-o/nlist.h>`,
`<dlfcn.h>`), the process contract in
`specs/simulator/darwin-process-start.md`, and `specs/simulator/host-library-init.md`
§2.7 (`ProgramVars`). It is not derived from Apple's dyld source.

Context: `specs/macos/macos-apps.md` §3 (execution model) and §5.2 (why
Ycode has its own dynamic linker: option 2 needs a redistributable one).

## 1. Scope

Ycode's dyld ("ydl" in file and symbol names) is the first user code of a
macOS process under Ycode. It:

- loads the dependent dylibs of the main executable, recursively;
- applies their fixups (chained fixups, or the classic rebase and bind
  opcode streams);
- runs the initializers, libSystem's first;
- calls `main`, then libSystem's `exit` with its result;
- serves `dlopen`, `dlsym`, `dladdr` and the image-list queries to
  Ycode's libSystem through a private table (§7).

It is deliberately small. It has no shared cache, no closures, no
interposing and no code-signature checks (§9).

## 2. Mach-O facts used

| Fact | Value |
|---|---|
| 64-bit header magic, CPU type arm64 | `0xFEEDFACF`, `0x0100000C` (CPU subtype low 24 bits 0 = generic arm64; arm64e is not accepted) |
| Universal header magics (big-endian) | `0xCAFEBABE` (32-bit offsets, 20-byte arch records), `0xCAFEBABF` (64-bit, 32-byte records) |
| File types | `MH_EXECUTE` 2, `MH_DYLIB` 6, `MH_BUNDLE` 8 |
| Load commands read | `LC_SEGMENT_64` 0x19, `LC_SYMTAB` 0x2, `LC_LOAD_DYLIB` 0xC, `LC_ID_DYLIB` 0xD, `LC_LOAD_WEAK_DYLIB` 0x80000018, `LC_RPATH` 0x8000001C, `LC_REEXPORT_DYLIB` 0x8000001F, `LC_DYLD_INFO(_ONLY)` 0x22 / 0x80000022, `LC_LOAD_UPWARD_DYLIB` 0x80000023, `LC_MAIN` 0x80000028, `LC_DYLD_EXPORTS_TRIE` 0x80000033, `LC_DYLD_CHAINED_FIXUPS` 0x80000034 |
| Section types used | `S_MOD_INIT_FUNC_POINTERS` 0x9 (8-byte pointers), `S_INIT_FUNC_OFFSETS` 0x16 (4-byte offsets from the Mach header) |
| Segment flag | `SG_READ_ONLY` 0x10: the segment is writable only while fixups are applied |
| Chained-fixups header | 28 bytes: version (0), starts offset, imports offset, symbols offset, import count, import format, symbols format (0 = uncompressed) |
| Import formats | `DYLD_CHAINED_IMPORT` (1, 4 bytes: ordinal 8 bits, weak 1, name offset 23), `..._ADDEND` (2, plus a signed 32-bit addend), `..._ADDEND64` (3, 16 bytes: ordinal 16 bits, weak 1, name offset 32, 64-bit addend). Ordinals ≥ 0xF0 (or ≥ 0xFFF0) are the negative special values |
| Per-segment starts | size 4, page size 2, pointer format 2, segment offset 8, max valid pointer 4, page count 2, then one 16-bit start per page; `0xFFFF` = no fixups on the page |
| Pointer formats accepted | `DYLD_CHAINED_PTR_64` (2: rebase target is an unslid address) and `DYLD_CHAINED_PTR_64_OFFSET` (6: rebase target is an offset from the Mach header). Both: bit 63 = bind; next-in-chain 12 bits at 51 with a 4-byte stride; rebase target 36 bits and high byte 8 bits at 36; bind ordinal 24 bits and addend 8 bits at 24 |
| Export-trie terminal flags | kind in the low 2 bits (regular 0, thread-local 1, absolute 2); weak definition 0x4; re-export 0x8 (then ordinal and import name); stub-and-resolver 0x10 (then stub offset and resolver offset) |
| Special library ordinals | 0 self, −1 main executable, −2 flat lookup, −3 weak lookup |
| Classic opcodes | The rebase and bind opcode sets of `LC_DYLD_INFO` (high nibble opcode, low nibble immediate), pointer type 1 only |
| `dlsym` pseudo-handles | `RTLD_NEXT` −1, `RTLD_DEFAULT` −2, `RTLD_SELF` −3, `RTLD_MAIN_ONLY` −5 |

These are interoperability facts from the public headers (evidence level 1).
`ycode/MacUserland/common/yc_macho.h` declares them in Ycode's own names.

## 3. The process contract with the VMM

`ycode-simd --macos` (see `macos-apps.md` §3) builds the process:

1. Maps the **main executable** at its preferred addresses (no slide), each
   segment with its initial protection; `__PAGEZERO` stays unmapped.
2. Maps **Ycode's dyld** (`/usr/lib/dyld` in the macOS userland root) at
   the fixed dynamic-linker base the simulator path also uses for its
   loader, sliding it there. The dyld image has **no fixups at all** (the
   build checks it, §10), so the slide needs no processing.
3. Writes the argument block below the stack top: at `SP` the main
   executable's Mach-header address, then `argc`, `argv[]`, NULL, `envp[]`,
   NULL, `apple[]`, NULL, then the strings (`darwin-process-start.md` §1.3).
   `apple[]` contains `executable_path=<guest path>`.
4. Sets `TPIDRRO_EL0` to the main thread's TSD base (`host-libraries.md`
   §8.3), maps the commpage, and starts the main thread at the dyld's
   `LC_MAIN` entry with `SP` as above and every other register zero.

`SP` is not 16-byte aligned at entry; the entry code (`ydl_start.S`) passes
it to `ydl_main` in `x0`, aligns `SP` down, and clears the frame pointer and
link register.

## 4. Loading

### 4.1 Order

The main executable is image 0. Images are kept in a list; dependencies are
loaded breadth-first: for each image in list order, each of its dependent
libraries is found or loaded and appended. A library already in the list
(matched by the path it was loaded from or by its install name) is reused.

### 4.2 Finding a library

For a dependency name `N` of image `L`:

1. If `DYLD_LIBRARY_PATH` is set: each of its directories with the leaf name
   of `N`.
2. `@executable_path/…`: relative to the main executable's directory.
3. `@loader_path/…`: relative to `L`'s directory.
4. `@rpath/…`: each `LC_RPATH` of `L`, then of the main executable; an
   rpath may itself start with `@executable_path` or `@loader_path`.
5. Otherwise the path itself.

A missing weak dependency (`LC_LOAD_WEAK_DYLIB`) is skipped; its symbols
bind to 0 when the import is weak. A missing required dependency ends the
process (§8).

### 4.3 Mapping a library

1. Read the first 4 KB. For a universal file, pick the generic arm64 slice.
2. Accept only 64-bit arm64 `MH_DYLIB` or `MH_BUNDLE`.
3. Reserve one inaccessible anonymous range covering every segment
   (rounded to 16 KB pages); the kernel chooses the address.
4. Map each segment's file part over the reservation with its initial
   protection (`MAP_FIXED | MAP_PRIVATE` of the file); a zero-fill tail on
   the last file page is cleared (the page is made writable for that
   moment); the remaining zero-fill pages get the segment's protection.
5. The slide is the loaded header address minus the unslid address of the
   segment that maps file offset 0.

## 5. Fixups

All fixups of all images are applied before any initializer runs. While an
image is fixed up, its `SG_READ_ONLY` segments are made writable and
afterwards read-only again.

- **Chained fixups.** Every import is resolved first (§6) into a target
  table (address plus the import's addend; a missing weak import is 0).
  Then each segment's chains are walked page by page: a bind stores
  `target[ordinal] + 8-bit addend`; a rebase stores the slid target with
  the high byte placed in bits 56–63. Chains must stay inside their page;
  other pointer formats (arm64e and 32-bit) are refused with a clear error.
- **Classic opcodes.** The rebase stream adds the slide to each pointer;
  the bind and lazy-bind streams bind each location. Lazy binds are done
  eagerly (Ycode's dyld has no stub binder). Threaded binds (arm64e) are
  refused.

## 6. Symbol resolution

- **Two-level namespace.** An import with ordinal `k ≥ 1` is looked up in
  the image's `k`-th dependency; 0 in the image itself; −1 in the main
  executable; −2 in every image in load order (flat); −3 flat, then the
  image itself.
- **Lookup in an image:** its export trie. A re-export entry continues in
  the named dependency under the import name (or the same name). If the
  trie has no entry, the image's `LC_REEXPORT_DYLIB` dependencies are
  searched in order. Recursion is bounded (depth 32).
- **Values:** regular and thread-local exports are header-relative; an
  absolute export is the value itself; a stub-and-resolver export calls
  the resolver once and uses its result.
- **Not found:** a weak import binds to 0; otherwise the process ends with
  a "Symbol not found" error that names the symbol, the referencing image
  and the expected image (§8).

Weak-definition coalescing across images is not done: the first lookup
result wins.

## 7. Initializers and the libSystem interface

### 7.1 Order

1. libSystem (the image whose install name is `/usr/lib/libSystem.B.dylib`)
   first, after its own dependencies.
2. Then the main executable's dependency graph, depth-first: an image's
   initializers run after those of its non-upward dependencies.

Each initializer is called as
`init(argc, argv, envp, apple, &program_vars)`.
`program_vars` is the public five-pointer layout: Mach header of the main
executable, `&argc`, `&argv`, `&environ`, `&progname`
(`host-library-init.md` §2.7).

### 7.2 The private table

Before any initializer runs, the dyld stores the address of its interface
table into libSystem's exported variable `_ycode_dyld_api` (a pointer). The
table (`ycode/MacUserland/common/yc_dyld_api.h`) is a Ycode-private
contract, **version 1**; later versions only append members:

| Member | Meaning |
|---|---|
| `version` | 1 |
| `image_count`, `image_header`, `image_name`, `image_slide` | The image list (for `_dyld_image_count` and friends) |
| `dlopen`, `dlsym`, `dlclose`, `dlerror`, `dladdr` | The `<dlfcn.h>` functions. `dlsym` adds the leading underscore. `dlclose` never unloads. `dladdr` finds the image by address range and the nearest preceding defined symbol in its symbol table |
| `add_image_callback` | `_dyld_register_func_for_add_image`: the callback runs at once for every loaded image and later for each image `dlopen` adds |
| `executable_path` | The main executable's guest path |

A big spin lock serializes `dlopen` (loading and fixups); initializers and
callbacks run outside it.

### 7.3 After `main`

The dyld calls libSystem's `exit` (the export `_exit`) with `main`'s
return value, so atexit handlers run and stdio is flushed. Without
libSystem it makes the `exit` system call itself.

## 8. Errors and diagnostics

- A fatal load error prints `dyld[<pid>]: <message>` on standard error,
  ends the process through `abort_with_payload` with the dyld reason
  namespace (6), and falls back to `exit(134)`.
- Messages: `Library not loaded: <name>` with `Referenced from: <image>`;
  `Symbol not found: <name>` with `Referenced from:` and `Expected in:`;
  format errors name the image.
- `DYLD_PRINT_LIBRARIES` (non-empty, not `0`) prints each image path as it
  is mapped.

## 9. Not supported (Milestone A)

Shared caches; prebuilt closures; `LC_UNIXTHREAD` main executables;
arm64e (pointer authentication, threaded binds, arm64e chain formats);
thread-local variables (`_tlv_bootstrap`); interposing; insertion
libraries (`DYLD_INSERT_LIBRARIES`); unloading; `RTLD_NEXT` precision (it
is a flat lookup); weak-definition coalescing; code-signature or
library-validation checks; platform and minimum-OS checks between images.
Limits: 256 images, 64 dependencies and 16 segments per image.

## 10. Build

- Compiled for `arm64-apple-macos14.0` (Darwin calling convention),
  freestanding, without a C library; the objects' platform tags are
  stripped (as `SimHostLibs/build.sh` does) and the image is linked with
  `ld64.lld` as an `MH_EXECUTE` with entry `__ydl_start` and no libraries.
- The build fails unless the image's chained-fixups data has **no**
  fixups (no pointer that needs a slide).
- `ydl_format.c` has no system calls and no global state, so the same file
  is compiled into a host unit test (`MacUserland/tests/`).

## 11. Tests

Host unit tests for `ydl_format.c`: LEB128 edge cases; export-trie lookup
(regular, absolute, re-export, resolver, missing, malformed); chained
import decoding for the three formats; chain application for both pointer
formats; rebase and bind opcode streams. End-to-end: the Milestone A
samples (`macos-apps.md` §9.1).

## Evidence

| Claim | Level |
|---|---|
| §2 format facts | 1 (public `<mach-o/*.h>` and `<dlfcn.h>` headers) |
| §3 process contract | 1, via `darwin-process-start.md` |
| `ProgramVars` layout, libSystem-first initializer order | 1, via `host-library-init.md` §1.1 and §2.7 |
| Everything else (search order details, the private table, errors) | Ycode design |
