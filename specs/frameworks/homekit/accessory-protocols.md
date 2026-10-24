# HomeKit spec: talking to accessories (HAP and Matter)

Part of `specs/frameworks/homekit/`. How an open HomeKit implementation can
reach real or simulated accessories. This file records **protocol facts and
names only** (identifiers, message names, state machines, primitives), in
our own words. It does not reproduce specification text or code. It is the
input for the HAP controller and the accessory simulator in `plan.md`.

## 1. Sources and licensing (verified 2026-10-19)

| Source | What it is | License / terms | Use here |
|---|---|---|---|
| Apple **HomeKit ADK** (`github.com/apple/HomeKitADK`) | Apple's open-source HAP *accessory* implementation (IP and BLE transports, pairing, setup codes, characteristic/service catalog). Archived by Apple on 2025-10-28 (read-only). | **Apache-2.0** | Level 1 (Apple open source). Facts below marked "ADK" were read there. |
| **HomeKit Accessory Protocol Specification, Non-Commercial Version** | Apple's protocol document. | Download needs an Apple Account sign-in and acceptance of a license that limits use to non-commercial accessories (secondary sources; we did not sign in or download). | **Not used.** Owner may obtain it (`README.md`, "Owner inputs"). Our facts come from the ADK instead. |
| **connectedhomeip** (`github.com/project-chip/connectedhomeip`) | The Matter SDK, including `src/darwin/Framework` (an Xcode project for the Matter framework on Apple platforms: `Matter.xcodeproj`, `CHIP/`) and a `data_model` directory. | **Apache-2.0** (repository license) | Level 1 for Matter controller/device behavior and for the `MTR…` names that appear in HomeKit's API. |
| **Matter specification** (Connectivity Standards Alliance) | Core, Application Cluster, Device Library and Namespace documents. | **Not Apache-2.0.** The PDFs carry a CSA license limited to internal use; commercial reproduction prohibited. | Not used. Use connectedhomeip as the source of truth instead. |

Consequence: an open implementation may be built from the ADK and
connectedhomeip (both Apache-2.0, with attribution and NOTICE handling),
plus public Apple documentation. It must not copy text from the HAP or
Matter specification documents. "Works with Apple Home" certification and
MFi authentication are out of scope.

## 2. HAP (HomeKit Accessory Protocol)

### 2.1 Roles and identity

- The **controller** (iPhone, home hub, or our open daemon) pairs with an
  **accessory server**. Each side has a long-term Ed25519 key pair and a
  pairing identifier (controller: a UUID-like string; accessory: its device
  ID, six hex bytes written like a MAC address).
- An accessory server hosts one or more **accessories** (a bridge hosts
  many), identified by an accessory instance ID (`aid`, 1 for the primary).
  Each accessory has **services**, each with **characteristics**, every
  service and characteristic having an instance ID (`iid`) unique within
  the accessory. Every accessory has an Accessory Information service and,
  for HAP over IP, a Protocol Information service.

### 2.2 Discovery (IP)

- mDNS/DNS-SD service type **`_hap._tcp`** (ADK). TXT keys (ADK):
  `c#` configuration number (changes when the attribute database changes),
  `ff` pairing feature flags, `id` device ID, `md` model name, `pv`
  protocol version, `s#` state number (1 for IP), `sf` status flags (bit
  for "not paired"), `ci` category number (§2.5), `sh` setup hash (base64
  of a truncated hash over setup ID and device ID; optional).
- The ADK also advertises a secondary `_mfi-config._tcp` service (MFi
  configuration; not needed by a controller).
- BLE accessories advertise manufacturer data instead; a BLE transport is
  later work (§2.7).

### 2.3 IP transport

- HTTP/1.1 over TCP, upgraded after pair-verify to an encrypted session
  (§2.4). Request paths routed by the ADK accessory server: `/pair-setup`,
  `/pair-verify`, `/pairings`, `/accessories`, `/characteristics`,
  `/prepare` (timed writes), `/identify` (unpaired identify), `/resource`
  (camera snapshots), `/secure-message`, `/config`, `/configured`.
- Content types: `application/pairing+tlv8` (pairing), `application/hap+json`
  (attribute database and characteristic I/O), `application/octet-stream`.
- `GET /accessories` returns the attribute database as JSON: accessories
  with `aid`, services with `iid`, `type`, characteristics with `iid`,
  `type`, `perms`, `format`, `value`, and optional metadata (unit, min,
  max, step, max length, valid values). Types are short hex IDs for
  Apple-defined types and full UUIDs otherwise (`type-identifiers.md` §1).
- `GET /characteristics?id=aid.iid,…` reads; `PUT /characteristics` writes
  values and subscribes or unsubscribes to events (an "ev" flag per
  characteristic). Multi-status replies carry a per-characteristic HAP
  status.
- HAP status codes (ADK): 0 success; −70401 insufficient privileges;
  −70402 cannot communicate with the service; −70403 busy; −70404 write to
  read-only; −70405 read from write-only; −70406 notifications not
  supported; −70407 out of resources; −70409 no such resource; −70410
  invalid value or rejected timed write; −70411 insufficient
  authorization. (−70408 "timed out" is expected by convention but was not
  in the ADK file read; verify.) Mapping to `HMErrorCode`: `errors.md` §3.
- Events: the accessory pushes unsolicited messages on the same
  connection, starting with an `EVENT/1.0 200 OK` status line, JSON body
  listing changed characteristics. The ADK coalesces notifications for up
  to one second.
- Characteristic permissions on the wire include: paired read, paired
  write, events, additional authorization, timed write, hidden, write
  response; they map to HomeKit's property strings (Readable, Writable,
  SupportsEventNotification, RequiresAuthorizationData, Hidden).

