# Spec: Mach-O images and the dyld shared cache (read-only)

Status: **in progress** in `ycode/Sources/YcodeMachO`. This is the format layer
of the Linux simulator loader (see `docs/SIMULATOR.md`, option B). It parses
files and maps nothing. Execution is a later stage.

All integers are little-endian unless noted otherwise. The layouts come from
Apple's open-source `xnu` (`EXTERNAL_HEADERS/mach-o/loader.h`, `fat.h`) and
`dyld` (`include/mach-o/dyld_cache_format.h`) headers, which are under the
APSL. This spec restates them as interop facts. Ycode's code is written from
this spec and does not copy those headers.

## 1. Universal (fat) files

- Magic is **big-endian**: `0xCAFEBABE` for 32-bit offsets, `0xCAFEBABF` for
  64-bit offsets. The next u32 is the slice count.
- Each 32-bit-offset entry is 20 bytes: `cputype`, `cpusubtype`, `offset`,
  `size`, `align`, all big-endian u32.
- Each 64-bit-offset entry is 32 bytes: `cputype` u32, `cpusubtype` u32,
  `offset` u64, `size` u64, `align` u32, `reserved` u32, all big-endian.
- CPU types: arm64 = `0x0100000C`, x86-64 = `0x01000007`. The low 24 bits
  of the CPU subtype select the arm64 variant: 0 = arm64, 2 = arm64e. The
  high byte holds flags (`0x80` on arm64e slices).
- Observed: the simulator runtime ships host-side helpers
  (`launchd_sim_trampoline`, `iokitsimd`) as **macOS-platform** universal
  binaries with arm64, arm64e, and subtype-12 slices. Apple's `lipo` names
  the subtype-12 slice `arm64e.x1`. There is no published mapping, so Ycode
  shows the raw subtype.

## 2. Thin 64-bit Mach-O

Header (32 bytes): `magic` = `0xFEEDFACF`, `cputype`, `cpusubtype`,
`filetype`, `ncmds`, `sizeofcmds`, `flags`, `reserved`.

| filetype | Meaning |
|---|---|
| 2 | executable |
| 6 | dylib |
| 7 | dynamic linker |
| 8 | bundle |
| 0xB | dSYM |
| 0xC | kext bundle |

The load commands follow the header. Each one starts with `cmd` (u32) and
`cmdsize` (u32, a multiple of 8). The commands Ycode reads:

