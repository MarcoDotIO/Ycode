# CPU feature publication: observations (2026-10-23)

Dirty-room notes for `specs/simulator/cpu-features.md` (lead L1 of a private note from an
outside practitioner, kept off the public repository). No disassembly or decompilation
was used. Raw outputs are in `research/dirty/cpufeat/` (git-ignored). Probe
sources are in `research/experiments/cpufeat/`.

## Method

- Reference: a test simulator `ycode-test-cpufeat` (iPhone Duo, iOS 27.1
  24A94401; the only iPhone type this runtime accepts) on this Mac
  (Apple M3 Max, macOS 27.2 26B5112a). Three probes of our own, built with
  `-target arm64-apple-ios27.1-simulator` and run with `simctl spawn`:
  - `cpufeat_probe.c`: walks every sysctl OID (`{0,2}` next-OID,
    `{0,1}` name, `{0,4}` format), prints `hw.*`, `machdep.*` and `kern.os*`;
    prints the raw bytes of `hw.optional.arm.caps`; reads the commpage
    words at their public addresses (base `0x0000000FFFFFC000`).
  - `byname_probe.c`: `sysctlbyname` for chosen names and `uname`, to see
    whether the simulator's libsystem answers differently from the kernel
    walk. It does not.
  - `idregs_probe.c`: reads `DCZID_EL0` and `CTR_EL0` at EL0 with a SIGILL
    guard.
  The simulator was deleted afterwards.
- Host comparison: `sysctl hw machdep` and `sysctl -a | grep hw.optional`
  on the Mac itself.
- Thor (read-only, SSH key): `lscpu`, `/proc/cpuinfo`, sysfs cache and
  `midr_el1` files.
- Public sources (level 1, semantics only): xnu-12377.1.9
  (`osfmk/arm/cpu_capabilities.h`, `osfmk/arm/commpage/commpage.c`,
  `bsd/kern/kern_mib.c`, `osfmk/arm/arm_features.inc`), the SDK header
  `arm/cpu_capabilities_public.h` (iPhoneSimulator27.1.sdk), dyld-1378
  (`common/FunctionVariantsArm64.inc`, `dyld/DyldProcessConfig.cpp`),
  libplatform-375.100.10 (`src/timingsafe/arm64/timingsafe.c`,
  `src/cachecontrol/arm64/cache.s`), WebKit `MacroAssemblerARM64.cpp`
  (`collectCPUFeatures`), LLVM compiler-rt
  `cpu_model/aarch64/fmv/apple.inc`.
- Binary metadata (level 4): `dyld_info -function_variants` and
  `dyld_info -imports` over the iOS 27.1 simulator shared cache
  (`-dyld_cache_path`), and string literals in the cache attributed to
  dylibs with the cache's `.map` file (a small script of ours that only
  maps file offsets to images).

## 1. The simulator sees the host kernel

Every sysctl value and every commpage word that a simulator process reads
is the host Mac's. The simulator runtime does not substitute any of them,
not even `kern.osproductversion` (it returns the host's `"27.2"`, not
`"27.1"`) or `hw.model` (`"Mac15,10"`). `uname` returns the host kernel
version. `sysctlbyname` in the simulator gives the same values as the raw
OID walk. Host `sysctl` output matches the simulator's value for value.
Level 3.

So "what the reference reports" equals "what the host Mac's kernel reports".
On a different Apple-silicon Mac the values change (feature bits, cache
sizes, CPU counts, `hw.cpufamily`).

## 2. Values on this Mac (M3 Max)

Identity: `hw.machine "arm64"`, `hw.model`/`hw.product "Mac15,10"`,
`hw.target "J514mAP"`, `hw.targettype "J514m"`, `hw.cputype 0x0100000C`,
`hw.cpusubtype 2` (arm64e), `hw.cpufamily 0x72015832`, `hw.cpusubfamily 5`,
`machdep.cpu.brand_string "Apple M3 Max"`, `kern.grade_cputype` 0 (exists).

CPUs: `hw.ncpu`, `activecpu`, `physicalcpu(_max)`, `logicalcpu(_max)` 14;
`hw.nperflevels 2`; perflevel0 "Performance" 10 CPUs (L1I 192 KiB, L1D
128 KiB, L2 16 MiB, 5 CPUs per L2); perflevel1 "Efficiency" 4 CPUs (L1I
128 KiB, L1D 64 KiB, L2 4 MiB, 4 per L2). `machdep.cpu.core_count`,
`thread_count`, `cores_per_package`, `logical_per_package` 14.

