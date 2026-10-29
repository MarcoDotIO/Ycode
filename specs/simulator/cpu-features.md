# CPU feature publication (sysctl `hw.*` / `machdep.cpu.*` and commpage capabilities)

Status: implemented 2026-10-23 (§9; switch `YCODE_CPU_FEATURES`, default on). Dirty-room source: `research/notes/cpufeat-observations.md`
(lead L1 of a private note from an outside practitioner, kept off the public repository).
Related: `stage3-contract.md` (sysctl table), `darwin-process-start.md` §3
(commpage layout and guest CPU count N), `fast-traps.md` (timebase),
`dyld-sim-handoff.md` (dyld reads `hw.optional.arm.caps`).

## 1. Purpose

Guest code finds out which optional CPU features it may use from three
places: the `hw.optional.*` sysctls, the `hw.optional.arm.caps` bit vector,
and the commpage capability words. Ycode currently reports almost nothing
(`hw.optional.arm.caps` = 0, every other `hw.optional.*` name = 0, commpage
capabilities = TLS, VFP, event, FMA, CPU count and cache-line size only).
Feature-gated guest code then takes its slower generic paths.

This spec says what Apple's simulator reports, which guest code reads the
values, and what Ycode must report on the Thor. The rule: **report a feature
only if the guest vCPU really executes it, and never report a feature that
Ycode does not handle (SME, MTE, pointer authentication, Apple-private
bits)**. A false claim crashes the guest with an illegal instruction. A
missing claim only costs speed.

## 2. What the reference reports (Apple simulator on Apple silicon)

### 2.1 Where the values come from

