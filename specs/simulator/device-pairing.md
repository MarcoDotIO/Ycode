# Spec: pairing an iPhone simulator with an Apple Watch simulator

Status: **draft, round 0** (agent OBS-WATCH, 2026-10-29); round W4 under
Ycode in §8 (PAIR-HOST, 2026-10-30); round W5, the relay, in §10
(PAIR-RELAY, 2026-10-30); the dirty-room answers to §9 Q5, Q9, Q11 and
Q12 in §11 (OBS-WATCH2, 2026-10-30); round W3b, P-10 … P-13, in §12
(WATCH-W3B, 2026-10-30); round W6, the IDE (P-8, P-9), in §13 (PAIR-IDE,
2026-10-30); the dirty-room answers to §9 Q13 and Q14 in §14 (OBS-WATCH3,
2026-10-31). It describes how
Xcode 27.1's simulators pair an iOS 27.1 iPhone with a watchOS 27.0 Apple
Watch — the records CoreSimulator keeps, what each guest does, the host
endpoint and wire format that carry the traffic between the two guests,
what WatchConnectivity apps see — and what Ycode must add so that two
Ycode simulators pair the same way. The watch runtime itself is in
`watchos.md`. Facts come from files read as formats (level 2), black-box
runs on the Mac (level 3: `simctl`, guest logs, `lsof`, `lsmp`, our own
apps and our own host tool that relayed and recorded the traffic) and
bundle metadata (level 4: service names, exported names, strings). No
disassembly or decompilation was used; Apple's payload contents were not
interpreted beyond their key names. Raw material: `research/dirty/watch/`
(git-ignored); prose: `research/notes/pairing-observations.md`; our code:
`research/experiments/watch/` (`WCProbe`, `idsrelay`).

The Mac was under very heavy load during these runs (load average
190–840): **times are upper bounds**, and latencies include large backlogs.

## 1. Answers in brief

1. **Records**: a pair is `{UUID: {active, companion, gizmo}}` in the device
   set (`device_set.plist`, `DevicePairs`). A watch pairs with at most one
   phone (`maxPairs` 1); a phone with up to 100 watches, exactly one
   **active**. `simctl create` never pairs; `unpair` **erases the watch**
   (§2).
2. **No pairing work happens until both devices are booted.** Then the host
   (a) registers one Mach endpoint in each guest and (b) sends each guest's
   bridge agent "connect to remote <peer>" and "make <peer> the active
   pair"; the guests' own daemons (ids_simd, nanoregistryd) do the rest and
   run the initial paired sync (§3).
3. **Transport**: each guest's `ids_simd` owns the Mach service
   **`com.apple.IDSSimRPC.local`**. The host registers, in each guest's
   bootstrap, the host-side name **`com.apple.IDSSimRPC.remote.<peer
   UDID>`** whose port *is the peer's* `IDSSimRPC.local` port. The two
   ids_simd processes then exchange Mach messages directly: there is no
   relay process and no socket. When either device shuts down the host
   removes the name from the other (§4).
4. **Wire**: one MIG routine. Request **id 1000**: complex, one
   out-of-line region (a keyed-archive binary plist of
   `{senderDeviceID, serviceName, messageID, data}`), NDR, a 32-bit length,
   reply port send-once. Reply **id 1100**: NDR + `RetCode` 0, sent at
   once. Payloads up to 67 KB seen (§4.3).
5. **Apps**: WatchConnectivity works over this path (`sendMessage` with
   replies, message data, application context, user info). With the phone
   off, the watch still reports `isReachable` true and its sends queue. The
   phone reports `isWatchAppInstalled` true once the watch's appconduitd
   tells it about a watch app installed directly on the watch (round 0's
   false was host load); installing through the phone fails in the
   reference (§11.4). `transferUserInfo` and `transferFile` never reach the
   receiving app in the reference; complication user info and application
   context do (§11.2, §11.3).
6. **For Ycode** (two VMs instead of two processes of one kernel): pair
   records and `ycode-sim pair` commands, a guest agent that carries out
   the host's five pairing requests, and a **cross-VM Mach relay** for the
   `remote.<peer>` endpoints that carries MIG 1000/1100 with one OOL region
   and turns the peer's absence into a dead port (§7).

## 2. Records and commands (CoreSimulator side)

### 2.1 The device set

`~/Library/Developer/CoreSimulator/Devices/device_set.plist`:

| Key path | Value |
|---|---|
| `DevicePairs` → `<pair UUID>` → `active` | bool |
| `DevicePairs` → `<pair UUID>` → `companion` | the phone's UDID (string) |
| `DevicePairs` → `<pair UUID>` → `gizmo` | the watch's UDID (string) |
| `DefaultDevices` → `<runtime id>` → `<device type id>` | UDID of CoreSimulator's default device of that type |

The devices' own `device.plist` files carry nothing about pairing. Writes
reach the file within a second of the command.

### 2.2 `simctl` commands

| Command | Behavior |
|---|---|
| `simctl pair <watch> <phone>` | prints the new pair UUID; argument order does not matter (roles come from the device families); both devices may be shut down. The phone's first pair is **active**; a further pair of the same phone is **inactive**, unless the phone has no active pair |
| `simctl pair_activate <pair>` | makes it active and the phone's other pairs inactive; on the active pair: POSIX 37 "This pair is already active" |
| `simctl unpair <pair>` | removes the record; **shuts down (if booted) and erases the watch** (the phone is kept); returns in 0.2 s, the erase follows within 20 s; an unknown pair: "Invalid device pair", exit 148. Unpairing the active pair does not activate another |
| `simctl list pairs [-j]` | per pair: watch and phone (name, UDID, state) and "(active\|inactive, connected\|disconnected)"; JSON `pairs` → `<UUID>` → {`watch`, `phone`, `state`} |

Refusals (`SimError` 403 "Unable to pair devices", underlying domain
`SimDevicePairingTest`): code 4 "At least one of the requested devices is
already paired with the maximum number of supported devices" (a watch with
a second phone); code 2 "does not support pairing" (phone + phone, watch +
watch).

### 2.3 Who may pair (the rules behind the refusals)

From the runtimes' `pairingRequirements` and the device types' features:

| Side | Requirement |
|---|---|
| watchOS 27.0 runtime | `maxPairs` 1; the partner's family in [1] (iPhone); partner OS ≥ 12.0 |
| iOS 27.1 runtime | `maxPairs` 100; the partner's family in [4] (watch); partner OS ≥ 3.2 |
| Device types | the phone has `com.apple.CoreSimulator.pairing` (conditional on runtime) and `com.apple.watch.pairing.companion`; the watch runtime has `com.apple.CoreSimulator.pairing` and `com.apple.watch.pairing.qws` |

**Default pairs**: device types carry `pairByDefaultForRuntimeVersions`
(iPhone 17: 26.0–99.99, iPhone 18 Pro: 27.0–99.99, iPhone Duo: 27.1–99.99;
Series 12 and Ultra 4: 27.0–99.99; Series 11 and Ultra 3: 26.0–26.99; SE
3: none). CoreSimulator's own default devices on this Mac were paired
iPhone 17 Pro Max ↔ Series 11 (46mm), iPhone Air ↔ Series 11 (42mm),
iPhone 17 ↔ Ultra 3 (49mm), for both iOS 26.5/watchOS 26.5 and iOS
27.0/watchOS 27.0 (all active). How the default devices and pairs are
chosen when Xcode creates them is open (§9 Q4).

## 3. Lifecycle (what happens in the guests)

### 3.1 Host requests to the guest

The host talks to a guest agent, CoreSimulatorBridge (a host-supplied
daemon in `DEV/data/Library/LaunchDaemons`, `simulator-features.md` §1).
It logs five pairing requests (strings and log lines, levels 3–4):

