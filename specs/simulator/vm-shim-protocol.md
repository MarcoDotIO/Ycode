# Spec: Ycode micro-VM, stage 2 contract (VMM ↔ EL1 shim ↔ EL0)

Status: **implemented and verified (stage 2 of `docs/SIMULATOR-LINUX.md`).**
The end-to-end self-test passes on the Thor. Every component
built in stage 2 follows this document exactly. If something needs to change,
change it here first.

This is Ycode's own design. It describes no Apple internals. The Darwin
facts it relies on are in `specs/simulator/darwin-arm64-abi.md`, and the Arm
architecture facts come from the public Arm Architecture Reference Manual.

## 1. Components

| Component | Location | Language | Runs |
|---|---|---|---|
| EL1 shim | `ycode/SimShim/shim.S` → `shim.bin` | arm64 assembly | guest EL1 |
| EL0 self-test | `ycode/SimShim/el0_selftest.S` → `el0_selftest.bin` | arm64 assembly | guest EL0 |
| Shim build script | `ycode/SimShim/build.sh` | sh (clang + llvm-objcopy) | host |
| ABI and layout library | `ycode/Sources/YcodeDarwinABI` | Swift, portable (macOS and Linux) | host |
| KVM bindings | `ycode/Sources/CKVM` | C (compiled only on Linux) | host |
| Hypervisor | `ycode/Sources/YcodeHypervisor` | Swift (Linux-only code under `#if os(Linux)`) | host |
| VMM executable | `ycode/Sources/ycode-simd` | Swift | host |

## 2. Guest physical memory (GPA)

| GPA | Size | Use |
|---|---|---|
| `0x0900_0000` | 16 KiB | **Doorbell** (MMIO). There is no memslot here, so guest stores exit to the VMM |
| `0x4000_0000` | 512 MiB | **RAM** (one KVM memslot, slot 0) |

The VMM divides RAM as follows (offsets from `0x4000_0000`; every region is
16 KiB-aligned):

| Offset | Size | Contents |
|---|---|---|
| `0x0000_0000` | 1 MiB | Shim image (`shim.bin`), loaded at offset 0. **The shim entry point is its first byte.** |
| `0x0010_0000` | 16 KiB | Boot info block (§4) |
| `0x0010_4000` | 16 KiB | Trap frame (§5), one per vCPU (stage 2 has one vCPU) |
| `0x0011_0000` | 64 KiB | EL1 stack. Its top is `0x4012_0000` |
| `0x0020_0000` | 8 MiB | Page tables (allocated by the VMM) |
| `0x0100_0000` | rest | Pages backing EL0 memory (image, stack, commpage) |

## 3. Stage-1 translation (built by the VMM, loaded by the shim)

- **16 KiB granule**, `T0SZ = 17` (47-bit VA). The walk starts at **level 1**
  and has 3 levels: L1 covers VA bits 46:36, L2 bits 35:25, L3 bits 24:14.
  Every table is 2048 entries (16 KiB). TTBR1 walks are disabled (`EPD1 = 1`).
- `MAIR_EL1`: Attr0 = `0xFF` (Normal, write-back read/write-allocate),
  Attr1 = `0x00` (Device-nGnRnE).
- Descriptors:
  - L3 page descriptors have bits[1:0] = `0b11`. Table descriptors have
    `0b11`.
  - Every valid leaf sets AF (bit 10), SH = inner shareable (bits 9:8 =
    `0b11`), and AttrIndx (bits 4:2).
  - AP[2:1] (bits 7:6): `00` = EL1 RW / EL0 none, `01` = EL1 RW / EL0 RW,
    `10` = EL1 RO / EL0 none, `11` = EL1 RO / EL0 RO.
  - PXN is bit 53 and UXN is bit 54.
- **The EL1 regions are identity-mapped (VA = GPA) and EL1-only:**

| VA | Mapping |
|---|---|
| `0x4000_0000`–`0x400F_FFFF` | Shim image. EL1 RX, AP `00`, UXN=1, PXN=0. For simplicity it may be mapped writable, but it must never be EL0-accessible |
| `0x4010_0000`–`0x4011_FFFF` | Boot info, frame, and EL1 stack. EL1 RW, UXN=1, PXN=1 |
| `0x4020_0000`–`0x409F_FFFF` | Page tables. EL1 RW, UXN=1, PXN=1 |
| `0x0900_0000` (one page) | Doorbell. Attr1 (device), EL1 RW, UXN=1, PXN=1 |

  These VAs lie below 4 GiB, inside a Darwin executable's `__PAGEZERO`, so
  they never collide with EL0 mappings.