An iOS simulator process is a macOS process. Its sysctls and its commpage
are the **host Mac kernel's**, unchanged. The simulator runtime does not
substitute any CPU value, nor `kern.osproductversion` (the simulator
returns the host's macOS version, for example `"27.2"`), `hw.model`
(`"Mac15,10"`) or `uname`. `sysctlbyname` in the simulator returns the same
values as a raw OID walk and as `sysctl` on the host. So every value below
depends on the host Mac's chip. Nothing in this area is fixed by the
simulator.

### 2.2 Values observed (host: Apple M3 Max, 14 CPUs)

| Key | Value | Size / type |
|---|---|---|
| `hw.machine` | `"arm64"` | string |
| `hw.model`, `hw.product` | `"Mac15,10"` | string |
| `hw.target` / `hw.targettype` | `"J514mAP"` / `"J514m"` | string |
| `hw.cputype` | `0x0100000C` (ARM64) | int |
| `hw.cpusubtype` | 2 (ARM64E: the host is arm64e) | int |
| `hw.cpufamily` | `0x72015832` (an Apple family) | int |
| `hw.cpusubfamily` | 5 | int |
| `hw.cpu64bit_capable` | 1 | int |
| `hw.ncpu`, `hw.activecpu`, `hw.physicalcpu(_max)`, `hw.logicalcpu(_max)` | 14 | int |
| `hw.nperflevels` | 2 | int |
| `hw.perflevel0.{physical,logical}cpu(_max)` / `.name` | 10 / `"Performance"` | int / string |
| `hw.perflevel0.l1icachesize` / `l1dcachesize` / `l2cachesize` / `cpusperl2` | 196608 / 131072 / 16777216 / 5 | int |
| `hw.perflevel1.*` | 4 CPUs, `"Efficiency"`, 131072 / 65536 / 4194304 / 4 | int / string |
| `hw.perflevel2.*`, `*.l3cachesize`, `*.cpusperl3`, `*.sharesl2` | ENOENT | — |
| `hw.cachelinesize` | 128 | 8 bytes |
| `hw.l1icachesize` / `hw.l1dcachesize` / `hw.l2cachesize` | 131072 / 65536 / 4194304 (smallest cluster) | 8 bytes |
| `hw.l3cachesize` | ENOENT | — |
| `hw.cacheconfig` | {14, 1, 4, 0, …} (10 quads: CPUs sharing memory, L1, L2) | 80 bytes |
| `hw.cachesize` | {memory size, 65536, 4194304, 0, …} (10 quads) | 80 bytes |
| `hw.memsize` | 38654705664 (host RAM) | 8 bytes |
| `hw.pagesize` | 16384 | 8 bytes |
| `hw.tbfrequency` | 24000000 | 8 bytes |
| `machdep.cpu.brand_string` | `"Apple M3 Max"` | string |
| `machdep.cpu.core_count`, `thread_count`, `cores_per_package`, `logical_per_package` | 14 | int |
| `machdep.virtual_address_size` | 47 | int |
| `machdep.ptrauth_enabled` | 0 | int |
| `kern.osproductversion` | host macOS version | string |
| `kern.grade_cputype` | 0 (exists) | int |
| EL0 `DCZID_EL0` | 0x4: DC ZVA block **64** bytes, allowed | register |
| EL0 `CTR_EL0` read | SIGILL (user access not enabled) | register |

`hw.cachelinesize` (128) is **not** the DC ZVA block size (64). The two are
independent values.

### 2.3 `hw.optional.arm.caps`

Format (level 1, public header `arm/cpu_capabilities_public.h` and xnu
`bsd/kern/kern_mib.c`): a byte string of `ceil(CAP_BIT_NB / 8)` bytes. With
`CAP_BIT_NB` = 97 that is **13 bytes**. Bit *n* is bit `n % 8` of byte
`n / 8`. 1 means the feature is present. The OID type is `CTLTYPE_QUAD` with
format string `"Q"`, but the value is 13 bytes, not 8. Bit numbers are ABI:
they never change. New bits are only added at the end.

Reference value: `ff ef ff fb 9f 00 0e 0c 00 02 00 00 00`.

| Bit | Name | Ref | Bit | Name | Ref |
|---|---|---|---|---|---|
| 0 | FEAT_FlagM | 1 | 27 | FEAT_RPRES | 1 |
| 1 | FEAT_FlagM2 | 1 | 28 | FEAT_ECV | 1 |
| 2 | FEAT_FHM | 1 | 29 | FEAT_AFP | 1 |
| 3 | FEAT_DotProd | 1 | 30 | FEAT_LSE2 | 1 |
| 4 | FEAT_SHA3 | 1 | 31 | FEAT_CSV2 | 1 |
| 5 | FEAT_RDM | 1 | 32 | FEAT_CSV3 | 1 |
| 6 | FEAT_LSE | 1 | 33 | FEAT_DIT | 1 |
| 7 | FEAT_SHA256 | 1 | 34 | FEAT_FP16 | 1 |
| 8 | FEAT_SHA512 | 1 | 35 | FEAT_SSBS | 1 |
| 9 | FEAT_SHA1 | 1 | 36 | FEAT_BTI | 1 |
| 10 | FEAT_AES | 1 | 37–38 | (no name) | 0 |
| 11 | FEAT_PMULL | 1 | 39 | (no public name) | **1** |
| 12 | FEAT_SPECRES | 0 | 40–48 | FEAT_SME, SME2, SME_F64F64, SME_I16I64, SME2p1, SME_F16F16, SME_B16B16, SME_F8F16, SME_F8F32 | 0 |
| 13 | FEAT_SB | 1 | 49 | AdvSIMD | 1 |
| 14 | FEAT_FRINTTS | 1 | 50 | AdvSIMD_HPFPCvt | 1 |
| 15 | FEAT_LRCPC | 1 | 51 | FEAT_CRC32 | 1 |
| 16 | FEAT_LRCPC2 | 1 | 52–57 | SME_F32F32, SME_BI32I32, SME_B16F32, SME_F16F32, SME_I8I32, SME_I16I32 | 0 |
| 17 | FEAT_FCMA | 1 | 58 | FEAT_PACIMP | 1 |
| 18 | FEAT_JSCVT | 1 | 59 | (no public name) | **1** |
| 19 | FEAT_PAuth | 1 | 60–63 | FEAT_MTE, MTE2, MTE3, MTE4 | 0 |
| 20 | FEAT_PAuth2 | 1 | 64 | FEAT_HBC | 0 |
| 21 | FEAT_FPAC | 1 | 65 | FEAT_EBF16 | 0 |
| 22 | FEAT_DPB | 1 | 66 | FEAT_SPECRES2 | 0 |
| 23 | FEAT_DPB2 | 1 | 67 | FEAT_CSSC | 0 |
| 24 | FEAT_BF16 | 1 | 68 | FEAT_FPACCOMBINE | 0 |
| 25 | FEAT_I8MM | 1 | 69–72 | FEAT_MTE_ASYNC, MTE_CANONICAL_TAGS, MTE_STORE_ONLY, MTE_NO_ADDRESS_TAGS | 0 |
| 26 | FEAT_WFxT | 0 | 73 | FP_SyncExceptions | 1 |
| | | | 91 | FEAT_SVE_B16B16 | 0 |

### 2.4 Per-feature and legacy `hw.optional.*` names

Each `hw.optional.arm.<NAME>` for the bit names above is a 4-byte int that
equals the bit (for example `hw.optional.arm.FEAT_LSE` = 1). The reference
also has these names with no caps bit, all 0: `FEAT_FP8`, `FEAT_LUT`,
`FEAT_FAMINMAX`, `FEAT_CPA`, `FEAT_CPA2`, `FEAT_FPMR`, `FEAT_PAuth_LR`,
`FEAT_SME_LUTv2`, and `hw.optional.arm.sme_max_svl_b` = 0.
**There is no `FEAT_SVE`, `FEAT_SVE2` or AMX name** (ENOENT).

Legacy names (4-byte ints) and their meaning:

| Name | Ref | Same as |
|---|---|---|
| `hw.optional.floatingpoint` | 1 | FP present |
| `hw.optional.neon` | 1 | AdvSIMD |
| `hw.optional.neon_hpfp` | 1 | AdvSIMD_HPFPCvt |
| `hw.optional.neon_fp16` | 1 | FEAT_FP16 |
| `hw.optional.armv8_crc32` | 1 | FEAT_CRC32 |
| `hw.optional.armv8_gpi` | 1 | FEAT_PACIMP |
| `hw.optional.armv8_1_atomics` | 1 | FEAT_LSE |
| `hw.optional.armv8_2_fhm` | 1 | FEAT_FHM |
| `hw.optional.armv8_2_sha512` | 1 | FEAT_SHA512 |
| `hw.optional.armv8_2_sha3` | 1 | FEAT_SHA3 |
| `hw.optional.armv8_3_compnum` | 1 | FEAT_FCMA |
| `hw.optional.ucnormal_mem` | 1 | commpage `kHasUCNormalMemory` |
| `hw.optional.arm64` | 1 | — |
| `hw.optional.watchpoint` / `breakpoint` | 4 / 6 | hardware debug register counts |
| x86 names (`sse`, `avx1_0`, …) | registered, read fails | — |

### 2.5 Commpage capability words

Layout (level 1, xnu `osfmk/arm/cpu_capabilities.h`): 64-bit word at
`_COMM_PAGE_CPU_CAPABILITIES64` (base + 0x010); its low 32 bits are repeated
at `_COMM_PAGE_CPU_CAPABILITIES` (base + 0x020). The CPU count byte
(0x022) is bits 16–23 of the same word. The cache line size is a 16-bit
value at 0x026. CPUFAMILY is a 32-bit value at 0x080.

| Mask | Name | Ref | Mask | Name | Ref |
|---|---|---|---|---|---|
| `0x8` | kHasFeatFP16 | 1 | `bit 32` | kHasFeatSHA3 | 1 |
| `0x10/0x20/0x40` | kCache32/64/128 | 128 | `bit 33` | kHasFeatFCMA | 1 |
| `0x80` | kFastThreadLocalStorage | 1 | `bit 34` | kHasFeatAFP | 1 |
| `0x100` | kHasAdvSIMD | 1 | `bit 40` | kHasFEATFlagM | 1 |
| `0x200` | kHasAdvSIMD_HPFPCvt | 1 | `bit 41` | kHasFEATFlagM2 | 1 |
| `0x400` | kHasVfp | 1 | `bit 42` | kHasFeatDotProd | 1 |
| `0x800` | kHasUCNormalMemory | 1 | `bit 43` | kHasFeatRDM | 1 |
| `0x1000` | kHasEvent | 1 | `bit 44` | kHasFeatSPECRES | 0 |
| `0x2000` | kHasFMA | 1 | `bit 45` | kHasFeatSB | 1 |
| `0x4000` | kHasFeatFHM | 1 | `bit 46` | kHasFeatFRINTTS | 1 |
| `0x8000` | kUP (exactly one CPU) | 0 | `bit 47` | kHasArmv8GPI | 1 |
| `0xFF0000` | kNumCPUs | 14 | `bit 48` | kHasFeatLRCPC | 1 |
| `0x01000000` | kHasARMv8Crypto (AES+PMULL+SHA1+SHA256) | 1 | `bit 49` | kHasFeatLRCPC2 | 1 |
| `0x02000000` | kHasFeatLSE | 1 | `bit 50` | kHasFeatJSCVT | 1 |
| `0x04000000` | kHasARMv8Crc32 | 1 | `bit 51` | kHasFeatPAuth | 1 |
| `0x80000000` | kHasFeatSHA512 | 1 | `bit 52` | kHasFeatDPB | 1 |
| | | | `bit 53` | kHasFeatDPB2 | 1 |
| | | | `bit 54` | kHasFeatLSE2 | 1 |
| | | | `bit 55` | kHasFeatCSV2 | 1 |
| | | | `bit 56` | kHasFeatCSV3 | 1 |
| | | | `bit 57` | kHasFeatDIT | 1 |
| | | | `bit 58` | kHasFP_SyncExceptions | 1 |
| | | | `bit 59` / `bit 60` | kHasFeatSME / kHasFeatSME2 | 0 |

Reference words: capabilities64 = `0x87ffef97a70e7fc8`, capabilities32 =
`0xa70e7fc8`, cache line (0x026) = 128, CPUFAMILY = `0x72015832`. The
reference also sets bits **29, 36, 39 and 63**, which have no name in the
public header. Ycode must leave them clear.

## 3. Which guest code reads these values

| Consumer | Reads | Effect when absent | Evidence |
|---|---|---|---|
| dyld processor function variants | `hw.optional.arm.caps` (once at start, into a 128-bit value; failure means "default only") | the default variant is used | dyld source (1). The iOS 27.1 simulator shared cache has **no** function-variant tables, so this changes nothing today (4) |
| compiler-rt function multiversioning (`target_clones`, `target_version`) | `hw.optional.arm.caps` with a 13-byte buffer; if that fails, the per-feature names | the default version is used | LLVM source (1). In the cache only `libwebrtc` names `hw.optional.arm.caps` (4) |
| JavaScriptCore JIT | `FEAT_LSE`, `FEAT_JSCVT`, `FEAT_FP16`, `FEAT_FRINTTS`, `FEAT_SHA3`, `FEAT_DotProd` by name; 0 or an error means absent | slower JIT sequences (for example no FJCVTZS for JS number to int32, CAS loops without LSE) | WebKit source (1), strings in JavaScriptCore (4) |
| libplatform timingsafe (constant-time crypto helpers) | commpage kHasFeatDIT, kHasFeatSB | DSB SY + ISB instead of SB; PSTATE.DIT is not set | libplatform source (1) |
| libplatform `sys_icache_invalidate` (JIT code publication) | commpage CPUFAMILY | an unknown family uses the architectural invalidate sequence; listed Apple families add extra DSBs | libplatform source (1) |
| Accelerate (libBLAS, libLAPACK, libBNNS) | `hw.cpufamily`, `hw.cpusubfamily`, `hw.perflevel0.l2cachesize`, `hw.perflevel0.name`; libBLAS and libLAPACK also import the commpage capability reader | kernel choice and blocking sizes | names and imports only (4) |
| Audio and speech DSP (libAudioDSP, SiriTTS, EmbeddedAcousticRecognition, Espresso) | `FEAT_SME`, `FEAT_SME2`, `machdep.cpu.brand_string`, commpage capability reader | SME paths are not taken | names and imports only (4) |
| libwebrtc | `FEAT_I8MM`, `FEAT_PMULL`, `FEAT_DotProd`, `armv8_crc32`, `FEAT_SME(2)`, `hw.optional.arm.caps` | generic codec kernels | names only (4) |
| ImageIO, VideoToolbox, SceneKit, VFX | `hw.optional.FEAT_FP16`, `hw.l2cachesize`, `neon_fp16`, `neon_hpfp` | generic paths | names only (4) |
| CoreGraphics, IOSurface, libGLImage | `hw.cachelinesize` | alignment and padding | names only (4) |
| libdispatch, Swift concurrency | commpage CPU counts, `hw.activecpu`, `hw.logicalcpu_max`, `hw.physicalcpu` | thread-pool widths | `darwin-process-start.md` (1) |
| Inline commpage readers in closed libraries | commpage words | unknown | cannot be found without disassembly; not done |

**Compiler baseline (level 3).** clang compiles `arm64-apple-ios*-simulator`
code for `apple-m1` by default (Armv8.5-A with LSE, LRCPC, FHM, DotProd,
SHA3/SHA512, FP16, JSCVT, FCMA, FlagM/FlagM2, FRINTTS, SB, SSBS, DPB/DPB2,
BTI, PAuth and PREDRES enabled). Simulator code can use these instructions
**without any check**. So the published values do not decide whether that
code runs. They only decide the paths that check at run time (the table
above).

**Consequence for the speed goal.** The report that "caps = 0 makes the
whole runtime generic" is not supported. The expected gain is in JIT
JavaScript, Accelerate/BNNS, audio/speech, WebRTC/media codecs and
constant-time crypto helpers. Measure it (§7.3) before claiming a boot-wide
effect. (Inference, level 4.)

## 4. Ycode on the Thor: what to publish

### 4.1 Source of truth: the guest vCPU's ID registers

The Thor's Linux EL0 view (`/proc/cpuinfo`) is **not** what a guest sees.
KVM gives each vCPU a sanitized copy of the ID registers, and hides features
that the vCPU was not configured for (SVE without the SVE vCPU feature,
pointer authentication without the ptrauth vCPU features, SME, MTE without
the MTE capability, and others depending on the kernel version). Ycode
initializes vCPUs with only the PSCI 0.2 feature.

At VMM start, after the first vCPU is initialized, Ycode must:

1. Read the guest-visible ID registers with `KVM_GET_ONE_REG` on that vCPU
   (system-register encodings `op0=3, op1=0, CRn=0`): `ID_AA64PFR0_EL1`,
   `ID_AA64PFR1_EL1`, `ID_AA64ISAR0_EL1`, `ID_AA64ISAR1_EL1`,
   `ID_AA64ISAR2_EL1`, `ID_AA64MMFR0_EL1`, `ID_AA64MMFR1_EL1`,
   `ID_AA64MMFR2_EL1`, `ID_AA64ZFR0_EL1`, `ID_AA64SMFR0_EL1`, plus `CTR_EL0`
   and `DCZID_EL0` (the last two may be read from the host, because KVM
   passes them through). Log all values once.
2. Derive each feature from its ID field with the thresholds in §4.2.
3. Clear every feature in the deny list (§4.3).
4. Run the FPCR probe for FP_SyncExceptions (§4.2).
5. Build the three outputs (caps bytes, per-feature names, commpage word)
   from **one** feature set, so they always agree.
6. Allow an override for A/B tests and as a safety switch:
   `YCODE_CPU_FEATURES=off` publishes the current minimal set; `on` (the
   default after verification) publishes the derived set.

Do not hard-code the Thor table below. It is the **expected** result on the
Thor and the test oracle. It is not the implementation.

### 4.2 Derivation rules (Arm architecture ID fields)

A field is the 4-bit unsigned value at the given bits. "≥ v" compares
unsigned values. This follows the Arm Architecture Reference Manual. xnu
derives its own bits in the same way (level 1).

| Feature (caps bit) | Register.field [bits] | Present when |
|---|---|---|
| FlagM (0) / FlagM2 (1) | ISAR0.TS [55:52] | ≥ 1 / ≥ 2 |
| FHM (2) | ISAR0.FHM [51:48] | ≥ 1 |
| DotProd (3) | ISAR0.DP [47:44] | ≥ 1 |
| SHA3 (4) | ISAR0.SHA3 [35:32] | ≥ 1 |
| RDM (5) | ISAR0.RDM [31:28] | ≥ 1 |
| LSE (6) | ISAR0.Atomic [23:20] | ≥ 2 |
| SHA256 (7) / SHA512 (8) | ISAR0.SHA2 [15:12] | ≥ 1 / ≥ 2 |
| SHA1 (9) | ISAR0.SHA1 [11:8] | ≥ 1 |
| AES (10) / PMULL (11) | ISAR0.AES [7:4] | ≥ 1 / ≥ 2 |
| CRC32 (51) | ISAR0.CRC32 [19:16] | ≥ 1 |
| SPECRES (12) / SPECRES2 (66) | ISAR1.SPECRES [43:40] | ≥ 1 **and** the guest SCTLR_EL1.EnRCTX = 1 / ≥ 2 |
| SB (13) | ISAR1.SB [39:36] | ≥ 1 |
| FRINTTS (14) | ISAR1.FRINTTS [35:32] | ≥ 1 |
| PACIMP (58) | ISAR1.GPI [31:28] | ≥ 1 (denied, §4.3) |
| LRCPC (15) / LRCPC2 (16) | ISAR1.LRCPC [23:20] | ≥ 1 / ≥ 2 |
| FCMA (17) | ISAR1.FCMA [19:16] | ≥ 1 |
| JSCVT (18) | ISAR1.JSCVT [15:12] | ≥ 1 |
| PAuth (19) / PAuth2 (20) / FPAC (21) / FPACCOMBINE (68) | ISAR1.API [11:8] or APA [7:4] | ≥ 1 / ≥ 3 / ≥ 4 / ≥ 5 (all denied, §4.3) |
| DPB (22) / DPB2 (23) | ISAR1.DPB [3:0] | ≥ 1 / ≥ 2 |
| BF16 (24) / EBF16 (65) | ISAR1.BF16 [47:44] | ≥ 1 / ≥ 2 |
| I8MM (25) | ISAR1.I8MM [55:52] | ≥ 1 |
| WFxT (26) | ISAR2.WFxT [3:0] | ≥ 2 (denied, §4.3) |
| RPRES (27) | ISAR2.RPRES [7:4] | ≥ 1 |
| CSSC (67) | ISAR2.CSSC [55:52] | ≥ 1 |
| HBC (64) | ISAR2.BC [23:20] | ≥ 1 |
| ECV (28) | MMFR0.ECV [63:60] | ≥ 1 (deferred, §4.3) |
| AFP (29) | MMFR1.AFP [47:44] | = 1 |
| LSE2 (30) | MMFR2.AT [35:32] | ≥ 1 |
| CSV3 (32) | PFR0.CSV3 [63:60] | ≥ 1 |
| CSV2 (31) | PFR0.CSV2 [59:56] | ≥ 1 |
| DIT (33) | PFR0.DIT [51:48] | ≥ 1 |
| AdvSIMD (49) / AdvSIMD_HPFPCvt (50) / FP16 (34) | PFR0.AdvSIMD [23:20] | ≠ 0xF / ≠ 0xF / = 1 (and PFR0.FP [19:16] = 1) |
| SSBS (35) | PFR1.SSBS [7:4] | ≥ 1 |
| BTI (36) | PFR1.BT [3:0] | ≥ 1 |
| SME… (40–48, 52–57) | PFR1.SME [27:24], SMFR0 | denied (§4.3) |
| MTE… (60–63, 69–72) | PFR1.MTE [11:8] | denied (§4.3) |
| SVE_B16B16 (91) | ZFR0 | denied (§4.3) |
| FP_SyncExceptions (73) | none: write the six FPCR trap-enable bits (IOE, DZE, OFE, UFE, IXE, IDE) in the guest, read FPCR back, restore it | all six bits read back as 1 |

### 4.3 Deny list (never published, whatever the ID registers say)

| Features | Why |
|---|---|
| SME and all SME_* bits, `sme_max_svl_b` | KVM does not give the guest SME. Streaming mode would need ZA/ZT0 context handling that Ycode does not have. |
| MTE and all MTE_* bits | Ycode does not tag memory and does not enable the MTE capability. |
| PAuth, PAuth2, FPAC, FPACCOMBINE, PACIMP (`armv8_gpi`, commpage kHasArmv8GPI and kHasFeatPAuth) | Ycode does not configure the pointer-authentication vCPU features, so non-hint PAC instructions are UNDEFINED in the guest. The runtime is arm64, not arm64e. The reference's `machdep.ptrauth_enabled` is 0 as well. |
| WFxT | Reference reports 0. WFET/WFIT at EL0 could cause extra VM exits. No consumer in the runtime needs it. |
| ECV (for now) | The only EL0 use is the self-synchronizing counter registers (CNTVCTSS_EL0/CNTPCTSS_EL0). With the default 24 MHz guest timebase the guest must not read the raw counter. Publish ECV only after the EL1 shim handles the CNTVCTSS/CNTPCTSS encodings in the same way as CNTVCT when EL0 counter access traps. |
| SPECRES, SPECRES2 | Not on the Thor (no `predres`). Also needs SCTLR_EL1.EnRCTX. The reference reports 0. |
| Caps bits 37–39, 59, 74–90, 92–96; commpage bits 29, 35–39, 61–63 | No public meaning. The reference sets some of them, which are Apple-private. |
| SVE, SVE2 (no name exists), SVE_B16B16 | iOS userland has no SVE name to detect. The SVE vCPU feature would add a large register context. Keep the vCPU without SVE. |

### 4.4 Expected values on the Thor (test oracle)

Inputs: Thor host hwcaps (observed) and KVM behaviour as described in
§4.1. "verify" means the guest ID register must confirm the value. If it
does not, the derived value (normally 0) wins.

| Bit | Feature | Ref (M3 Max) | Thor host | Ycode publishes |
|---|---|---|---|---|
| 0, 1 | FlagM, FlagM2 | 1, 1 | flagm, flagm2 | 1, 1 |
| 2 | FHM | 1 | asimdfhm | 1 |
| 3 | DotProd | 1 | asimddp | 1 |
| 4 | SHA3 | 1 | sha3 | 1 |
| 5 | RDM | 1 | asimdrdm | 1 |
| 6 | LSE | 1 | atomics | 1 |
| 7, 8, 9 | SHA256, SHA512, SHA1 | 1 | sha2, sha512, sha1 | 1 |
| 10, 11 | AES, PMULL | 1 | aes, pmull | 1 |
| 12 | SPECRES | 0 | absent (no hwcap); the guest view shows 1 (§9.2) | 0 (denied) |
| 13 | SB | 1 | sb | 1 |
| 14 | FRINTTS | 1 | frint | 1 |
| 15, 16 | LRCPC, LRCPC2 | 1 | lrcpc, ilrcpc | 1 |
| 17 | FCMA | 1 | fcma | 1 |
| 18 | JSCVT | 1 | jscvt | 1 |
| 19, 20, 21 | PAuth, PAuth2, FPAC | 1 | paca/pacg on host | **0** (denied) |
| 22, 23 | DPB, DPB2 | 1 | dcpop, dcpodp | 1 |
| 24 | BF16 | 1 | bf16 | 1 |
| 25 | I8MM | 1 | i8mm | 1 |
| 26 | WFxT | 0 | wfxt | 0 (denied) |
| 27 | RPRES | 1 | absent | 0 |
| 28 | ECV | 1 | ecv | 0 (deferred) |
| 29 | AFP | 1 | afp | 1 (verify) |
| 30 | LSE2 | 1 | uscat | 1 |
| 31, 32 | CSV2, CSV3 | 1 | not affected by Spectre v2 / Meltdown | 1 (verify; KVM sets these fields itself) |
| 33 | DIT | 1 | dit | 1 |
| 34 | FP16 | 1 | fphp, asimdhp | 1 |
| 35 | SSBS | 1 | ssbs | 1 |
| 36 | BTI | 1 | bti | 1 (verify) |
| 39, 59 | (private) | 1 | — | 0 |
| 40–48, 52–57 | SME family | 0 | absent | 0 |
| 49, 50 | AdvSIMD, AdvSIMD_HPFPCvt | 1 | asimd, asimdhp | 1 |
| 51 | CRC32 | 1 | crc32 | 1 |
| 58 | PACIMP | 1 | pacg | 0 (denied) |
| 60–72 | MTE…, HBC, EBF16, SPECRES2, CSSC, FPACCOMBINE | 0 | absent | 0 |
| 73 | FP_SyncExceptions | 1 | expected not supported on Neoverse (trap-enable bits read as 0) | FPCR probe; expected 0 |
| 91 | SVE_B16B16 | 0 | — | 0 |

Expected `hw.optional.arm.caps` (13 bytes) when all "verify" rows hold:
`ff ef c7 e3 1f 00 0e 00 00 00 00 00 00`
(bits 0–11, 13–18, 22–25, 29–36, 49–51).

Expected commpage capabilities64 (before CPU count and kUP):
`0x03f76f0787007fa8`, that is:
kHasFeatFP16 | kCache64 | kFastThreadLocalStorage | kHasAdvSIMD |
kHasAdvSIMD_HPFPCvt | kHasVfp | kHasUCNormalMemory | kHasEvent | kHasFMA |
kHasFeatFHM | kHasARMv8Crypto | kHasFeatLSE | kHasARMv8Crc32 |
kHasFeatSHA512 | SHA3 | FCMA | AFP | FlagM | FlagM2 | DotProd | RDM | SB |
FRINTTS | LRCPC | LRCPC2 | JSCVT | DPB | DPB2 | LSE2 | CSV2 | CSV3 | DIT.
Then OR in `N << 16` and, when N = 1, kUP (`0x8000`). With the default
N = 1: `0x03f76f078701ffa8`. The 32-bit word at 0x020 is the low half.
kHasARMv8Crypto is set only if AES, PMULL, SHA1 and SHA256 are all present.
kHasUCNormalMemory is a kernel memory-type capability that xnu always sets
on Apple arm64. It names no EL0 instruction. Set it for parity (open
question Q4).

Per-feature names: every `hw.optional.arm.FEAT_*` / `AdvSIMD*` /
`SME_*` / `FP_SyncExceptions` name from §2.3 returns its bit. The extra
names in §2.4 (`FEAT_FP8`, …, `sme_max_svl_b`) return 0. Legacy names:
`floatingpoint` 1, `neon` 1, `neon_hpfp` 1, `neon_fp16` 1, `armv8_crc32` 1,
`armv8_1_atomics` 1, `armv8_2_fhm` 1, `armv8_2_sha512` 1, `armv8_2_sha3` 1,
`armv8_3_compnum` 1, `ucnormal_mem` 1, `arm64` 1, `armv8_gpi` **0**,
`watchpoint` 0 and `breakpoint` 0 (Ycode offers no hardware debug
registers to the guest). Names not in the table keep reading 0, as
today. The reference returns ENOENT for unknown names. Callers treat both
as "absent", so this difference does not matter.

### 4.5 Other keys

| Key | Ycode today | Publish | Why |
|---|---|---|---|
| `hw.optional.arm.caps` | 0, 8 bytes | §4.4, **13 bytes** | Format of §2.3. A size query (no buffer) returns 13. If the caller's buffer is shorter, copy what fits and fail with ENOMEM (xnu `SYSCTL_OUT` behavior, level 1). dyld passes 16 bytes and compiler-rt passes 13 bytes; both work. |
| `hw.cachelinesize` | 64 | **64** (from the guest `CTR_EL0` CWG, else DminLine; the Thor has 64) | The Thor's real coherency line. The reference's 128 is Apple's own value. Do not copy it: it is not the ZVA block on Apple either. |
| commpage 0x026 and kCache bit | 64, kCache64 | same value as `hw.cachelinesize` | consistency |
| `DCZID_EL0` (hardware) | 64-byte block, DZE set | unchanged | equals the reference (64). Never derive ZVA from `hw.cachelinesize`, or the reverse. |
| `hw.l1icachesize` / `hw.l1dcachesize` / `hw.l2cachesize` | 128 KiB / 64 KiB / 4 MiB (Apple-like) | **65536 / 65536 / 1048576** (Thor per-core values from the host sysfs cache description) | Accelerate and ImageIO size their blocks with these. True values are better for speed. |
| `hw.perflevel0.l1icachesize` / `l1dcachesize` / `l2cachesize` / `cpusperl2` / `name` | missing | 65536 / 65536 / 1048576 / 1 / `"Performance"` | read by libBLAS/libLAPACK/libBNNS. `nperflevels` stays 1. |
| `hw.cacheconfig` / `hw.cachesize` | missing | {N, 1, 1, 0 ×7} / {guest memory, 65536, 1048576, 0 ×7} (10 quads each) | completeness (optional) |
| `hw.cpufamily` and commpage 0x080 | 0 | **0** (CPUFAMILY_UNKNOWN) | An Apple family would make libplatform add DSBs, and could select Apple-tuned code that assumes Apple-only hardware (AMX). Unknown is safe. |
| `hw.cpusubfamily` | missing | 0 (unknown) | read by Accelerate |
| `hw.cputype` / `hw.cpusubtype` | `0x0100000C` / 0 | unchanged | Do not report 2 (arm64e) as the host does: loaders could prefer arm64e slices, which need pointer authentication. |
| `hw.ncpu`, `activecpu`, `physicalcpu(_max)`, `logicalcpu(_max)`, `perflevel0.*cpu*`, `machdep.cpu.core_count`, `thread_count`, `cores_per_package`, `logical_per_package` | N (machdep missing) | N everywhere (`darwin-process-start.md` policy) | consistency with the commpage counts |
| `hw.memsize`, `memsize_usable` | guest RAM | unchanged | Ycode policy |
| `hw.tbfrequency` | **1 000 000 000** | **`GuestTimebase.frequency(hostFrequency:)`**: 24 000 000 by default | Must agree with `mach_timebase_info` (125/3 at 24 MHz). Today it does not. |
| `machdep.cpu.brand_string` | missing | a Ycode string that names no Apple product, for example `"Ycode VM (Arm Neoverse V3AE)"` derived from MIDR | read by CoreImage, Espresso and perfdata. No Apple trademarks (AGENTS.md rule 5). |
| `machdep.virtual_address_size` | missing | the guest user VA width that Ycode's stage-1 configuration gives | hint. Low priority. |
| `machdep.ptrauth_enabled` | missing | 0 | matches the reference |
| `kern.osproductversion` | `"27.1"` | unchanged (Ycode decision) | The reference returns the host macOS version here. Not CPU-related. Recorded only. |
| `kern.grade_cputype` | ENOENT | unchanged in this spec | The reference has it (value 0). See `dyld-sim-handoff.md`. Recorded only. |

### 4.6 State the guest kernel must preserve once these features are published

- PSTATE.DIT and PSTATE.SSBS: keep them across every trap, fast trap,
  thread switch and thread_get/set_state. New threads and signal frames
  start with DIT = 0 and SSBS at its reset default.
- FPCR, including AH/FIZ/NEP (AFP): preserved per thread.
- No new trap handling is needed for the other features. They are plain
  EL0 instructions that the hardware executes.

## 5. Consistency invariants (tests must check all of them)

1. For every caps bit *n* with a name, `hw.optional.arm.<name>` equals
   bit *n*.
2. Every commpage kHas* bit equals the matching caps bit (§2.5 pairs).
   kHasARMv8Crypto equals AES ∧ PMULL ∧ SHA1 ∧ SHA256.
3. Legacy names equal their modern counterparts (§2.4).
4. Commpage cache bit, commpage 0x026 and `hw.cachelinesize` agree.
5. Commpage CPU count, `hw.ncpu` and friends all equal N.
6. No bit in the deny list is set anywhere.
7. Every published feature is present in the guest-visible ID registers,
   and executes in the guest probe (§7.1).
8. `hw.tbfrequency` × numer / denom of `mach_timebase_info` = 10⁹.

## 6. Risks

| Risk | Result | Mitigation |
|---|---|---|
| A published feature is not executable in the guest (KVM hides it, or a kernel or firmware update changes it) | SIGILL / EXC_BAD_INSTRUCTION, possibly in a launch-critical daemon | Derive the features from the guest ID registers at every VMM start, never from a fixed table. Run the §7.1 probe. Keep `YCODE_CPU_FEATURES=off`. |
| PAuth published without the vCPU feature | crash on the first non-hint PAC instruction | denied (§4.3) |
| SME or MTE published | crash, or state corruption | denied |
| ECV published while counter reads trap to the shim | CNTVCTSS read is not decoded, so SIGILL | deferred until the shim handles it |
| Private reference bits copied | unknown Apple-only paths (for example AMX) | never set unnamed bits; CPUFAMILY stays 0 |
| `hw.cachelinesize` confused with the ZVA block | `bzero`/`memset` stride errors, which corrupt memory silently | independent sources (CTR_EL0 vs DCZID_EL0), invariant 4, and a test that zeroes a buffer with guard bytes |
| Guest is migrated to a host with fewer features (other Thor kernels, other arm64 hosts) | SIGILL | features are recomputed on each start. Snapshots and prebuilt VMs (`snapshot.md`) must store the feature set and refuse to resume on a host that lacks one of its features. |
| DIT/SSBS/AFP state is lost across traps | wrong timing or FP results, hard to find | §4.6; the probe checks round trips through a trap |
| Changed values alter thread-pool or blocking choices | performance changes up or down | A/B measurement (§7.3) before the new values become the default |

## 7. Verification plan

### 7.1 Guest feature probe (Ycode's own guest tool, built for the simulator)

For each feature, run one representative instruction in a guest process
under a SIGILL guard, and record executed / SIGILL:

- **Positive (must execute when published):** FlagM `CFINV`; FlagM2
  `AXFLAG`; FHM `FMLAL`; DotProd `SDOT`; SHA3 `EOR3`; RDM `SQRDMLAH`; LSE
  `CAS`, `LDADD`; SHA1 `SHA1C`; SHA256 `SHA256H`; SHA512 `SHA512H`; AES
  `AESE`; PMULL `PMULL` (64×64→128); SB `SB`; FRINTTS `FRINT32Z`; LRCPC
  `LDAPR`; LRCPC2 `LDAPUR`; FCMA `FCMLA`; JSCVT `FJCVTZS`; DPB `DC CVAP`;
  DPB2 `DC CVADP`; BF16 `BFDOT`; I8MM `SMMLA`; FP16 scalar half `FADD`;
  HPFPCvt `FCVTL` from half; CRC32 `CRC32CX`; DIT `MSR DIT,#1` then
  `MRS DIT`; SSBS `MSR SSBS,#1`; AFP: set FPCR.AH, read it back;
  FP_SyncExceptions: the FPCR probe of §4.2.
- **Negative (must SIGILL, cleanly):** PAuth `PACGA` and `AUTIA` (non-hint
  form); SME `SMSTART`; SVE `RDVL`; MTE `IRG`; SPECRES `CFP RCTX`; WFxT
  `WFET`; ECV `MRS CNTVCTSS_EL0` (while it is deferred).
- **No instruction to test (ID register only):** LSE2, CSV2, CSV3, BTI
  (hint space, no effect without guarded pages).
- **State round trip:** set DIT, SSBS and FPCR.AH, make a syscall and a
  fast trap, yield to another thread, check that the bits are still set.
- **Consistency:** the probe also prints every sysctl of §2 and the
  commpage words, and checks the §5 invariants. Run the same probe in the
  Apple simulator to produce the reference column.
- **ZVA safety:** zero a buffer with `bzero` at many alignments and
  lengths, with guard bytes before and after, and check the guards.

### 7.2 Boot and launch

Run a full cold boot (all services; see `parity-means-full-boot.md`) and
launch the stock apps and a test app with the new values. Zero new
crash logs, zero EXC_BAD_INSTRUCTION. Compare the crash count with an
`YCODE_CPU_FEATURES=off` boot on the same build.

### 7.3 Speed measurement (A/B, same build, interleaved runs)

Compare `off` and `on`:
- JavaScriptCore: a JSContext loop with double→int32 conversions and
  atomics, plus a standard JS benchmark page in a WKWebView.
- Accelerate: `cblas_sgemm` 512×512 and a BNNS convolution.
- CommonCrypto SHA-256 and AES-CBC throughput, and `timingsafe_bcmp` in a
  loop (SB versus DSB+ISB).
- libcompression (zlib/LZFSE) and ImageIO decode of a large JPEG/HEIC.
- Cold-boot time to the home screen and the app-launch time (three runs
  each).
Report the median and spread. Do not claim a boot-wide gain unless the
boot time moves outside the run-to-run noise.

## 8. Open questions

- Q1 (answered, §9.2). What exactly does KVM 6.8 on the Thor expose to a
  PSCI-only vCPU for CSV2, CSV3, AFP, BTI, ECV and WFxT? All six are
  visible: CSV2 = 1, CSV3 = 1, AFP = 1, BT = 1, ECV = 2, WFxT = 2. SPECRES
  is visible too (1). The §4.4 assumptions hold; ECV and WFxT stay
  unpublished by the deny list.
- Q2. Should ECV be published once the shim decodes CNTVCTSS/CNTPCTSS? It
  is only useful if the guest reads the counter directly, which the
  default timebase mode does not allow.
- Q3. Should Ycode report `hw.cachelinesize` 128 for parity with Apple
  hosts? This spec chooses 64, which is true on the Thor, the same as the
  ZVA block, and has no known consumer that needs 128. Revisit only if a
  parity test shows a difference.
- Q4. kHasUCNormalMemory / `ucnormal_mem`: set for parity (as here) or clear
  because Ycode does not support uncached normal mappings? No EL0
  instruction depends on it.
- Q5. Which closed libraries read the commpage inline (without
  `__get_cpu_capabilities`)? This cannot be found at levels 1–4. The A/B
  measurement shows whether it matters.
- Q6. Would writable ID registers (KVM 6.7+) be useful to **hide** features
  (WFxT, ECV, SVE fields) at the hardware level as well, so that the guest
  ID view and the published view are identical by construction?

## 9. Implementation (agent CPUFEAT-IMPL, 2026-10-23)

### 9.1 Where

- `YcodeDarwinKernel/CPUFeatures.swift`: the register model, the §4.2
  derivation, the deny list, the caps bytes, the commpage bits, the
  profile (`GuestCPUProfile`) and the sysctl entries it adds. The
  sysctl table (`SysctlTable.standard`) and `CommpageBuilder` read the
  installed profile, so all three outputs come from one feature set.
- `ycode-simd/CPUFeatureSetup.swift` and `CKVM/ckvm_cpufeat.c`: at the start
  of `--exec`/`--device` runs, before the first VM, a scratch VM with one
  vCPU initialized as every Ycode vCPU (preferred target, PSCI 0.2 only)
  is read with KVM_GET_ONE_REG and destroyed. ID registers are VM-wide in
  KVM, so this equals reading the first vCPU of the first image (§4.1) and
  keeps the image build path unchanged. One log line gives the mode, the
  published, allowed and derived sets, and every register value.
- The FPCR probe runs at EL0 of the VMM process, not in the guest: the
  same cores run the guest, KVM does not trap FPCR, and nothing has to
  run in a VM before the first image. The guest probe (§9.3) repeats it
  inside the guest.
- `YCODE_CPU_FEATURES=off` publishes nothing optional (caps 13 zero bytes,
  no `hw.optional.*` entries, so every such name reads 0 as before; the
  base commpage bits TLS, VFP, event, FMA only). The other corrected
  values (timebase, caches, machdep, perflevel0) do not depend on the
  switch. Default: on.
- Cache sizes come from the host's sysfs cache description (cpu0 index
  entries; Thor: L1I 64 KiB, L1D 64 KiB, L2 1 MiB, one CPU per L2);
  `hw.cachelinesize` from CTR_EL0.CWG (Thor: 64). The brand string is
  built from MIDR (Thor: `"Ycode VM (Arm Neoverse V3AE)"`).
