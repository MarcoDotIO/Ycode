# SimShim: guest code for the Ycode micro-VM

This directory holds the guest-side code of stages 2 and 3a of
`docs/SIMULATOR-LINUX.md`. The contracts are
`specs/simulator/vm-shim-protocol.md` (stage 2) and
`specs/simulator/stage3-contract.md` (stage 3a, which extends it). All of
this is original Ycode code. It is written from those contracts,
`specs/simulator/dyld-sim-handoff.md`, and the public Arm Architecture
Reference Manual.

| File | What it is |
|---|---|
| `shim.S` | The EL1 shim. It boots the vCPU (contract §4), owns the vector table, and forwards every exception to the VMM through the trap frame and doorbell (§5). |
| `el0_selftest.S` | The EL0 self-test (§7). It makes Darwin-style `svc #0x80` calls and exits with 0, or with 10–16 at the first failed step. |
| `host_stubs.S` | The stage-3a host page (stage3-contract §5): the EL0 launch trampoline `_ycode_launch`, one stub per `dyld_sim` helper slot, the helpers table, and the zero-filled RW area. |
| `build.sh` | Builds `out/shim.bin`, `out/el0_selftest.bin`, and `out/host_stubs.bin` (flat binaries), plus `out/host_stubs.syms`. `out/` is git-ignored. |
| `guest-tests/` | `hello.c` and `build.sh` (stage3-contract §9). macOS only: builds `out/guest-tests/hello` for the iOS simulator platform. |

## Build

```sh
# Linux (the Thor): the tools come from the Swift toolchain.
. ~/.local/share/swiftly/env.sh
sh build.sh
```

The script needs `clang`, `ld.lld`, and `llvm-objcopy` (override them with
`CLANG=`, `LD_LLD=`, `OBJCOPY=`). It writes small linker scripts into
`out/`, keeps the ELF files (`out/*.elf`) for `llvm-objdump -d`, prints the
size of each binary, and fails if a step fails. It also checks that the
self-test's magic is at file offset `0x4000` and that the shim is at most
1 MiB. For the host page it checks that `host_stubs.bin` is exactly
65536 bytes, that the word at file offset `0x4000` is version 18, that
slots 32 and 33 are 0 and every other slot points into the code page, that
offset `0x0F00` holds `ret`, and that `+0x8000..+0xFFFF` is zero. With
`llvm-nm` available it writes `out/host_stubs.syms` (offset and name of
every symbol).

```sh
# macOS: the guest test program (needs Xcode's iOS simulator SDK).
sh guest-tests/build.sh       # -> out/guest-tests/hello, checks platform 7
```

## Layout

- `shim.bin` is linked at `0x4000_0000`. The entry point is byte 0. The
  vector table is at offset `0x800` (2 KiB aligned, 16 entries of `0x80`
  bytes), and the common trap path follows it. The code uses only
  PC-relative addressing, so the load address does not matter in practice.
- `el0_selftest.bin` is linked at `0x1_0000_0000`. Text and the hello
  string fill the first 16 KiB page. The data page starts at file offset
  `0x4000` (VA `0x1_0000_4000`) with the magic `0x5943_4F44_4531_3645`. The
  file is 16 KiB + 8 bytes. The VMM rounds the data part up to 16 KiB.

## Register and memory assumptions

- **Boot.** The shim takes every value it programs from the boot info block
  (§4): `MAIR_EL1`, `TCR_EL1`, `TTBR0_EL1`, `SCTLR_EL1`, the EL1 stack top,
  the EL0 entry/SP/thread registers, and EL0 `x0`–`x7`. It hard-codes only
  `CPACR_EL1.FPEN = 0b11` and `SPSR_EL1 = 0x3C0`, as the contract says.
  The `SCTLR_EL1` value must keep `A = 0` (the shim never makes unaligned
  accesses, but EL0 code may), must keep `M = 1`, and must keep the shim's
  pages executable at EL1 (`WXN = 0`, or map the shim read-only).
- **Finding the frame.** After boot, `TPIDR_EL1` holds the boot info
  address. A vector entry pushes the guest's `x0`/`x1` onto the EL1 stack
  (16 bytes), loads a kind code into `x1`, and branches to `trap_common`.
  That path reads the frame address from boot info `+56`, saves `x2`–`x30`,
  pops the guest's `x0`/`x1` from the stack, and stores them into the frame.
  No guest register is lost. `SP_EL1` is the same at `eret` as it was at
  exception entry. The doorbell address is read from boot info `+64`.
  Therefore the boot info block must stay mapped and unchanged while the
  guest runs.