- **EL0 mappings for the stage-2 self-test** (VA → pages from the EL0 pool):

| VA | Size | Permissions |
|---|---|---|
| `0x1_0000_0000` | the first 16 KiB of `el0_selftest.bin` | EL0 RX (AP `11`, PXN=1, UXN=0) |
| `0x1_0000_4000` | the remainder of the image, rounded up to 16 KiB | EL0 RW (AP `01`, PXN=1, UXN=1) |
| `0x1_7000_0000` − 64 KiB, up to `0x1_7000_0000` | stack | EL0 RW, XN. Initial SP = `0x1_7000_0000` |
| `0xF_FFFF_C000` | 16 KiB commpage | EL0 RO (zero-filled in stage 2) |

- Recommended system register values (the VMM supplies them in boot info):
  - `TCR_EL1`: T0SZ=17, IRGN0=ORGN0=`0b01`, SH0=`0b11`, TG0=`0b10` (16 KiB),
    EPD1=1, TG1=`0b01` (16 KiB, unused), IPS=`0b010` (40-bit). TBI0=0 in
    stage 2; **TBI0=1 from stage 6** (Darwin sets `TCR_TBI0`, xnu
    `proc_reg.h`; Swift code dereferences tagged pointers), and the VMM
    strips the top byte of guest addresses it accesses.
  - `SCTLR_EL1`: M, C, I, SA, SA0, UCT, DZE, UCI, nTWI, nTWE, SPAN, EIS, EOS,
    and the architectural RES1 bits set. A (alignment check) = 0, WXN = 0,
    EE = E0E = 0 (little-endian).

## 4. Boot handoff

The vCPU starts at EL1h with the MMU off. The VMM sets:

- `PC` = `0x4000_0000`;
- `PSTATE` = EL1h with DAIF masked;
- **`x0` = GPA of the boot info block** (`0x4010_0000`).

All boot info fields are little-endian u64:

| Offset | Field |
|---|---|
| 0 | magic = `0x3154_4F4F_4244_4359` (ASCII "YCDBOOT1" read as a little-endian u64) |
| 8 | `ttbr0_el1`: GPA of the L1 table |
| 16 | `tcr_el1` |
| 24 | `mair_el1` |
| 32 | `sctlr_el1` |
| 40 | EL0 entry PC |
| 48 | EL0 initial SP |
| 56 | trap frame address (VA = GPA, identity-mapped) |
| 64 | doorbell address (VA = GPA = `0x0900_0000`) |
| 72 | initial `tpidrro_el0` |
| 80 | initial `tpidr_el0` |
| 88–151 | initial EL0 `x0`…`x7` (8 × u64) |
| 152 | EL1 stack top |

The shim must do the following, in order:

