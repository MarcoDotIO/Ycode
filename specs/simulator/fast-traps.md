# Spec: exit-free hot calls (clock, wall clock, credentials)

Status: **implemented, default on** since 2026-10-17 (`YCODE_FAST_TRAPS=0`
turns it off; the same for the HVC doorbell, `YCODE_HVC_DOORBELL=0`).
Measured 2026-10-17 (§8): correct, removes about a third of all traps, and
does not change the time to the home screen. Since the same day the guest
mach time runs at 24 MHz (`darwin-process-start.md` §5, "Guest timebase");
§3.2 gives the in-place scaling that keeps the two paths equal.
This is Ycode's own design. It changes no Darwin interface: every value the
guest computes is the value the kernel would have returned through the
trap. The Darwin facts come from `darwin-process-start.md` §3–§4 (xnu open
source, level 1); the Arm facts from the Arm Architecture Reference Manual;
the KVM facts from the Linux KVM API documentation.

## 1. Goal and scope

Some traps answer from state that the guest can read itself. Each one still
costs a VM exit and one acquisition of the global kernel lock (in one boot:
about 15 M of 33 M traps were clock traps −3/−4, each waiting about
130–190 µs for the lock). With the flag on, `libsystem_kernel` (our host
library, `ycode/SimHostLibs/kernel`) answers these calls at EL0 from the
virtual counter and the commpage, with no exception at all:

| Call | Trap it replaces | Answer at EL0 |
|---|---|---|
| `mach_absolute_time` | −3 | `CNTVCT_EL0` + `TIMEBASE_OFFSET` (§3) |
| `mach_continuous_time` | −4 | the same + `CONT_TIMEBASE` (§3) |
| `mach_approximate_time`, `mach_continuous_approximate_time` | −3 / −4 | the precise value (`APPROX_TIME_SUPPORTED` = 0) |
| `__commpage_gettimeofday` (so `gettimeofday`) | BSD 116 | `NEWTIMEOFDAY_DATA` snapshot (§4) |
| `getuid`, `geteuid`, `getgid`, `getegid` | BSD 24, 25, 47, 43 | Ycode credential block (§5) |

`getpid` is already answered from a library variable after the first call
(`host-libraries.md`, not part of this flag). §6 lists the calls that are
deliberately **not** answered in the guest.

The answers are computed in the host library, not in the EL1 shim: an EL0
read costs no exception, and the shim stays a pure forwarder
(`vm-shim-protocol.md` §5).

## 2. The switch: commpage byte `0x0F8`

RW-data page offset `0x0F8` lies in Darwin's `UNUSED1` padding
(`darwin-process-start.md` §3.2, 0x0D9–0x0FF, kernel fill 0). Ycode uses it
as a private flag byte:

| Bit | Name | Meaning when set |
|---|---|---|
| 0 | `DIRECT_CLOCK` | §3 holds: the library reads the counter in place and scales it (§3.2) |
| 1 | `CRED_BLOCK` | §5 holds: the library answers the credential calls from the block |
| 2–7 | — | reserved, 0 |

The VMM sets the byte when it builds the commpage. Bit 0 is set only when
the switch is on (the default) **and** the host can give the VM one VM-wide
counter offset (§3.1). Bit 1 is set when the switch is on. Byte value 0 (the default) means
the library traps exactly as before.