- **Doorbell.** The doorbell is a single `str x0, [x2]` (64-bit, no
  writeback, so the abort has a valid syndrome for KVM MMIO emulation). It
  sits between two `dsb sy` barriers. `x0` holds the frame address.
- **Resume.** The shim reloads `SP_EL0`, `ELR_EL1`, `SPSR_EL1`,
  `TPIDRRO_EL0`, `TPIDR_EL0`, and `x0`–`x30` from the frame, then runs
  `isb` and `eret`. It does not reload `ESR`, `FAR`, `kind`, or the
  reserved slot.
- **Not saved.** FP/SIMD registers, `FPCR`, and `FPSR` are not part of the
  frame. Neither the shim nor the VMM changes them, so the guest keeps them.

## Decisions where the contract is silent

- **The vector entries the contract does not name:**
  - Current EL with `SP_EL0`, synchronous: kind 4, then spin. The shim
    never runs on `SP_EL0`.
  - Current EL (either SP), IRQ/FIQ/SError: kind 3, then spin. The frame
    is per vCPU, so an exception taken inside the shim cannot be resumed
    safely.
  - Lower EL AArch32, synchronous: the same path as AArch64 (EC `0x15`
    gives kind 1, anything else gives kind 2). AArch32 IRQ/FIQ/SError give
    kind 3. EL0 is always AArch64 here, so these entries are not expected
    to run.
  - Lower EL (AArch64) kinds 2 and 3 are resumable. The shim restores the
    frame and `eret`s if the VMM calls `KVM_RUN` again. Per §6, the stage-2
    VMM exits instead.
- **Extra boot steps.** Step 6 also runs `ic iallu` (before the MMU and the
  I-cache are enabled). Step 8 also sets `TPIDR_EL1` (see above). An
  `isb` runs before every `eret`, so the code does not depend on
  `SCTLR_EL1.EOS`.
- **A faulting shim.** If `SP_EL1` itself is corrupt, the push in a
  current-EL vector entry faults again and loops without reaching the
  doorbell. The VMM then sees a vCPU that never exits. Such a fault can
  only come from a shim bug.
- **Self-test details:**
  - The PID comparison uses all 64 bits of `x0` and the initial `x1`.
  - The time comparison is unsigned.
  - The hello string (35 bytes) is in the read-only text page.
  - If `exit` ever returns, the test runs `brk #0xdead`, so the VMM sees a
    kind-2 trap instead of a silent loop.

## Stage 3a: the shim additions (stage3-contract §7)

- **`resumeFlags`** (trap frame `+312`, formerly reserved). The save path
  still writes 0 there before it rings the doorbell. On resume, if bit 0
  is set (the VMM changed the page tables), the shim runs
  `tlbi vmalle1; ic iallu; dsb ish; isb`, clears bit 0 in the frame, and
  then restores the registers and `eret`s. The `ic iallu` is an addition to
  the contract's sequence: a recycled guest page may receive new code from
  the VMM, so the I-cache is dropped together with the TLB.
- **`CNTKCTL_EL1`** = `0x2` at boot (after `CPACR_EL1`): EL0VCTEN = 1,
  EL0PCTEN = 0, event stream and EL0 timer access off.
- Everything else is unchanged. The stage-2 self-test still passes with
  the new shim.

## Stage 3a: the host page (`host_stubs.bin`)

Linked at VA `0x3_1000_0000`, exactly 64 KiB (`0x10000`) long:

| Offset | Contents |
|---|---|
| `+0x0000` | `_ycode_launch` (the EL0 entry) |
| `+0x0060` | Shared failure tails (`bsd_fail_minus1`, `bsd_fail_null`) |
| `+0x0080`..`+0x0530` | The helper stubs (one per non-NULL slot, 16-byte aligned) |
| `+0x0F00` | **`ycode_ret_stub`: a single `ret`. Fixed.** Use it for `dyld_all_image_infos.notification`. The assembler fails if the stubs grow past it |
| `+0x4000` | Helpers table, 544 bytes: version 18, slots 1–67 at `8·n` |
| `+0x8000` | errno cell (`int` in an 8-byte slot) |
| `+0x8008` | `startGlue` cell |
| `+0x8040` | Launch block (12 × u64), see below |
| `+0x8100` | `dyld_all_image_infos` (368 bytes) |
| `+0x8300` | `infoArray`, `uuidArray`, path strings (2 KiB) |
| `+0x9000` | `sysctlbyname` and scratch (4 KiB) |

Everything from `+0x0F04` to `+0x3FFF` and from `+0x4220` to `+0xFFFF` is
zero (a stray jump into the code page hits `udf #0`).

### `_ycode_launch`

`x19` = launch block (`+0x8040`), `x20` = `start_sim`; both are
callee-saved, so they survive the call into `dyld_sim`.

