# Spec: simulator networking beyond plain sockets

Status: **reference** (agent OBS-NET, 2026-10-27). It records, for the iOS
27.1 (24A94401) simulator runtime of Xcode 27.1, everything the guest's
networking depends on besides AF_INET/AF_INET6 sockets: the endpoints guest
processes use, what the guest sees of the network and where each part comes
from, how names are resolved, which parts each common use case needs, and
what Ycode must provide. It complements the host-passthrough socket work
(NET-IMPL) and `scdynamicstore-host.md`.

Every behavioral fact comes from black-box runs on a Mac (level 3): a
recorder of our own inserted into reference guest processes (look-ups, XPC
connections, socket calls and the bytes on the mDNSResponder, routing and
kernel-control sockets, `sysctl`, `ioctl`, notification names), a probe of
our own that calls public and documented interfaces inside the guest, and
denial runs in which the recorder made one dependency fail inside the guest
process. Wire formats are those of Apple open source (level 1:
mDNSResponder `dnssd_ipc.h`, xnu `route.h`, `route_private.h`, `netsrc.h`,
`sockio.h`, `if.h`, configd). Notes: `research/notes/obs-net-2026-10-27.md`.

Terms:

- **Host**: the machine the simulator runs on (in the reference, the Mac;
  in Ycode, the Linux host). **Guest**: processes of the simulated device.
- **Host kernel facility**: something the reference guest gets from the
  Mac's kernel directly, because guest processes are host processes.
  Ycode's guest kernel personality has to provide these itself.
- **Host-side endpoint**: a Mach name, socket path or file that leads to a
  host process.
- **Guest-side service**: a daemon of the runtime, started by
  `launchd_sim` (`launchd-sim.md`).
- **Primary interface**: the interface of the host's default route
  (in the observed runs an Ethernet interface named `en7`, index 10).

## 1. Answers in brief

1. The guest has **no DNS daemon of its own**. Every `libsystem_dnssd`
   client, which includes `getaddrinfo` and all of Network.framework (so
   URLSession, `nw_connection`, WebKit), talks to the **host's
   mDNSResponder over the UNIX socket `/var/run/mDNSResponder`**. This is
   the only host-side endpoint that ordinary guest networking uses.
2. The only host Mach service involved is
   `com.apple.SystemConfiguration.configd` (`configd_host`), used only by
   the guest's `configd_sim` to mirror the host's network keys
   (`scdynamicstore-host.md`). `configd_sim` then serves the guest's
   store, DNS configuration and network information.
3. Everything else the guest knows about the network comes from **kernel
   facilities**: the interface list, the routing table, a routing-socket
   query for the default route, interface `ioctl`s, and the
   `com.apple.netsrc` kernel control. The simulator's Network.framework
   makes **no NECP system calls**.
4. Certificate checks go to the guest's own **`trustd`**, which needs the
   network itself (OCSP).
5. Networking daemons that a device has but the runtime does not
   (nehelper, networkserviceproxy, CommCenter, symptomsd, networkd,
   nesessionmanager) are either never contacted or fail with "Connection
   invalid", and every client tolerates that.

## 2. Endpoints

### 2.1 Host-side endpoints and guest-side services