- `kern.grade_cputype` stays ENOENT, as §4.5 says: a grading answer would
  change how dyld grades slices, for no gain.
- sysctl reads that do not fit the caller's buffer now copy what fits and
  fail with ENOMEM (§4.5), for every name.

### 9.2 The guest's ID registers on the Thor (Q1)

KVM 6.8, vCPU with only the PSCI 0.2 feature, read 2026-10-23:

| Register | Value | Fields that matter |
|---|---|---|
| MIDR_EL1 | `0x410fd830` | Arm, part 0xD83 (Neoverse V3AE) |
| ID_AA64PFR0_EL1 | `0x1101001021111111` | CSV3 1, CSV2 1, DIT 1, SVE **0** (hidden), AdvSIMD 1, FP 1 (FP16) |
| ID_AA64PFR1_EL1 | `0x21` | SSBS 2, BT 1, MTE **0** (hidden), SME 0 |
| ID_AA64ISAR0_EL1 | `0x0221111110212120` | TS 2, FHM 1, DP 1, SHA3 1, RDM 1, Atomic 2, CRC32 1, SHA2 2, SHA1 1, AES 2 |
| ID_AA64ISAR1_EL1 | `0x0011111100211002` | I8MM 1, BF16 1, **SPECRES 1**, SB 1, FRINTTS 1, GPI/GPA/API/APA **0** (hidden), LRCPC 2, FCMA 1, JSCVT 1, DPB 2 |
| ID_AA64ISAR2_EL1 | `0x2` | WFxT 2, RPRES 0, no CSSC/BC |
| ID_AA64MMFR0_EL1 | `0x2100022200101125` | ECV 2 |
| ID_AA64MMFR1_EL1 | `0x0000111010312122` | AFP 1 |
| ID_AA64MMFR2_EL1 | `0x1221011112001011` | AT 1 (LSE2) |
| ID_AA64ZFR0_EL1, ID_AA64SMFR0_EL1 | 0 | — |
| CTR_EL0 (EL0) | `0xb444c004` | CWG 4 (64 bytes), DminLine 4 |
| DCZID_EL0 (EL0) | `0x4` | 64-byte block, allowed |
| FPCR trap-enable probe | 0 | FP_SyncExceptions 0 |