1. `sp = (block.stackTop − 16) & ~15`, `x29 = 0`, `[sp] = block.startGlueAddr`.
   SP is 16-byte aligned and strictly below the kernel block, so the 9th
   argument never overlays the mach_header slot.
2. `x0..x7` = block words 1–8 (`argc`, `argv`, `envp`, `apple`, `mainMH`,
   `simMH`, `simSlide`, `helpers`); `blr` block word 0 (`prepareEntry`).
3. `x20 = x0`; `x1 = block.argv`, `x2 = block.envp`, `x3 = block.apple`,
   `x0 = [argv − 8]` (argc re-read from `argv[-1]`); `blr x20`.
4. `x16 = 1; svc #0x80` (BSD `exit` with the returned `x0`), then `brk #1`.

### Stub offsets and kinds

Kinds: **P** = pure EL0 (no trap), **B** = BSD forwarder (carry → errno cell,
return −1), **M** = Mach forwarder (`x0` passes through), **Y** = Ycode-private
trap (`x16 = 0x7963_00NN`). For **Y**, "−1" and "NULL" mean the BSD
convention with that failure value; "kr" and "void" mean `x0` passes through.

| Slot | Helper | Offset | Kind | Trap / behavior |
|---|---|---|---|---|
| 1 | `open` | `+0x0080` | B | 5. Mode from `[sp]` (32-bit) into `x2` |
| 2 | `close` | `+0x00A0` | B | 6 |
| 3 | `pread` | `+0x00B0` | B | 153 |
| 4 | `write` | `+0x00C0` | B | 4 |
| 5 | `mmap` | `+0x00D0` | B | 197. Returns −1 (`MAP_FAILED`) on error |
| 6 | `munmap` | `+0x00E0` | B | 73 |
| 7 | `madvise` | `+0x00F0` | B | 75 |
| 8 | `stat` | `+0x0100` | B | 338 (`stat64`) |
| 9 | `fcntl` | `+0x0110` | B | 92. Argument from `[sp]` (64-bit) into `x2` |
| 10 | `ioctl` | `+0x0130` | B | 54. Argument from `[sp]` (64-bit) into `x2` |
| 11 | `issetugid` | `+0x0150` | P | 0 |
| 12 | `getcwd` | `+0x0160` | Y | `0x7963_0003`, NULL |
| 13 | `realpath` | `+0x0180` | Y | `0x7963_0002`, NULL |
| 14 | `vm_allocate` | `+0x01A0` | M | −10 |
| 15 | `vm_deallocate` | `+0x01B0` | M | −12 |
| 16 | `vm_protect` | `+0x01C0` | M | −14 |
| 17 | `vlog` | `+0x01D0` | Y | `0x7963_0001`, void |
| 18 | `vwarn` | `+0x01E0` | Y | `0x7963_0001`, void |
| 19 | `pthread_mutex_lock` | `+0x01F0` | P | 0 |
| 20 | `pthread_mutex_unlock` | `+0x0200` | P | 0 |
| 21 | `mach_thread_self` | `+0x0210` | M | −27 |
| 22 | `mach_port_deallocate` | `+0x0220` | M | −18 |
| 23 | `task_self_trap` | `+0x0230` | M | −28 |
| 24 | `mach_timebase_info` | `+0x0240` | M | −89 |
| 25 | `OSAtomicCompareAndSwapPtrBarrier` | `+0x0250` | P | `dmb ish`, `ldaxr`/`stlxr` loop, `dmb ish`; 1 or 0 |
| 26 | `OSMemoryBarrier` | `+0x0290` | P | `dmb ish` |
| 27 | `getProcessInfo` | `+0x02A0` | P | `0x3_1000_8100` |
| 28 | `errnoAddress` | `+0x02B0` | P | `0x3_1000_8000` |
| 29 | `mach_absolute_time` | `+0x02C0` | M | −3 |
| 30 | `thread_switch` | `+0x02D0` | M | −61 |
| 31 | `opendir` | `+0x02E0` | P | NULL |
| 32 | `readdir_r` | — | — | NULL slot |
| 33 | `closedir` | — | — | NULL slot |
| 34 | `coresymbolication_load_notifier` | `+0x02F0` | P | `ret` |
| 35 | `coresymbolication_unload_notifier` | `+0x0300` | P | `ret` |
| 36 | `proc_regionfilename` | `+0x0310` | Y | `0x7963_0005`, −1 |
| 37 | `getpid` | `+0x0330` | B | 20 |
| 38 | `mach_port_insert_right` | `+0x0340` | M | −21 |
| 39 | `mach_port_allocate` | `+0x0350` | M | −16 |
| 40 | `mach_msg` | `+0x0360` | M | −31 |
| 41 | `abort_with_payload` | `+0x0370` | B | 521 |
| 42 | `task_register_dyld_image_infos` | `+0x0380` | P | `KERN_SUCCESS` |
| 43 | `task_unregister_dyld_image_infos` | `+0x0390` | P | `KERN_SUCCESS` |
| 44 | `task_get_dyld_image_infos` | `+0x03A0` | P | `KERN_NOT_SUPPORTED` (46) |
| 45 | `task_register_dyld_shared_cache_image_info` | `+0x03B0` | P | `KERN_SUCCESS` |
| 46 | `task_register_dyld_set_dyld_state` | `+0x03C0` | P | `KERN_SUCCESS` |
| 47 | `task_register_dyld_get_process_state` | `+0x03D0` | P | `KERN_NOT_SUPPORTED` (46) |
| 48 | `task_info` | `+0x03E0` | Y | `0x7963_0006`, kr |
| 49 | `thread_info` | `+0x03F0` | Y | `0x7963_0007`, kr |
| 50 | `kdebug_is_enabled` | `+0x0400` | P | 0 |
| 51 | `kdebug_trace` | `+0x0410` | P | 0 |
| 52 | `kdebug_trace_string` | `+0x0420` | P | 0 |
| 53 | `amfi_check_dyld_policy_self` | `+0x0430` | P | `*out = 0xFF` (u64, if `out` ≠ NULL); returns 0 |
| 54 | `notifyMonitorOfMainCalled` | `+0x0450` | Y | `0x7963_0011`, void |
| 55 | `notifyMonitorOfImageListChanges` | `+0x0460` | Y | `0x7963_0010`, void |
| 56 | `mach_msg_destroy` | `+0x0470` | Y | `0x7963_0008`, void |
| 57 | `mach_port_construct` | `+0x0480` | M | −24 |
| 58 | `mach_port_destruct` | `+0x0490` | M | −25 |
| 59 | `fstat` | `+0x04A0` | B | 339 (`fstat64`) |
| 60 | `vm_copy` | `+0x04B0` | Y | `0x7963_0004`, kr |
| 61 | `task_dyld_process_info_notify_get` | `+0x04C0` | P | `KERN_NOT_SUPPORTED` (46) |
| 62 | `fsgetpath` | `+0x04D0` | B | 427 |
| 63 | `getattrlistbulk` | `+0x04E0` | B | 461 |
| 64 | `getattrlist` | `+0x04F0` | B | 220 |
| 65 | `getfsstat` | `+0x0500` | B | 347 (`getfsstat64`) |
| 66 | `notifyMonitorOfDyldBeforeInitializers` | `+0x0510` | Y | `0x7963_0012`, void |
| 67 | `sysctlbyname` | `+0x0520` | Y | `0x7963_0009`, −1 |