| Endpoint | Kind | Side | Used by (observed) | Needed for |
|---|---|---|---|---|
| `/var/run/mDNSResponder` | AF_UNIX stream socket at that host path | host (the host's mDNSResponder) | `getaddrinfo` (libsystem_info), Network.framework in every process (URLSession, `nw_connection`, WebKit Networking, nsurlsessiond, trustd, apsd, Safari Safe Browsing), libresolv's `dns_search` | every name resolution except `res_query` (§4) |
| `com.apple.SystemConfiguration.configd` = `…configd_host` | Mach (MIG `config`) | host | `configd_sim` only (SimulatorSupport plug-in) | the guest store's network keys, and through them the DNS configuration and network information (§3.3) |
| `com.apple.SystemConfiguration.PPPController` | Mach | host (registered) | nobody | nothing seen |
| `com.apple.SystemConfiguration.configd_sim` | Mach (MIG `config`, `configopen` 20000 then a session) | guest (`configd_sim`) | SystemConfiguration in CFNetwork and other clients (proxies, reachability, store reads) | none of the use cases of §5 |
| `com.apple.SystemConfiguration.DNSConfiguration_sim` | XPC | guest (`configd_sim`) | libsystem_configuration (`dns_configuration_copy`, used by libresolv) | `res_query`'s server list; it falls back to `/etc/resolv.conf` |
| `com.apple.SystemConfiguration.NetworkInformation_sim` | XPC | guest (`configd_sim`) | libsystem_configuration (network information state), MobileSafari | none of the use cases of §5 |
| `com.apple.trustd` | XPC | guest (`trustd`) | Security in every process that makes a TLS connection | HTTPS (§5) |
| `com.apple.nsurlsessiond` | XPC | guest | Foundation, for background URL sessions | background sessions only; not default or ephemeral sessions |
| `com.apple.cfnetwork.cfnetworkagent` | XPC | guest (job present) | not seen | nothing seen |
| `com.apple.nehelper` | XPC | absent | libsystem_networkextension (asks "app-tracker-check" for a signing identifier) | nothing: "Connection invalid", tolerated |
| `com.apple.networkserviceproxy` | XPC | absent | NetworkServiceProxy | nothing: "Connection invalid", tolerated |
| `com.apple.commcenter.coretelephony.xpc`, `com.apple.commcenter.carrierspace.xpc` | XPC | absent | Foundation clients (34 connections in one boot) | nothing: "Connection invalid", tolerated |
| `com.apple.dnssd.service`, networkd, symptomsd, `com.apple.usymptomsd`, nesessionmanager | — | absent | never contacted | nothing |

No network XPC connection is switched to the host with the libxpc
simulator-to-host mechanism (only the Metal and IOSurface services are).

### 2.2 Host kernel facilities the guest uses

| Facility | Used by | What it answers in the reference | Needed for |
|---|---|---|---|
| AF_INET/AF_INET6 TCP sockets, non-blocking `connect` (EINPROGRESS) | Network.framework, CFNetwork | the host stack | (b), (c) |
| Connected AF_INET UDP sockets | WebKit Networking (QUIC, HTTP/3) | the host stack | (c) when the site offers HTTP/3 |
| Unconnected UDP `bind` + `sendto` to port 53 | libresolv `res_query` | the host stack | `res_query` only |
| AF_UNIX `connect` and SCM_RIGHTS passing on `/var/run/mDNSResponder` | libsystem_dnssd | §4.2 | (a), (b), (c) |
| PF_ROUTE raw socket: `RTM_GET_SILENT` for the default route | Network.framework path evaluation | §3.6 | (b), (c), (d) |
| `sysctl` `CTL_NET`/`PF_ROUTE` `NET_RT_IFLIST` (interface list, `getifaddrs`), `NET_RT_DUMP`, `NET_RT_DUMP2`, `NET_RT_IFLIST` for one AF_LINK index | libsystem_info, Network.framework, SystemConfiguration, other daemons | the host's interfaces and routes, unchanged | the interface list of a path (§3.6); not required for satisfied |
| Interface `ioctl`s on an AF_INET datagram socket: SIOCGIFFLAGS, SIOCGIFMTU, SIOCGIFEXPENSIVE, SIOCGIFCONSTRAINED, SIOCGIFULTRACONSTRAINED, SIOCGIFLINKQUALITYMETRIC, SIOCGIFFUNCTIONALTYPE, SIOCGIFDELEGATE; elsewhere also SIOCGIFEFLAGS, SIOCGIFTYPE, SIOCGIFMEDIA, SIOCGIFXMEDIA, SIOCGIFALTMTU | Network.framework (per path evaluation), configd_sim, SystemConfiguration, CoreUtils | the host interface's values | the interface type of a path (without them it is "other") |
| SIOCGCONNINFO on connected TCP sockets | Network.framework | connection information | not tested |
| Kernel control `com.apple.netsrc` (AF_SYSTEM datagram socket, CTLIOCGINFO, `connect`, version-2 request and reply) | `getaddrinfo`, Network.framework | §3.7 | not required (denied: everything still worked) |
| NECP system calls | — | never called by any guest process | nothing |

### 2.3 Notifications (guest notifyd)

`configd_sim` posts, when its state is built or changes:
`com.apple.system.SystemConfiguration.nwi`,
`com.apple.system.config.network_change`,
`com.apple.system.config.network_change.nwi`,
`com.apple.system.config.network_change.dns`,
`com.apple.system.config.proxy_change`,
`com.apple.system.SystemConfiguration.dns_configuration`.
Clients register for these and for `com.apple.system.networkd.settings`,
`com.apple.neconfigurationchanged`, `com.apple.system.dns`,
`com.apple.system.dns.delay` and `com.apple.system.dns.resolver.dir`,
which nobody was seen to post.

## 3. What the guest sees

### 3.1 Interfaces

`getifaddrs` returns the host's complete interface list unchanged: every
interface (loopback, Ethernet, Wi-Fi, bridges, tunnels, virtual-machine
interfaces), each with its AF_LINK entry (interface type 6 for
Ethernet-like, 0x18 for loopback, 1 for tunnels), its flags as the host
kernel reports them (UP, BROADCAST, NOTRAILERS, RUNNING, SIMPLEX,
MULTICAST and so on) and its IPv4 and IPv6 addresses, netmasks and
broadcast or destination addresses. `if_nameindex` returns the host's
names and indices. The guest has no interface of its own.

### 3.2 Routing table

A routing-table dump (`NET_RT_DUMP`) returns the host's IPv4 and IPv6
tables unchanged, in the host kernel's format (including the embedded
scope in IPv6 link-local destinations and the interface-scoped default
routes of secondary interfaces).