Derived (before the deny list): `ff ff c7 f7 1f 00 0e 00 00 00 00 00 00`
(adds SPECRES, WFxT, ECV to the published set). Published, equal to the
§4.4 oracle: caps `ff ef c7 e3 1f 00 0e 00 00 00 00 00 00`; commpage
capabilities64 `0x03f76f078701ffa8` with N = 1 (the guest reads exactly
this at 0x010, `0x8701ffa8` at 0x020, line 64 at 0x026, CPU family 0).

### 9.3 Guest probe (`SimShim/guest-tests/stageperf/p_cpufeat.c`)

Built with `build-stageperf.sh`, run with `ycode-simd --exec`. Results with
the switch on (`cpufeat ok`):

- Every published feature executed in a child process: FlagM, FlagM2,
  FHM, DotProd, SHA3, RDM, LSE (CAS, LDADD), SHA1, SHA256, SHA512, AES,
  PMULL, SB, FRINTTS, LRCPC, LRCPC2, FCMA, JSCVT, DPB, DPB2, BF16, I8MM,
  FP16, AdvSIMD, HPFPCvt, CRC32, DIT, SSBS, AFP (FPCR.AH reads back): 29
  of 29.
- Hidden features that raise SIGILL: PACGA, SMSTART, RDVL (SVE), CFP RCTX.
  The last two arrive at EL1 as EC 0x19 (SVE trap: the shim leaves
  CPACR_EL1.ZEN clear) and EC 0x18 (system instruction trap: SCTLR_EL1.EnRCTX
  clear). They used to end the process with SIGSEGV; the kernel now
  maps EC 0x18, 0x19, 0x1D (SME), 0x07 and 0x09 from EL0 to SIGILL
  (EXC_BAD_INSTRUCTION), as for an undefined instruction.