1. Validate the magic (on mismatch, spin in `wfi`).
2. Set `SP_EL1` from the boot info.
3. Write `MAIR_EL1`, `TCR_EL1`, `TTBR0_EL1`.
4. `isb`.
5. Enable FP/SIMD for EL0 and EL1 (`CPACR_EL1.FPEN = 0b11`).
6. Invalidate the TLB on every PE of the inner shareable domain (`tlbi vmalle1is`; a VM reused for another process, `boot-profile.md` §9 SP1, may have the old process's entries cached on other PEs), `dsb sy`, `isb`.
7. Write `SCTLR_EL1`, then `isb`. Execution continues because the shim is
   identity-mapped.
8. Set `VBAR_EL1` to its vector table (2 KiB-aligned).
9. Set `TPIDRRO_EL0` and `TPIDR_EL0`.
10. Set `SP_EL0`, `ELR_EL1` = EL0 entry, `SPSR_EL1` = `0x3C0` (EL0t, DAIF
    masked).
11. Load `x0`…`x7`, zero the other GPRs, and `eret`.

## 5. Trap frame and doorbell

The frame is 320 bytes of little-endian u64 at the frame address:

| Offset | Field |
|---|---|
| 0–247 | `x0`…`x30` |
| 248 | `sp_el0` |
| 256 | `elr_el1` (for SVC this is already the address *after* the `svc`) |
| 264 | `spsr_el1` |
| 272 | `esr_el1` |
| 280 | `far_el1` |
| 288 | `tpidrro_el0` (the shim writes it back to the register on resume) |
| 296 | `tpidr_el0` (written back on resume) |
| 304 | `kind`: 1 = SVC from EL0 (EC `0x15`); 2 = any other synchronous exception from EL0; 3 = IRQ/FIQ/SError; 4 = synchronous exception taken at EL1 (shim bug) |
| 312 | `resumeFlags` (stage 3 on; §5.2) |

On any exception, the shim's vector entry does the following:

1. Saves all GPRs, `SP_EL0`, `ELR_EL1`, `SPSR_EL1`, `ESR_EL1`, `FAR_EL1`,
   `TPIDRRO_EL0`, and `TPIDR_EL0` to the frame, and sets `kind`.
2. Executes `dsb sy`, then **stores the frame address (u64) to the
   doorbell**. This store becomes a `KVM_EXIT_MMIO` write of 8 bytes at GPA
   `0x0900_0000`. The VMM handles the trap while the vCPU is stopped, and
   may modify any field of the frame.
3. After the VMM re-enters the vCPU, the store completes. The shim then
   restores everything from the frame (including the `ELR`/`SPSR` the VMM
   may have edited) and `eret`s.

For kind 4, the shim stores to the doorbell and then spins. The VMM treats
it as fatal.

### 5.1 Alternative doorbell: forwarded HVC (default on since 2026-10-17)

The doorbell may instead be an `HVC` call that KVM forwards to the VMM. The
VMM chooses the form per VM (the HVC form by default when the host installs
the filter below; `YCODE_HVC_DOORBELL=0` keeps the MMIO form); both forms
carry the same frame and give the same resume semantics.

- **Selection.** Boot info field 64 (doorbell address) = **0** selects the
  HVC doorbell; any other value is the MMIO doorbell address as above. The
  VMM writes the same value into every vCPU's boot info of a VM.
- **Function ID.** `0xC600_5943`: an SMCCC fast call (bit 31), SMC64
  convention (bit 30), owning entity 6 (vendor-specific hypervisor
  service), function number `0x5943` ("YC"). It is outside the Arm
  Architecture service range (`0x8000_0000`–`0x8000_FFFF`), which the KVM
  filter refuses.
- **VMM setup.** Before any vCPU of the VM runs, the VMM installs one SMCCC
  filter range on the VM fd: `KVM_SET_DEVICE_ATTR`, group
  `KVM_ARM_VM_SMCCC_CTRL` (0), attribute `KVM_ARM_VM_SMCCC_FILTER` (0),
  `struct kvm_smccc_filter { u32 base = 0xC600_5943; u32 nr_functions = 1;
  u8 action = KVM_SMCCC_FILTER_FWD_TO_USER (2); u8 pad[15] = 0 }`. If the
  kernel refuses (no SMCCC filter support), the VMM keeps the MMIO doorbell
  for that VM and the boot info carries the MMIO address.
- **Shim.** In place of the doorbell store, the shim keeps the frame address
  in `x4`, sets `w0` = the function ID, executes `hvc #0`, and then reloads
  `x0` from `x4`. The `dsb sy` before it stays. The shim relies on no
  register value the VMM returns: it restores everything from the frame as
  before. (`HVC` is undefined at EL0, so only the shim can ring this
  doorbell.)
- **Exit.** KVM returns `KVM_EXIT_HYPERCALL` with `nr` = the function ID and
  `flags` bit 0 (`KVM_HYPERCALL_EXIT_SMC`) = 0. At that point the PC already
  points at the instruction after the `HVC` (KVM API documentation), so the
  VMM changes no register: it reads the frame at the vCPU's own frame
  address (it knows it per vCPU; the call carries no address), handles the
  trap, writes the frame back, and calls `KVM_RUN` again. A hypercall exit
  with any other `nr`, or with the SMC flag, is an unexpected exit (status
  71).
- **Parked vCPUs** (`stage4a-contract.md` §4) are stopped just after the
  `HVC` instead of at the store; resuming one runs the same restore path, so
  reuse works unchanged.
- **Cost.** A bare forwarded HVC round trip is about 230 ns (8 %) cheaper
  than the MMIO exit on the Thor (`native-mode.md` §8.2). Through the full
  `ycode-simd` trap path (guest probe `p_fasttraps`, 3 runs each, the Thor
  under load), the saving is about the same in absolute terms:
  - lock-free trap −3: MMIO 4691/4692/4902 ns, HVC 4538/4514/4548 ns
    (median −154 ns, −3 %);
  - locked trap `getppid`: MMIO 4770/4763/4795 ns, HVC 4683/4544/4540 ns
    (−226 ns, −5 %).
- **Boot.** The time to the home screen with HVC was 550 s (set 1) and
  515/510 s (set 2). Without it, the times were 570/560/535 s and 525 s
  (`fast-traps.md` §8.3). That is about 2–3 % faster, within the harness
  noise. The trap counts and lock times were unchanged. Every boot reached
  the home screen with no host crash and `guest_fatal` 43–44. The VMM
  prints `ycode-simd: HVC doorbell on (...)` once when it installs the
  filter.
- **Recommendation.** Make this the default doorbell. The gain is small but
  consistent, the cost is nothing, and a host without the SMCCC filter
  falls back to MMIO by itself. Until the default changes, it stays opt-in.

### 5.2 `resumeFlags` (frame word +312): TLB and I-cache maintenance on resume

The VMM sets the word before it resumes a trap; the shim acts on it on the
restore path and the next trap entry clears it. Bits (2026-10-24, agent
GUEST-CPU, `guest-cpu.md` §4):

| Bit(s) | Meaning |
|---|---|
| 0 | Invalidate stale translations before the `eret`. Alone: `tlbi vmalle1is` (every stage-1 entry of the VM, on every core), then `ic ialluis`, `dsb ish`, `isb` |
| 1 | Touch FP/SIMD (`stage3-contract.md` §7) |
| 2 | With bit 0: no `ic ialluis`. The VMM sets it when the host's CTR_EL0.DIC is 1 (instruction fetch is coherent with data writes, so no I-cache invalidation is needed for new code), unless `YCODE_TLB_FLUSH_ICACHE=1` |
| 3 | With bit 0: invalidate only the last-level entries of `count` 16 KiB pages from `VA` (`dsb ishst`, then one `tlbi vale1is` per page, operand `VA[55:12]`), not the whole TLB |
| 8–15 | With bit 3: `count − 1` (1–256 pages) |
| 16–63 | With bit 3: `VA >> 14` |

When the VMM asks for bit 0:

- Only after a change that **removed or altered a valid leaf descriptor**
  (unmap, protect, a fixed mapping over an existing one). A change that only
  fills invalid entries (a new mapping, a lazy page given backing) needs no
  invalidation: a translation that faults is never held in a TLB (Arm ARM,
  "Translation Lookaside Buffers": only valid translations are cached). On a
  host whose CTR_EL0.DIC is 0, every change still asks for bit 0 (the
  I-cache invalidation it carries is what a reused code page needs there).
  `YCODE_TLB_FLUSH_ADDS=1` restores "every change".
- With bit 3 when the change was one span of at most 256 pages that only
  changed leaf descriptors (the VMM's tables never free or replace a table)
  and no other change of the address space happened during the trap; the
  whole TLB otherwise. `YCODE_TLB_BY_VA=0` turns bit 3 off.
- Leaf descriptors are global (nG = 0), so a by-VA invalidation needs no
  ASID.

The VMM resumes the vCPU only by calling `KVM_RUN` again. To stop the guest
(for example on `exit`), it simply does not resume.

## 6. Darwin trap handling in the VMM (stage 2 subset)

The VMM decodes `x16` as described in `specs/simulator/darwin-arm64-abi.md`.
For BSD calls it sets or clears carry (`SPSR` bit 29) and writes `x0`. The
stage-2 calls:

| x16 | Call | Behavior |
|---|---|---|
| 1 | `exit(status)` | Stop. The VMM process exits with `status & 0xFF` |
| 4 | `write(fd, buf, len)` | fd 1 → host stdout, fd 2 → host stderr. Copies `len` bytes from guest VA `buf` (through the page tables). On success `x0 = len`. Other fds return EBADF (9) |
| 20 | `getpid()` | `x0` = the guest PID assigned by the VMM (stage 2: `100`) |
| −3 | `mach_absolute_time` | `x0` = monotonic time in 24 MHz ticks (the Apple-silicon timebase, numer/denom 125/3). No carry semantics |
| −4 | `mach_continuous_time` | The same as −3 |
| any other positive | — | carry set, `x0 = 78` (ENOSYS) |
| any other negative | — | `x0 = 0x1` (`KERN_INVALID_ADDRESS`-style failure), no carry |

For a non-SVC kind, the VMM prints the frame (ESR decoded: EC, IL, ISS, FAR,
ELR) and exits with status 70.

## 7. EL0 self-test (stage-2 exit criterion)

`el0_selftest.bin` is our own code. It is linked at VA `0x1_0000_0000`, with
`.text` first and the data section 16 KiB-aligned (`.balign 16384`) at
`0x1_0000_4000`. Initial registers: `x0` = the expected `tpidrro_el0` value,
`x1` = the expected PID. In order, it:

1. Checks `mrs tpidrro_el0 == x0`. On failure, exit(10).
2. Calls `getpid` (BSD 20). It expects carry clear and `x0` equal to the
   initial `x1`. On failure, exit(11) (carry) or exit(12) (value).
3. Calls `mach_absolute_time` (−3) twice. It expects both nonzero and the
   second ≥ the first. On failure, exit(13).
4. Calls BSD 9999. It expects carry set and `x0 == 78`. On failure, exit(14).
5. Calls `write(1, "hello from EL0 (Darwin ABI on KVM)\n", len)`. It
   expects carry clear and `x0 == len`. On failure, exit(15).
6. Reads a 64-bit magic `0x5943_4F44_4531_3645` from the start of the data
   page (VA `0x1_0000_4000`), proving that the 16 KiB page split works. On
   failure, exit(16).
7. Calls `exit(0)`.

**Stage-2 exit criterion:** on the Thor, the following command prints the
hello line and a trap log, and exits with status 0:

```
ycode-simd --shim shim.bin --el0 el0_selftest.bin
```

## 8. Swift API of `YcodeDarwinABI` (used by the hypervisor)

```swift
public enum VMLayout { /* the constants of §2 and §3 as static lets (GPA/VA values, sizes) */ }

public struct PageTableBuilder {
    public init(tableArenaGPA: UInt64, tableArenaSize: Int)
    /// Maps [va, va+size) to [pa, pa+size), 16 KiB-aligned, with the given attributes.
    public mutating func map(va: UInt64, pa: UInt64, size: UInt64, attributes: PageAttributes) throws
    /// The L1 table's GPA (the value for TTBR0_EL1).
    public var rootGPA: UInt64 { get }
    /// Every table page to copy into guest RAM: (gpa, 16 KiB of bytes).
    public var tables: [(gpa: UInt64, bytes: [UInt8])] { get }
    /// Translates a VA through the built tables (for VMM-side copies). nil if unmapped.
    public func translate(_ va: UInt64) -> (pa: UInt64, attributes: PageAttributes)?
}

public struct PageAttributes: Equatable {
    public enum Access { case el1ReadWrite, el1ReadOnly, el0ReadWrite, el0ReadOnly }
    public var access: Access
    public var device: Bool          // MAIR Attr1 when true
    public var el0Execute: Bool      // false → UXN = 1
    public var el1Execute: Bool      // false → PXN = 1
}

public struct BootInfo { /* the fields of §4 */ public func encoded() -> [UInt8] }

public struct TrapFrame {        // §5
    public var x: [UInt64]       // 31 entries
    public var spEL0, elr, spsr, esr, far, tpidrro, tpidr, kind: UInt64
    public init(decoding bytes: [UInt8]) throws
    public func encoded() -> [UInt8]
    public var carry: Bool { get set }   // SPSR bit 29
}

public protocol GuestMemoryAccess { // implemented by the hypervisor
    func read(va: UInt64, count: Int) throws -> [UInt8]
    func write(va: UInt64, bytes: [UInt8]) throws
}

public enum TrapOutcome: Equatable { case resume, exit(status: Int32), fatal(String) }

public struct DarwinTrapDispatcher {
    public var pid: Int32
    public var stdout: (String) -> Void, stderr: (String) -> Void   // or raw bytes
    public var log: (String) -> Void          // one line per handled trap
    public mutating func handle(_ frame: inout TrapFrame, memory: GuestMemoryAccess) -> TrapOutcome
}
```

## 9. Resolutions made during stage 2 (normative)

These were settled while building stage 2 and are now part of the contract.

- **The shim's private register.** The shim sets `TPIDR_EL1` to the boot
  info address and uses it in its vectors to find the frame and the
  doorbell. EL0 cannot read it. The boot info block must stay mapped and
  unchanged while the guest runs.
- **Exceptions taken at EL1** (any synchronous exception or any IRQ, FIQ, or
  SError while the shim runs), and lower-EL AArch32 entries, ring the
  doorbell and then spin. The VMM must never resume them.
- **Resumable kinds.** Lower-EL kinds 2 and 3 may be resumed. The shim
  restores everything and `eret`s if the VMM runs the vCPU again.
- **Register values used**, from `YcodeDarwinABI.VMLayout`:
  - `TCR_EL1 = 0x0000_0002_4091_B511`. T1SZ is set to 17 (not 0) so that
    the unused TTBR1 field is architecturally valid.
  - `MAIR_EL1 = 0xFF`.
  - `SCTLR_EL1 = 0x34D5_D99D`. The ARMv8.0 RES1 bits are set, plus ITD and
    SED (EL0 is AArch64-only).
- **`x16` decoding.** Only the low 32 bits are used, read as signed.
  `0x80000000` (platform) is unimplemented in stage 2 and takes the "other
  negative" path. `x16 = 0` counts as BSD and returns ENOSYS.
- **`write` edge cases:**
  - An unreadable buffer (including EL1-only pages) returns EFAULT (14)
    with carry set.
  - A length above `Int32.max` returns EINVAL (22).
  - A length of 0 returns 0.
  - The fd is the low 32 bits, read as signed.
- **Diagnostics.**
  - After an MMIO exit, the PC that KVM reports still points at the
    doorbell store. KVM advances it on the next `KVM_RUN`.
  - A guest *read* of the doorbell is unexpected, and the VMM exits with
    71.
- **VMM exit statuses:**
  - the guest's `exit` status;
  - 70 for a fatal trap;
  - 71 for an unexpected KVM exit, the watchdog, or the exit cap;
  - 64 for usage errors;
  - 66 for unreadable input;
  - 1 for a KVM error.
- **Platforms.** The KVM bindings and the hypervisor are compiled only for
  arm64 Linux (`__linux__ && __aarch64__`, `os(Linux) && arch(arm64)`). On
  other platforms `ycode-simd` reports that it is unavailable.

## Evidence

- Arm facts (granule, descriptor bits, system registers, exception
  vectors): the public Arm Architecture Reference Manual for A-profile
  (level 1).
- KVM behavior (MMIO exits for unbacked GPAs, `KVM_RUN`, `ONE_REG`): the
  Linux kernel's public KVM API documentation (level 1).
- SMCCC filter, `KVM_EXIT_HYPERCALL` fields and the PC after a forwarded
  `HVC` (§5.1): the Linux KVM API documentation and
  `Documentation/virt/kvm/devices/vm.rst` (level 1); the exit cost:
  `research/experiments/linux-host/exitbench.c` on the Thor (level 3).
  The full-path trap cost and the boot times with the HVC doorbell: the
  guest probe `p_fasttraps` and harness boots on the Thor, 2026-10-17
  (level 3).
- The 16 KiB granule is available in KVM guests on the Thor:
  `research/experiments/linux-host/kvm_probe.py` (level 3).

## Addendum (stage 6): read-only file window

From stage 6 every VM also has a read-only memslot at GPA
`0x80_0000_0000` (64 GiB) that maps the `ycode-simd` process's shared file
window (each guest-mapped file mapped once, read-only, shared by all VMs).
The file-mapping bump window ends below it. Guest writes to it fault;
copy-on-write privatizes the page into pool memory first
(`stage6-contract.md` §5.1).