### 3.3 The guest's dynamic store

The guest store (served by `configd_sim`) holds the host's network keys:

| Key pattern | Observed content |
|---|---|
| `Plugin:InterfaceNamer` | start, stack and quiet timestamps, one timestamp per named interface |
| `Setup:/Network/Global/IPv4` | `ServiceOrder`: the host's service IDs |
| `Setup:/Network/Service/<id>`, `…/Interface`, `…/IPv4`, `…/IPv6`, `…/Proxies` | the host's configured services |
| `Setup:/Network/Interface/<if>/AirPort` | Wi-Fi settings entity |
| `State:/Network/Global/IPv4` | `PrimaryInterface` (name), `PrimaryService` (ID), `Router` (address) |
| `State:/Network/Global/DNS` | `SearchDomains`, `ServerAddresses`, `__CONFIGURATION_ID__` ("Default: <service id> 0"), `__FLAGS__` 2, `__IF_INDEX__` (primary interface index), `__ORDER__` 0 |
| `State:/Network/Global/Proxies` | `ExceptionsList` ["*.local", "169.254/16"], `FTPPassive` 1, `__SCOPED__` with the same two keys per active interface (no proxy configured) |
| `State:/Network/Interface/<if>/Link`, `LinkQuality`, `IPv4`, `IPv6`, `AirPort`, `CaptiveNetwork` | per-interface state |
| `State:/Network/Service/<id>`, `…/IPv4`, `…/IPv6`, `…/DNS`, `…/DHCP` | per-service state |
| `State:/Network/MulticastDNS` | ["local", "254.169.in-addr.arpa", "8.e.f.ip6.arpa", "9.e.f.ip6.arpa", "a.e.f.ip6.arpa", "b.e.f.ip6.arpa"] |
| `State:/Network/PrivateDNS` | [] |

The host's store has the same network keys; the guest store has no other
host keys. (Two `com.apple.sharing` keys in the guest store are written by
guest processes.)

