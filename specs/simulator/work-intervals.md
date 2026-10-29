# Spec: work intervals (the kernel side of os_workgroup)

Status: **implemented, minimal** (agent AUDIO-HOST, 2026-10-27). Written for
the audio host service (`audio-host.md` §10, "Ycode implementation"): its
message 59 hands a guest IO thread a *workgroup port*, which the guest's
libdispatch turns into an `os_workgroup_t` and joins. In xnu a workgroup
port is the port of a joinable *work interval*. This spec says what Ycode's
Darwin kernel models of work intervals and what it leaves out.

Sources (level 1): xnu's open source — `bsd/kern/sys_work_interval.c`
(the call), `osfmk/kern/work_interval.c` (objects, ports, join),
`bsd/sys/work_interval.h` (operations, flags, records),
`libsyscall/wrappers/work_interval.c` (what the library sends) — and the
public `os/workgroup_object.h` (a workgroup can be made from a port that
`os_workgroup_copy_port` gave, possibly in another process). How the
runtime's libdispatch uses the call was not traced; the operations below
are the ones the xnu wrappers for "make a workgroup from a port", "join"
and "leave" send.

## 1. Objects

- A **work interval** has an ID (a system-wide counter, first ID 2; 0 is
  never an ID), its creation flags and its creator's pid.
- A **joinable** work interval (flag `WORK_INTERVAL_FLAG_JOINABLE` 0x1) is
  reached through a kernel-object port (`MachKernelObject.workInterval`,
  xnu `IKOT_WORK_INTERVAL`). Holders of send rights can pass them in
  messages like any right; the interval lives while a right does.
- A **thread** has at most one joined work interval. Ycode's scheduler does
  not use it (no thread groups, no deadline hints): joining only records it.

## 2. `__work_interval_ctl(operation, work_interval_id, arg, len)` (BSD 499)

| Operation | Value | Ycode |
|---|---|---|
| CREATE | 1 | ENOTSUP (deprecated in xnu too) |
| DESTROY | 2 | `arg` must be NULL and the ID non-zero; the thread must have joined the interval with that ID; it leaves it. Otherwise EINVAL |
| NOTIFY | 3 | `arg` non-NULL, ID non-zero, `len` ≥ 40 (`struct work_interval_notification`); the thread must have joined that interval and be in the creating process; accepted and ignored. Otherwise EINVAL |
| CREATE2 | 4 | **not modeled**: ENOSYS, the answer every operation had before (guest processes make no work intervals of their own; see §4) |
| JOIN | 5 | `arg` must be NULL (EINVAL). The ID is a port name: 0 leaves the joined interval (success also when none); otherwise it must be a send right of the caller to a live work-interval port (EINVAL otherwise), which the thread joins (replacing an earlier one) |
| GET_FLAGS | 9 | `arg` non-NULL and `len` ≥ 16, the ID a valid port name naming a work-interval send right (EINVAL otherwise); writes `struct work_interval_create_params` {u64 id = 0, u32 port = the name, u32 flags = the creation flags} (EFAULT when unwritable) |
| other | — | ENOTSUP |

Flags (`sys/work_interval.h`): JOINABLE 0x1, GROUP 0x2, UNRESTRICTED 0x4,
ENABLE_AUTO_JOIN 0x8, ENABLE_DEFERRED_FINISH 0x10, IGNORED 0x20; the type
in the top four bits (`WORK_INTERVAL_TYPE_COREAUDIO` = 1 << 28).

## 3. The host side

`MachHostTask.makeWorkIntervalPort(flags:)` makes a joinable work interval
whose creator is the host (pid 0) and returns a send right named in the
host task. The audio service makes one per IO context with
`WORK_INTERVAL_TYPE_COREAUDIO | GROUP | JOINABLE` and hands copies of it in
message 59's reply. A guest therefore can get the flags and join, but not
notify (it is not the creator), as with a Mac's audio daemon.

## 3a. The guest library

Ycode's guest `libsystem_kernel` (SimHostLibs `kernel/workinterval.c`)
implements the work-interval library calls itself (creation, joins and
notifications succeed and change nothing; `home-screen.md` §6 item 3), so
guest processes never needed the kernel for the intervals they make.
For ports handed over by someone else the library asks the kernel first:

| Library call | Ycode |
|---|---|
| `work_interval_get_flags_from_port(port, &flags)` | GET_FLAGS on a valid port; on failure (not a kernel work interval, e.g. a port from the library's own `work_interval_copy_port`) flags 0 and success, as before |
| `work_interval_join_port(port)` | JOIN on a valid port; success either way |
| `work_interval_leave()` | JOIN with the null port; success |

errno is left as it was when the kernel call fails.

## 4. Not modeled

- Creating work intervals in guests (CREATE2), and with it the CA_CLIENT
  rules, auto-join, deferred finish, thread groups and naming operations of
  later xnu versions. A guest that creates a workgroup keeps getting the
  failure it got before this change.
- Scheduling: a joined interval changes nothing about how the thread runs.
- Snapshots keep work-interval ports (ID, flags, creator; port record tags
  34–36) but not which interval a thread joined: after a restore threads
  have none. Joining only records the interval, so nothing observable is
  lost except a later DESTROY with that ID (EINVAL).

## 5. Diagnostics

`YCODE_DEBUG_WORK_INTERVALS=1`: one stderr line per call
(`ycode-work-interval: pid … (process) thread … <operation> id=… -> <result>`).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Operations, argument checks, errors, records, flags | 1 | xnu `bsd/kern/sys_work_interval.c`, `osfmk/kern/work_interval.c`, `bsd/sys/work_interval.h` |
| What a "workgroup from a port", join and leave send | 1 | xnu `libsyscall/wrappers/work_interval.c` (`work_interval_get_flags_from_port`, `work_interval_join_port`, `work_interval_leave`) |
| A workgroup port may come from another process | 1 | macOS SDK `os/workgroup_object.h` |
| Ycode behavior | — | `WorkInterval.swift`, `WorkIntervalTests`, SimHostLibs `kernel/workinterval.c` |
