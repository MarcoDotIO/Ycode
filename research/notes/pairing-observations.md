# iPhone–Apple Watch simulator pairing observations (agent OBS-WATCH, 2026-10-29)

Dirty-room notes behind `specs/simulator/device-pairing.md`. Prose only. Raw
logs, `lsmp` listings, captured message payloads and plists stay in
`research/dirty/watch/` (git-ignored). No disassembly or decompilation;
Ghidra and the reference tools folder were not opened. Setup, devices and
the host load are described in `watchos-observations.md` §Setup: every time
here was taken with a load average of 190–840 and is an upper bound.

## Records (simctl, device set; levels 2 and 3)

- `simctl create` of an iPhone creates **no** watch and no pair; the device
  set file did not change.
- `simctl pair <watch> <phone>` (either argument order works; roles come
  from the device families) returns a new pair UUID at once, with both
  devices shut down. The pair is recorded in
  `~/Library/Developer/CoreSimulator/Devices/device_set.plist` under
  `DevicePairs` → `<pair UUID>` → {`active` (bool), `companion` (phone
  UDID), `gizmo` (watch UDID)}. Neither `device.plist` changes. The file was
  written within a second.
- Limits come from the runtimes' `pairingRequirements`. A watch already in a
  pair: "At least one of the requested devices is already paired with the
  maximum number of supported devices" (SimError 403, underlying
  `SimDevicePairingTest` code 4). Phone + phone or watch + watch: "does not
  support pairing" (code 2). A phone took a second watch: the first pair of
  a phone is **active**, later ones **inactive**.
- `simctl pair_activate <pair>` switches `active` (the other pair of the
  same phone becomes inactive); activating the active pair: POSIX error 37
  "This pair is already active". `unpair` of an unknown pair: "Invalid
  device pair" (exit 148). Unpairing the active pair leaves the phone's
  other pair inactive; the next new pair of that phone becomes active.
- `simctl list pairs` prints "(active|inactive, connected|disconnected)".
  "connected" appears only while both devices are booted and the host's
  relay is up; it lags shutdowns by a few seconds.
- **Unpair erases the watch.** After `unpair` of a shut-down pair, the
  watch's `data` directory was recreated (its birth time is the unpair
  time) and the next boot was a first boot (24 migration plugins). After
  `unpair` of a booted pair, `simctl` returned in 0.2 s, the phone's bridge
  logged "unpair from remote", then "disconnect from remote", and within
  20 s the watch was shut down and its `data` recreated. The phone is not
  erased. CoreSimulator's strings name both steps ("Error shutting down
  device during unpairing", "Error erasing device during unpairing").
- The owner's set (read only) shows CoreSimulator's default devices: per
  iOS 26.5 and 27.0 runtime, iPhone 17 Pro Max ↔ Series 11 (46mm), iPhone
  Air ↔ Series 11 (42mm), iPhone 17 ↔ Ultra 3 (49mm), all active. The
  iPhone 18 Pro, iPhone Duo and Series 12 types, whose
  `pairByDefaultForRuntimeVersions` start at 27.0/27.1, had no default
  pair in that set.

## Lifecycle (level 3)

- **Phone booted, watch shut down.** The phone's CoreSimulatorBridge gets
  "Request received to remove pairs that are no longer paired by the host"
  with `hostPairedArray` = [watch UDID], `simPairedArray` = [] on first
  boot, `unpairArray` = []. No pairing endpoint is registered. Our app on
  the phone: `isPaired` true, `isWatchAppInstalled` false, `isReachable`
  false.
- **Both booted (first time after pairing).** Order, from both guests' logs:
  1. host registers the endpoints (below) in both bootstraps;
  2. each bridge: "Request received to connect to remote <peer>" →
     `IDSSimulatorLocalPairingTransportConnect(peer)` → ids_simd
     `transportConnectWithSimulatorID:` (it looks up the endpoint);
  3. each bridge: "Request received to make <peer> the active pair" →
     "<peer> has not previously paired. Pairing." (later boots: "has
     previously paired. Switching.") → bridge connects to
     `com.apple.nano.nanoregistry.paireddeviceregistry`;
  4. nanoregistryd: `IDSSimulatorLocalPairingAddPairedDevice` and
     `…SwitchActivePairedDevice` (ids_simd `addPairedDeviceWithSimulatorID:`,
     `switchToActivePairedDeviceWithSimulatorID:`), "State change: <peer>
     [CREATED] _bluetoothIdentifier …", `localPairingDataStorePath`;
  5. initial paired sync: replicator, bluetoothregistryclassc, location,
     siri, sockpuppet, appsyncconduit messages both ways.
  In this run the phone's bridge was blocked 145 s on nanoregistryd
  ("blocked on threadIsBlockedWaitingOn_nanoregistryd_syncGrabLegacyRegistry")
  and the watch's `bootstatus` stayed "Waiting on Data Migration" until the
  pairing finished: the watch's first paired boot took 163.9 s (its first
  unpaired boot 30.3 s). Load average 190 at the time; cause not isolated.
  A second fresh pair (`ycode-test-phone-3`/`ycode-test-watch-3`, lighter
  load at the start, load rising to 700 during the boot) had no stall: the
  watch's bridge got connect 4 s into its boot and set-active 1.3 s later,
  both nanoregistryd logged the pair (`isActive`, `isPaired` 1) within
  11 s of the boot start, and `bootstatus` was terminal at 54.4 s (data
  migration 18 s, "Waiting on System App" 28 s).