### 3.4 DNS configuration

`dns_configuration_copy` (from `DNSConfiguration_sim`; configuration
version 20170629):

| Resolver | Domain | Interface | Flags | Reach | Order | Timeout | Options | Servers |
|---|---|---|---|---|---|---|---|---|
| default #0 | — | primary (index, name) | 0x2 | 0x2 | 0 | 0 | — | the host's DNS servers; search list = `SearchDomains` |
| #1–#6 | each `State:/Network/MulticastDNS` domain | 0 | 0x2 | 0 | 300000, 300200, … (step 200) | 5 | "mdns" | none |
| scoped, one per active interface | — | that interface | 0x1002 | 0x2 | 0 | 0 | — | that interface's DNS servers |

No service-specific resolvers. `res_ninit` gives the default resolver's
servers and search list.

### 3.5 Proxies and reachability

`CFNetworkCopySystemProxySettings` returns the value of
`State:/Network/Global/Proxies`. `SCNetworkReachability` flags were 0x2
(reachable) for a host name, for 0.0.0.0 and for ::.

### 3.6 Path status (`nw_path`, `NWPathMonitor`)

With the host online, the first update arrives within milliseconds and
says: status **satisfied**; one interface, the **primary interface only**,
with its host name and index and type wired (Ethernet) or Wi-Fi as the
host interface is; not expensive, not constrained; **`has_ipv4`,
`has_ipv6` and `has_dns` all false**; no gateways. This is less than the
same API reports in a host (Mac) process for the same network
(`has_ipv4` and `has_dns` true, every active interface, the gateway): the
simulator's Network.framework evaluates paths without NECP, from these
inputs:

1. **Default route query** on a PF_ROUTE raw socket: a `RTM_GET_SILENT`
   message (type 0x11, version 5, 128 bytes; flags 0x807 (UP, GATEWAY,
   HOST, STATIC); addrs DST and IFP;
   destination AF_INET 0.0.0.0; an empty AF_LINK address for IFP). The
   kernel answers with an `RTM_GET` message (type 4, version 5, 164
   bytes): the primary interface's index, flags 0x40010843 (UP, GATEWAY,
   DONE, STATIC, PRCLONING, GLOBAL), addrs DST,
   GATEWAY, NETMASK, IFP and IFA; MTU; destination 0.0.0.0, the gateway
   address, an empty netmask, the interface's AF_LINK address (index, type
   6, name, hardware address) and the interface's IPv4 address. Without
   a routing socket the path is **unsatisfied** and URLSession fails with
   -1009 ("The Internet connection appears to be offline.").
2. **The interface list** (`NET_RT_IFLIST`). Without it the path is still
   satisfied but lists no interface.
3. **Interface `ioctl`s** on the primary interface (§2.2). The interface
   type comes from them (SIOCGIFFUNCTIONALTYPE: wired = 2, Wi-Fi
   infrastructure = 3, cellular = 5, loopback = 1); without them the type
   is "other", expensive and constrained come from SIOCGIFEXPENSIVE and
   SIOCGIFCONSTRAINED.
4. Notification `com.apple.system.SystemConfiguration.nwi` for changes.

The NWI state (`NetworkInformation_sim`) and the store were not needed for
a satisfied path.

### 3.7 Source-address selection (`com.apple.netsrc`)

Before connecting, `getaddrinfo` (to sort results) and Network.framework
open the kernel control named `com.apple.netsrc`, and send one 36-byte
request per candidate destination: version 2, interface scope 0, the
destination socket address (with the port). Each 56-byte reply holds: the
source address the kernel would use, minimum RTT, connection attempts and
successes for that route, flags (observed: ROUTEABLE 0x20), label and
precedence of source and destination (observed 4 and 0x23 for IPv4
destinations), and the interface index. Layouts: xnu `netsrc.h`. Without
the kernel control, resolution and fetches still worked.

### 3.8 Where each part comes from