- Hidden features that execute (the hardware has them; the guest is
  simply not told, which is safe): AUTIA (a NOP: SCTLR_EL1.EnIA = 0), WFET,
  `MRS CNTVCTSS_EL0` (CNTKCTL_EL1.EL0VCTEN = 1 for the direct clock), IRG
  (MTE instructions without tag checking). The FPCR probe executes and
  reads back 0. §7.1 expected these to SIGILL; that is only possible by
  trapping them (Q6), and nothing is published for them.
- Invariants 1–6 and 8 hold (names, commpage, legacy names, cache line,
  CPU counts, deny list, `hw.tbfrequency` 24 000 000 × 125 / 3 = 10⁹).
  The caps size query returns 13; an 8-byte buffer gets the first 8 bytes
  and ENOMEM.
- DIT, SSBS and FPCR (FZ, DN, FIZ, AH, NEP) survive a BSD trap, a Mach
  trap, the in-place `mach_absolute_time`, a page fault, `sched_yield`, a
  20 ms sleep and another thread's run and join (DIT and SSBS are in
  SPSR_EL1, which the shim saves in the frame; FPCR stays in the thread's
  own vCPU). **A new thread used to inherit FPCR from the previous thread
  of a reused (parked) vCPU** (main line: `0x3c00000` in 4 of 4 rounds);
  `VCPUPool` now sets FPCR = FPSR = 0 when a parked vCPU starts a new
  thread, and new threads start with DIT 0, SSBS 0, FPCR 0 in 4 of 4
  rounds.
