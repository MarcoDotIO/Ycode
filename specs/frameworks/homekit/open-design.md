# HomeKit spec: open implementation and accessory simulator

> **Ycode-original design note.** This file is our own design, not a
> description of Apple's implementation. It builds on the facts in the other
> files of `specs/frameworks/homekit/` and on Apache-2.0 sources named in
> `accessory-protocols.md` §1. Nothing here was derived from Apple binaries.

There are two products, and they meet in the middle:

1. **Simulator parity (Track S).** Ycode's iOS simulator runs Apple's own
   runtime, so apps use Apple's `HomeKit.framework` and Apple's `homed`
   inside the guest. Ycode only has to provide what that stack depends on
   (`simulator-baseline.md` §8). No reimplementation of HomeKit is needed
   for parity.
2. **Open HomeKit (Track O).** A Linux-buildable, open-source library and
   daemon with HomeKit's object model and behavior (`object-model.md`),
   talking HAP and later Matter to accessories. It serves apps built for
   Ycode's open-frameworks track, and it powers the **Ycode accessory
   simulator** that both tracks use for testing.

## 1. Track S: what Ycode's simulator must provide

Ordered by what unblocks the baseline checklist (`simulator-baseline.md`
§9) first.

| # | Dependency | Ycode work | Checklist |
|---|---|---|---|
| S1 | `homed` and `homeeventsd` launch jobs | Must run in the **full** boot. Ycode's lean boot (`specs/simulator/lean-boot.md` §3.2) disables `com.apple.homed`; with it disabled, a HomeKit app gets no homes callback and hangs at "loading". Either drop homed from the lean list, or start it on demand when an app whose `__entitlements` section contains `com.apple.developer.homekit` is launched. `service-fidelity.md` lists homed as "open". | HK-B05, B15 |
| S2 | Entitlements read from `__TEXT,__entitlements` | Already needed for other entitlements; homed rejects clients without the HomeKit entitlement. Verify Ycode's code-signing emulation reports the section's content to the daemon (connection must survive). | HK-B07, B08 |
| S3 | TCC prompt for `kTCCServiceWillow` | tccd + SpringBoard alert path; the answer persists per bundle; reset clears it. Also offer a Ycode-side **pre-grant** (the Mac's simctl cannot pre-grant HomeKit; offering it is a convenience, off by default for parity). | HK-B01–B04, B10 |
| S4 | Usage-string abort | Comes for free from tccd if S3 works. | HK-B06 |
| S5 | CloudKit account state "no account" | homed must see *no account* quickly (as on the Mac) and answer `addHome` with 2040, not hang. If `cloudd` or account services are disabled or wedged in Ycode, homed may wait instead; that is a parity bug. | HK-B05 |
| S6 | `apsd`, `rapportd` | homed registers with both at start; they must answer or fail fast. | — |
| S7 | `HomeUIService` hosted scene | SpringBoard must be able to host the service for the setup flow; completion 23 when no home. | HK-B12 |
| S8 | mDNS (`_hap._tcp`) from the guest | Browsing must reach the host network namespace that the Ycode accessory simulator advertises into (§4). Without accessories the baseline is "0 found". | HK-B11 |
| S9 | Bluetooth LE | None in the simulator on the Mac either; not needed. | — |

**Accounts.** On the Mac, everything inside a home needs an iCloud
sign-in on the device. Ycode will not fake Apple's account services. The
parity default is the no-account behavior. If the owner later wants homes
in Ycode's simulator with Apple's homed, the honest options are (a) a real
Apple Account sign-in inside the guest, if Ycode's networking and account
services allow it, or (b) running apps against Track O's open daemon
instead of Apple's (a non-parity "open HomeKit" mode, clearly labelled).
Open question in `plan.md` §5.

## 2. Track O: architecture

```
 app ──► libHomeKitOpen (Swift; HMHomeManager… API surface)
            │  IPC (local socket, our own protocol)
            ▼
         ycode-homed (daemon) ──► store (SQLite, our schema)
            │        ├─► scheduler (timer, calendar, solar, duration events)
            │        └─► authorization (per-app grants, "Home data")
            ▼
         transports: HAP-IP controller │ HAP-BLE (later) │ Matter (connectedhomeip)
            ▼
         accessories: real (owner's choice) or Ycode accessory simulator
```

- **libHomeKitOpen**: the public surface of `object-model.md` in Swift
  (with an Objective-C-compatible layer where the open Foundation allows),
  model objects as client-side mirrors of daemon state, keyed by
  `uniqueIdentifier`. All callbacks on the main queue (`object-model.md`
  §12). Values and validation from `type-identifiers.md` (metadata
  checks produce errors 43–46 before any I/O).
- **ycode-homed**: owns truth. One process per user session. Clients
  subscribe; the daemon fans out changes so every other client gets the
  delegate callback, while the originator gets only its completion
  (to be confirmed, `plan.md` HK-A06). Generation counters let a client
  resync after reconnect.
- **Store**: SQLite with our own schema: homes, rooms, zones, membership,
  service groups, accessories (pairing reference, `aid`), services and
  characteristics (by `iid`, cached values), action sets/actions,
  triggers/events, users, per-app authorization. No cloud sync in round
  one; an optional sync layer later (CRDT or server-based), never Apple's
  CloudKit.
- **Accounts**: Track O does not need an Apple Account. It has a local
  "home owner" identity. This is a deliberate difference from Apple
  (documented, opt-in when used inside the simulator).
- **Scheduler**: timer triggers (fire date, recurrence), event triggers
  with calendar, significant-time (sunrise/sunset from the home location
  via a public solar algorithm), duration end events, characteristic and
  threshold events (from notifications), presence and location events
  (from simulated location in Ycode, later). The home hub role is played by
  the daemon itself, so `homeHubState` reports Connected and event triggers
  activate (a documented difference unless a "no hub" mode is chosen).
- **HAP-IP controller**: DNS-SD browse, pair-setup/verify, encrypted
  sessions, attribute-database fetch, reads, writes, timed writes, event
  subscriptions (`accessory-protocols.md` §2). Crypto from a maintained
  open library (SRP-6a, Ed25519, X25519, ChaCha20-Poly1305, HKDF-SHA-512).
  Pairing keys in a local keystore with file permissions; never in the
  repository.
- **Matter**: wrap connectedhomeip's controller (Apache-2.0); map clusters
  to HAP-typed services with our own table so apps see the same
  `HMService` types; expose `matterNodeID` / `matterEndpointID`.
- **Setup flow**: `HMAccessorySetupManager` presents a Ycode-written setup
  sheet (scan or type a code, choose room, name) instead of Apple's UI.

## 3. Ycode accessory simulator (Track O, used by both)

Purpose: give tests and developers accessories without hardware or
Apple's HomeKit Accessory Simulator (which is not installed here and needs
a developer download).