| What | Source in the reference |
|---|---|
| Interfaces, addresses, flags, indices | host kernel |
| Routing table, default-route answer | host kernel |
| Interface type, MTU, expensive, constrained | host kernel (interface `ioctl`s) |
| Source address, route statistics | host kernel (`com.apple.netsrc`) |
| Store keys (`State:/Network/…`, `Setup:/Network/…`) | host configd, mirrored by the guest's `configd_sim` |
| DNS configuration, NWI state, notifications | the guest's `configd_sim`, built from the mirrored keys |
| Proxy settings | the mirrored `State:/Network/Global/Proxies` |
| Name resolution | the host's mDNSResponder (§4) |
| `/etc/resolv.conf` (fallback of `res_query`) | the host's file |
| Certificate trust | the guest's `trustd` (which uses the network) |

## 4. DNS

### 4.1 Paths

| Interface | Path | Request types |
|---|---|---|
| `getaddrinfo` | dnssd over `/var/run/mDNSResponder` | `connection_request`, then two `query_request` on the shared connection (type A, then AAAA), `cancel_request` for each when done |
| Network.framework (URLSession default and ephemeral sessions, `nw_connection`, WebKit Networking for Safari, daemons) | dnssd over `/var/run/mDNSResponder` | `connection_request`, then one `addrinfo_request` per host name (both families) |
| libresolv `dns_search` / `DNSServiceQueryRecord` | dnssd over `/var/run/mDNSResponder` | a `query_request` on its own connection |
| libresolv `res_query` | direct UDP to port 53 of the first server of the DNS configuration (§3.4), from a newly bound ephemeral port; if the DNS configuration is unavailable, the servers of `/etc/resolv.conf` | standard DNS |
| `com.apple.dnssd.service` (XPC) | not used | — |
| DNS over HTTPS/TLS | not used (no private-DNS configuration; URLSession metrics report the resolution protocol as unknown) | — |

### 4.2 dnssd wire format (as observed)

The protocol is that of open-source mDNSResponder (`dnssd_ipc.h`); the
observed use:

- **Header**, 28 bytes, network byte order: version (1), data length,
  IPC flags, operation, 8-byte client context, record index.
- **Operations seen**: 1 `connection_request`, 8 `query_request`,
  15 `addrinfo_request`, 63 `cancel_request`; replies 68 `query_reply_op`
  and 72 `addrinfo_reply_op`.
- **`connection_request`** has no body; the server answers on the same
  socket with a 4-byte error code (0).
- **Subordinate requests** (contexts 1, 2, … on the shared connection):
  the body starts with an empty control-path string (one zero byte); each
  request is followed by a 1-byte `sendmsg` that carries a socket
  descriptor (SCM_RIGHTS) for the request's error return.
- **`query_request` from `getaddrinfo`**: IPC flags 0x2 (trailing TLVs);
  body: flags 0x0001D000 (Timeout, SuppressUnusable, ShareConnection,
  ReturnIntermediates), interface index 0, the name, record type, class
  IN, then TLVs 3 (AAAA policy, value 0), 4 (failover policy, value 1)
  and 6 (validation policy).
- **`addrinfo_request` from Network.framework**: IPC flags 0; body: flags
  0xC000D000 (AllowExpiredAnswers, the 0x40000000 private flag,
  SuppressUnusable, ShareConnection, ReturnIntermediates), interface index
  0, protocol 0 (IPv4 and IPv6), the name.
- **Replies** (header with the request's context, then): flags (Add,
  MoreComing, and 0x40000000 "answered from cache" when so), interface
  index, error code, the fully qualified name, record type, class, data
  length, data, TTL. With no routable IPv6 on the host, AAAA is answered
  with error -65554 (NoSuchRecord) because SuppressUnusable is set, and
  `getaddrinfo` returns only IPv4 addresses.
- `getaddrinfo` fails at once with EAI_NONAME (8) and URLSession with
  -1003 when the socket cannot be connected.

