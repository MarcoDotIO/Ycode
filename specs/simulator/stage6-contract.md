# Contract: simulator stage 6 — headless boot with the runtime's job set

Status: **active (2026-10-12)**. Stage 6 of `docs/SIMULATOR-LINUX.md`
("launchd_sim plus the core daemons; a headless boot"). Stage 5 (Mach IPC
and bootstrap) was absorbed by stages 4b and 4c. Reference:
`launchd-sim.md` (§4.1 discovery, §4.6 boot sequence, §6.3 host-side
services, §7.2), `bootstrap-wire.md`, `stage4c-contract.md` §9.4.

## 1. Exit criterion

On the Thor, `ycode-simd --device <dir> --runtime-paths` (new option: the
four `Paths` CoreSimulator uses, `launchd-sim.md` §4.1, with DEV's own
`Library/LaunchDaemons` empty or Ycode-written) and `--timeout-ms 180000`,
no debug flags:

1. `launchd_sim` imports the full job set and stays up for the whole run.
2. A `launchctl list` one-shot near the end shows at least the **core set**
   running: logd, notifyd, cfprefsd (system and user), configd-class
   (whatever the runtime uses), containermanagerd (system and user),
   deviceconfigurationd, UserEventAgent, mobileassetd or its equivalent
   if demanded, and lsd/`runningboardd` if started on demand.
   The integrator lists exactly which are up and why the others are not.
3. No **crash loop**: no job in the core set exits more than twice, and
   `launchd.log` contains no "crashed" or "throttled" line for it.
4. Everything else that crashes or throttles is listed with the abort
   message (fault report) and a one-line cause: Ycode gap (to fix later),
   missing host service (`launchd-sim.md` §6.3, expected), or display/GPU
   dependency (stage 8, expected). SpringBoard and backboardd are expected
   to fail without a display; that is acceptable here.
5. Every earlier check still passes (the 4c-iii verify suite).

## 2. Model

As 4c-iii (`stage4c-contract.md` §9.2): one integrator agent owns all of
`ycode/`; small tested fixes; evidence levels 1–3 only (Apple open source,
files read as formats, our own runs and probes); no disassembly, no
`.claude/Xcode.app`, no `research/dirty/`, no Ghidra. Questions that
levels 1–3 cannot answer are reported, not guessed.

## 3. Also in scope (if they block)

- `proc_pid_rusage` start/exit times (launchd's run-time and throttle
  logic).
- The `0x11` assertion at `launchd_sim+64312` (a level-3 probe on the Mac
  can show whether `launchd_sim` holds the receive right of its task
  bootstrap port there).
- Host-side names (`launchd-sim.md` §6.3): Ycode registers none yet; if a
  core daemon needs one to start, report which.
- Performance: if the boot is too slow to reach steady state in 180 s,
  measure where time goes (trap counts per process, vCPU counts) before
  optimizing.

## 4. Decisions and findings (checkpoint 1, 2026-10-12)

- **Release builds for device runs.** Under the debug build the global
  kernel lock is 88–95 % busy (address-space operations linear in chunk
  count; a KVM memslot per shared-cache `mmap` per process). Release cuts
  it to ~70 % with ~8× throughput. Performance work is split out (§5).
- **`/System` in device mode** is served from `RR/System`, read-only: the
  runtime opens some bundles at their unrooted `/System/…` path (level 3);
  on the Mac that path reaches the host's own copy. Orchestrator decision:
  keep it (the guest sees its own runtime's bundles).
- `/` and every directory above a served prefix stat as read-only
  directories (opening them gives EACCES).
- TBI0 is on (vm-shim-protocol.md updated); private routines 12–15 are in
  `host-libraries.md` §11.2; `proc_pid_rusage` carries start/exit times.
- **configd_sim** asserts without the host's configd service
  (`launchd-sim.md` §6.3 `com.apple.SystemConfiguration.configd`). This is
  a missing host service; it is listed, not required, for the exit
  criterion until a host-side SCDynamicStore is specified (Apple's
  open-source configd is the level-1 source when that work starts).

## 5. Performance track (separate agent, parallel)

Owner **Q** (new): `Sources/YcodeDarwinABI/AddressSpace.swift`,
`Sources/YcodeHypervisor/PhysicalBacking.swift` and `KVM.swift`, and new
files they need. Goals, measured on a full boot with the release build:
address-space operations O(log n) in the number of mappings; one host
mapping and memslot of each shared-cache file reused by every VM instead
of per-process registration; then a design proposal (not code) for taking
per-process VM operations out of the global kernel lock. The integrator
does not edit Q's files during this time (route requests through the
orchestrator).