- `bzero` and `memset` at 77 offsets × 27 lengths (0 … 65 537), with 256
  guard bytes on each side: 4 158 cases, 0 wrong; DC ZVA zeroes exactly
  the 64-byte DCZID block.
- With the switch off the probe also passes (caps 13 zero bytes, commpage
  `0x1b4a0`, invariants hold, nothing published, so no instruction is
  required to execute).

### 9.4 Snapshots and prebuilt VMs

- A snapshot's system record stores the published set (`snapshot.md`
  §6.1, field 17). `KernelSnapshotRestore` refuses a snapshot whose set is
  not a subset of this host's allowed set (derived minus deny list),
  naming the missing features; the warm-boot launcher then boots cold.
  A snapshot without the field (older builds) restores as before. The
  check uses the allowed set, not the published one, so switching
  `YCODE_CPU_FEATURES` between save and restore does not force a cold
  boot; the restored images get a commpage built from the current
  setting and keep the snapshot's sysctl tables.
- Prebuilt VMs (`PrebuiltVMs`, `YCODE_VM_PREBUILD`) live only inside one
  `ycode-simd` process. The profile is installed once, before the first
  VM of the process is built, and never changes, so every prebuilt VM
  shares the process's feature set; no per-VM record is needed.

### 9.5 Speed: micro-benchmarks (A/B)