## 5. Minimal set per use case

Found by denying one dependency at a time inside the client process (the
probe, or Safari and its WebKit extensions), with everything else as in a
normal boot.

| Use case | Required | Not required (denied, still worked) |
|---|---|---|
| (a) `getaddrinfo` | `/var/run/mDNSResponder` (dnssd: `connection_request`, `query_request`, `cancel_request`) | `configd_sim`, `DNSConfiguration_sim`, `NetworkInformation_sim`, routing socket, `com.apple.netsrc`, interface `ioctl`s, routing sysctls |
| (b) URLSession HTTPS fetch | `/var/run/mDNSResponder` (`addrinfo_request`); a PF_ROUTE socket answering the default-route query (else -1009); `com.apple.trustd` (else -1202); TCP sockets | the three `configd_sim` services, `com.apple.netsrc`, interface `ioctl`s, routing sysctls, nsurlsessiond (ephemeral and default sessions) |
| (c) Safari loading a page | as (b), in the WebKit Networking extension; connected UDP sockets for HTTP/3 where the site offers it (TCP is raced and works too) | the three `configd_sim` services (QUIC connection and page display still worked; that run's main document came from WebKit's cache) |
| (d) `NWPathMonitor` satisfied | a PF_ROUTE socket answering the default-route query | mDNSResponder, the three `configd_sim` services, `com.apple.netsrc`; interface `ioctl`s (type becomes "other") and routing sysctls (no interface listed) only change the details |
| `res_query` | UDP to the DNS servers; servers from `DNSConfiguration_sim` or `/etc/resolv.conf` | mDNSResponder |

`trustd` itself fetches OCSP responses over the network (it resolves and
connects like any client), so HTTPS needs (a)–(b) to work inside `trustd`
too; with stapled OCSP responses (as with the sites used here) the
evaluation succeeded.

## 6. IPv6, VPN, proxies and network conditioning

- **IPv6**: the guest sees exactly the host's IPv6 addresses and routes.
  On a host without routable IPv6, mDNSResponder suppresses AAAA answers
  (SuppressUnusable) and paths report no IPv6. Behavior on an IPv6-capable
  host was not observed.
- **VPN**: host tunnel interfaces (`utun*`) appear in the guest unchanged.
  No VPN was active on the host. The guest has no Network Extension
  daemons (`nehelper` and `nesessionmanager` are absent), so a guest
  cannot configure a VPN; host VPNs apply to guest traffic because the
  traffic is the host's.
- **Proxies**: the guest's proxy settings are the host's
  `State:/Network/Global/Proxies`, mirrored. No proxy was configured on
  the host, so proxy use was not observed.
- **Network conditioning**: `simctl` has no network-conditioning command
  (its `status_bar` overrides only change the displayed Wi-Fi and cellular
  indicators). Xcode's device-conditions feature is for connected devices.
  A host-wide conditioner would affect guest traffic because the guest
  uses the host stack; not tested.

## 7. What Ycode must do (beyond plain sockets)

1. **dnssd responder at `/var/run/mDNSResponder`.** Guest processes
   connect to that literal path. Ycode's guest kernel must route a guest
   AF_UNIX `connect` to that path to Ycode's dnssd responder (NET-IMPL),
   with SCM_RIGHTS descriptor passing and the 1-byte-payload `sendmsg`
   per request (§4.2). The responder must implement at least
   `connection_request` (4-byte error reply), `query_request` (with the
   trailing TLVs 3, 4 and 6 accepted), `addrinfo_request` (protocol 0 =
   both families), `cancel_request`, the error return on the passed
   descriptor, `query_reply_op` and `addrinfo_reply_op`. It should honor
   SuppressUnusable (answer AAAA with NoSuchRecord when the host has no
   routable IPv6) so that clients do not try unusable addresses. No XPC
   `com.apple.dnssd.service` is needed.