`out/host_stubs.syms` is the authoritative list for a given build; the
offsets above are what the current source produces. Only `+0x0000`,
`+0x0F00`, `+0x4000`, and the `+0x8000` area are fixed by contract.

### Decisions where the contract is silent

- **One stub per slot.** Every non-NULL slot has its own stub, so the VMM
  can name the helper from an ELR inside the host page.
- **`mmap` failure** returns −1 (`MAP_FAILED`), not NULL. The NULL rule of
  §5 applies to `getcwd`, `realpath`, and `opendir`.
- **Private traps with a `kern_return_t` or `void` result** (`vm_copy`,
  `task_info`, `thread_info`, `vlog`/`vwarn`, `mach_msg_destroy`, the three
  monitor notifications) pass `x0` through and ignore carry. `realpath`,
  `getcwd`, `proc_regionfilename`, and `sysctlbyname` use carry → errno.
- **Slots 54, 55, 66** use the private trace traps of §5 (not the plain
  `ret` of dyld-sim-handoff §7.3), because the contract lists them.
- **`task_*` dyld-info slots:** the register/unregister/set-state ones
  return `KERN_SUCCESS`; the ones with out-parameters (44, 47, 61) return
  `KERN_NOT_SUPPORTED`, so a caller never reads an unfilled result.
- **`issetugid`** is a pure stub returning 0 (§7.3 table 1), not BSD 327.
- **Variadic loads:** `open` loads the mode with `ldr w2` (an `int`);
  `fcntl` and `ioctl` load all 64 bits (`long` / pointer). If the caller
  passed no variadic argument, the value is ignored by the VMM.
- **The errno cell** is written with a 32-bit store; its upper half stays 0.
- **The notification stub** of §5 is `ycode_ret_stub` itself.