| cmd | Name | Payload after cmd/cmdsize |
|---|---|---|
| `0x19` | SEGMENT_64 | `segname[16]`, `vmaddr` u64, `vmsize` u64, `fileoff` u64, `filesize` u64, `maxprot` u32, `initprot` u32, `nsects` u32, `flags` u32, then `nsects` × 80-byte sections (see below) |
| `0x0C`, `0x80000018`, `0x8000001F`, `0x80000023`, `0x20` | LOAD_DYLIB, LOAD_WEAK_DYLIB, REEXPORT_DYLIB, LOAD_UPWARD_DYLIB, LAZY_LOAD_DYLIB | `name` offset u32 (from the command start), `timestamp`, `current_version`, `compatibility_version` |
| `0x0D` | ID_DYLIB | the same as LOAD_DYLIB |
| `0x0E` | LOAD_DYLINKER | `name` offset u32 |
| `0x1B` | UUID | 16 bytes |
| `0x32` | BUILD_VERSION | `platform`, `minos`, `sdk`, `ntools` (u32 each), then `ntools` × (`tool`, `version`) |
| `0x80000028` | MAIN | `entryoff` u64 (offset from the start of `__TEXT`), `stacksize` u64 |
| `0x8000001C` | RPATH | `path` offset u32 |
| `0x1D`, `0x80000034`, `0x80000033`, `0x26`, `0x29` | CODE_SIGNATURE, DYLD_CHAINED_FIXUPS, DYLD_EXPORTS_TRIE, FUNCTION_STARTS, DATA_IN_CODE | `dataoff` u32, `datasize` u32 (offsets into `__LINKEDIT`'s file range) |
| `0x02` | SYMTAB | `symoff`, `nsyms`, `stroff`, `strsize` |
| `0x0B` | DYSYMTAB | 18 × u32 |
| `0x2C` | ENCRYPTION_INFO_64 | `cryptoff`, `cryptsize`, `cryptid` (nonzero means the image is encrypted; Ycode refuses to load it), `pad` |

The fields of a SEGMENT_64 section (80 bytes) are: `sectname[16]`,
`segname[16]`, `addr` u64, `size` u64, `offset` u32, `align` u32, `reloff`
u32, `nreloc` u32, `flags` u32, `reserved1..3` u32.

Strings referenced by an offset inside a load command are NUL-terminated
and lie within that command. Fixed-size name fields are NUL-padded, not
necessarily NUL-terminated.

Versions are packed as `xxxx.yy.zz`: the major version is the upper 16
bits, then one byte each for minor and patch.

| platform | Meaning |
|---|---|
| 1 | macOS |
| 2 | iOS |
| 3 | tvOS |
| 4 | watchOS |
| 5 | bridgeOS |
| 6 | Mac Catalyst |
| **7** | **iOS Simulator** |
| 8 | tvOS Simulator |
| 9 | watchOS Simulator |
| 10 | DriverKit |
| 11 | visionOS |
| 12 | visionOS Simulator |

Protections are bits: read 1, write 2, execute 4.

## 3. dyld shared cache

A cache is one **main file** plus optional **subcache files** that share a
virtual address space. Example: `dyld_sim_shared_cache_arm64` with `.01`,
`.atlas`, and `.map` beside it.

### Header (at file offset 0 of each cache file)

`magic` is 16 bytes, NUL-padded, and starts with `dyld_v1` followed by
spaces and the architecture (for example `dyld_v1  arm64`). The header has
grown over time. **A field exists only if its offset is below
`mappingOffset`**, because the mapping table starts right after the header.

| Offset | Field | Type |
|---|---|---|
| 0x10 | mappingOffset | u32 |
| 0x14 | mappingCount | u32 |
| 0x18 | imagesOffsetOld | u32 |
| 0x1C | imagesCountOld | u32 |
| 0x20 | dyldBaseAddress | u64 |
| 0x28 | codeSignatureOffset / 0x30 size | u64 / u64 |
| 0x48 | localSymbolsOffset / 0x50 size | u64 / u64 |
| 0x58 | uuid | 16 bytes |
| 0x68 | cacheType (0 development, 1 production, 2 universal) | u64 |
| 0xD8 | platform (as in §2) | u32 |
| 0xDC | bit field: formatVersion (bits 0–7), dylibsExpectedOnDisk (bit 8), **simulator (bit 9)**, locallyBuiltCache (bit 10), builtFromChainedFixups (bit 11), newFormatTLVs (bit 12) | u32 |
| 0xE0 | sharedRegionStart | u64 |
| 0xE8 | sharedRegionSize | u64 |
| 0xF0 | maxSlide | u64 |
| 0x138 | mappingWithSlideOffset | u32 |
| 0x13C | mappingWithSlideCount | u32 |
| 0x16C | osVersion | u32 |
| 0x170 | altPlatform | u32 |
| 0x174 | altOsVersion | u32 |
| 0x188 | subCacheArrayOffset | u32 |
| 0x18C | subCacheArrayCount | u32 |
| 0x190 | symbolFileUUID | 16 bytes |
| 0x1C0 | imagesOffset | u32 |
| 0x1C4 | imagesCount | u32 |
| 0x1C8 | cacheSubType | u32 |

The image list is at `imagesOffset`/`imagesCount` when that field exists.
Otherwise it is at `imagesOffsetOld`/`imagesCountOld`.

### Mapping table

Each `mappingCount` entry is 32 bytes: `address` u64, `size` u64,
`fileOffset` u64, `maxProt` u32, `initProt` u32.

The extended table at `mappingWithSlideOffset` has 56-byte entries:
`address`, `size`, `fileOffset`, `slideInfoFileOffset`, `slideInfoFileSize`,
`flags` (u64 each), then `maxProt` and `initProt` (u32 each).

| Flag bit | Meaning |
|---|---|
| 0 | auth data |
| 1 | dirty data |
| 2 | const data |
| 3 | text stubs |
| 4 | dynamic config data |
| 5 | read-only data |
| 6 | const TPRO data |

### Image list

Each entry is 32 bytes: `address` u64 (the image's Mach-O header address in
the cache's VM space), `modTime` u64, `inode` u64, `pathFileOffset` u32
(file offset of a NUL-terminated install path), `pad` u32.

### Subcaches

The subcache table is at `subCacheArrayOffset`. If the header contains
`cacheSubType` (offset 0x1C8 is below `mappingOffset`), each entry is 56
bytes: `uuid[16]`, `cacheVMOffset` u64, `fileSuffix[32]`. The file name is
the main file name plus the suffix. Otherwise each entry is 24 bytes,
`uuid[16]` and `cacheVMOffset` u64, and the suffix is `.N` (1-based).

Each subcache has its own header and mapping table. Its `uuid` must match
the entry. To read the bytes at a cache VM address, find the mapping that
contains the address across the main cache and all its subcaches. The file
offset is then `mapping.fileOffset + (address − mapping.address)` in that
mapping's file.

## Evidence

- Level 1: Apple open source (`xnu` and `dyld` headers), read through the
  GitHub API on 2026-10-11.
- The layout is checked by parsing the real iOS 27.1 simulator runtime's
  cache and binaries (see the tests and `research/notes`).