2. **Default-route answer on a PF_ROUTE socket.** Implement
   `socket(PF_ROUTE, SOCK_RAW, …)` and answer an `RTM_GET_SILENT` (and
   `RTM_GET`) for 0.0.0.0 (and, for IPv6 parity, ::) with an `RTM_GET`
   reply in the host kernel layout of §3.6, built from the Linux host's
   default route: index of the primary interface, flags as in §3.6 (an
   interface-scoped route of a secondary interface also has IFSCOPE),
   the gateway, the interface's
   AF_LINK address and its IPv4 address, MTU. This alone decides whether
   paths are satisfied and whether URLSession thinks it is online.
   Answer "no route" when the host has none, so the guest sees offline.
3. **Interface list and routing sysctls.** `NET_RT_IFLIST` (and
   `NET_RT_IFLIST2`), `NET_RT_DUMP`, `NET_RT_DUMP2` in the Darwin layouts,
   built from the Linux host's interfaces and routes, so that
   `getifaddrs`, `if_nameindex` and the path's interface list work.
4. **Interface `ioctl`s** of §2.2 on AF_INET datagram sockets: flags, MTU,
   functional type (wired for Ethernet, Wi-Fi infrastructure for wireless,
   loopback for the loopback interface), expensive 0, constrained 0,
   ultra-constrained 0, link-quality metric, delegate 0, extended flags,
   interface type, media; and SIOCGCONNINFO on connected TCP sockets.
   Unknown requests should fail with an error rather than crash; a wrong
   or missing functional type only changes the reported interface type.
5. **Consistent interface identity.** The same names and indices must
   appear in `getifaddrs`, `if_nameindex`, the routing replies, the
   `ioctl`s, `com.apple.netsrc` replies, the DNS configuration and the
   store keys (`PrimaryInterface`, `__IF_INDEX__`,
   `State:/Network/Interface/<if>/…`). The reference shows the host's own
   names; Ycode may present the Linux host's interfaces under Darwin-style
   names (for example `lo0` and `en0` for the primary), as long as every
   view agrees.
6. **`com.apple.netsrc` kernel control** (optional for function, needed
   for parity): CTLIOCGINFO by name, `connect`, and the version-2
   request/reply of §3.7 with the source address the Linux host would use
   and the interface index (RTT and counters may be 0). Without it, fail
   the CTLIOCGINFO lookup cleanly; the guest copes.
7. **Host store values for `configd_sim`.** Ycode's host SCDynamicStore
   (`scdynamicstore-host.md`) is empty today, so `configd_sim` builds an
   empty DNS configuration and NWI state. For parity, serve the network
   keys of §3.3 from the Linux host's configuration (at least
   `Setup:/Network/Global/IPv4` with a service order, per-service
   `Setup:` `Interface` and `IPv4`, `State:/Network/Service/<id>/IPv4` and
   `…/DNS`, `State:/Network/Interface/<if>/Link` and `IPv4`,
   `State:/Network/Global/IPv4`, `…/DNS`, `…/Proxies`,
   `State:/Network/MulticastDNS`, `State:/Network/PrivateDNS`,
   `Plugin:InterfaceNamer`), answer `configget_m` for the plug-in's keys
   and patterns, and send the change notification when they change. This
   is not required for (a)–(d) but gives `res_query`, proxy settings,
   reachability and `dns_configuration_copy` their host values.