- **ycode-hap-sim**: a HAP-IP accessory server on the Linux host (or the
  Mac), written by us. The ADK (Apache-2.0) is the reference for behavior;
  we may also link it, with attribution, if that is faster.
- **Accessory definitions** in a small declarative file (YAML/JSON, our
  format): accessory name, category number, setup code, services with
  characteristic types, formats, permissions, metadata and initial
  values; optional bridge with child accessories. A library of presets:
  lightbulb (on, brightness, hue, saturation), outlet, switch, thermostat,
  lock, garage door, window covering, sensors (temperature, humidity,
  motion, contact, leak, smoke, CO, CO2, air quality), fan, air purifier,
  security system, programmable switch (stateless events), television
  with input sources, valve/irrigation, Wi-Fi router.
- **Behaviors**: target→current state transitions with configurable
  delay (garage door: Opening → Open), random or scripted sensor drift,
  forced errors per characteristic (each HAP status code), unreachable
  toggle, slow responses, configuration-number bumps (`c#`) to test
  database refresh.
- **Control API**: a local HTTP/JSON or CLI interface for tests to set
  values (as if pressed on the device), read the last written value, list
  subscriptions, and reset pairings.
- **Matter devices**: run connectedhomeip example apps (e.g. the
  all-clusters or lighting app) as simulated Matter nodes.
- **Network placement**: advertise on an isolated network namespace or
  virtual bridge shared with the simulator guest, so probes never touch the
  owner's real accessories and real accessories never see test traffic.

## 4. Simulator integration

- In Track S, Apple's homed inside the guest pairs with ycode-hap-sim only
  after the owner signs in (homes required). That gives a reference-grade
  test of the accessory simulator against Apple's controller.
- In Track O mode, the guest app links libHomeKitOpen (or an interposed
  `HomeKit.framework` shim, if the open-frameworks track ever replaces
  system frameworks) and ycode-homed runs on the host; IPC crosses the VM
  boundary over Ycode's existing host-service channel.

## 5. Open design questions

- Cluster→service mapping for Matter devices (needs observation with an
  account, a Matter device, and Apple's homed; or our own table).
- Characteristic metadata defaults per type: HomeKit ships a defaults
  resource in the framework (`DefaultCharacteristics.plist`); we must
  derive our own defaults table from HAP (ADK) instead, and observe
  reference values with the Accessory Simulator.
- Exact delegate fan-out rules, name-validation rules and limits (max
  homes, rooms, name lengths) require the account-enabled probes.

## Evidence

Ycode-original design throughout. Facts it relies on are evidenced in the
other files (levels 1–4). The lean-boot and service-fidelity references are
to Ycode's own simulator specs.