`p_cpufeat_bench` (original Ycode probe over public APIs), `--exec`, same
build, `YCODE_CPU_FEATURES=on` and `off` interleaved, 5 runs each under
`timed.sh` (machine to itself). Each run reports the median of 7 timed
repetitions after a warm-up; the table gives the median of the 5 run
medians and their range.

| Benchmark | on | off | on/off |
|---|---|---|---|
| JSC: double→int32 loop, 10⁷ iterations (ms) | 20.44 [20.43–20.46] | 20.44 [20.44–20.45] | 1.000 |
| JSC: `Atomics.add`/`compareExchange`, 5·10⁶ (ms) | 53.52 [53.43–53.57] | 53.42 [53.42–53.46] | 1.002 |
| JSC: objects, strings, sort (ms) | 49.1 [46.2–51.5] | 51.6 [41.1–52.9] | noise |
| `cblas_sgemm` 512 (GFLOP/s) | 24.38 [24.34–24.49] | 24.53 [24.27–24.68] | 0.994 |
| BNNS 3×3 convolution 64×64×32→64 (ms) | 3.815 [3.810–3.838] | 3.816 [3.810–3.865] | 1.000 |
| CC_SHA256, 32 MiB (MiB/s) | 1580 [1579–1583] | 1583 [1582–1583] | 0.999 |
| AES-128-CBC, 32 MiB (MiB/s) | 1639 [1637–1645] | 1643 [1640–1644] | 0.997 |
| `timingsafe_bcmp`, 64 bytes (ns/call) | 30.47 [30.38–32.95] | 30.41 [30.37–30.42] | 1.002 |
| LZFSE encode / decode, 8 MiB (MiB/s) | 52.2 / 1262 | 51.9 / 1255 | 1.005 / 1.006 |
| zlib encode / decode (MiB/s) | 48.2 / 754 | 48.2 / 753 | 1.000 / 1.001 |
| **ImageIO JPEG decode 2048×2048 (ms)** | **57.9 [55.6–58.3]** | **68.3 [67.9–68.9]** | **0.848** |