Darwin code never reads this byte (it is padding in xnu's layout), so the
byte does not change what Apple's own libraries in the runtime see.

## 3. Mach time from the counter

### 3.1 Precondition: one counter for the whole simulated system

The kernel's mach time for a process is `host CNTVCT − offset`, where
`offset` is the simulated system's counter offset: the host counter at the
first launch, so mach time starts near 0. For the guest's `CNTVCT_EL0` to
be that same clock on **every** vCPU of **every** VM:

1. The VMM gives each VM the system's offset with the VM ioctl
   `KVM_ARM_SET_COUNTER_OFFSET` (capability `KVM_CAP_COUNTER_OFFSET`,
   Linux 6.4+), before any vCPU of the VM runs. The offset applies to every
   vCPU of the VM, present and future.
2. Without that ioctl, KVM resets the VM's counter offset each time it
   creates a vCPU (measured: `first-boot.md` §6 item 4). Setting
   `KVM_REG_ARM_TIMER_CNT` on vCPU 0 then does not hold for later threads,
   and a guest that read the counter in place would see time jump back. So
   **without the capability, `DIRECT_CLOCK` stays 0** and the traps answer.
3. With the ioctl, the kernel's clock for the process uses exactly the
   system's offset (not a sampled one), so the guest and the kernel read the
   same counter: no skew between the trap path and the in-place path, and
   none between processes.

EL0 may read `CNTVCT_EL0` because the shim sets `CNTKCTL_EL1.EL0VCTEN`
(`stage3-contract.md` §7). The physical counter stays EL1-only.

### 3.2 Timebase and the clock scale

The counter runs at `CNTFRQ_EL0` as the guest sees it (KVM does not
virtualize the frequency; on the Thor 1 GHz). The guest's mach time runs at
the guest timebase G (24 MHz by default, `mach_timebase_info` 125/3; the
host frequency F with `YCODE_GUEST_TIMEBASE=host`). Both paths compute mach
time from the guest counter c (`CNTVCT_EL0`, which equals host counter −
system offset, §3.1) with one fixed-point formula:

  mach time = ⌊c × M / 2^s⌋ + `TIMEBASE_OFFSET`

M (u64) and s (0…64) depend only on F and G, so every process and thread
uses the same pair:

- G = F: M = 1, s = 0 (the counter as is).
- otherwise s is the largest value ≤ 64 for which ⌊G × 2^s / F⌋ < 2^64, and
  M = ⌊G × 2^s / F⌋ (F = 1 GHz, G = 24 MHz: s = 64, M = ⌊0.024 × 2^64⌋).

The kernel's trap −3/−4 answer uses exactly this formula (not an exact
division), so the in-place value equals the trapped one at the same counter
value. The result is monotonic in c. Its rate is low by less than 1/M of
the exact ratio G/F (F = 1 GHz, G = 24 MHz: below 3 × 10⁻¹⁸).

The VMM publishes the pair in the Ycode-private block above
`_COMM_PAGE_END` (§5 holds the credentials at 0x1000):

| Offset | Size | Field |
|---|---|---|
| 0x1010 | 8 | M, the clock multiplier |
| 0x1018 | 8 | s, the clock shift (0…64) |

It writes them with the commpage, before any thread of the process runs,
and never changes them. A block with M = 0 means "no scaling" (M = 1,
s = 0), so an older VMM that leaves the block zero keeps the old meaning.

`USER_TIMEBASE` (0x090) is 0 with the 24 MHz timebase: Apple code that
reads the commpage itself (libsyscall's `mach_absolute_time.s`,
`kdebug_trace.c`) must not use the raw counter, whose unit is not mach time.
Ycode's library chooses the in-place path by `DIRECT_CLOCK`, not by
`USER_TIMEBASE`. With `YCODE_GUEST_TIMEBASE=host` `USER_TIMEBASE` is 1.

### 3.3 The library's reads

The Darwin user path of `darwin-process-start.md` §3.6 with the scale of
§3.2:

- `mach_absolute_time` = ⌊(`isb; mrs CNTVCT_EL0`) × M / 2^s⌋ +
  `TIMEBASE_OFFSET` (0x088).
  The offset is read before and after the counter; the read repeats if the
  two differ. Ycode keeps `TIMEBASE_OFFSET` = 0 (no sleep).
- `mach_continuous_time` = absolute + `CONT_TIMEBASE` (0x098), repeated
  while `CONT_TIMEBASE` changes. Ycode keeps it 0 (no sleep: continuous =
  absolute, as the trap −4 answers).
- `mach_approximate_time`: `APPROX_TIME_SUPPORTED` (0x0C8) stays 0, so the
  precise value is returned (any value no newer than the precise one is
  allowed; the precise one is).

Monotonicity: the counter is architecturally monotonic per PE and
synchronized across PEs (Arm ARM, generic timer); with one offset and one
(M, s) system wide, and a scale that is monotonic in the counter, no thread
ever sees time go back against another thread or process.

## 4. Wall clock from the commpage snapshot

`NEWTIMEOFDAY_DATA` (0x120, five u64) as `darwin-process-start.md` §3.6
defines it:

| +off | Field | Ycode value |
|---|---|---|
| 0 | `TimeStamp_tick` | mach time of the snapshot (§3 clock, guest timebase units); 0 = invalid |
| 8 | `TimeStamp_sec` | calendar seconds at the snapshot |
| 16 | `TimeStamp_frac` | the sub-second part as a 64-bit binary fraction: ⌊nsec × 2^64 / 10^9⌋ |
| 24 | `Ticks_scale` | ⌊2^63 / G⌋ × 2 (G = `Ticks_per_sec`) |
| 32 | `Ticks_per_sec` | the guest timebase frequency G (§3.2), the unit of `TimeStamp_tick` |