Caches and memory: `hw.cachelinesize` 128 (8-byte quad), `hw.l1icachesize`
131072, `hw.l1dcachesize` 65536, `hw.l2cachesize` 4194304 (the top-level
names report the smallest cluster), no L3 names. `hw.cacheconfig` = {14, 1,
4, 0…} and `hw.cachesize` = {memory (truncated to 32 bits), 65536, 4194304,
0…} (10 quads each). `hw.memsize` 38654705664. `hw.tbfrequency` 24000000.
`hw.pagesize` 16384. `machdep.virtual_address_size` 47.
`machdep.ptrauth_enabled` 0.

EL0 registers: `DCZID_EL0` = 0x4 (DC ZVA block 64 bytes, allowed).
`CTR_EL0` read at EL0 raises SIGILL (the kernel does not allow user reads).
So the 128 in `hw.cachelinesize` is not the ZVA block size.

`hw.optional.arm.caps`: 13 bytes, `ff ef ff fb 9f 00 0e 0c 00 02 00 00 00`.
Bits set: 0–11, 13–25, 27–36, 39, 49–51, 58, 59, 73. Bits 39 and 59 have no
name in the public header. Clear: 12 (SPECRES), 26 (WfxT), 37, 38, 40–48
(SME), 52–57 (SME_*), 60–72 (MTE, HBC, EBF16, SPECRES2, CSSC, FPACCOMBINE,
MTE_*), 91 (SVE_B16B16).

Per-feature keys (all 4-byte ints): the `hw.optional.arm.FEAT_*` names
match the bits above. Extra names with no CAP bit, all 0: `FEAT_FP8`,
`FEAT_LUT`, `FEAT_FAMINMAX`, `FEAT_CPA`, `FEAT_CPA2`, `FEAT_FPMR`,
`FEAT_PAuth_LR`, `FEAT_SME_LUTv2`, `sme_max_svl_b`. There is **no**
`FEAT_SVE`, `FEAT_SVE2`, or AMX name (ENOENT). Legacy names:
`floatingpoint`, `neon`, `neon_hpfp`, `neon_fp16`, `armv8_crc32`,
`armv8_gpi`, `armv8_1_atomics`, `armv8_2_fhm`, `armv8_2_sha512`,
`armv8_2_sha3`, `armv8_3_compnum`, `ucnormal_mem`, `arm64` = 1;
`watchpoint` 4, `breakpoint` 6. x86 names are registered but fail.

Commpage: `"commpage 64-bit"`, version 3; capabilities 64 (0x010) =
`0x87ffef97a70e7fc8`; 32-bit word (0x020) = its low half; NCPUS 14; page
shifts 14/14/14; cache line (0x026) 128; clusters 3; active/physical/logical
14; memory size as `hw.memsize`; CPUFAMILY (0x080) `0x72015832`;
user timebase type 3 and continuous-hwclock 1 (Apple counter; Ycode must
not copy this, `darwin-process-start.md`); cpu-to-cluster
{0,0,0,0,1,1,1,1,1,2,2,2,2,2}. Capability bits set: 3, 6–14, 17–19 (14
CPUs), 24–26, 29, 31–34, 36, 39–43, 45–58, 63. Bits 29, 36, 39 and 63 have
no name in the public xnu header.

## 3. Thor CPU (read-only)

MIDR 0x410FD830 (Arm, part 0xD83, Neoverse V3AE class), 14 CPUs in one
cluster, 1 thread per core. Linux hwcaps: fp asimd evtstrm aes pmull sha1
sha2 crc32 atomics fphp asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3
sm3 sm4 asimddp sha512 sve asimdfhm dit uscat ilrcpc flagm ssbs sb paca pacg
dcpodp sve2 sveaes svepmull svebitperm svesha3 svesm4 flagm2 frint svei8mm
svebf16 i8mm bf16 dgh bti ecv afp wfxt. Not present: rpres, predres (no
SPECRES), mte, sme, hbc, cssc, ebf16. Caches: L1D 64 KiB, L1I 64 KiB,
L2 1 MiB per core (unified), coherency line 64 bytes. Kernel
6.8.12-tegra. Level 3.

These are the host's EL0 view. What a KVM guest sees is a sanitized copy
that KVM controls per vCPU feature; that was not measured (no code was run
on the Thor).

## 4. Who reads these values (consumers)

- **dyld processor function variants** (dyld-1378, level 1): dyld reads
  `hw.optional.arm.caps` once into a 128-bit value and maps CAP bits to
  variant flags (`flagm` … `crc32`). Level 4: the iOS 27.1 simulator shared
  cache has **no** function-variant tables at all, and this Mac's own cache
  has only per-process `mte_enabled` variants. So today no shared-cache
  code changes path with these bits.