### 2.4 Pairing and sessions (ADK)

- **Pair Setup** (M1–M6) with the accessory's 8-digit setup code, over
  TLV8. M1/M2 start SRP (method, salt, accessory public key), M3/M4 verify
  SRP proofs, M5/M6 exchange long-term public keys, pairing identifiers and
  Ed25519 signatures inside ChaCha20-Poly1305-encrypted TLVs. Keys are
  derived with HKDF-SHA-512 using fixed salt/info labels (e.g. a
  "Pair-Setup-Encrypt" pair for the M5/M6 key; separate controller-sign and
  accessory-sign label pairs). Nonce labels "PS-Msg04/05/06". SRP username
  is "Pair-Setup". SRP-6a uses the 3072-bit group with SHA-512 (to confirm
  against the ADK crypto PAL in round 4). Transient and split pairing
  flags exist. The accessory refuses setup when already paired, after
  100 failed attempts, or while busy with another controller.
- **Pair Verify** (M1–M4): an ephemeral X25519 exchange signed with the
  long-term keys, then session keys derived with HKDF-SHA-512 for the two
  directions ("Control" salt with read/write key labels). After verify,
  every HTTP message is framed and sealed with ChaCha20-Poly1305 using a
  per-direction counter nonce.
- **Pairings**: add, remove and list pairings (admin controllers only).
- TLV8 item types used by pairing (names, ADK): Method, Identifier, Salt,
  PublicKey, Proof, EncryptedData, State, Error, RetryDelay, Certificate,
  Signature, Permissions, FragmentData, FragmentLast, Flags; error values
  include Unavailable, Busy, MaxTries, Authentication. Numeric values to be
  taken from the ADK headers in round 4.

### 2.5 Category numbers (`ci`, ADK)

0 bridged accessory, 1 other, 2 bridge, 3 fan, 4 garage door opener,
5 lighting, 6 lock, 7 outlet, 8 switch, 9 thermostat, 10 sensor,
11 security system, 12 door, 13 window, 14 window covering,
15 programmable switch, 16 range extender (obsolete), 17 IP camera,
19 air purifier, 20 heater, 21 air conditioner, 22 humidifier,
23 dehumidifier, 28 sprinkler, 29 faucet, 30 shower system. HomeKit's API
exposes categories as the UUID strings of `type-identifiers.md` §3; the
open implementation keeps a table from these numbers to those strings
(television, set-top box, streaming stick, audio receiver, speaker,
AirPort, Wi-Fi router and video doorbell numbers are not in the ADK enum;
take them from other permissively licensed HAP implementations, or observe
them with the HomeKit Accessory Simulator).

### 2.6 Setup payload

- Setup codes are 8 digits shown as `XXX-XX-XXX`; trivial codes are
  rejected (ADK has a validity check).
- The setup URL is `X-HM://` followed by 9 base-36 characters (a packed
  value carrying version, category, transport flags and the setup code)
  and a 4-character setup ID. Level 3: `HMAccessorySetupPayload` accepts
  exactly this length (13 characters after the scheme) and rejects shorter
  strings, other schemes and Matter `MT:` codes. Bit layout to be taken
  from the ADK's setup-payload code in round 4.
- The setup hash `sh` in the TXT record lets a controller match a scanned
  code to a discovered accessory.

### 2.7 BLE transport (later)

The ADK implements HAP over Bluetooth LE: GATT services per HAP service,
characteristic instance-ID descriptors, a PDU protocol (read, write,
signature read, timed write, execute write, configuration, protocol
configuration), broadcast notifications and disconnected events. Facts to
be collected in a later round; the Linux host side would use BlueZ.

## 3. Matter

- HomeKit is a Matter controller on Apple platforms. In the public API it
  shows as `HMAccessory.matterNodeID`, `HMService.matterEndpointID`,
  `HMHome.matterControllerID`, the two XPC-connection blocks on `HMHome`,
  and `HMAccessorySetupRequest.matterPayload` (an `MTRSetupPayload`). The
  runtime ships `Matter.framework` and `MatterSupport.framework`; homed
  vends `com.apple.matter.*` Mach services (level 2).
- The `MTR…` API of Matter.framework corresponds to connectedhomeip's
  Darwin framework (`src/darwin/Framework`, Apache-2.0). An open
  implementation can build the controller side from connectedhomeip on
  Linux (the SDK builds there) and simulated Matter devices from its
  example applications.
- Matter onboarding payloads are `MT:` QR strings and 11/21-digit manual
  codes; HomeKit's HAP setup-payload parser does not accept them (level 3).
- Matter devices appear to HomeKit apps as ordinary accessories with HAP
  service and characteristic types; the cluster-to-service translation is
  inside Apple's daemon and not observable without an account and a device.
  An open implementation needs its own mapping table (design work,
  `open-design.md` §5).

## 4. What we must not do

- Do not pair with, browse in detail, or control any accessory on the
  owner's network during probes (task rule). Probe logs record counts only.
- Do not implement MFi authentication (hardware or token) or claim
  certification.
- Do not ship specification text; cite the ADK file names instead.

## Evidence

Level 1: §1 (repository pages and license metadata; CSA PDF license
notices via search results), §2 (Apple HomeKit ADK source: service
discovery, IP accessory server, pair-setup, category enum, property flags),
§3 (connectedhomeip repository layout). Level 2: Matter Mach service names
(homed launchd plist). Level 3: setup-payload acceptance (§2.6), Matter
code rejection (§3). Level 4: Matter-related API names. Items marked
"to confirm" or "verify" are not yet evidenced. No level 5.