Only the JPEG decode moves (−15 %, ranges disjoint): ImageIO is among the
consumers that read `neon_fp16`/`FEAT_FP16` (§3). JavaScriptCore,
Accelerate, CommonCrypto, libcompression and `timingsafe_bcmp` do not
change: in this runtime they either do not test these names at run time
or already use the instructions unconditionally (the apple-m1 compile
baseline, §3). Their speed is the hardware's either way.

BOOT-AB-PLACEHOLDER

## Evidence

| Claim | Level | Source |
|---|---|---|
| Simulator values are the host kernel's, including `kern.osproductversion` and `hw.model` | 3 | own probes in the simulator vs `sysctl` on the host (`research/notes/cpufeat-observations.md` §1) |
| All reference values in §2.2–2.5 (M3 Max) | 3 | `cpufeat_probe`, `byname_probe`, `idregs_probe` (`research/experiments/cpufeat/`) |
| `hw.optional.arm.caps` format, bit numbers, 13-byte size, ENOMEM on a short buffer | 1 | `arm/cpu_capabilities_public.h` (SDK), xnu `bsd/kern/kern_mib.c` |
| Commpage offsets and bit masks | 1 | xnu `osfmk/arm/cpu_capabilities.h` |
| Derivation of bits from ID registers, the FPCR probe, SPECRES needing EnRCTX | 1 | xnu `osfmk/arm/commpage/commpage.c`, `osfmk/arm64/proc_reg.h`; Arm ARM field definitions |
| dyld reads caps for processor function variants | 1 | dyld `DyldProcessConfig.cpp`, `common/FunctionVariantsArm64.inc` |
| The iOS 27.1 simulator cache has no function-variant tables | 4 | `dyld_info -function_variants` on the simulator cache |
| compiler-rt FMV reads caps (13 bytes) or the per-feature names | 1 | LLVM `compiler-rt/lib/builtins/cpu_model/aarch64/fmv/apple.inc` |
| JSC reads six FEAT names | 1 + 4 | WebKit `MacroAssemblerARM64.cpp`; strings in JavaScriptCore |
| timingsafe reads DIT/SB; icache invalidate reads CPUFAMILY | 1 | libplatform `timingsafe.c`, `cache.s` |
| Other consumers (Accelerate, audio, WebRTC, ImageIO, …) | 4 | string literals attributed through the cache map; `dyld_info -imports` for `__get_cpu_capabilities` |
| Simulator compiler baseline apple-m1 | 3 | `clang -###` for `arm64-apple-ios27.1-simulator` |
| Thor features, MIDR, caches | 3 | `lscpu`, `/proc/cpuinfo`, sysfs (read-only) |
| What KVM hides from a PSCI-only vCPU | 1 (Linux KVM behaviour, public) for SVE, PAuth, SME and MTE; 3 for all fields | §9.2: KVM_GET_ONE_REG on the Thor (`ycode-simd` start-up log), 2026-10-23 |
| Ycode's current values (`hw.tbfrequency` 1e9, caps 8 bytes, commpage bits) | own code | `ycode/Sources/YcodeDarwinKernel/SysctlTable.swift`, `ProcessImage.swift` |
| Speed effect concentrated in gated libraries, not boot-wide | inference (4) | §3; to be measured (§7.3) |
| Q1 answer, published set and commpage word on the Thor | 3 | §9.2, `ycode-simd` log and `p_cpufeat` in the guest (Thor, 2026-10-23) |
| Published features execute, hidden ones SIGILL or execute harmlessly; invariants; DIT/SSBS/FPCR round trips; FPCR leak across reused vCPUs (main line) and its fix; bzero guards | 3 | `p_cpufeat` runs with the switch on and off and against the main-line build (Thor, 2026-10-23) |
| Snapshot feature record and refusal | own code + unit tests | `CPUFeaturesTests.snapshotRefusesMissingFeatures`, `SnapshotKernelRoundTripTests` |
| Micro-benchmark A/B (§9.5) | 3 | `p_cpufeat_bench`, 5 + 5 interleaved runs under `timed.sh` (Thor, 2026-10-23) |