- **compiler-rt FMV** (`__init_cpu_features_resolver`, level 1): uses
  `hw.optional.arm.caps` (13-byte buffer) when it succeeds, else the
  per-feature names. Used only by code built with `target_clones` /
  `target_version`. In the cache, the string `hw.optional.arm.caps` appears
  once, in `libwebrtc.dylib`.
- **JavaScriptCore** (level 1, WebKit source; level 4, strings in the
  cache): `FEAT_LSE`, `FEAT_JSCVT`, `FEAT_FP16`, `FEAT_FRINTTS`,
  `FEAT_SHA3`, `FEAT_DotProd` by name, a value of 0 or an error selects the
  slower JIT sequences (for example the double-to-int32 conversion without
  FJCVTZS).
- **libplatform timingsafe** (level 1): reads commpage `kHasFeatDIT` and
  `kHasFeatSB`. Without SB it uses DSB SY + ISB as the speculation barrier;
  without DIT it does not set PSTATE.DIT.
- **libplatform `sys_icache_invalidate`** (level 1): reads the commpage
  CPUFAMILY and adds extra DSBs for a list of Apple families (the list
  includes `0x72015832`). With an unknown family it uses the architectural
  sequence.
- **Other dylibs** (level 4, string literals and imports only):
  - `hw.cpufamily` / `hw.cpusubfamily` / `hw.perflevel0.l2cachesize` /
    `hw.perflevel0.name`: Accelerate's libBLAS, libLAPACK, libBNNS (also
    `hw.cpufamily` in libmecabra, AVConference, FTServices, perfdata).
  - `hw.optional.arm.FEAT_SME`/`FEAT_SME2`: libAudioDSP, SiriTTS,
    libwebrtc.
  - `FEAT_I8MM`, `FEAT_PMULL`, `FEAT_DotProd`, `armv8_crc32`: libwebrtc.
  - `hw.optional.FEAT_FP16` and `hw.l2cachesize`: ImageIO.
  - `neon_fp16`: VideoToolbox. `neon_hpfp`: SceneKit, VFX.
  - `hw.cachelinesize`: CoreGraphics, IOSurface, libGLImage, libusd_ms.
  - `machdep.cpu.brand_string`: CoreImage, Espresso, perfdata, libusd_ms.
  - Imports of `__get_cpu_capabilities` (commpage capability reader):
    libBLAS, libLAPACK, libAudioDSP, IOKit, Bom,
    EmbeddedAcousticRecognition, Espresso, SiriTTS, libsystem_c.
  Code that reads the commpage words inline cannot be found without
  disassembly. That is not done here.
- **Compiler baseline** (level 3): clang for `arm64-apple-ios*-simulator`
  defaults to `-target-cpu apple-m1` (Armv8.5-A: LSE, RCPC, FHM, DotProd,
  SHA3/SHA512, FP16, JSCVT, FCMA, FlagM/FlagM2, FRINTTS, SB, SSBS, PAuth,
  PREDRES, BTI, DPB/DPB2). Simulator code can use these with no runtime
  check. The Thor implements all of them except PREDRES (which xnu also
  reports as absent on this Mac).

## 5. What this means for the speed hypothesis

Most simulator code already uses the M1 feature set without checking, and
no shared-cache code is dispatched by dyld function variants. The
`caps = 0` state therefore does not make the whole runtime take generic
paths. The gated paths are specific: the JavaScriptCore JIT, timingsafe
(SB/DIT), Accelerate (BLAS/LAPACK/BNNS: family, perflevel, cache sizes,
commpage capabilities), audio/speech DSP, WebRTC, ImageIO, VideoToolbox, and
any code that reads the commpage inline. A speed gain should be expected
in those areas, not across the board. That is an inference (level 4) and
must be measured.

## Evidence summary

| Claim | Level |
|---|---|
| Simulator values equal host kernel values | 3 |
| M3 Max values (sysctl, caps bytes, commpage words, DCZID, CTR SIGILL) | 3 |
| CAP bit numbers, commpage bit masks, xnu derivation from ID registers | 1 |
| dyld, compiler-rt, JSC, timingsafe, icache consumers | 1 |
| No function variants in the iOS 27.1 simulator cache | 4 |
| Dylibs that name sysctls or import `__get_cpu_capabilities` | 4 |
| Thor features and caches | 3 |
| Simulator compiler baseline apple-m1 | 3 |