**Writer (the VMM, under the kernel lock, so one writer at a time per
process):**

1. When it builds the commpage with `DIRECT_CLOCK` set: the first snapshot.
2. On every trap BSD 116 (`gettimeofday`) of a process whose commpage has
   `DIRECT_CLOCK`: after answering, it stores a new snapshot taken at the
   same instant (`TimeStamp_tick` = the kernel's mach time, then the
   calendar time).

The store order is Darwin's: `TimeStamp_tick` = 0, a store barrier, the
other four fields, a store barrier, the new `TimeStamp_tick`.

**Reader (`__commpage_gettimeofday(struct timeval *tp)`):**

1. If `DIRECT_CLOCK` is 0: return non-zero (the caller makes BSD 116), as
   before.
2. Load `TimeStamp_tick` (t). 0: return non-zero.
3. Load the other four fields, then a load barrier, then `TimeStamp_tick`
   again; if it differs from t, start again at step 2.
4. Read the mach time (§3.3). Δ = now − t (0 if now < t). If Δ ≥
   `Ticks_per_sec`: return non-zero (the snapshot is older than one second;
   the caller's BSD 116 refreshes it).
5. frac' = frac + Δ × scale (mod 2^64); sec' = sec + 1 if that wrapped.
   `tv_sec` = sec', `tv_usec` = ⌊frac' × 10^6 / 2^64⌋. Return 0.

So a process that asks for the wall clock often makes at most about one
BSD 116 trap per second; between refreshes the value differs from the
host's calendar clock only by the host's clock-discipline drift over one
second (microseconds). `mach_get_times` uses the same path for its
`timespec`.

## 5. Credentials from the commpage

Ycode's kernel gives every guest process fixed credentials
(`DarwinFileSystem.guestUID` / `guestGID`): `setuid` and its family are not
implemented, and the kernel never changes a process's credentials. The VMM
publishes them in a Ycode-private block on the RW-data page **above
Darwin's `_COMM_PAGE_END` (0xFFF)**, where Darwin defines nothing:

| Offset | Size | Field |
|---|---|---|
| 0x1000 | 4 | real uid (`getuid`) |
| 0x1004 | 4 | effective uid (`geteuid`) |
| 0x1008 | 4 | real gid (`getgid`) |
| 0x100C | 4 | effective gid (`getegid`) |

When `CRED_BLOCK` is set, `getuid`/`geteuid`/`getgid`/`getegid` return the
field; otherwise they make the BSD call.

**Invalidation rules (the kernel owns them, the library caches nothing):**

- The library reads the block on every call; it keeps no copy. A change is
  therefore visible to every thread at once.
- If the kernel ever implements a process-wide credential change (`setuid`,
  `seteuid`, `setgid`, `setegid`, `setreuid`, `setregid`), it must rewrite
  the block before the changing call returns.
- If it implements per-thread credentials (`settid`, `settid_with_pid`,
  `pthread_setugid_np`), it must clear `CRED_BLOCK` for that process
  before the call returns (the block cannot hold per-thread values), so the
  calls trap from then on.
- `exec` and `posix_spawn` build a new commpage (new image, new block).
  `fork` would copy the block with the parent's memory; the child has the
  same credentials, so the copy is correct.
- Group lists (`getgroups`) are not in the block and keep trapping.

## 6. Calls deliberately left as traps

| Call | Why it is not answered in the guest |
|---|---|
| `getppid` (BSD 39) | The parent changes when the parent exits (re-parenting); a cached value would go stale |
| `task_self_trap` (−28), `host_self_trap` (−29), `thread_self_trap` (−27) | Not fixed answers: each call adds a user reference to a send right (`copyoutNewSend` in the kernel). Callers deallocate what they get; answering without the trap would let the reference count reach 0 and free a name that is still in use. `mach_task_self()` already reads `mach_task_self_` without a trap |
| `mach_reply_port` (−26) | Creates a new port on every call |
| `thread_selfid` (BSD 372) | Fixed per thread, but our `libsystem_pthread` already keeps it in `pthread_t.thread_id` after the first call; the remaining calls are about one per thread start |

## 7. Measuring and verifying

- Guest probe `SimShim/guest-tests/stageperf/p_fasttraps.c`: for each fast
  path, the in-place answer equals (ids) or brackets (time) the trapped one;
  mach time is monotonic within and across 8 threads and across a spawned
  child; the wall clock agrees with BSD 116 within 5 ms; per-call cost of
  each path. The probe makes the trap with an inline `svc #0x80` so it can
  compare both paths in one run.
- The per-trap-number counts of `YCODE_TRAP_PROFILE` show what moved.
  `YCODE_TRAP_PROFILE_ROWS=<n>` (default 25) lists more rows per table, so
  that traps that become rare still appear with their counts.

## 8. Measurements (Thor, 2026-10-17)

### 8.1 Correctness: guest probe

`p_fasttraps` ran 12 times, 3 times in each of the four modes (no switch,
`YCODE_HVC_DOORBELL=1`, `YCODE_FAST_TRAPS=1`, both). Every run printed
`fasttraps ok`. With the switch on, the flag byte was `0x03`. Without it,
the byte was `0x00` and every path trapped. The checks were these:

| Check | Result with the switch on |
|---|---|
| `mach_absolute_time` / `mach_continuous_time` between two trapped readings (1000 rounds each) | always between them |
| monotonic: 8 threads × 200 000 reads, within each thread and against the newest value of any thread | 0 backwards |
| a thread created after the others; a spawned child's clock against the parent's bracket | inside the bracket |
| a 50 ms sleep, measured in mach time | 50 ms |
| `gettimeofday` against BSD 116, also after a 1.2 s pause (stale snapshot) | worst difference 17–43 µs (limit 5 ms) |
| `getuid`/`geteuid`/`getgid`/`getegid` against BSD 24/25/47/43, in the parent and in a spawned child | equal |
| the same after `fork` | not testable: Ycode's kernel does not implement `fork` (BSD 2), so the probe reports `fork=unsupported`. §5 gives the rule for when `fork` is implemented |

### 8.2 Cost per call (probe, ns, 3 runs each, the Thor under load ≈ 17)

| Call | Trap (no switch) | With `YCODE_FAST_TRAPS=1` |
|---|---|---|
| `mach_absolute_time` | 4908–5020 | 69–85 |
| `mach_continuous_time` | 4707–4753 | 69–70 |
| `gettimeofday` | 5527–5589 | 79–80 |
| `geteuid` | 4746–4873 | 3 |

### 8.3 Full boot (harness, `YCODE_LEAN_BOOT` unset, device in RAM)

Trap counts come from `YCODE_TRAP_PROFILE` with 400 rows. Each value is for
one boot (set 2, interleaved, 19:03–20:42).

| Trap | No switch | `YCODE_FAST_TRAPS=1` | Change |
|---|---|---|---|
| −4 `mach_continuous_time` | 3 453 208 | 0 | −100 % |
| −3 `mach_absolute_time` | 1 982 814 | 2 398 | −99.9 % |
| BSD 116 `gettimeofday` | 599 096 | 17 489 | −97 % (about 1 refresh per second per process, §4) |
| BSD 25 / 24 / 43 / 47 | 322 992 / 7269 / 521 / 183 | 0 | −100 % |
| all traps | 15.4 M | 10.5 M | −32 % |
| kernel-lock wait, summed over threads | 9606 s | 7189 s | −25 % |
| kernel-lock held | 282 s | 296 s | +5 % |

The traps in §6 did not change: −26, −27, −28, −29, BSD 20 and BSD 372 had
the same counts within 5 %.

Time to the home screen (s, 5 s resolution):

| Set | No switch | `HVC_DOORBELL` | `FAST_TRAPS` | Both |
|---|---|---|---|---|
| 1 (04:05–05:10, load from other agents) | 570, 560, 535 | 550 | 565, 580 | 555, 535, 520 |
| 2 (19:03–20:42) | 525 | 515, 510 | 535 | 535 |
| mean, n | 547.5, 4 | 525, 3 | 560, 3 | 536, 4 |

Every boot reached the home screen, and no boot had a host crash.
`guest_fatal` was 38–50 in every mode (set 2: 38 with no switch, 45 with
`FAST_TRAPS`, 50 with both; set 1: 41–47). Run-to-run noise in this harness
is ±10 % (`speed` results). The differences between the modes are smaller
than that noise.

**Reading.** The switch removes about 4.9 M VM exits and a quarter of the
lock wait, but the kernel lock stays held for the same time. The boot is
bound by long serialized holds (mach_msg2, workq_kernreturn, kevent_id,
posix_spawn), not by the cheap traps. This matches the earlier finding
that removing the clock traps alone did not move the boot. The gain is per
call: a guest that reads the clock or the wall clock in a loop (animation,
timers, logging) saves about 5 µs per call. The guest-spin hazard of an
exit-free clock (a guest that polls the clock no longer gives the host an
exit) did not show: no boot slowed beyond noise.

**Recommendation.** The switch can become the default. It is correct by
§8.1, it is neutral for the boot, and each call is about 60× cheaper. Turn
it on together with the HVC doorbell (`vm-shim-protocol.md` §5.1), which
gave the best combined means. Until the default changes, it stays opt-in.

### 8.4 With the 24 MHz guest timebase (2026-10-17, integrated build)

`p_fasttraps` printed `fasttraps ok` with the scaled clock (default), with
`YCODE_GUEST_TIMEBASE=host`, with `YCODE_FAST_TRAPS=0`, and with both
switches off: the in-place 24 MHz value lies between two trapped readings
in every round, 8 threads × 200 000 reads never go back, a spawned child
stays inside the parent's bracket, a 50 ms sleep measures 50 ms, and the
wall clock is within 20–27 µs of BSD 116. Cost: `mach_absolute_time` 70 ns
in place (the scale adds no measurable cost) against 4.4–4.6 µs trapped.

Full boots (harness, `YCODE_LEAN_BOOT` unset, device in RAM, 700 s, two
boots at a time), both switches on:

| Guest timebase, N | home_s | traps (M, 700 s) | kernel lock busy |
|---|---|---|---|
| 24 MHz, N = 1 | 240, 285, 270 | 9.6–10.6 | 23–29 % |
| 24 MHz, N = 14 | 245, 295, 285 | 10.7–13.2 | 30–35 % |
| host (1 GHz), N = 1 | 320, 330 | 19.0–19.1 | 46 % |

With the host timebase homed alone makes 4.8 M traps per boot (the Swift
`Task.sleep` spin of `darwin-process-start.md` §5); with 24 MHz, 0.03 M.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Commpage time fields, reader/writer protocol, `UNUSED1` padding, `_COMM_PAGE_END` | 1 | `darwin-process-start.md` §3 (xnu `osfmk/arm/cpu_capabilities.h`, libsyscall) |
| `KVM_ARM_SET_COUNTER_OFFSET` semantics (VM-wide, applies to later vCPUs) | 1 | Linux KVM API documentation; uapi `linux/kvm.h` (`KVM_CAP_COUNTER_OFFSET` = 227) |
| Swift's fixed 24 MHz deadline conversion (why mach time is scaled) | 1 | `darwin-process-start.md` §5 "Guest timebase" (swift `DispatchGlobalExecutor.cpp`) |
| Clock scale formula, block at 0x1010, `USER_TIMEBASE` = 0 with the scaled clock | — | Ycode design (§3.2) |
| Counter reset per new vCPU without it | 3 | `first-boot.md` §6 item 4 (`clockprobe.c` on the Thor) |
| EL0 counter access through `CNTKCTL_EL1.EL0VCTEN`; counter monotonic and synchronized across PEs | 1 | Arm Architecture Reference Manual (generic timer) |
| Trap counts and lock waits of clock and credential traps | 3 | `YCODE_TRAP_PROFILE` of a harness boot on the Thor |
| §8.4: probe and boots with the scaled clock | 3 | `p_fasttraps` (4 modes) and 8 harness boots on the Thor, agent A2b runs `SX/IA2/ig/runs`, 2026-10-17 |
| §8: probe results, cost per call, trap counts, lock times and home-screen times in four modes | 3 | `p_fasttraps` (12 runs) and 14 valid harness boots on the Thor, 2026-10-17 (agent EXIT runs `SX/EXIT/runs`, `SX/EXITM/runs`; two later boots were discarded because the data drive was full) |
| Send-right references from the self-port traps | 3 | Ycode's kernel (`MachIPCTraps.swift`); xnu `osfmk/kern/ipc_tt.c` behavior (level 1) |
| Credentials fixed in Ycode's kernel | — | Ycode decision (`DarwinFileSystem.guestUID`) |

Level 5 was not used. `.claude/Xcode.app`, `research/dirty/`, and Ghidra
were not opened.