- **Repeat boots, pair existing.** Watch booted with the phone up: 18.7 s and
  25.2 s to terminal; pair "(active, connected)" right after. Watch booted
  alone: 20.2 s. Phone booted while the watch was up: the watch's bridge
  got "connect to remote" 1.2 s after the phone's boot and "make … the
  active pair" 3.4 s after it; queued transfers then completed.
- **Either device shut down.** The host **unregisters** the endpoint from the
  other device's bootstrap (look-ups fail with "Failed to find service …").
  No bridge request was logged on the surviving side.
- **Watch booted, phone shut down.** Our watch app: `isCompanionAppInstalled`
  true and **`isReachable` true**; sends go out of WatchConnectivity and
  ids_simd logs "Failed to deliver request: 268435459" (0x10000003,
  `MACH_SEND_INVALID_DEST`) for each, keeping them queued; they were
  delivered after the phone booted.
- **ids_simd restarted** (killed, KeepAlive restarts it): its
  `com.apple.IDSSimRPC.local` port is the same port (launchd keeps the
  receive right), so the peer's endpoint stays valid; the new ids_simd
  repeats `transportConnect` for its remembered peer. Local clients that had
  registered services did not all re-register ("Recipient for service
  com.apple.private.alloy.watchconnectivity has not registered. Messages for
  it are being left in a pending state").

## The transport (levels 3 and 4)

- Guest side: in each device **ids_simd** (job `com.apple.ids_simd`,
  `IDSSimulatorSupport.framework/Support/ids_simd`, KeepAlive) checks in the
  Mach service **`com.apple.IDSSimRPC.local`** and also serves the local
  NSXPC service `com.apple.IDSSimulatorSupport` for the device's IDS
  clients (identityservicesd's framework in each daemon or app that uses an
  IDS service; CoreSimulatorBridge and nanoregistryd call the
  `IDSSimulatorLocalPairing*` functions through it). Same job on iOS and
  watchOS.
- Host side: with both paired devices booted, the host registers in each
  device's bootstrap a host-side endpoint named
  **`com.apple.IDSSimRPC.remote.<peer UDID>`** whose port **is the peer's
  `com.apple.IDSSimRPC.local` port**. Evidence: `launchctl print` shows the
  names in the simhost block (`host-side = 1`); `lsmp` of both launchd_sim
  processes and both ids_simd processes shows the same port object for the
  watch's `…remote.<phone>` entry, the phone's `…local` entry and the phone
  ids_simd's receive right (and the converse); our host tool's look-ups
  through CoreSimulator returned the same port name for "remote.<phone> in
  the watch" and "local in the phone". CoreSimulator's strings contain both
  name forms.
- There is **no relay process and no socket**: `lsof` of both guests showed
  no TCP/UDP or Unix socket between them; the two ids_simd processes send
  Mach messages to each other directly (possible on macOS because both
  guests are processes of one kernel). Each holds a send right to the
  peer's port with a dead-name request.
- Registering is refused while the name has a valid send right: with our
  port pre-registered under the phone's `…remote.<watch>`, the host logged
  "Error registering service … send right is still valid" (POSIX 17) and
  "Error connecting IPC relay to companion", and the pair stayed
  "disconnected" until our port died.
- Wire format (our `idsrelay`, a host tool that swapped the watch's
  endpoint for a port of its own and forwarded to the phone's local port,
  replacing the reply right so replies passed through it too; 234 messages
  with WCProbe traffic):
  - request: msgh_id **1000**, complex, remote = the endpoint (copy send),
    reply = a **send-once** right (MIG routine), no voucher, size 56:
    header (24), descriptor count (4) = 1, one **out-of-line memory
    descriptor** (16; virtual copy, deallocate), NDR record (8: 00 00 00 00
    01 00 00 00), a 32-bit byte count equal to the OOL size;
  - reply: msgh_id **1100**, simple, size 36: header, NDR, 32-bit return
    code 0; it came back 0.3–5.7 ms after the request (median 0.8 ms);
  - the OOL region is a binary property list written by NSKeyedArchiver
    (`$archiver` NSKeyedArchiver, `$version` 100000, `$top` {root}) of an
    NSDictionary with exactly four keys: `senderDeviceID` (NSUUID, the
    sending simulator's UDID), `serviceName` (NSString, the IDS service, for
    example `com.apple.private.alloy.watchconnectivity`), `messageID`
    (NSString, a UUID string) and `data` (NSData, the IDS payload, opaque);
  - OOL sizes 1 239–67 765 bytes (median 1 985); `data` 695–67 130 bytes
    (the 64 KiB WatchConnectivity message data is the largest);
  - only ids 1000/1100 appeared; both captures relayed the watch → phone
    direction only
    (run 1: 80 requests, run 3: 118 request–reply pairs).
- In ids_simd: per-service simulated restrictions, a preference of the
  device (`DEV/data/Library/Preferences/ids_simd.plist`, keys
  `SimulatedNetworkRestrictions-<service>`, false by default for
  `…replicator` and `…sockpuppet.classd`, "Explicitly set restrictions state
  0 … from paired device"). With restrictions on (the default for other
  services) the **receiver** delays delivery by about 0.175 s + 10 µs per
  byte (650 B → 0.181 s, 948 B → 0.184 s, 7 809 B → 0.251 s): a simulated
  Bluetooth link. Services with restrictions off (WatchConnectivity among
  them: "restrictions are currently disabled for
  com.apple.private.alloy.watchconnectivity") get no delay.
- Sender side: ids_simd keeps an outgoing queue ("outgoingMessages: (…)",
  "Resuming servicing of the send queue", "outgoingMessages is empty.
  finished for now"); messages for a peer that is not reachable stay queued
  (the first paired boot queued for 2 min 17 s).

## WatchConnectivity as an app sees it (level 3, our WCProbe)

- Built with `swiftc` for both simulators; the watch app is a single-target
  watch app (`WKApplication` true, `WKCompanionAppBundleIdentifier` = the
  iOS bundle id) embedded at `WCProbe.app/Watch/WCProbeWatch.app`.
- `simctl install` of the iOS app on the paired phone: installed in 6.5 s.
  appconduitd on the phone noticed the embedded watch app ("Adding app
  dev.ycode.wcprobe.watchkitapp", "new and user says install all apps so
  installing") and sent app-sync messages over IDS service
  `com.apple.private.alloy.appsyncconduit.v2`; on the watch no process had
  registered that service ("Messages for it are being left in a pending
  state") and the phone's requests timed out after 160 s. The watch app was
  **not** installed on the watch within 6.5 minutes (the watch's
  app list never showed it until we installed it directly).
- `simctl install` of the watch app on the watch, then `simctl launch` on
  both: watch side `isCompanionAppInstalled` true, `isReachable` false then
  true within a second of launch (the phone app was running). Phone side
  `isPaired` true, **`isWatchAppInstalled` false**, `isReachable` false,
  `watchDirectoryURL` nil the whole session; its
  `updateApplicationContext` and `transferUserInfo` failed with
  WCErrorDomain 7006 "Watch app is not installed." So with the watch app
  installed directly on the watch (not through the phone), traffic works
  watch → phone (messages with replies, message data, application
  context, user info), and the phone refuses to start transfers.
- Watch → phone `sendMessage` with reply: minimum one-way 0.92 s, minimum
  round trip 2.0 s; under load the backlog grew to 130 s (median one-way
  53 s). 64 KiB `sendMessageData`: minimum round trip 3.4 s. Between the
  two ids_simd processes (their own logs): median 0.92 s from "sent" to
  "received", maximum 1.0 s, minimum 0; at the Mach level the request is
  acknowledged within a millisecond, so the ~0.9 s is spent inside
  ids_simd (queueing) or the clients, not in the transport.
- WatchConnectivity uses IDS services `com.apple.private.alloy.watchconnectivity`
  (messages, 1 449-byte requests and 994-byte replies on the wire for our
  small dictionaries) and `…watchconnectivity.classd`.
- Second run (fresh pair `ycode-test-phone-3`/`ycode-test-watch-3`): the
  iOS app installed on the phone in 13.3 s; the embedded watch app was
  again not on the watch 2 min later. Installed directly and launched 3 min
  after the pair formed, the watch app's `activateSession` never completed
  (4 min, two launches): wcd logged "client pairingID: (null), system
  pairingID: <phone>" and "activating for currently active counterpart",
  then nothing for it. The phone app behaved as in the first run.
- The phone app received the watch's application context
  (`didReceiveApplicationContext`) and messages; user-info deliveries on
  the phone were not seen in the captured windows.

## Not observed

- The Device Hub pair UI and Xcode's run destination for a watch app (GUI
  only; not driven). Device Hub's "Paired with <watch> ›" capsule is in
  `specs/ide/device-hub.md` §4.1 from an earlier round.
- Whether an Xcode run of a watch scheme installs through the phone or
  directly, and how it makes the phone's `isWatchAppInstalled` true.
- The cause of the 145 s stall in the first paired boot (load is the
  likely cause: the second run had none).
- Crown and side-button effects (see `watchos-observations.md` §Input).
