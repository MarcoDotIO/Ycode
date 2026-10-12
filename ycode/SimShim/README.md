# SimShim: stage-2 guest code for the Ycode micro-VM

This directory holds the guest-side code of stage 2 of `docs/SIMULATOR-LINUX.md`.
The contract is `specs/simulator/vm-shim-protocol.md`. All of this is
original Ycode code. It is written from that contract and the public Arm
Architecture Reference Manual.

| File | What it is |
|---|---|
| `shim.S` | The EL1 shim. It boots the vCPU (contract §4), owns the vector table, and forwards every exception to the VMM through the trap frame and doorbell (§5). |
| `el0_selftest.S` | The EL0 self-test (§7). It makes Darwin-style `svc #0x80` calls and exits with 0, or with 10–16 at the first failed step. |
| `build.sh` | Builds `out/shim.bin` and `out/el0_selftest.bin` (flat binaries). `out/` is git-ignored. |

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
1 MiB.

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