8. **`/etc/resolv.conf`** visible to the guest at that path with the host's
   servers (libresolv's fallback).
9. **No NECP.** The guest makes no NECP system calls; nothing to provide.
10. **`trustd` needs the network.** Guest `trustd` resolves and connects
    like any client (OCSP); no host trust service is involved.
11. **Absent services stay absent.** `com.apple.nehelper`,
    `com.apple.networkserviceproxy`, CommCenter's services and the other
    names of §2.1 marked absent must keep failing as in the reference
    (look-up 1102, XPC "Connection invalid"); clients tolerate it.
12. **QUIC.** Connected UDP sockets with `send`/`recv` (and the message
    variants) must work for Safari's HTTP/3; TCP fallback also works.

## 8. Open questions

1. Whether `configd_sim`'s IPMonitor computes `State:/Network/Global/*`
   and the DNS configuration from the mirrored service keys, or the
   global keys are mirrored as they are; which minimal key set gives a
   correct DNS configuration and NWI state.
2. What `SCNetworkReachability` flags are without the host store values
   and without NWI state (not tested with denials).
3. Path and resolution behavior on an IPv6-capable host, with a proxy or
   PAC file configured, and with a VPN active on the host.
4. Path updates when the host's network changes (interface down, primary
   change): which routing-socket messages Network.framework listens for
   (it keeps the routing socket open) and which notifications it needs.
5. The value of TLV 6 in `getaddrinfo`'s queries and the error-return
   protocol on the passed descriptor (taken from open source, not
   observed byte for byte).
6. Whether WebKit needs anything more for a page that is not in its disk
   cache when the `configd_sim` services are unavailable (the denial run
   showed a cached page; the connection itself was set up).

## Evidence

| Claim | Level | Source |
|---|---|---|
| The runtime has no mDNSResponder, networkd, symptomsd, nehelper, nesessionmanager or networkserviceproxy job; `configd_sim` MachServices and plug-ins | 2 | the runtime's launchd plists and `System/Library/SystemConfiguration` bundle names |
| Service names to watch | 4 | string search of the runtime's shared cache for service names (names only) |
| Endpoints used, by which process, with which result (§2.1); no sim-to-host network XPC | 3 | our recorder's look-up, XPC, socket and `xpc_connection_enable_sim2host_4sim` hooks in every guest process, boots b1 and b3 |
| `/var/run/mDNSResponder` is the host's socket and the only dnssd path | 3 | recorder (`connect` and `connect$NOCANCEL` with the path), the host's socket file |
| No NECP system calls | 3 | recorder hooks on the five `necp_*` calls, about 400 processes, boots b1 and b3 |
| Kernel facilities and their use (§2.2, §3.6, §3.7) | 3 | recorder (`socket`, `ioctl`, `sysctl`, routing and kernel-control bytes), probe runs p1–p4, r-path, r-gai, r-fetch |
| `ioctl` names, routing message types and layouts, netsrc layouts, functional-type values | 1 | xnu `sockio.h`, `sockio_private.h`, `route.h`, `route_private.h`, `netsrc.h`, `if_private.h` |
| Notifications (§2.3) | 3 | recorder `notify_*` hooks |
| Interfaces, routes, store, DNS configuration, proxies, reachability, path (§3) | 3 | our probe in the guest (public APIs; `SCDynamicStore` and `dns_configuration_copy` shapes from open-source configd), compared with the host's `scutil`, `ifconfig`, `netstat` output and with the same probe built for macOS |
| dnssd operations, flags, TLVs and replies (§4.2) | 3, 1 | recorder byte dumps on the mDNSResponder socket; meaning from mDNSResponder `dnssd_ipc.h` and the SDK's `dns_sd.h` |
| `res_query` direct UDP and its fallback | 3 | recorder (`bind`, `sendto` to port 53) with and without `DNSConfiguration_sim` |
| Minimal sets (§5) | 3 | denial matrix in the probe (11 denials × `getaddrinfo`, URLSession, path monitor), Safari boots b3 (normal) and b4 (`configd_sim` services denied in Safari and WebKit), guest unified log of the WebKit Networking extension |
| trustd request and reply keys; OCSP fetches by `trustd` | 3 | recorder XPC dumps; recorder in `trustd` (boot b1) |
| Safari uses QUIC/HTTP/3 in the WebKit Networking extension; WebContent does no networking | 3 | recorder (connected UDP socket, TCP race) and the guest's unified log |
| Network conditioning (§6) | 3, 4 | `simctl help`; string search of the Simulator app and Xcode frameworks for feature names |

Level 5 (disassembly or decompilation) was not used.
