# Spec: the minimal IOKit registry (stage 6)

Status: **Ycode design over level-1 interfaces**, 2026-10-12. Ycode has no
IOKit. Simulator daemons still reach IOKit through IOKitUser's client
library, which talks to the host's I/O main port with the MIG subsystem
**2800** (`device.defs`, Apple open source). On the Mac, IOKitLib uses
`host_get_io_master` unless `IOS_SIMULATOR_IOKITSIMD=1`, which CoreSimulator
does not set (level 3). Ycode answers that subsystem with a registry that is
almost empty.

## Behavior (normative for the VMM)

| Request | Answer |
|---|---|
| `host_get_io_main` / `host_get_io_master` | A send right to the VMM's main port (private routine 16, `host-libraries.md` §11.2) |
| `io_server_version` | `MIG_BAD_ID`, so IOKitLib falls back to the legacy routines |
| Registry contents | One service: `IOPMrootDomain` (the power-management root that `UserEventAgent`'s alarm plugin asserts on) |
| Matching (`io_service_get_matching_services*`, `io_service_get_matching_service*`) | `IOPMrootDomain` when the matching dictionary names it; otherwise an empty iterator |
| Properties (`io_registry_entry_get_property*`, `…create_cf_properties`) | None exist (the "not found" answer of the routine) |
| Interest and matching notifications | Accepted; never fire |
| `IOServiceOpen` and user-client methods | Succeed; every scalar and structure output is zeroed (**Ycode decision**: the callers seen treat zeros as "no data") |

## Why

Without a main port, IOKitLib dereferences NULL (mediaremoted) and
`UserEventAgent`'s alarm plugin asserts at `com.apple.alarm + 9512`
(stage 6, level 3). A real device tree is display/HID/GPU work (stage 8).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Subsystem 2800 and routine layouts | 1 | `device.defs` (xnu), IOKitUser `IOKitLib.c` |
| `IOS_SIMULATOR_IOKITSIMD` unset on the Mac | 3 | environment of simulator daemons (`ps -E`) |
| Crashes without it | 3 | Ycode stage-6 runs |