| Request (bridge's names) | Log line | What the bridge does in the guest |
|---|---|---|
| `ids_relay_connect` | "Request received to connect to remote <peer>." | `IDSSimulatorLocalPairingTransportConnect(<peer UUID>)` → ids_simd `transportConnectWithSimulatorID:` (it looks up `com.apple.IDSSimRPC.remote.<peer>`) |
| `ids_relay_set_active` | "Request received to make <peer> the active pair." then "<peer> has not previously paired. Pairing." or "… has previously paired. Switching." | NanoRegistry's paired-device registry (`com.apple.nano.nanoregistry.paireddeviceregistry`): pair with the simulator (selector name `pairWithSimulator:withQueue:withCompletion:` in the bridge) or switch to it; the bridge's binary carries the entitlement key `com.apple.nano.nanoregistry.pairunpairobliterate` |
| `ids_relay_remove_unpaired` | "Request received to remove pairs that are no longer paired by the host." with `hostPairedArray`, `simPairedArray`, `unpairArray` (UDID lists) | presumably unpairs in NanoRegistry every simulator in `unpairArray` (inferred from the names; `unpairArray` was empty in every run) |
| `ids_relay_unpair` | "Request received to unpair from remote <peer>." | ids_simd `deletePairedDeviceWithSimulatorID:`; NanoRegistry: `isPaired` 0, then the record DELETED |
| `ids_relay_disconnect` | "Request received to disconnect from remote <peer>." | `IDSSimulatorLocalPairingTransportDisconnect(<peer>)` → ids_simd `transportDisconnectWithSimulatorID:` |

nanoregistryd itself then calls `IDSSimulatorLocalPairingAddPairedDevice`
and `…SwitchActivePairedDevice` (ids_simd `addPairedDeviceWithSimulatorID:`,
`switchToActivePairedDeviceWithSimulatorID:`) and records the pair
("State change: <peer> [CREATED] _bluetoothIdentifier …",
`localPairingDataStorePath`).

### 3.2 Sequences observed

| Situation | What happens |
|---|---|
| Phone boots, watch shut down | bridge: remove-unpaired with `hostPairedArray` = [watch]; no endpoint; nothing else |
| Watch boots with the phone up (first time after pairing) | host registers both endpoints (§4.1); both bridges: connect (watch 4.0 s, phone 4.7 s after the watch's boot started), then set-active; nanoregistryd pairs; initial paired sync (replicator, NanoRegistry, location, Siri, sockpuppet, app sync services) |
| Same, timing | second run (fresh pair, lighter load): the watch's bridge got connect 4 s into the watch's boot, set-active 1.3 s later; both nanoregistryd recorded the pair within 11 s of the boot start; the watch's first paired boot reached terminal at **54.4 s** (data migration 18 s, "Waiting on System App" 28 s). First run (load average 190): the phone's bridge was blocked **145 s** on nanoregistryd ("blocked on threadIsBlockedWaitingOn_nanoregistryd_syncGrabLegacyRegistry") and the watch's `bootstatus` stayed at "Waiting on Data Migration" until the pairing finished: 163.9 s to terminal (unpaired first boot: 30.3 s). Cause open (§9 Q1) |
| Repeat boots | watch with phone up: 18.7 s, 25.2 s, then "(active, connected)"; phone booted while the watch was up: the watch's bridge got connect 1.2 s and set-active 3.4 s after the phone's boot; queued transfers then completed |
| Either device shuts down | the host **unregisters** `com.apple.IDSSimRPC.remote.<it>` from the survivor; `list pairs` turns "disconnected" within seconds. *Corrected in §11.1:* the survivor's bridge does get "disconnect from remote <it>" (seen both times a watch shut down with the phone up) |
| Unpair, both booted | phone bridge: unpair, then disconnect; the watch shut down and erased within 20 s |
| Unpair, both shut down | the watch's `data` is recreated empty; its next boot is a first boot (24 migration plugins) |
| ids_simd restarts (crash) | its `com.apple.IDSSimRPC.local` port survives (launchd keeps the receive right), so the peer's endpoint stays valid; the new ids_simd repeats `transportConnect` for its remembered active peer; local clients do not all re-register (messages for them stay pending) |

### 3.3 What changes in each device's data

| File (under `DEV/data/Library/`) | Device | Content |
|---|---|---|
| `DeviceRegistry.state/history.plist`, `historySecureProperties.plist` | both | keyed archive of an `NRDeviceCollectionHistory` (a binary blob); written by nanoregistryd |
| `DeviceRegistry/<peer UDID>/…` | both | per-peer store: `CompanionSync/*.db`, `NanoPreferencesSync/NanoDomains/<domain>`, `PairedSync/resumeContext.dat` (phone), `CoreLocation/…`, `BulletinDistributor/…` (watch) |
| `Preferences/com.apple.pairedsyncd.plist`, `com.apple.nanoprefsyncd.plist`, `com.apple.WatchListKit.plist`, `*.companion.plist` health feature files | phone | written during the initial sync |
| `AppConduit/AvailableApps.plist` | phone | the phone's list of watch apps |
| `Preferences/ids_simd.plist` | both | `SimulatedNetworkRestrictions-<service>` booleans (§4.4) |

All are written by the guests' own daemons. A Ycode host never writes them;
it only has to make the guests run the requests of §3.1.

## 4. The transport

### 4.1 Endpoints

| Name | Where | Port |
|---|---|---|
| `com.apple.IDSSimRPC.local` | each guest; `MachServices` of `com.apple.ids_simd` (KeepAlive), in the guest's job domain (`user/501` on iOS, `system` on watchOS) | ids_simd's receive right |
| `com.apple.IDSSimRPC.remote.<peer UDID>` | each guest, host-side endpoint under `com.apple.xpc.launchd.simhost` (`host-side = 1`) | **a send right to the peer's `IDSSimRPC.local` port** |
| `com.apple.IDSSimulatorSupport` | each guest; ids_simd's NSXPC service for the device's own IDS clients | ids_simd |

Evidence that the remote name is the peer's local port: `lsmp` of both
`launchd_sim` and both ids_simd processes shows one port object as the
watch's `remote.<phone>` entry, the phone's `local` entry and the phone
ids_simd's receive right (and the converse); our host tool's look-ups gave
the same port for "remote.<phone> in the watch" and "local in the phone".

Registration (`launch-sim-control.md` 701) happens when both are booted
(before the bridges' connect requests) and is refused with `EEXIST` while
the name already has a valid send right ("Error registering service … send
right is still valid"; the host then logs "Error connecting IPC relay to
companion" and the pair stays disconnected). Removal (709) happens when
the peer shuts down. No socket, no relay process: `lsof` of both guests
shows no network or Unix socket between them.

### 4.2 Direction and lifetime

Symmetric: each ids_simd sends to its `remote.<peer>` port and serves its
own `local` port with a MIG server loop. Each holds the peer's send right
with a **dead-name request**. When the peer is gone, sends fail with
`MACH_SEND_INVALID_DEST` (0x10000003, "Failed to deliver request:
268435459") and the messages stay in ids_simd's outgoing queue until a new
connect.

### 4.3 Message format (relayed and recorded by our host tool)

Request:

| Field | Value |
|---|---|
| `msgh_id` | **1000** |
| `msgh_bits` | remote: the endpoint (copy send); local: a **send-once** reply right; no voucher; **complex** |
| `msgh_size` | 56 |
| body | descriptor count 1; one `MACH_MSG_OOL_DESCRIPTOR` (virtual copy, deallocate); NDR record (`00 00 00 00 01 00 00 00`); 32-bit byte count = the OOL size |
| OOL region | a binary property list (`bplist00`) written by NSKeyedArchiver (`$archiver` "NSKeyedArchiver", `$version` 100000, `$top` {`root`}), root an NSDictionary with exactly: `senderDeviceID` (NSUUID: the **sending simulator's UDID**), `serviceName` (NSString: the IDS service), `messageID` (NSString: a UUID), `data` (NSData: the IDS message, opaque) |
| sizes seen | OOL 1 239–67 765 bytes (median 1 985); `data` 695–67 130 bytes |

Reply:

| Field | Value |
|---|---|
| `msgh_id` | **1100** |
| `msgh_bits` | remote: the send-once right (move); not complex |
| `msgh_size` | 36: header, NDR, 32-bit `RetCode` |
| `RetCode` | 0 in every reply seen |
| timing | 0.3–5.7 ms after the request (median 0.8 ms): the receiver queues and acknowledges; delivery to the local client happens later |

Only ids 1000/1100 were seen (198 requests over two captures; both
captures relayed the watch → phone direction; the phone's side uses the
symmetric endpoint of §4.1, its message ids were not captured; traffic
types: WatchConnectivity, replicator, Do
Not Disturb). Services seen in the envelope or the logs:
`com.apple.private.alloy.watchconnectivity`, `….watchconnectivity.classd`,
`…replicator`, `…bluetoothregistryclassc`, `…location.auth2`,
`…siri.device`, `…sockpuppet`, `…sockpuppet.classd`, `…appsyncconduit.v2`,
`…donotdisturb`, `…bulletindistributor.settings`.

### 4.4 Simulated link (inside ids_simd)

- **Receiver delay**: per service, unless "restrictions" are off for it,
  the receiving ids_simd delays delivery by about **0.175 s + 10 µs per
  byte** (650 B → 0.181 s, 948 B → 0.184 s, 7 809 B → 0.251 s). The switch
  is the device preference `SimulatedNetworkRestrictions-<service>` in
  `ids_simd.plist`; the paired device can set it ("Explicitly set
  restrictions state 0 for service … from paired device"). Off (no delay)
  for `replicator`, `sockpuppet.classd`, `watchconnectivity`,
  `appsyncconduit.v2`, `location.auth2` in our runs.
- **Sender queue**: ids_simd queues outgoing messages and services the
  queue in batches ("outgoingMessages: (…)", "Resuming servicing of the
  send queue", "outgoingMessages is empty. finished for now"). Between the
  two ids_simd processes we measured median 0.92 s from "sent" to
  "received" (minimum 0, maximum 1.0 s) for WatchConnectivity messages.
- **Messages for a service nobody registered** stay pending in the
  receiver ("Recipient for service … has not registered. Messages for it
  are being left in a pending state").

These are behaviors of Apple's ids_simd, which runs unchanged in Ycode's
guests: Ycode gets them for free and must not add delays of its own.

## 5. What apps see (WatchConnectivity, our WCProbe)

| Question | Observed |
|---|---|
| `WCSession.isSupported()` | true on both |
| Phone: `isPaired` | true whenever a pair exists, even with the watch shut down |
| Phone: `isWatchAppInstalled`, `watchDirectoryURL` | false, nil — the watch app was installed directly on the watch (`simctl install <watch>`); the phone's appconduitd never learned of it |
| Phone: `isReachable` | false throughout (follows from the above) |
| Phone: `updateApplicationContext`, `transferUserInfo` | WCErrorDomain **7006** "Watch app is not installed." |
| Watch: `isCompanionAppInstalled` | true |
| Watch: `isReachable` | true within a second of launch with the phone app running; **also true with the phone shut down** (sends then fail in ids_simd and queue) |
| Watch: activation on a freshly paired watch | in the second run (app launched 3 min after a fresh pair) `activateSession` never completed in 4 min and two launches: wcd logged "activating for currently active counterpart" (system pairing ID = the phone) and nothing further. In the first run (launched 13 min after pairing) it completed at once |
| Watch → phone `sendMessage` + reply | works; minimum one-way 0.92 s, minimum round trip 2.0 s (backlogs to 130 s under the host load) |
| Watch → phone `sendMessageData` (64 KiB) + reply | works; minimum round trip 3.4 s |
| Watch → phone application context | delivered (`didReceiveApplicationContext`) |
| Watch → phone `transferUserInfo` | the watch's transfer finished without error |
| Installing the iOS app (with the embedded watch app) on the paired phone | not installed on the watch in either run (6.5 min, 2 min). First run: iOS app installed (6.5 s); the phone's appconduitd found the watch app ("new and user says install all apps so installing") and asked the watch over IDS service `com.apple.private.alloy.appsyncconduit.v2`; no watch process had registered that service, the requests timed out after 160 s, and the watch app was **not** on the watch 6.5 min later |

The embedded layout used: `<iOS app>/Watch/<watch app>.app`, watch app
`Info.plist` with `WKApplication` true and `WKCompanionAppBundleIdentifier`
equal to the iOS app's bundle id, `UIDeviceFamily` [4],
`CFBundleSupportedPlatforms` [WatchSimulator].

## 6. IDE side

- Device Hub: an iPhone paired with a watch simulator shows a capsule
  "Paired with <watch name> ›" between the device and its controls
  (`specs/ide/device-hub.md` §4.1). The pairing UI itself (creating or
  removing a pair from Device Hub) was not observed (GUI only).
- Run destinations for a watch app scheme, and whether Xcode installs the
  watch app through the phone or directly: not observed (§9 Q2, Q3).
- Ycode's IDE never pairs devices itself today (`specs/ide/devices.md`,
  `destinations.md`: list only). *Since W6 (§13) it does: Device Hub
  pairs, unpairs and switches the active watch, and runs watch apps.*

## 7. What Ycode must add

### 7.1 Requirements

Records and commands:

- **P-1** Pair records in Ycode's device set with the semantics of §2.1:
  pair UUID, companion, gizmo, active; one active pair per phone; the
  limits of §2.3 from the runtime's `pairingRequirements` and the device
  type's family; the refusal texts of §2.2 may be Ycode's own.
- **P-2** CLI: `ycode-sim pair <watch> <phone>` (either order; prints the
  pair UUID), `ycode-sim unpair <pair>`, `ycode-sim pair-activate <pair>`,
  `ycode-sim list-pairs [--json]` with "(active|inactive,
  connected|disconnected)"; `ycode-simd` gets the peer's identity
  (UDID) and the active flag.
- **P-3** Unpair shuts the watch down if booted and **erases** it (fresh
  `DEV/data`); the phone is kept.

Guest side:

- **P-4** A Ycode guest agent (Ycode cannot ship CoreSimulatorBridge) that
  performs the five requests of §3.1 in the guest, in the observed order:
  on peer up → connect, then set-active; at boot → remove-unpaired with the
  host's list; on unpair → unpair then disconnect. It calls the runtime's
  own `IDSSimulatorLocalPairing*` functions and NanoRegistry's
  paired-device registry, and needs the NanoRegistry pairing entitlement
  (`simulator-features.md` §6 for how Ycode's agents get entitlements,
  Q8 there).

Host side:

- **P-5** On "both devices of a pair booted": register in each guest the
  host-side name `com.apple.IDSSimRPC.remote.<peer UDID>` (701, in the
  guest's job domain: `system` on watchOS, `user/501` on iOS), then send
  the agent's connect and set-active requests. On a peer's shutdown:
  unregister the name (709) in the survivor and invalidate the port so the
  survivor's held send right becomes a dead name (sends fail with
  `MACH_SEND_INVALID_DEST`, §4.2).
- **P-6** (**done in W5, §10**) The **relay** (§7.2): the port registered under `remote.<peer>`
  is a Ycode host port; every message on it is a MIG 1000 request that
  Ycode delivers into the peer VM to the peer's `IDSSimRPC.local` port
  (found by look-up in the peer, 702 or the watchOS equivalent), with the
  OOL region copied byte for byte and a send-once reply right that Ycode
  answers with the peer's reply (1100, `RetCode`). Ycode does not parse
  the plist.
- **P-7** (**done in W5, §10**) No added latency, no reordering per direction, payloads up to at
  least 1 MiB (67 KB seen; WatchConnectivity file transfers may be larger,
  §9 Q5). *§11.3:* a `transferFile` is one request of the file's size
  (20 MiB carried in the reference), so the 16 MiB cap of §10.2 must go
  (P-12).

IDE:

- **P-8** (**done in W6, §13**) Devices window / Device Hub: show pairs ("Paired with … ›" on
  the phone), create a pair (pick a watch type for a phone), unpair, make
  active; new phones get a default watch only if the owner asks (Ycode
  decision; the reference's defaults are §2.3).
- **P-9** (**done in W6, §13**) Running a watch app: build the embedded watch app, install the
  iOS app on the phone and the watch app on the paired watch (the
  reference's exact path is §9 Q2/Q3), launch on the watch; destinations
  for watch schemes list watch simulators with their paired phone.
  *§11.4:* install the iOS app first (without pushing its embedded watch
  app through the phone), then the watch app **directly on the watch**;
  list as watch-scheme destinations the watch simulators and every phone
  with an active paired watch of a suitable OS.

Requirements P-10…P-13 (from the dirty-room answers) are in §11.5.

### 7.2 The relay across two VMs

On the Mac the two guests share one kernel, so the host can hand a guest a
send right to a port received in another guest. Under Ycode each guest has
its own Mach world inside its own `ycode-simd`. The relay therefore has two
halves, one per VM, joined by a host channel between the two `ycode-simd`
processes (or one supervisor process):

```
watch VM                            host                              phone VM
ids_simd ──1000──▶ remote.<phone> ─▶ ycode-simd(W) ══ channel ══▶ ycode-simd(P) ─1000─▶ IDSSimRPC.local (ids_simd)
ids_simd ◀─1100─── (send-once)    ◀─ ycode-simd(W) ◀═ channel ══  ycode-simd(P) ◀─1100── (send-once)
```

Per message: the receiving half takes the request off its host port, keeps
the guest's send-once reply right, forwards {OOL bytes, NDR, length} over
the channel; the far half builds a new request in its VM with a fresh
send-once reply port of its own, sends it to the peer's local port, and
returns the peer's reply code, which the near half sends on the original
reply right. The far half resolves the peer's local port once per boot of
the peer (it survives ids_simd restarts, §3.2). If the far VM is down the
near half's port is dead (P-5), so the guest sees exactly the reference's
failure.

### 7.3 Risks

1. Cross-VM Mach forwarding is new to Ycode; the OOL region must be
   delivered as an OOL descriptor (ids_simd reads it as such).
2. Domain differences (`system` vs `user/501`) for registration and
   look-up (`watchos.md` §2.4).
3. The first paired boot is a first boot plus the initial paired sync
   (54 s on the reference in the lighter run, 164 s under heavy load);
   under Ycode it will be several times that, and tests must allow it.
4. The guest agent's entitlement for NanoRegistry pairing.
5. App install through the phone does not work in the reference within
   minutes (§5); P-9 should install the watch app directly, then check
   what the phone reports (§9 Q3).

## 8. Round W4 under Ycode (agents PAIR-HOST and PAIR-HOST2, 2026-10-29/30)

Clean-room implementation of P-1…P-5 and Ycode's results. Evidence is level
3: Ycode's own simulator on the arm64 Linux host, with an iPhone 18 Pro on
iOS 27.0 (24A434) and an Apple Watch Series 12 (46mm) on watchOS 27.0
(24R362), the guests' own logs (a `log stream` one-shot in each guest) and
`ycode-sim list-pairs`. No Apple simulator, Xcode or reference tool was
run or opened for this round.

### 8.1 What was added

| Req. | Where | Status |
|---|---|---|
| P-1 records | `YcodeSimFeatures/DevicePairing.swift`: `DevicePairStore`, `PairingRules` (§2.3's limits: a watch 1 pair, a phone 100; partner OS ≥ 12.0 / ≥ 3.2; phone + phone, watch + watch and other families refused) | done |
| P-2 commands | `ycode-simd [--device-set D] --pair <a> <b> \| --unpair <pair> \| --pair-activate <pair> \| --list-pairs [--json]` (`PairingCommand.swift`); `ycode-sim pair \| unpair \| pair-activate \| list-pairs [--json]` (`scripts/ycode-sim.sh`, no boot slot) | done |
| P-3 unpair erase | the phone's guest unpairs and disconnects, the watch shuts down, its directory is erased; the phone is kept | done, with both devices booted and with both shut down (§8.5) |
| P-4 guest agent | `SimGuestAgents/pairing/ycode-pairing-agent.m`, staged into every device | connect, set-active (first pairing) and disconnect make the guests pair (§8.4); remove-unpaired, the NanoRegistry side of unpair, and set-active for a peer paired before are logged but make no guest call (§9 Q9) |
| P-5 endpoints | `ycode-simd/PairingHost.swift`: 701 of `com.apple.IDSSimRPC.remote.<peer>` with a host port when both devices run; 709 and the port destroyed when the peer stops or the pair goes | done for two devices on one host; the port's traffic goes to a stub relay (§8.3) |

### 8.2 Ycode decisions

- **Record format.** `<device set>/ycode-device-pairs.plist`, an XML
  property list `{Version: 1, DevicePairs: {<pair UUID>: {active,
  companion, gizmo, companionDirectory, gizmoDirectory}}}`: the reference's
  three keys (§2.1) plus each device's directory relative to the set.
  Writes are atomic and serialized by the lock file
  `.ycode-device-pairs.lock` next to it. The set is `--device-set`, else
  `$YCODE_DEVICE_SET` (`ycode-simd`) or `$YCODE_SIM_DEVICE_SET`
  (`ycode-sim`), else the directory holding the device directory; a running
  device reads the records of the directory that holds it unless
  `$YCODE_DEVICE_SET` says otherwise.
- **Devices.** A device is named by its directory, its directory's name in
  the set, or its UDID. It must have booted once (its type record says
  phone or watch). Its UDID is `DEV/ycode-udid`, which every boot writes,
  else the one derived from the directory's host path (`--udid` overrides
  it at boot, and the record keeps it).
- **Commands.** `pair` takes the devices in either order and prints the new
  pair UUID; a phone's first pair is active, a further one inactive.
  Refusal texts are Ycode's own. Exit status: 148 for an unknown pair, 37
  for a pair that is already active (as §2.2), 1 for a refused pairing or a
  failed erase, 64 for bad usage. `list-pairs` prints §2.2's layout; a pair
  is "connected" when the watch's host reports its link to the phone up and
  both endpoints registered, and the phone runs.
- **Rendezvous (two `ycode-simd` on one host).** Each running device
  listens on one AF_UNIX stream socket in the host's memory directory,
  `ycodepair-<uid>-<first 16 hex digits of the UDID>.sock`, mode 0600 (on
  Linux under `/dev/shm`). The watch's host connects to its phone's socket
  every 2 s until it is linked: `hello {udid, role, pid, version}`, answered
  `welcome` or `refused` (the phone rereads the records first, so a pair
  made a moment ago counts). Frames: a 4-byte big-endian length, then a
  binary property list whose root dictionary has a `type`; 4 MiB at most.
  The link carries `registered` (this guest has its endpoint); the pairing
  commands use the same socket with one `command {verb, args}` frame and get
  one `answer {ok, text, state?}` (verbs `state`, `reload`, `unpair <peer>`,
  `shutdown`, and `agent <op> [key=value]…` for diagnostics). The control
  socket also takes `pairing <verb> …`. There is no broker; a link across
  hosts is not designed (§8.6).
- **Order (`PairingSequencer`).** At the agent's hello: remove-unpaired
  with the host's list. Link up and the control session bound: 701
  `remote.<peer>` with a host port of its own (queue limit 64), then
  `registered` to the peer. Both endpoints registered and the agent
  connected: connect, then set-active for the active pair (a watch's only
  pair counts as active). Link down: 709 and the port destroyed, so the
  guest's held right becomes a dead name; no agent request (§3.2).
  *Changed in §12 (P-11):* then disconnect to the agent. Unpair
  while both run: the phone's agent gets unpair, then disconnect, then the
  endpoint goes and the link closes; the watch is told `shutdown`; the
  command erases its directory once its socket is gone (it waits up to
  180 s, `YCODE_UNPAIR_SHUTDOWN_WAIT_S`). A 701 refused with `EEXIST`
  (a name left by an earlier run, e.g. after a restore) is replaced
  (709, then 701 again).
- **Paired before.** `DEV/ycode-paired-peers` lists the peers whose
  set-active succeeded in this device's guest; it chooses "first pairing"
  or "paired before" for set-active, and an unpair removes the peer (for a
  stopped phone, the command edits the file).
- **Guest agent.** A launchd daemon `dev.ycode.simulator.pairing` (RunAtLoad,
  KeepAlive, Interactive; `user/<uid>` on iOS, `system` on watchOS) staged
  into every device, paired or not, so that a phone booted after an unpair
  gets remove-unpaired. Watch devices get the watchOS simulator build
  (`SimGuestAgents/out/watchos/`; a signed image is not retagged), with
  the entitlement key of §3.1 in `__TEXT,__entitlements`. It connects to
  `/private/var/run/dev.ycode.pairing`, which the VMM answers itself, with
  the settings channel's frames (4-byte length, XML property list):
  requests `{id, op, peer, previouslyPaired, hostPaired}` with ops
  `removeUnpaired`, `connect`, `setActive`, `unpair`, `disconnect`
  (`ping`, `call` for diagnostics), replies `{id, ok, detail, error}`, events
  `hello` and `log`. The host waits up to 120 s for a reply
  (`YCODE_PAIRING_AGENT_WAIT_S`).
- **Erase (P-3).** Everything in the device directory except its type
  record and `ycode-udid` goes (moved aside, then removed); the next boot is
  a first boot of the same device (no bootstrap plist, so the first-boot
  preferences are written again). `ycode-sim unpair` also drops the
  watch's saved snapshot.

### 8.3 The interface left for W5

`PairingHost.relay` is a `PairingRelay` (in `PairingHost.swift`):

- `endpoint(peer:received:context:)`: a message taken off the guest's
  `remote.<peer>` port, on the endpoint's receive thread; the relay owns its
  rights (it replies or discards).
- `link(peer:received:context:)`: a link frame whose `type` the pairing host
  does not handle (W5's own frames, e.g. `relay-request`, `relay-reply`).
- `linkChanged(peer:up:context:)`: the peer's host came or went (the far
  half's look-up is per boot of the peer, §7.2).

The `PairingRelayContext` gives the device's UDID, the host task (ports,
sends, receives), `sendToPeer(_:frame:)` over the link, and
`findInGuest(_:)` (702 in this device's guest, for the peer's
`com.apple.IDSSimRPC.local`). This round's relay, `AcknowledgingPairingRelay`
(`YCODE_PAIRING_RELAY=ack`, the default), answers each 1000 at once with
1100, NDR and `RetCode` 0 and drops the payload; `YCODE_PAIRING_RELAY=none`
answers nothing. W5 replaces it with the two halves of §7.2: the near half
sends the OOL bytes and keeps the guest's send-once right; the far half
finds `IDSSimRPC.local` in its guest, sends a new 1000 with an OOL region
and a send-once reply port of its own, and returns the `RetCode`. W6 can
drive the records through `ycode-sim pair`/`unpair`/`pair-activate` and read
`list-pairs --json`.

### 8.4 The guest calls (what Ycode's runs showed)

- **Transport.** `IDSSimulatorLocalPairingTransportConnect` and
  `…Disconnect` are called as (peer NSUUID, completion block, dispatch
  queue); the runtime's own log line under Ycode for the sibling call
  `IDSSimulatorLocalPairingAddPairedDevice` names that parameter list. In
  the first agent's runs (its notes; not repeated in this round) an
  NSString peer was dropped by ids_simd and a missing queue ended the agent
  in libdispatch; the agent therefore passes
  an NSUUID and a queue, and records a call that ended its process (its
  state file) so that the call is not tried again in that boot. ids_simd
  logs `transportConnectWithSimulatorID:` for the peer; the completion
  comes after 0.0–3.1 s. Its parameters are not known (the first word is 0).
- **Set-active.** `pairWithSimulator:withQueue:withCompletion:` on the
  NanoRegistry class that answers it (`NRPairedDeviceRegistry`), with the
  peer as an NSUUID. nanoregistryd then calls
  `IDSSimulatorLocalPairingAddPairedDevice` and
  `…SwitchActivePairedDevice` (both log "returned error (null)") and records
  the pair: "State change: <peer> [CREATED] _bluetoothIdentifier …", then
  `localPairingDataStorePath`, `isActive` 1, `compatibilityState` 3. The
  registry's completion did not come in any run (nanoregistryd then sends a
  property request to the peer, which the stub relay acknowledges but does
  not deliver); the agent answers the host after 20 s and reports a later
  completion as a `log` event (§9 Q10).
- **Not called yet.** remove-unpaired (the guest's own pair list is not
  read), NanoRegistry's unpair, and set-active for a peer paired before.

### 8.5 Runs (2026-10-30)

Set: a fresh copy of a never-paired iPhone 18 Pro (iOS 27.0) and a Series 12
46mm watch (watchOS 27.0) whose directory had just been erased by an unpair,
so each watch boot was a first boot (datamigrator and the migration plugins
ran). Both devices were started at the same moment, each in its own boot
slot, full boot (no lean list); `list-pairs` every 5 s; the unpair came
after both [CREATED] lines and the hold.

Commands:

| Command | Result |
|---|---|
| `ycode-sim unpair <pair>`, both devices shut down | "erased …/watch", exit 0; the watch directory kept only `ycode-device-type` and `ycode-udid` |
| the same pair again | "Invalid device pair: …", exit 148 |
| `ycode-sim pair phone watch` | a pair UUID, exit 0 |
| `ycode-sim pair watch phone` (already paired) | refused, "they are already paired (pair …)", exit 1 |

Paired boots (times from both `ycode-simd` starts, which were 4 ms apart;
guest log times converted with the host clock):

| | p1 | p2 |
|---|---|---|
| host 1-min load at the start | 4 (93 a minute later: another agent's boot and build) | 47 |
| `list-pairs` "(active, connected)" | first poll, 5.1 s | first poll, 5.0 s |
| ids_simd `transportConnectWithSimulatorID:` | watch 5.6 s, phone 7.9 s | before the log stream began |
| watch nanoregistryd "State change: <phone> [CREATED]" | 33.8 s | 23.4 s |
| phone nanoregistryd "State change: <watch> [CREATED]" | 48.1 s | 25.5 s |
| watch face (frame record) | — (unpaired at 66 s, before it) | **64.9 s** |
| phone home screen | — | 117.0 s |
| unpair, both booted | 7.8 s; watch 188 MB → 12 KB | 9.2 s; watch 259 MB → 12 KB |
| transport requests on the stub | 5 (1 193–3 425 bytes) | 6 (679–1 480 bytes) |

The `list-pairs` text while both ran:

```
== Device Pairs ==
A14C1055-1F81-4D7B-A25C-710D1D9A7DC1 (active, connected)
    Watch: Apple Watch Series 12 (46mm) [watch] (71EF2E8D-…) (Booted)
    Phone: iPhone 18 Pro [phone] (3381BCAD-…) (Booted)
```

After the unpair it listed no pair. The phone's host logged unpair, then
disconnect (its completion after 0.0–0.5 s), link down, and 709 of
`remote.<watch>`; the watch's
host logged its shutdown and its own 709. The **first paired boot** reached
the watch face in 64.9 s (the reference: 54.4 s to terminal under light
load, §3.2); the pair was recorded 23–48 s after the start (the reference:
within 11 s). Under Ycode both endpoints and the connect were in place by
the first poll (5 s; ids_simd logged the connect 6–8 s after the start in
p1); most of the remaining wait is nanoregistryd starting during the first
boot. A peer that stops without an unpair (link down: 709 and no agent
request) was not run in this round; the sequencer's unit test covers it.

Tests: `DevicePairingTests` (records, rules, either order, activation and
its errors, listing text and JSON, the sequencer's orders: both up, agent
last, inactive pair, peer stop, a 701 that lands after the peer left, unpair
while both run; frames, a 1 MiB payload, socket paths) and `PairingTests`
(families, device info, finding a device by path, name or UDID, writing
the records, the erase, the agent's job, staging without a binary, the
watch build for a watch).

### 8.6 What remains

- W5: the relay (P-6, P-7) in place of the stub; then whether the
  registry's completion comes (§9 Q10) and the initial paired sync runs.
  **Done in §10.**
- P-4: the guest calls for remove-unpaired, NanoRegistry's unpair and the
  switch to a peer paired before (§9 Q9).
- `pair-activate` with a phone that has several watches is covered by unit
  tests only; no run had more than one watch.
- Pairing across hosts (the two devices on different machines): the
  rendezvous is per host.
- W6: the IDE side (P-8, P-9).

## 9. Open questions

1. Why nanoregistryd blocked for 145 s in the first run's paired boot.
   A second fresh pair under lighter load paired within 11 s, so host load
   is the likely cause; not proven.
2. How Xcode runs a watch app: the run destination's name for a watch
   paired to a phone, and whether it installs the watch app through the
   phone (appconduitd) or directly on the watch.
   **Partly answered (§11.4)**: the watch scheme's destinations include
   every iPhone simulator with an active paired watch; through the phone
   the install fails in the reference; Xcode's own install call was not
   observed (no GUI run).
3. What makes the phone's `isWatchAppInstalled` true in the simulator (an
   install through the phone that completes, or Xcode telling appconduitd).
   **Answered (§11.4)**: the watch's appconduitd reporting the app it
   installed; see Q12.
4. How CoreSimulator chooses default devices and default pairs (which
   iPhone with which watch) for a new runtime.
5. WatchConnectivity file transfers (`transferFile`) and complication user
   info: do they use the same IDS path, and how large do requests get?
   **Answered (§11.3)**: same path; a file goes inline in one request of
   its size plus about 3.4 KB (20 974 907 B for 20 MiB); never delivered to
   the receiving app; complication user info is delivered.
6. Device Hub's pairing UI (create, unpair, switch active) and what it
   calls.
7. Whether the reference ever sends a request with an id other than 1000
   (none in 198 watch → phone requests), and the phone → watch ids
   (expected symmetric; not captured).
8. What a freshly paired watch's wcd waits for before a watch app's
   `activateSession` completes (pending for 4 min in one run, immediate
   13 min after pairing in the other): the initial paired sync, the
   phone's app list, or host load.
9. Which guest calls the reference's agent makes for remove-unpaired
   (reading the guest's own pair list), for NanoRegistry's side of an
   unpair, and for set-active with a peer paired before ("Switching", §3.1).
   Ycode's agent logs these requests only (§8.4).
   **Partly answered under Ycode (§10.5)**: with one watch, set-active for
   a peer paired before needs no call (repeat paired boots work). The
   NanoRegistry unpair (or remove-unpaired) call **is needed**: without
   it a phone paired again with the same watch refuses the pairing
   ("already paired with device") and WatchConnectivity on the phone
   reports the watch app not installed (r4). The calls themselves remain
   open.
   **Answered (§11.1)**: `unpairWithSimulator:withQueue:withCompletion:`
   (for unpair and for each UDID of remove-unpaired's `unpairArray`) and
   `switchToSimulator:withQueue:withCompletion:` on
   `NRPairedDeviceRegistry`; the pair list from `getPairedDevices` and
   each device's `NRDevicePropertyPairingID`.
10. When NanoRegistry's pairing completion is called and with which
    arguments: under Ycode it had not come minutes after nanoregistryd
    recorded the pair, with the relay a stub (§8.4).
    **Answered under Ycode (§10.5)**: with the relay it comes 23–31 s
    after the call, its first word 0.
11. Whether `transferUserInfo` reaches the receiving app in the reference
    (`session(_:didReceiveUserInfo:)`), and how the receiving side gets the
    transfer's contents: under Ycode the sender's transfer finishes without
    error and the receiver's wcd gets the IDS message, but the receiving app
    gets nothing (§10.4). §5 records only the sender's side.
    **Answered (§11.2)**: the reference behaves the same way — never
    delivered, in any app state.
12. Under Ycode the phone reports `isWatchAppInstalled` true and a
    `watchDirectoryURL` for a watch app installed directly on the watch
    after a clean pairing (r2, r3), and false and nil when its registry
    refused the pairing (r4); the reference reported false and nil (§5).
    Whether the reference's false comes from its own pairing or
    appconduitd state, or is the rule for a direct install.
    **Answered (§11.4)**: with a healthy pairing the reference reports
    true and a `watchDirectoryURL` within a second of the direct install;
    round 0's false was the watch's appconduitd not receiving under load.
13. *(W3b, §12.3)* After a phone's active pair is switched to a watch it
    paired with before (`pair_activate`; the agent's
    `switchToSimulator:…`), does the phone's WatchConnectivity follow (the
    app's session deactivates and activates with the new watch)? Under
    Ycode the registry switches, but the phone's wcd logs "Handling switch
    with nil pairing ID" and "No matching NRDevice for active IDS device"
    and the app's session stays with the old watch. Where does wcd's
    active IDS device come from, and which of its properties must match an
    NRDevice's?
    **Answered (§14.1)**: the reference does not follow either. Its phone
    wcd logs the same two lines and then nothing; the app keeps its session
    with the old watch (no callback for minutes) until wcd restarts (phone
    reboot). Only a switch to a **newly paired** watch is followed, through
    NanoRegistry's device-did-pair event.
14. *(W6, §13)* The IDE side the spec lacks: the title of a run
    destination that is an iPhone with its paired watch (Ycode: "<phone>
    with <watch>"); Device Hub's Pair Apple Watch… form (fields, which
    watches it offers, whether it creates one); and whether creating an
    iPhone in Device Hub or Xcode offers a paired watch in the same step
    (Ycode: Add Device ▸ iPhone with Paired Watch…).
    **Partly answered (§14.2)**: on the command line the row is the phone
    itself (its name, `platform:iOS Simulator`, its UDID); the GUI title,
    the Pair form and the create flow need the GUI and were not observed.

## 10. Round W5 under Ycode (agent PAIR-RELAY, 2026-10-30)

Clean-room implementation of P-6 and P-7 and Ycode's results. Evidence is
level 3: Ycode's own simulator on the arm64 Linux host, the same devices as
§8 (iPhone 18 Pro on iOS 27.0 24A434, Apple Watch Series 12 46mm on
watchOS 27.0 24R362), the guests' own logs (`log stream` one-shots of
nanoregistryd, ids_simd, wcd, the pairing agent and our app), the relay's
counters, and our own WatchConnectivity app. No Apple simulator, Xcode or
reference tool was run or opened for this round.

### 10.1 What was added

| Req. | Where | Status |
|---|---|---|
| P-6 relay | `YcodeHostServices/PairingTransportRelay.swift` (both halves, portable); `ycode-simd/PairingHost.swift` (`TransportPairingRelay`, the default; `YCODE_PAIRING_RELAY=ack\|none` keep the W4 stub) | **done**: both directions, every request answered in the runs (§10.4) |
| P-7 latency, order, size | the same | **done**: relay share median 1–2 ms per request, order kept per direction, requests up to 11.8 MB carried (16 MiB allowed) |
| Peer absence | the relay and §8's endpoint removal | **done**: in-flight requests answered `MACH_SEND_INVALID_DEST`, later sends fail in the guest with it (dead name); nothing hangs (§10.4) |
| `mach_msg_server`, `mach_msg_server_once` | `SimHostLibs/kernel/machmsg.c` | **added**: ids_simd serves `IDSSimRPC.local` with `mach_msg_server_once`; the stub left every request queued (§10.3) |
| Apps on the watch | the pairing agent: `installApp`, `appState`, `openApp` (diagnostics) | an app is installed and opened directly on a device; used for the watch app of our probe |
| WCProbe | `SimGuestAgents/wcprobe`, `build-wcprobe.sh` | our own iOS app with an embedded watch app, from the public WatchConnectivity documentation |

### 10.2 Ycode decisions

- **Frames.** Two link frames (binary property lists on the rendezvous
  socket of §8.2): `relay-request {seq, generation, id, body, ool, reply,
  sent}` and `relay-reply {seq, generation, code, id?, body?, ool?}`.
  `body` is the request's inline bytes after the descriptors (NDR and the
  byte count, unchanged); `ool` the out-of-line regions, byte for byte, in
  order; `id` the message id (1000; any id is carried). `code` 0 means the
  far guest answered and `id`/`body`/`ool` are its reply; otherwise it is a
  Mach error the near half turns into the reply. `sent` is the host's
  monotonic clock at the near half's send (both halves run on one host),
  for the one-way time. A message that carries port rights is refused
  (`MACH_SEND_INVALID_RIGHT`): rights cannot cross VMs and none is expected
  (§4.3). Ycode does not parse the plist.
- **Near half** (the device whose guest sent). The endpoint's thread takes
  each request off `remote.<peer>`, numbers it per peer, keeps the guest's
  send-once reply right, and sends the frame. The peer's answer is sent on
  that right: the far guest's own reply as received (1100, NDR, its
  `RetCode`), or a MIG error reply (request id + 100, NDR, `RetCode` =
  the error).
- **Far half** (the peer's device). Requests are delivered into the guest
  from one serial queue per peer, in arrival order, without waiting for
  the previous reply: each gets a fresh receive right of the host task in
  one port set, sent as `MAKE_SEND_ONCE`; one thread receives the replies
  and sends them back. The guest's `IDSSimRPC.local` is found by 702 once
  and cached; a dead cached right is looked up again once.
- **Errors (no guest waits forever).** No link, a 702 that keeps failing
  for `YCODE_PAIRING_RELAY_LOOKUP_S` (20 s), or a far send to a dead port:
  `RetCode` `MACH_SEND_INVALID_DEST` (0x10000003, what a sender sees when
  its peer is gone, §4.2). No answer in `YCODE_PAIRING_RELAY_TIMEOUT_S`
  (60 s): `MACH_SEND_TIMED_OUT`; the far reply port goes, so a late reply
  is dropped. The far guest drops the reply right: `MIG_SERVER_DIED`. Link
  down: every request of this guest still waiting is answered
  `MACH_SEND_INVALID_DEST`, the peer's requests in flight here are
  abandoned, and the endpoint itself is unregistered and destroyed (§8.2),
  so the guest's next sends fail in its own kernel with the dead name.
  Each link has a generation; a frame of an older link is ignored.
- **Size.** Link frames may be 17 MiB; a request of more than 16 MiB
  (out-of-line bytes plus body) is answered `MACH_SEND_TOO_LARGE`. The
  initial paired sync sent an 11.8 MB request (§10.4), far above the
  reference's 67 KB (§4.3).
- **No delay of Ycode's own** (P-7, §4.4): the simulated link stays
  ids_simd's.
- **`pairing relay`** (the control socket and the rendezvous socket's
  `command`) prints the counters: requests, bytes, the largest, replies,
  failures, timeouts per direction; the near half's round trip and the far
  half's one-way time (min, median, max).
- **Apps on a watch.** Ycode's `ylaunch` is an iOS simulator build, so the
  pairing agent got three diagnostics requests, `installApp path=<guest
  path>`, `appState bundleID=…` and `openApp bundleID=…`, from the
  interfaces of `app-install-launch.md` §4.1, §4.3, §4.4. `openApp` uses
  the workspace and, when that refuses (it did once on the watch), the
  FrontBoard open-application service; the agent's entitlements now carry
  `com.apple.frontboard.launchapplications` for it. Driven with
  `ycode-simd --device D --control pairing agent installApp path=…`.
- **WCProbe** (Ycode's own app). One Swift source for both sides: the
  default `WCSession`, its state every 5 s, an application context and a
  user-info transfer after activation, `sendMessage` with a reply every
  3 s while reachable, after five replies a burst of 20 messages and one
  64 KiB `sendMessageData`; one log line each (`NSLog` and
  `<tmp>/wcprobe.log`). Layout of §5: `WCProbe.app` (`dev.ycode.wcprobe`)
  with `Watch/WCProbeWatch.app` (`WKApplication`,
  `WKCompanionAppBundleIdentifier`).

### 10.3 What blocked the first relayed request

The first runs carried the first request into the far guest and got no
reply. The far ids_simd then logged "Error processing
com.apple.IDSSimRPC.local message: 46" about 2 400 times a second, and
`--trace-name ids_simd` showed why: ids_simd serves its port with
`mach_msg_server_once`, which Ycode's `libsystem_kernel` had only as an
unimplemented stub, so each call returned without taking the request and
the dispatch source fired again. W4's stub relay never sent anything into
a guest, so this did not show. `mach_msg_server_once` and `mach_msg_server`
now follow `mach-ipc.md` §5.1/§5.2: a receive with the caller's receive
options (a `MACH_RCV_TIMEOUT` receive polls), a larger buffer for
`MACH_RCV_LARGE`, the demux, `MIG_NO_REPLY` (no reply, the request kept),
a failed `RetCode` destroys the request, a reply to a send right sent with
`MACH_SEND_TIMEOUT` 0, a reply the send leaves intact destroyed.

### 10.4 Runs (2026-10-30)

Each run boots the phone and the watch together, each in its own boot
slot, full boot. When the pair is "(active, connected)", both registries
have the peer and both home screens showed, it installs WCProbe on the
phone and its watch app directly on the watch (the agent's `installApp`),
opens the phone app, 5 s later the watch app, records `pairing relay`
every 30 s, stops the phone after a hold, and keeps the watch for the
absence.

| | r2: first paired boot | r3: repeat paired boot | r4: pair again after an unpair |
|---|---|---|---|
| Devices | a fresh copy of a never-paired phone; the watch erased by an unpair (a first boot) | the same pair again | r3's phone (its registry still holds the watch), the watch erased by an unpair and paired again (same UDID) |
| Thor 1-min load at the start | 13.9 | 4.8 | 1.8 |
| "(active, connected)" | 5.1 s | 5.1 s | 5.1 s |
| watch face / phone home screen | 61.7 s / 137.2 s | 45.5 s / 80.8 s | 65.7 s / 80.8 s |
| registry completion (Q10) | watch 22.7 s, phone 31.1 s after the call | (paired before: no call) | watch 15.7 s; phone: **refused**, `com.apple.nanoregistry.pairingerror` 1 "already paired with device" |
| install: phone app / watch app | 16.2 s / 3.7 s | 8.0 s / 4.4 s | 10.2 s / 3.8 s |
| relay requests until the apps opened, phone → watch / watch → phone | 484 (25.7 MB, largest 11.8 MB) / 511 (1.3 MB, largest 90 KB) | | 79 (5.1 MB) / 102 (0.3 MB) |
| relay requests until the phone stopped | 774 / 811, **0 failed, 0 timed out** | 253 / 286, 0 failed, 0 timed out | 257 (29.0 MB, largest 11.8 MB) / 280, 0 failed, 0 timed out |
| relay round trip (near half), median (max) | 1.9 ms (3.5 s, the 11.8 MB request) / 2.2 ms (0.36 s) | 1.7 ms / 1.9 ms | 2.0 ms (3.4 s) / 1.8 ms (1.0 s) |
| relay one-way (far half), median | 0.9–1.0 ms | 0.9–1.0 ms | 1.0 ms |

What WCProbe saw (r2; r3 the same unless noted):

| Question | Ycode |
|---|---|
| `isSupported`, activation | true; activated at once on both |
| Phone `isPaired` / `isWatchAppInstalled` / `watchDirectoryURL` | true / **true** / set — with the watch app installed directly on the watch (the reference: false, nil; §9 Q12) |
| Watch `isCompanionAppInstalled` | true |
| `isReachable` | watch: true 2.4 s after its app started; phone: true 10.9 s after its app started (5 s before the watch app). r3: both flipped five times in the first 6 s, then stayed true |
| Application context | delivered both ways (`didReceiveApplicationContext`) |
| `transferUserInfo` | both senders: "finished", no error; both receivers' wcd got the IDS message; **neither app got `didReceiveUserInfo`** in 5 min (r2, r3; §9 Q11) |
| `sendMessage` + reply, watch → phone | r2: 88 replies, round trip **min 1.24 s**, median 1.60 s, max 6.3 s; the peer received after min 0.64 s, median 0.97 s (the two guests' clocks). r3: 71, min 0.96 s, median 1.94 s |
| `sendMessage` + reply, phone → watch | r2: 87 replies, round trip **min 0.60 s**, median 1.55 s, max 5.8 s; received after min 0.20 s, median 1.13 s. r3: 73, min 1.15 s, median 1.22 s |
| Burst of 20 back to back | all answered; 7.3 s (watch) and 8.9 s (phone) for the 20; r3 7.2 s and 10.3 s |
| 64 KiB `sendMessageData` + reply | watch → phone 5.0 s (r3 4.1 s), phone → watch 2.0 s (r3 2.0 s) |
| Phone stopped (absence, r2 90 s, r3 90 s) | the relay answered the one request in flight `MACH_SEND_INVALID_DEST`; the endpoint went (709); the watch's ids_simd logged "Failed to deliver request: 268435459" for every later send (as §4.2) and "Error obtaining type of remote pairing port: 15"; the watch app's `isReachable` **stayed true** (as §5); its `sendMessage` calls failed after 60 s with WCErrorDomain 7017 "Transfer timed out"; nothing hung |

Against the reference (§4.4, §5: fastest one-way 0.92 s, fastest round
trip 2.0 s, under heavy host load): Ycode's fastest round trips are 0.6–1.2 s
and its medians 1.2–1.9 s, its fastest one-way 0.2–0.8 s. The relay's own
share is about 1–2 ms a request; the rest is ids_simd's simulated link
(its batched send queue and per-service receive delay, §4.4), which runs
unchanged in the guests. Round trips cluster at whole seconds plus about
0.3 s (the send queue's period). r3 ran with an experiment that was then
removed: each device saw its peer's directory read-only at the peer's
guest path, in case the receiving side reads a user-info transfer by the
sender's path; it changed nothing (the receivers never opened a peer path).

r4 (pair again with a phone whose registry still holds the watch): the
watch side worked as before (`isCompanionAppInstalled` true, reachable,
its 23 pings answered, but slowly: round trip min 3.9 s, median 9.0 s,
max 31 s; the burst of 20 took 22 s, the 64 KiB message 17 s), while the
phone's registry refused the new pairing and its WatchConnectivity side
stayed half paired: `isPaired` true, `isWatchAppInstalled` **false**,
`watchDirectoryURL` nil, never reachable; its application context, user
info and messages failed with WCErrorDomain 7006 "Watch app is not
installed" — the reference's §5 values. The watch's application context
still reached the phone app.

### 10.5 P-4 leftovers (§9 Q9) and the registry's completion (§9 Q10)

- **Q10.** With the relay, the completion of
  `pairWithSimulator:withQueue:withCompletion:` arrives: 22.7 s (watch) and
  31.1 s (phone) after the call in r2, first word 0 (the other two words
  are pointers that are not objects; their meaning is not in the spec).
  The agent still answers the host after 20 s and reports the completion
  as a `log` event (§8.4). The initial paired sync ran: the phone sent
  25.7 MB over 484 requests in the first 137 s, the registries exchanged
  their properties ("receivedPropertyChanges … fromIDSBTUUID").
- **Set-active for a peer paired before.** No guest call is made (§8.4).
  For one watch it is not needed: r3's repeat paired boot reconnected and
  WatchConnectivity worked. Switching a phone between several watches
  still needs the reference's call (§9 Q9).
- **Remove-unpaired and NanoRegistry's unpair.** Still no guest call,
  and r4 shows that this **blocks WatchConnectivity on the phone** when a
  phone is paired again with a watch it was unpaired from (the erased
  watch keeps its UDID): the phone's registry still holds the watch,
  `pairWithSimulator:…` completes with "already paired with device", and
  the phone app sees the watch app as not installed (above). The relay
  cannot help here: the phone's registry must forget the watch at the
  unpair (or at remove-unpaired), and the call that does it is not in the
  spec (§9 Q9, now needed). Until then, a phone that is paired again with
  the same watch needs a fresh copy (r2) or an erase. The agent now
  reports a completion whose first word is an NSError as a failed
  set-active, so the host does not record such a peer as "paired before"
  (`SimGuestAgents/pairing`; built, not run again).

### 10.6 Tests

- `PairingTransportRelayTests` (YcodeHostServicesTests; Mac, x86-64,
  Thor): two `DarwinSystem`s as the two VMs, real host-task ports — a
  request's region arrives byte for byte with the same id, body, size 56
  and a send-once reply right, and the far guest's own `RetCode` comes
  back; regions of 67 765 B, 1 MiB and 8 MiB; a request over the limit;
  50 requests in flight delivered in order before any reply, answered in
  reverse with per-request codes that reach their own senders; both
  directions at once; a simple routine; link loss (waiting requests and a
  later send: `MACH_SEND_INVALID_DEST`); a dead and a missing local port; a
  late look-up within the wait; a timeout (and the late reply dropped); a
  dropped reply right (`MIG_SERVER_DIED`); a request with rights refused;
  frames of an old link ignored.
- `DevicePairingTests`: a 16 MiB relay request fits a frame, 17 MiB does not.
- Results: Mac `swift build && swift test`: all pass but the known flaky
  `BSDFastPathTests.smallTrapsMatchTheLockedPath` (passes alone); x86-64
  Linux: all pass; the Thor's debug suites: YcodeDarwinABITests (154),
  YcodeDarwinKernelTests (429), YcodeSimdTests (90), YcodeSimFeaturesTests
  (39), YcodeHostServicesTests (69) pass; the Thor's release build with
  SimHostLibs' host tests: 0 failures; `scripts/lint.sh` exits 0.
  `mach_msg_server(_once)` has no host unit test (it is guest code that
  traps); runs r2–r4 exercise it in every ids_simd.

### 10.7 What remains

- §9 Q9: NanoRegistry's unpair / remove-unpaired call (it blocks pairing a
  phone again with the same watch, r4) and the switching call for a phone
  with several watches; Q11 (user-info delivery) and Q12
  (`isWatchAppInstalled` after a direct install) — all for the dirty room.
- `transferFile` and complication user info were not run (§9 Q5).
- W6 (P-8, P-9): the IDE creates and lists pairs through `ycode-sim
  pair`/`list-pairs --json`, installs the watch app on the watch (the
  agent's `installApp`/`openApp`, or a watchOS build of a launcher), and
  shows "Paired with …".

## 11. Dirty-room answers to §9 Q5, Q9, Q11, Q12 (agent OBS-WATCH2, 2026-10-30)

Reference runs on the Mac with Xcode 27.1 (CoreSimulator 1174.9.2): one
iPhone 18 Pro on iOS 27.0 (24A434) and two Apple Watch Series 12 (46mm) on
watchOS 27.0 (24R362), created, paired and deleted for this round; at most
one phone and one watch booted. Evidence is level 3 (`simctl`, each guest's
own log at debug level for the bridge, nanoregistryd, ids_simd, wcd and
appconduitd, our own WatchConnectivity app, file listings of the guests'
data) and level 4 where named (strings and imported symbol names of the
bridge, CoreSimulator and Xcode's iOS support plug-in). No disassembly.
Prose: `research/notes/obs-watch2-2026-10-30.md`; our app:
`research/experiments/watch/WCProbe2/`.

### 11.1 Q9: unpair, remove-unpaired, switching

The bridge's pairing requests use one class, `NRPairedDeviceRegistry`
(NanoRegistry framework; daemon service
`com.apple.nano.nanoregistry.paireddeviceregistry`), with the peer
simulator's UDID as an NSUUID, a dispatch queue and a completion block.
Each method maps to one XPC method of nanoregistryd (the names appear in
the daemon's transaction log lines):

| Bridge request | Bridge call | nanoregistryd XPC method | What the daemon then does |
|---|---|---|---|
| set-active, peer **not** in the registry ("has not previously paired. Pairing.") | `pairWithSimulator:withQueue:withCompletion:` | `xpcPairWithSimulator:withCompletion:` | `IDSSimulatorLocalPairingAddPairedDevice`, `…SwitchActivePairedDevice`, creates the record and the per-peer store, exchanges properties with the peer; the completion comes when the exchange is done (24–65 s in our runs) |
| set-active, peer in the registry, not active ("has previously paired.  Switching.") | `switchToSimulator:withQueue:withCompletion:` | `xpcSwitchToSimulator:withCompletion:` | `IDSSimulatorLocalPairingSwitchActivePairedDevice`; completion after 16 ms, **also with the peer shut down** |
| set-active, peer already the active device | none | — | the request fails with `NSPOSIXErrorDomain` 37 "Operation already in progress" (the watch's bridge logged `ids_relay_set_active:181 : …`); the host ignores it |
| unpair (`ids_relay_unpair`) | `unpairWithSimulator:withQueue:withCompletion:` | `xpcUnpairWithSimulator:withCompletion:` | `IDSSimulatorLocalPairingDeletePairedDevice` (ids_simd `deletePairedDeviceWithSimulatorID:completion:`), record `isPaired` 0 at once, `[DELETED]` 2.2 s later, then the completion |
| remove-unpaired (`ids_relay_remove_unpaired`) | the same `unpairWithSimulator:…` once per UDID in `unpairArray` | `xpcUnpairWithSimulator:withCompletion:` | as unpair; at a phone's boot the record was `[DELETED]` 14 s after the request |

How the bridge decides (level 3 behaviour, level 4 names: the bridge's
imports are `NRPairedDeviceRegistry`, `NRDevicePropertyPairingID`,
`IDSSimulatorLocalPairingTransportConnect/Disconnect` and
`DMGetMigrationPluginResults`; its selector strings include
`getPairedDevices` and `getActivePairedDevice`):

- **The guest's pair list** is the registry's paired devices
  (`getPairedDevices`), each identified by its `NRDevicePropertyPairingID`
  value, which is the peer simulator's UDID.
- **remove-unpaired**: `hostPairedArray` = the UDIDs of every pair record
  the host holds for this device, active or not; `simPairedArray` = the
  registry's pairing IDs; `unpairArray` = those in `simPairedArray` but not
  in `hostPairedArray`. Seen: a phone booted alone after its watch was
  unpaired while both were shut down — host [the other, inactive watch],
  sim [the unpaired watch], unpair [the unpaired watch], then the unpair
  call; a watch at boot — host [phone], sim [phone] or [] (erased), unpair [].
- **set-active**: the peer's UDID among the pairing IDs decides "Switching"
  or "Pairing"; the active device (`getActivePairedDevice`) decides the
  no-op.
- **On a watch the bridge waits for data migration** before it acts on
  set-active (it polls the data migrator's plug-in results about once a
  second; 12 s on a first boot), so a first paired boot pairs only after
  migration.
- **unpair reaches only the phone**: with both booted, `simctl unpair`
  returned in 0.26 s; the phone's bridge got unpair, then (after the
  completion) disconnect; the watch was shut down and erased, and its
  bridge logged no request before it stopped.

Pairing the **same, erased watch again** (same UDID) after either kind of
unpair: the phone's registry no longer holds it, so the phone's bridge logs
"has not previously paired. Pairing.", both completions arrive without
error (65 s after the boot), and WatchConnectivity on the phone reports the
watch app installed after a direct install. This is the r4 case of §10.4:
it works in the reference because the unpair call removed the record.

Other sequences seen:

- **A peer shuts down**: the survivor's bridge gets "disconnect from remote
  <peer>" (both times a watch shut down with the phone up). §3.2's "no
  bridge request on the survivor" was wrong.
- **`simctl pair_activate` while the phone runs and the new watch is shut
  down**: the host sends set-active to the phone's bridge at once and
  `pair_activate` waits for its answer. For a previously paired watch:
  0.18 s. For a never-paired watch: the phone's registry starts pairing,
  cannot reach the peer, retries property requests, and after **4 min
  27 s** the completion carries `com.apple.nanoregistry.pairingerror` 13
  ("IDS connect timeout"); the half-made record is `[DELETED]`, the bridge
  logs the error, `pair_activate` returns 0 and only then is the pair
  recorded active (`device_set.plist` had both pairs inactive meanwhile).
  When the watch was then booted the host sent connect and set-active to
  both bridges and the pairing succeeded.
- **Side effect**: that watch's record was deleted from the phone's
  registry again when the watch shut down 15 s after a successful pairing
  (the property requests left over from the failed first attempt failed
  for good); its next boot would pair from scratch.

### 11.2 Q11: `transferUserInfo`

- **Never delivered in the reference either**: watch → phone with the phone
  app in the foreground (3 transfers, watched 2 min), phone → watch with
  the watch app in the foreground (2), watch → phone with the phone app not
  running and launched 3.5 min later (`hasContentPending` true at
  activation, nothing delivered). No launch, no other daemon, no file in
  the receiving app's container makes a difference.
- **Sender**: `WCSession` writes the user info to
  `<app data>/Library/Application Support/com.apple.watchconnectivity/<peer UDID>/UserInfoTransfers/<transfer UUID>/userinfo-transfer-wire-data`
  (83 bytes for three keys) and hands it to wcd; wcd sends it as an **IDS
  resource** (`sendResourceAtURL`: the file is copied to `DEV/data/tmp/`
  and sent inline; one MIG 1000 request, IDS data 3 381 bytes, message id
  = the transfer UUID). The sender's `didFinish` comes 35–45 ms after the
  call, without error, as soon as ids_simd has the request.
- **Receiver**: ids_simd writes the resource into the receiving device's
  `DEV/data/tmp/<UUID>/userinfo-transfer-wire-data` (sometimes with a short
  random suffix), applies its delay (§4.4) and hands the message to wcd
  ("was handled"). Inside wcd the IDS framework presents it as an incoming
  *message*; wcd implements neither form of that delegate method
  ("doesRespondToSelector? NO") and drops it. The receiving app's
  `Documents/Inbox/com.apple.watchconnectivity/<peer UDID>/UserInfo/` stays
  empty (its `contents.index` is what `WCSession` reads at activation).
- **Delivered**, by contrast: application context (a protobuf message;
  delivered to a running app, and at the next activation to an app that
  was not running) and **complication user info** (below).
- Ycode's W5 result (senders finish, receivers' wcd get the message, apps
  get nothing) is therefore the reference behaviour.

### 11.3 Q5: `transferFile` and complication user info

| | Reference |
|---|---|
| Path | the same IDS service (`com.apple.private.alloy.watchconnectivity`) as an IDS resource: **the file's bytes inline in one MIG 1000 request**; ids_simd data 7 087 B (4 KiB file), 1 051 958 B (1 MiB), **20 974 907 B (20 MiB)**, i.e. the file plus about 3.4 KB |
| Sender | `didFinish fileTransfer` without error 36 ms (1 KiB), 0.52 s (1 MiB), 0.1 s (20 MiB) after the call |
| Receiving ids_simd | writes the file at once to `DEV/data/tmp/<UUID>/<sender's file name>`, delays delivery by 0.175 s + 10 µs per byte (**10.45 s** for 1 MiB, **205.6 s** for 20 MiB) and holds later messages to the same device behind it |
| Receiving app | never gets `session(_:didReceive:)` (as user info, §11.2); no `Documents/Inbox/…` entry |
| Complication user info (`transferCurrentComplicationUserInfo`, phone → watch) | **delivered**: wcd sends a protobuf message of type 9 (84-byte payload) plus a resource with a fixed id; the receiving wcd persists it as `<watch app data>/Documents/Inbox/com.apple.watchconnectivity/<phone UDID>/UserInfo/complication-userinfo-id` (+ `contents.index`) and the running watch app got `didReceiveUserInfo` (12 s after the send, queued behind the 1 MiB file). `isComplicationEnabled` false; `remainingComplicationUserInfoTransfers` stayed 50 |

In this run ids_simd read `SimulatedNetworkRestrictions-AllServices` = 1
and no per-service key for `watchconnectivity`, so WatchConnectivity
traffic **was** delayed (round 0 saw it off; §4.4).

### 11.4 Q12: `isWatchAppInstalled`, and running a watch app

- **Direct install on the watch** (`simctl install <watch>`), the iOS app
  already on the phone, pairing healthy: the watch's appconduitd sends the
  phone an install notification over `com.apple.private.alloy.appsyncconduit.v2`;
  0.7 s later the phone's appconduitd marks the watch app installed and the
  running phone app gets `sessionWatchStateDidChange` with
  **`isWatchAppInstalled` true** and `watchDirectoryURL` =
  `<phone app data>/Library/Application Support/com.apple.watchconnectivity/<watch UDID>/WatchContent/<install ID>`
  (32 upper-case hex digits, an id the phone's appconduitd made for the
  app). wcd takes the state from appconduitd. Round 0's false was host
  load (the watch's appconduitd was not yet receiving).
- **Install through the phone fails**: installing the iOS app makes the
  phone's appconduitd push the embedded watch app ("user says install all
  apps"). The transfer uses a **Unix-domain socket** that the watch's
  appconduitd creates at `/tmp/appconduit_<stream UUID>.sock` and the
  phone's appconduitd connects to (both guests share the Mac's `/tmp`).
  The watch then asks for free space, gets **0 bytes** (its cache-delete
  client cannot stat `/private/var/mobile`), waits about 10 min for a purge
  that frees nothing, and answers with error 12; the phone logs "Failed to
  install app". The watch app never appears on the watch.
- **Xcode**: `xcodebuild -showdestinations` for an iOS app that embeds a
  single-target watch app lists, for the **watch scheme**, every watchOS
  simulator and **every iPhone simulator with an active paired watch** of
  a suitable OS (phones paired with a 26.5 watch are listed as
  incompatible). `xcodebuild build` cannot use such a phone destination
  ("Unable to find a device matching …"): it is a run destination of the
  IDE. Level 4 (Xcode's iOS support plug-in): an install option
  `SkipWatchAppInstall` (also a key in CoreSimulator and set by the bridge
  on its install request), a worker step `_willInstallWatchAppForCompanion:maxTries:`,
  and the errors "The install is directed to a paired Apple Watch, but
  there isn't one." / "Select an iPhone Run Destination with a paired Apple
  Watch.". Read together: running a watch app targets the phone's active
  paired watch and installs the watch app there, and the iOS app's install
  can skip its embedded watch app. Which install call Xcode makes for the
  watch was not observed (no GUI run).

### 11.5 What Ycode must do

- **P-10** (**done in W3b, §12**; Q9; Ycode's pairing agent, `SimGuestAgents/pairing`) Carry out
  the remaining requests with the calls of §11.1:
  - set-active: read the registry's paired devices and their
    `NRDevicePropertyPairingID`; peer present and already active → no
    call, answer success (the reference's POSIX 37 is ignored by its host);
    present, not active → `switchToSimulator:withQueue:withCompletion:`;
    absent → `pairWithSimulator:…` (as today);
  - unpair → `unpairWithSimulator:withQueue:withCompletion:`, answer the
    host when the completion comes (about 2 s), then the host sends
    disconnect;
  - remove-unpaired at every boot → compute `unpairArray` as above from
    the host's list and the registry, `unpairWithSimulator:…` for each.
  Done when: a phone paired again with an erased watch of the same UDID
  pairs without "already paired with device" and reports the watch app
  installed (§10.4 r4 repeated), and a phone with two watches switches
  between them (`ycode-sim pair-activate`, then boot the other watch).
- **P-11** (**done in W3b, §12**; host sequencer, correction of §8) On a peer's shutdown send the
  survivor's agent **disconnect** (besides 709). A set-active for a peer
  that is not running may be sent at once, as the reference does, but
  Ycode's `pair-activate` must not wait minutes for it (Ycode decision:
  record the activation at once, let the agent's request finish or fail
  in the background).
- **P-12** (**done in W3b, §12**; relay, §10.2) Remove the 16 MiB request cap: a `transferFile`
  is one request of the file's size (20 MiB carried in the reference; no
  WatchConnectivity size limit is documented). Carry large out-of-line
  regions across the link in pieces with a memory bound, and keep the
  per-direction order (later requests wait behind a large one, as in the
  reference's ids_simd).
- **P-13** (**kept in W3b, §12**; WatchConnectivity transfers) Nothing to add for parity: user
  info and files are not delivered to apps in the reference; complication
  user info and application context are, through the relay as it is.
  Ycode must not deliver user info or files by a path of its own unless
  the owner asks for it (a Ycode decision with a visible switch).
- **P-9 (refined)** Install the watch app **directly on the watch** (the
  agent's `installApp`); the guests then tell the phone themselves.
  Pushing the embedded watch app through the phone needs a socket in a
  `/tmp` both guests can reach and fails in the reference anyway; Ycode
  need not support it. Run destinations for a watch scheme: each watch
  simulator, and each phone with an active paired watch.

### 11.6 Devices and runs

Created with `simctl create` and deleted at the end with their pairs (the
device set's pair records were identical before and after):
`ycode-test-phone2-a`, `ycode-test-watch2-a`, `ycode-test-watch2-b`. Runs,
in order: fresh pair and both booted (install through the phone, direct
install, user info, files, complication info), watch A down and a second
pair activated (the 4.5 min set-active), switch back to A, unpair with
both booted, pair A again, unpair with both down and a phone boot alone
(remove-unpaired).

## 12. Round W3b under Ycode (agent WATCH-W3B, 2026-10-30)

Clean-room implementation of P-10 … P-13 (§11.5) and Ycode's results.
Evidence is level 3: Ycode's own simulator on the arm64 Linux host (an
iPhone 18 Pro on iOS 27.0 24A434, two Apple Watch Series 12 46 mm on
watchOS 27.0 24R362), the guests' own logs, the pairing agent's replies,
the relay's counters and our WCProbe. No Apple simulator, Xcode or
reference tool was run or opened for this round.

### 12.1 What was added

| Req. | Where | Status |
|---|---|---|
| P-10 set-active | `SimGuestAgents/pairing/ycode-pairing-agent.m` (protocol 2): reads the registry (`getPairedDevices`, each device's `NRDevicePropertyPairingID`, `getActivePairedDevice`); peer active → no call; present → `switchToSimulator:withQueue:withCompletion:`; absent → `pairWithSimulator:…` | **done** for the registry: pairing again (b1) and switching both ways (c1, e1); the phone's WatchConnectivity does **not** follow a switch to a watch it paired with before (§12.3, Q13) |
| P-10 unpair | the agent: `unpairWithSimulator:withQueue:withCompletion:`, answered at its completion (30 s at most); the host then sends disconnect (§8.2's order) | **done**: completion 2.1 s after the call (b1) |
| P-10 remove-unpaired | the agent: the registry's pairing IDs minus the host's list, `unpairWithSimulator:…` for each | **done**: a phone booted after its second watch's pair was removed unpaired it (c1 D) |
| P-11 disconnect | `PairingSequencer.linkDown`: 709 and the port destroyed, then **disconnect** to the survivor's agent when it had connected | **done**: the watch's agent got disconnect when the phone stopped (a1) |
| P-11 activation | `pair-activate` records the activation and returns at once; the phone gets a switch-only set-active at once (`switchTo`, `peerRunning` false; `YCODE_PAIRING_SWITCH_ABSENT=defer`: the normal set-active when the watch runs); the outcome of the last set-active per peer is in `pairing state` | **done**: 0.03 s and 2.6 s (c1), 0.3 s and 0.02 s (e1) |
| P-12 size | `PairingTransportRelay`: no 16 MiB cap; out-of-line bytes above one 4 MiB piece cross as `relay-chunk` frames | **done**: the 20 MiB `transferFile` (one request of 20 975 305 bytes) crossed (a1) |
| P-13 | nothing delivers user info or files to apps by a path of Ycode's own | **kept** (a1: the watch app got no file) |
| Complication user info | the relay as it is | **delivered** (a1, §12.3) |

### 12.2 Ycode decisions

- **Reading the registry.** The agent asks the registry object of §8.4
  for `getPairedDevices` and `getActivePairedDevice` (§11.1's selector
  names) on a queue of its own and waits 30 s at most, so a registry that
  is not ready (a first boot) cannot hold the agent. A device's pairing ID
  is its value for the key the runtime exports as
  `NRDevicePropertyPairingID` (`dlsym`); the agent reads it with
  `-valueForProperty:` when the device answers that selector (Ycode's
  choice of accessor; §11.1 names the key, not the accessor), else with
  key-value coding. An NSUUID or a UUID string is accepted. When the
  registry cannot be read, set-active falls back to §8.2's record
  (`DEV/ycode-paired-peers`: paired before → no call; else pair), and
  remove-unpaired removes nothing.
- **Set-active.** As §11.5: the active device → no call and success (the
  reference's POSIX 37 is ignored by its host, so Ycode does not produce
  it); present → switch (the request answered at the completion or after
  20 s, a later completion reported as a `log` event, as for pair, §8.4);
  absent → pair. The reply carries `switched` when a switch was made; the
  host then records the peer as paired before.
- **Activation of an absent watch (P-11).** The reference sends set-active
  to the phone at once and its `pair_activate` waits for the answer (0.18 s
  for a switch, 4 min 27 s and a failed pairing for a never-paired watch,
  §11.1). Ycode records the activation at once and returns, and the
  phone's host sends `setActive {peer, peerRunning: false}` at once: the
  agent switches when the registry has the peer and **makes no call
  otherwise** (a pairing started with the peer absent fails after minutes
  and leaves a record that is deleted later, §11.1); the pairing then comes
  with the normal set-active when the watch runs. With
  `YCODE_PAIRING_SWITCH_ABSENT=defer` nothing is sent until the watch runs
  (its set-active then switches while it is connected); run e1 tried that
  default and it changed nothing for WatchConnectivity (§12.3), so Ycode
  keeps the reference's timing. A pair's first reading at a boot sends
  nothing (the reference sends set-active only with both up, §3.2). The
  outcome is in `ycode-simd --device <phone> --control pairing state`
  ("(set-active done at … s: …)"); `pair-activate` prints that the switch
  runs in the background.
- **Disconnect on a peer's shutdown.** Link down: 709 and the port
  destroyed first (the guest's held right becomes a dead name, §4.2), then
  disconnect to the agent; nothing when the agent had not connected. An
  unpair keeps its order (unpair, disconnect, then the endpoint), and does
  not send a second disconnect when the link then closes.
- **Pieces (P-12).** A request or reply whose out-of-line bytes are more
  than one piece (4 MiB, `YCODE_PAIRING_RELAY_CHUNK_KB`) is sent as
  `relay-chunk {seq, generation, part: request|reply, data}` frames, then
  its own frame with `oolSizes` (the regions' sizes) in place of `ool`; the
  far half joins the pieces and splits them by those sizes. Smaller
  messages keep the one frame of §10.2. The link is ordered and one thread
  sends a guest's requests, so a later request waits behind a large one and
  the far half assembles at most one message per direction; the peer's
  requests queued for delivery into a guest are bounded (64 MiB: the link's
  reader waits until the guest has taken enough; one message larger than
  the bound goes alone). A sanity bound remains: a request of more than
  1 GiB (`YCODE_PAIRING_RELAY_MAX_MB`) is answered `MACH_SEND_TOO_LARGE`.
  The frame limit of the rendezvous socket stays 17 MiB. The far half's
  one-way time is now measured from the message's own frame (its pieces
  before it are not counted).
- **P-13.** No change: user info and files reach the receiving wcd and
  ids_simd and go no further, as in the reference (§11.2, §11.3).

### 12.3 Runs (2026-10-30)

The Thor was heavily loaded by other agents (1-min load 140–170 during a1
and b1); boots waited for shared boot slots. Devices: `phone`, a copy of
the never-paired iPhone 18 Pro of earlier rounds; `watch1` and `watch2`,
new Series 12 46 mm devices.

| Run | What | Result |
|---|---|---|
| a1 | first paired boot: the fresh phone and a new watch started together and paired 10.8 s later (both running) | "(active, connected)" 5 s after the pair; both agents read empty registries and paired: completions phone 42.1 s, watch 21.0 s after the call; watch face 116 s, phone home 316 s after the start (load 140–170) |
| a1 | WCProbe after both home screens | phone `isPaired`, `isWatchAppInstalled` true, both reachable, pings and the burst of 20 answered both ways (the burst's round trips 1.6–7.1 s under the load), application context both ways |
| a1 | complication user info, phone → watch | **delivered**: the watch app's `didReceiveUserInfo` (marked complication) 0.57 s after `transferCurrentComplicationUserInfo` |
| a1 | 20 MiB `transferFile`, phone → watch | one request of **20 975 305 bytes** (its out-of-line region and body; the file is 20 971 520) crossed in six pieces; relay round trip 9.7 s (load 140–170); the sender's `didFinish` 10.2 s after the call, no error; the watch's ids_simd took 20 974 658 bytes of IDS data and delayed it **205.0 s** (the reference: 205.6 s, §11.3); the watch app got no file (P-13) |
| a1 | relay until the phone stopped | phone → watch 750 requests (53.2 MB, largest 20 975 305; three in 11 pieces), watch → phone 775 (1.8 MB); **0 failed, 0 timed out** |
| a1 | the phone stops (P-11) | the watch's host: link down, the one request in flight answered `MACH_SEND_INVALID_DEST`, 709, then **disconnect** to its agent (completion at once) |
| b1 | repeat paired boot | both agents: "already the active device: no call" |
| b1 | `ycode-sim unpair` with both running (P-10) | 9.9 s; the phone's agent: `unpairWithSimulator:…` completion **2.1 s** after the call (the reference: about 2 s), then disconnect; the phone's registry then empty; the watch shut down and erased |
| b1 | the same watch (same UDID) paired again and booted (it waited about 820 s for a boot slot) | the phone's registry did not have it: `pairWithSimulator:…` completion after 41.9 s **without error** (§10.4 r4: "already paired with device"); the watch's after 11.2 s |
| b1 | WCProbe after pairing again | phone: activated, `isPaired` and **`isWatchAppInstalled` true**, reachable; messages answered both ways (the phone's pings 3.7 s round trip, the watch's sequence to 50 received); user info finished without error |
| c1 | a second watch: booted alone once, paired with the running phone (inactive), made active while down (the switch-only set-active at once, the default) | `pair-activate` returned in **0.03 s**; the phone's agent: "not in the registry: no call" |
| c1 | the second watch boots | both paired: completions phone 18.2 s, watch 11.7 s; the phone's registry [watch2, watch1], active watch2 |
| c1 | watch2 stops; watch1 made active while down | `pair-activate` returned in 2.6 s; the phone's agent: **`switchToSimulator:…` completion 0.8 s** (the reference: 16 ms), registry active watch1 |
| c1 | watch1 boots | set-active: "already the active device: no call"; but the phone's WatchConnectivity **never activated** (`activationState` 0, `isPaired` false for 10 min) and the watch app's messages failed (WCErrorDomain 7012): at the switch the phone's wcd logged that it handled the switch "with nil pairing ID" and found "No matching NRDevice for active IDS device" (watch1 was not running), and it did not look again when watch1 connected |
| c1 | D: watch2's pair removed with both shut down; the phone booted alone | remove-unpaired: host [watch1], guest [watch2, watch1], **unpair [watch2]**, completion 17.9 s after the call (the reference: `[DELETED]` 14 s after); the registry then [watch1] |
| e1 | `SWITCH_ABSENT=defer` (the build's default then): watch2, erased by c1's D, paired again (inactive), made active while down, then booted | `pair-activate` 0.3 s, no guest call; at watch2's boot the phone paired with it; WCProbe with watch2: `isWatchAppInstalled` true, pings answered both ways at once (round trip 0.83 s) |
| e1 | watch2 stops; watch1 made active while down (no guest call), then booted | the phone's agent: **`switchToSimulator:…` completion 0.5 s** with watch1 connected; registry active watch1; but the phone's wcd logged the same "Handling switch with nil pairing ID", "No matching NRDevice for active IDS device", and the phone app's session stayed with watch2 (its `watchDirectory` under watch2's UDID, no deactivation callback, sends failing with WCErrorDomain 7014); watch1's app activated but its messages were never answered. Neither the transport's add nor its switch called again by hand (`pairing agent call`) changed that |

### 12.4 Tests

- `PairingTransportRelayTests`: a 20 MiB request crosses in five 4 MiB
  pieces byte for byte, with the request frame's `oolSizes` and every frame
  within the socket's limit; requests of 9 MiB, 100 B, 2 MiB, 7 B and 5 MiB
  with 1 MiB pieces and a 3 MiB queue bound arrive in order; the earlier
  cases unchanged (an over-the-limit request still `MACH_SEND_TOO_LARGE`
  with a small bound).
- `PairingSequencerTests`: disconnect after 709 when the peer stops;
  `pair-activate` of a pair whose watch is down sends `switchTo` once, the
  normal order follows when the watch runs, an activation while the agent
  is down is sent when it comes, a new pair active at once sends nothing;
  the request frames (`peerRunning`).
- Results (with `watchos.md` §12.4's tests): Mac `swift build && swift
  test` on the branch merged with the main line, 1 494 tests: all pass but
  `LevelsViewTests.defaultsColumnAndProvidingLevel` (an IDE test that ran
  out of time in the parallel run and passes alone); x86-64 Linux, 1 468
  tests, 0 failures; the Thor's debug suites (`YCODE_LOCK_ORDER_CHECK=1
  YCODE_IPC_LOCKS_TESTS=1`): YcodeDarwinABITests (154),
  YcodeDarwinKernelTests (430), YcodeSimdTests (95),
  YcodeSimFeaturesTests (40), YcodeHostServicesTests (72) pass; the Thor's
  release build with SimHostLibs' host tests: 0 failures;
  `scripts/lint.sh` exits 0.

### 12.5 What remains

- W6 (P-8, P-9): the IDE's pair UI and running a watch app.
- **§9 Q13** (new, dirty room): WatchConnectivity on the phone after a
  switch. Under Ycode the registry switches (c1, e1) but the phone's wcd
  does not follow it (§12.3); the answer tells whether the agent must make
  a further call or the transport must carry something it does not.
- §11.1's wait for data migration on a watch before set-active is not
  modelled; Ycode's runs paired without it.
- §9 Q1 (the 145 s stall) and Q4 (default pairs) stay open.

## 13. Round W6 under Ycode: the IDE (agent PAIR-IDE, 2026-10-30)

Clean-room implementation of P-8 and P-9 (with §11.4's refinement) in
Ycode's IDE, from §2, §6, §8.2, §10.2, §11.4, `watchos.md` §8 and §12,
and `specs/ide/device-hub.md`, `destinations.md`, `run.md`. Evidence is
level 3: Ycode's IDE on the Mac driving Ycode's own simulator on the arm64
Linux host (iPhone 18 Pro on iOS 27.0 24A434, Apple Watch Series 12 46 mm
on watchOS 27.0 24R362). No Apple simulator, Xcode, Device Hub or
reference tool was run, opened or observed for this round; Apple's
command-line `xcodebuild` built our own sample.

### 13.1 What was added

| Req. | Where | Status |
|---|---|---|
| P-8 show pairs | Device Hub: "Paired with <watch> ›" on an iPhone with an active pair (§6, `device-hub.md` §4.1) and "Paired with <phone> ›" on a watch, between the device and its controls; Info rows Active Watch, Paired Watches, Pair, Pairing (`device-hub.md` §I.9) | **done** |
| P-8 create a pair | an iPhone's Pair Watch… (an existing unpaired watch, or a new one: name, watchOS version, model); Add Device ▸ iPhone with Paired Watch… (a new iPhone and a new watch, paired); Add Device ▸ Apple Watch… | **done** |
| P-8 unpair, make active | the row's Unpair “<watch>” (the watch is shut down and erased, P-3) and Make “<watch>” Active | **done** |
| P-9 destinations | each Ycode watch, and each iPhone with an active paired watch ("<phone> with <watch>"), rows of watchOS schemes (`destinations.md`) | **done** |
| P-9 run | iOS scheme on a paired iPhone: the iOS app, then its embedded watch app **directly on the watch** (the agent's `installApp`); watch scheme on a phone-with-watch row: the companion iOS app built and launched, the watch app installed and opened on the active watch; watch scheme on a watch row: installed and opened there (`run.md` §Watch apps) | **done** |
| P-9 no paired watch | §11.4's texts, "The install is directed to a paired Apple Watch, but there isn't one." / "Select an iPhone Run Destination with a paired Apple Watch." | **done** |
| watchOS build | the companion iOS app's build builds the watch target for `watchsimulator` (the iOS app's target dependency and its "Embed Watch Content" copy phase); a watch scheme alone builds for `generic/platform=watchOS Simulator` | **done** with `xcodebuild` and Ycode's build engines (`WatchSamples`) |
| Compact watch window | the hub's Open in New Window on a running watch; the scroll wheel turns the crown (`watchos.md` §12) | **done** (§13.3) |
| Sample | `ycode/Samples/WatchSamples/WatchSamples.xcodeproj`: `WCProbe` (iOS, `dev.ycode.wcprobe`) embedding `WCProbeWatch` (watchOS, `dev.ycode.wcprobe.watchkitapp`), sources from `SimGuestAgents/wcprobe` (§10.2) | **added** |

### 13.2 Ycode decisions

- **One command per change.** The IDE runs the launcher's pairing
  commands of §8.2 over ssh with the device set named:
  `exec env YCODE_SIM_DEVICE_SET='<data>/devices' '<launcher>'
  pair|unpair|pair-activate|list-pairs --json …`. A device that never
  booted gets its type record first (`ycode-device-type`, the file a boot
  writes; `ycode-simd` refuses to pair a directory without one), so a pair
  can be made before either device boots, as `simctl pair` allows (§2.2).
  The pair's UUID is the last output line that is a UUID.
- **The IDE's copy of the pairs.** `list-pairs --json` (§8.2) is read when a
  workspace window lists its destinations, when Device Hub opens, after
  each pairing command, every eighth state poll of the hub (about 16 s),
  and by a run on a phone-with-watch row before it starts. Each pair's
  devices are recognised by the directory name the listing gives in
  brackets. The listing is kept in the defaults (`Ycode.remote.pairs`).
- **Created devices.** The hub's fixed rows are one device per runtime
  root and type (`run.md` §Runtimes and device types). Pairing needs
  watches and phones of the user's own, so devices created in the hub are
  kept in the defaults (`Ycode.remote.createdDevices`: name, type id,
  runtime root, directory `<device name>-<type id>-<runtime>-<8 hex
  digits>`); they are rows, run destinations (`ycode-remote-simulator:device:<directory>`)
  and can be deleted (`ycode-sim --erase`), not while paired.
- **Phone-with-watch rows.** "<phone> with <watch>", platform watchOS, the
  watch's runtime version, identifier `ycode-remote-simulator:paired:<phone
  directory>`; the watch is the phone's active one at the run's start. The
  reference's title for this row was not observed (Q14).
- **The run** (`run.md` §Watch apps): the watch is started as Device Hub's
  Start when it does not run, at the same time as the phone's run; the
  watch app is installed once the iOS app has launched and the pair is
  connected, so the watch's appconduitd can tell the phone (§11.4). A
  watch-scheme run on a phone-with-watch row also launches the iOS app (a
  phone run launches its app); the reference opens the watch app only.
  A watch the run started is shut down when the phone's run ends.
- **Display socket names.** A Unix socket path holds about 104 bytes; the
  hub's display socket `<data>/display/<device directory>.sock` became too
  long for the watches' and created devices' directory names, and their
  live display never connected (first run). A path over 100 bytes now uses
  `<data>/display/d-<FNV-1a of the directory name, 8 hex digits>.sock`
  when that name is the shorter one.

### 13.3 Runs (2026-10-30)

The opt-in `PairedRunEndToEndTests` drives the IDE's own controllers on the
Mac (a workspace window on `WatchSamples`, Device Hub with Ycode's rows
only, forms answered by the test) against the arm64 Linux host (1-min load
10–34 during the runs, other agents' boots in the shared slots); full boot,
warm boot off. Fresh devices: both created by the run.

| Step | Result (e1) |
|---|---|
| Add Device ▸ iPhone with Paired Watch… (iPhone 18 Pro, Series 12 46 mm) | both devices recorded, type records written, `ycode-sim pair` in **0.6 s**; the hub showed "Paired with Apple Watch Series 12 (46mm) ›" and the Info rows ("(active, disconnected)": neither runs) |
| Run of `WCProbeWatch` on "iPhone 18 Pro with Apple Watch Series 12 (46mm)" | the companion `WCProbe` built (with `WCProbeWatch` for the watchOS simulator), uploaded; phone and watch first boots in parallel; "(active, connected)" within 2 min; both registries paired (phone's `pairWithSimulator:…` completion after 13.2 s, the watch's after 41.8 s) |
| iOS app, then watch app | `ylaunch: launched dev.ycode.wcprobe`; then `installApp` on the watch **4.9 s**, `openApp` **0.38 s**; both apps running **209 s** after Run (build and both first boots included) |
| WatchConnectivity (WCProbe) | phone: activated, `isPaired` true; **`isWatchAppInstalled` true and a `watchDirectory`** 9.4 s after the phone app started (once the watch app was installed), reachable 1 s later; pings answered both ways: phone round trips n 22, min 0.81 s, median 2.79 s, max 12.1 s (host load 20–34); the bursts and the 64 KiB message answered (43 phone, 44 watch round-trip lines) |
| Hub during the run | the phone's live screen ("WCProbe phone") with its capsule; the watch row with "Paired with iPhone 18 Pro ›" — its live display did not connect (the socket path, §13.2), fixed for e2 |
| Stop | the phone's run stopped; the watch the run started was shut down |
| Unpair from the hub | `ycode-sim unpair` with both shut down: "Unpaired; the watch was erased"; the watch's directory held only `ycode-device-type` and `ycode-udid` (P-3) |

Run e2 (the same steps on two new devices, after the socket fix): pair
0.5 s; both apps running **141 s** after Run; round trips answered on
both devices; the hub showed the watch's live screen (WCProbe's list)
with "Paired with iPhone 18 Pro ›" and Info "Paired With iPhone 18 Pro",
"(active, connected)"; Open in New Window gave the watch's compact window,
and ten scroll-wheel events over its screen (−3 lines each) turned the
crown: the watch app's list scrolled from the top to rows 19–23 (its
scroll offset 1 122 points, `watchos.md` §12.3 measured 1 119.5 for its
burst); Stop, then Unpair (the watch erased, as in e1), then Delete… of
both devices erased them on the host.

Screenshots (Ycode's own windows, `screencapture -l`, outside the
repository): `pair-ide-1-hub-paired.png`, `pair-ide-2-hub-phone-running.png`,
`pair-ide-3-hub-watch-running.png`, `pair-ide-4-watch-compact.png`,
`pair-ide-5-watch-compact-crown.png`, `pair-ide-6-hub-unpaired.png`.

### 13.4 Tests

- `PairIDETests` (YcodeIDECoreTests; Mac and x86-64 Linux): the
  `list-pairs --json` listing (status lines before it, a missing
  directory, active and connected), the pair UUID in `pair`'s output, the
  commands (device set, type records, the order watch then phone), the
  type record written only when missing (run by `/bin/sh`), the agent's
  `installApp`/`openApp` commands and the guest path with and without
  `ycode-device-path` (run by `/bin/sh`), `agentIsUp`, created devices
  (targets, identifiers, directories, defaults, rows, a type its root does
  not run), watch and phone-with-watch destinations and their targets, the
  destination menu for watchOS and iOS schemes (deployment target), the
  sample's companion target and schemes, the embedded watch app, the
  pairs store, short display sockets.
- `PairIDEHubTests` (YcodeUITests): the hub's capsule on phone and watch,
  Info rows, menu items, Add Device items, no pairing items without a
  watchOS runtime; Pair Watch… with an existing watch through a stand-in
  launcher (type records, `pair`, `list-pairs`), Make Active, Unpair (asked
  first); iPhone with Paired Watch… (two created devices, paired, the phone
  selected), Delete refused while paired, then erasing; Apple Watch…; the
  destination menu of `WatchSamples`' two schemes, the products' paths,
  and §11.4's failure of a run whose pair is gone.
- `PairedRunEndToEndTests` (opt-in, `YCODE_E2E_PAIR_*`): §13.3.
- Results (the branch merged with the main line): Mac `swift build &&
  swift test`, 2 193 tests, all pass (exit 0); x86-64 Linux, 1 721 tests,
  all pass but `SourceKitLSPEndToEndTests.diagnosticsCompletionDefinition`
  (its 180 s limit, also alone; YcodeLanguage, untouched by this round);
  `scripts/lint.sh` exits 0. The simulator code is unchanged, so the
  Thor's suites were not rerun; its release build of the branch built and
  ran e1 and e2.

### 13.5 What remains

- Q13 (the phone's WatchConnectivity after a switch) still decides
  whether Make Active is useful for apps; the registry switches.
- The watch app's debugger: no debugger attaches to Ycode's remote runs.
- Gestures in the compact window wait for `watchos.md` Q15.
- Q14 (new, dirty room): the reference's title of a phone-with-watch run
  destination, Device Hub's Pair Apple Watch… form, and whether Xcode
  offers a paired watch when creating an iPhone.

## 14. Dirty-room answers to §9 Q13 and Q14 (agent OBS-WATCH3, 2026-10-31)

Reference: Xcode 27.1, CoreSimulator 1174.9.2; throwaway devices
`ycode-test-phone3-a` (iPhone 18 Pro, iOS 27.0 24A434),
`ycode-test-watch3-a` (Series 12 46 mm) and `ycode-test-watch3-b` (Ultra 4
49 mm, both watchOS 27.0 24R362), deleted with their pairs at the end. Our
WatchConnectivity probe (`WCProbe2`) ran in the phone's foreground
throughout; the watch app was installed directly on each watch. Guest logs
at debug level (wcd, nanoregistryd, the bridge, ids_simd, appconduitd).
No GUI. Notes: `research/notes/obs-watch3-2026-10-31.md`.

### 14.1 Q13: the phone's WatchConnectivity after a switch

| Step | Phone wcd | Phone app (`WCSession`) |
|---|---|---|
| phone + A, steady | — | activated; `isPaired`, `isWatchAppInstalled` true; `watchDirectoryURL` under A's UDID; reachable |
| A down, B (**never paired**) up, `pair_activate` B ("Pairing.", 1.6 s) | device became inactive / active notifications → "Resetting initial state" → "Handling switch with nil pairing ID" → "No matching NRDevice for active IDS device"; 0.8 s later wcd is launched for NanoRegistry's **device-did-pair** event, handles the switch, reads the registry ("isPaired: YES, pairingID: B") and re-activates its clients "awaiting initial set up complete" | **`sessionDidBecomeInactive` and `sessionDidDeactivate` in the same millisecond**; the app's `activate()` from `sessionDidDeactivate` did not complete in 5 min: the set-up failed because the phone's appconduitd had no IDS device for B yet (ACX error 28, "initial set up failed. Awaiting trigger"); neither a relaunch nor a direct install on B changed it |
| phone rebooted with A active | starts with A | activated with A |
| A down, B (**paired before**) up, `pair_activate` B ("Switching.", 0.33 s; registry: A inactive, ids_simd switches the active paired device, B active) | the same five lines, ending in **"No matching NRDevice for active IDS device"**, then **nothing** (no device-did-pair event comes for a device that is already paired) | **no callback** for 3 min: `activationState` 2, `isPaired` true, `isWatchAppInstalled` true, `watchDirectoryURL` still under **A**'s UDID, not reachable; a relaunched app is held "awaiting initial set up complete" with the system pairing ID null and never activates |
| phone rebooted with B active | starts with B | activated with B; `watchDirectoryURL` under B's UDID; `isWatchAppInstalled` true |

So the reference's phone WatchConnectivity **does not follow a switch to a
watch paired before**: the registry and IDS switch, wcd does not, until it
starts again. It follows a switch to a newly paired watch because
NanoRegistry posts device-did-pair; even then the app's session waits for
appconduitd to know the new device. The watch side was healthy in both
cases (the watch app activated, `isCompanionAppInstalled` true).

**What Ycode must do** (P-14):

- Nothing for parity: Ycode's §12.3 result (registry switched, wcd
  "Handling switch with nil pairing ID", the session left with the old
  watch) is the reference's behavior. Ycode must not make the phone's apps
  switch by a path of their own.
- IDE (Ycode decision, visible): after Make Active for a watch paired
  before, say that apps on the iPhone keep the previous watch until the
  iPhone restarts, and offer **Restart iPhone** (a phone reboot is the
  reference's recovery).
- A switch to a newly paired watch delivers the inactive and deactivate
  callbacks together, as above; Ycode's agent pairs through NanoRegistry
  (§11.1), which posts device-did-pair itself.

### 14.2 Q14: the phone-with-watch destination

- `xcodebuild -showdestinations` for the watch scheme lists the phone whose
  active paired watch is watchOS 27 as the phone itself: `{ platform:iOS
  Simulator, arch:arm64, id:<phone UDID>, OS:27.0, name:<phone name> }`,
  with no watch in the entry; every watchOS 27 watch is listed under its
  own name, paired or not. (`-json` is not offered for `-showdestinations`.)
- `xcodebuild build` of the watch scheme with `-destination id=<phone>`,
  `platform=iOS Simulator,id=<phone>` or
  `platform=watchOS Simulator,id=<phone>` fails "Unable to find a device
  matching the provided destination specifier" (as in §11.4): the row
  exists for the IDE's run only.
- The IDE's title of the row: **not observed** (GUI only). Level 4: the
  IDE's foundation framework has the format strings "%@ + %@", "%@ via %@"
  and "Installing on %@ via %@" with its proxied-device code; which one
  titles a simulator row is not known. Ycode keeps "<phone> with <watch>"
  (§13.2) until the GUI is observed.
- Device Hub's Pair Apple Watch… form and whether creating an iPhone offers
  a watch in the same step: **not observed** (GUI only). For reference,
  `devicectl device pairings` offers `list`, `pair --phone … --watch …`
  (the watch option repeatable), `set-active` and `unpair` (help text).

What Ycode must do: nothing new. A command-line build that names the phone
for a watch scheme may be refused, as the reference refuses it.

### 14.3 Ycode implementation (agent WATCH-W7, 2026-10-31)

Clean-room work from §14.1 and §14.2. No Apple simulator, Xcode, Device Hub
or reference tool was run or observed.

- **Q13, the simulator: no change** (parity). Ycode's phone wcd behaves as
  the reference's after a switch to a watch paired before (§12.3); the
  apps keep the old watch until the phone restarts. Nothing in Ycode makes
  them follow.
- **Q13, the IDE** (P-14, **Ycode decision**): Device Hub's Make
  “<watch>” Active on a running iPhone ends with the note "Apps on the
  iPhone keep using the previous watch until the iPhone restarts." and the
  buttons **Restart iPhone** / Later; Restart iPhone is the row's Restart
  (Shut Down, then Start). A shut-down iPhone gets no note. Details and
  texts: `specs/ide/device-hub.md` §I.10; test
  `PairIDEHubTests.makeActiveOffersToRestartARunningIPhone`.
- **Q14, `ycodebuild -showdestinations`**: for a scheme whose platforms
  include `watchsimulator`, a phone whose active pair's watch is an
  available watchOS simulator (`xcrun simctl list -j pairs`, state
  "(active, …)") is listed among the available destinations as the phone
  itself, `{ platform:iOS Simulator, arch:<host>, id:<phone>, OS:<its OS>,
  name:<phone> }`, in the listing's usual simulator order (watches before
  phones); every watch stays listed under its own name; an iOS scheme's
  listing is unchanged. **Ycode decisions**: §14.2 names the watchOS 27
  watch; Ycode accepts any watchOS simulator watch (the reference's rule for
  older watches was not observed), and the order of the phone's row among
  the others was not recorded either. `ycodebuild build` naming the phone
  for a watch scheme is not changed. Code: `YcodeXcodebuild`
  `Destinations.simulatorLines`, `Simulators.phonesWithActiveWatch`; test
  `ParityTests.phoneWithActiveWatchIsAWatchSchemeDestination`.
- **The IDE's title of the row stays Ycode's "<phone> with <watch>"**
  (§13.2): the reference's GUI title is not observed (§14.2), and this is
  recorded as Ycode's choice, not parity.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Device-set keys, pair creation, limits, errors, activation, unpair (§2) | 2, 3 | `simctl pair`, `pair_activate`, `unpair`, `list pairs -j` on throwaway devices; `device_set.plist` via `plutil` before and after |
| Unpair erases the watch (§2.2, §3.2) | 3, 4 | birth time of the watch's `data` directory; first-boot migration on the next boot; CoreSimulator strings ("Error erasing device during unpairing") |
| Pairing requirements and features (§2.3) | 2 | runtime `profile.plist` and device-type `profile.plist` files |
| Default pairs on this Mac (§2.3) | 3 | `device_set.plist` and `simctl list devices -j` (read only) |
| Bridge requests and the guest calls (§3.1) | 3, 4 | CoreSimulatorBridge, ids_simd and nanoregistryd logs in both guests; request names and selectors in the bridge's strings; CoreSimulator's selector strings |
| Sequences and times (§3.2) | 3 | `simctl bootstatus`, both guests' logs, `simctl list pairs` |
| Data written by pairing (§3.3) | 3 | file listings of both `DEV/data` before and after; `plutil -p` of `history.plist` |
| Endpoints, port identity, no socket (§4.1) | 3, 4 | `launchctl print` (simhost blocks), `lsmp` of both launchd_sim and both ids_simd, our host tool's look-ups through CoreSimulator, `lsof -i`/`lsof -U` of both guests; ids_simd and CoreSimulator strings for the name forms |
| Registration refused while valid; removal on shutdown (§4.1, §3.2) | 3 | host CoreSimulatorService log with our port pre-registered; look-ups after shutdowns |
| Dead peer behavior (§4.2) | 3 | ids_simd log "Failed to deliver request: 268435459" with the phone shut down |
| Message format, reply, sizes, ids (§4.3) | 3 | our `idsrelay` (host man-in-the-middle with reply interception), 80 + 118 requests; payload key names read with `plistlib` |
| Imports of ids_simd (MIG server, bootstrap look-up) | 4 | `nm -u` of ids_simd |
| Simulated link and queues (§4.4) | 3 | ids_simd logs in both guests; `ids_simd.plist` |
| What apps see (§5) | 3 | our WCProbe on both devices, unified log; appconduitd and ids_simd logs |
| Device Hub capsule (§6) | 3 | earlier round (`specs/ide/device-hub.md` §4.1) |
| Requirements, relay design, risks (§7) | — | Ycode decisions from the above |
| Round W4 under Ycode: records, commands, rendezvous, order, agent, erase (§8.1–§8.3) | — | Ycode decisions; unit tests `DevicePairingTests`, `PairingTests` |
| Guest calls and what nanoregistryd and ids_simd log in response (§8.4) | 3 | Ycode's own simulator on the arm64 Linux host: guest `log stream` of nanoregistryd, ids_simd and the agent; the agent's log |
| Runs p1, p2: connected, [CREATED], watch face, unpair erase (§8.5) | 3 | `ycode-sim list-pairs` every 5 s, guest logs, Ycode's frame record, the watch directory before and after |
| Round W5: relay frames, halves, errors, sizes, apps on a watch, WCProbe (§10.1, §10.2) | — | Ycode decisions; unit tests `PairingTransportRelayTests`, `DevicePairingTests` |
| ids_simd serves its port with `mach_msg_server_once`; the stub's spin (§10.3) | 3 | Ycode's own simulator: ids_simd's log ("Error processing … message: 46"), `ycode-simd --trace-name ids_simd` (the unimplemented library function and its caller) |
| MIG server conventions of `mach_msg_server(_once)` (§10.3) | 1 | `mach-ipc.md` §2.8, §5.1, §5.2 |
| Runs r2, r3, r4: relay counters, WatchConnectivity results and times, peer absence, registry completion (§10.4, §10.5) | 3 | Ycode's own simulator on the arm64 Linux host: `pairing relay` every 30 s, guest `log stream` of ids_simd, nanoregistryd, wcd and the pairing agent, WCProbe's log on both devices, the run's event times |
| Reference times compared (§10.4) | 3 | §4.4 and §5 (round 0) |
| Q9: bridge calls, nanoregistryd XPC methods, decision rules, arrays, unpair and remove-unpaired effects, survivor disconnect, the 4.5 min set-active (§11.1) | 3, 4 | guests' debug logs of the bridge, nanoregistryd and ids_simd (request lines, the daemon's transaction names, `State change` lines, the remove-unpaired arrays); `simctl pair`, `pair_activate`, `unpair`, `list pairs`; `device_set.plist`; bridge imports (`nm -u`) and selector strings |
| Q11: user-info wire path, sender and receiver files, non-delivery in every app state (§11.2) | 3 | our WCProbe2 on both devices; wcd, ids_simd and IDS-framework debug lines in both guests; listings of both apps' data containers and both devices' `DEV/data/tmp` |
| Q5: file sizes on the wire, delays, non-delivery; complication user info delivered (§11.3) | 3 | as Q11; ids_simd's "data is N bytes" and "before delay of N secs" lines |
| Q12: direct install and `isWatchAppInstalled`, install through the phone (socket, free space, error 12), destinations (§11.4) | 3 | appconduitd, cache-delete and wcd logs in both guests; WCProbe2; `simctl listapps`; `xcodebuild -showdestinations` and `build` on our own hand-written project |
| Q12: Xcode's install option and messages (§11.4) | 4 | strings of Xcode's iOS support plug-in, CoreSimulator and the bridge |
| Requirements P-10…P-13 (§11.5) | — | Ycode decisions from the above |
| Round W3b: the agent's registry calls and decisions, the sequencer's disconnect and switch-only set-active, relay pieces and bounds (§12.1, §12.2) | — | Ycode decisions; unit tests `PairingTransportRelayTests`, `PairingSequencerTests` |
| Runs a1, b1, c1: pairing, unpair and pairing again, switching, remove-unpaired, survivor disconnect, the 20 MiB request, complication user info (§12.3) | 3 | Ycode's own simulator on the arm64 Linux host: the pairing agent's replies in `ycode-simd`'s log, `pairing state`/`relay` and `pairing agent pairs`, guest `log stream` of ids_simd, nanoregistryd and wcd, WCProbe's logs on both devices |
| Round W6: the IDE's commands, copies of the pairs, created devices, destinations, runs, socket names (§13.1, §13.2) | — | Ycode decisions from §2, §8.2, §10.2, §11.4; unit tests `PairIDETests`, `PairIDEHubTests` |
| Runs e1, e2: create, pair, run, WatchConnectivity, unpair erase from the IDE (§13.3) | 3 | `PairedRunEndToEndTests` on the Mac against Ycode's simulator on the arm64 Linux host: the IDE console, the pairing agent's log, `list-pairs`, WCProbe's logs, the watch directory after the unpair, Ycode's window captures |
| Q13: wcd's switch handling, the device-did-pair path, the app's callbacks and session state after both kinds of switch, recovery at wcd's start (§14.1) | 3 | WCProbe2 on the phone and both watches; the phone's wcd, nanoregistryd, bridge, ids_simd and appconduitd at debug level; `simctl pair`, `pair_activate`, phone reboots |
| Q14: destinations on the command line, build refusal (§14.2) | 3 | `xcodebuild -showdestinations` and `build -destination` on our own hand-written project |
| Q14: format strings near the proxied-device code; `devicectl` pairing commands (§14.2) | 4 | strings of the IDE's foundation framework; `devicectl help device pairings` |
| P-14 (§14.1) | — | Ycode decisions from the above |
| Round W7: Make Active's note and Restart iPhone, `ycodebuild -showdestinations` with a phone-with-watch (§14.3) | — | Ycode decisions from §14.1, §14.2; unit tests `PairIDEHubTests`, `ParityTests` |
