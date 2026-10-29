# Spec: Ycode's guest networking (host passthrough)

Status: **implemented** (agent NET-IMPL, 2026-10-27). Ycode's design for
the networking of the simulated device: guest processes reach the network
through the host's own network stack, as the processes of Apple's
simulator use the Mac's. The reference behavior Ycode follows is
`networking.md` (agent OBS-NET); this spec says how Ycode provides it.

Code: `ycode/Sources/YcodeDarwinKernel/Descriptors/` (`InetSocket*.swift`,
`HostSocketPoller.swift`, `NetworkInterfaces.swift`, `RouteSocket.swift`,
`SocketEvents.swift`, `KernelControl.swift`, `DNSServiceServer.swift`,
`HostResolver.swift`),
`Select.swift` (poll), `KEvent.swift` (EVFILT_SOCK),
`ycode/Sources/YcodeHostServices/SCDynamicStoreNetworkState.swift`.
Guest probes: `ycode/SimShim/guest-tests/net/` (`build-net.sh`).

## 1. Model

- A guest IP socket **is** a host socket of the same family, type and
  protocol, opened by `ycode-simd` (non-blocking, close-on-exec). Its
  traffic is the host's traffic: addresses, routes, firewall, VPN and DNS
  are the host's. Nothing is translated at the packet level (no NAT, no
  user-space TCP/IP stack).
- What the guest sees of the network (interfaces, routes, interface
  `ioctl`s, the routing socket, the dynamic store) is a **model built
  from the host** (§3), with Darwin names and layouts.
- Names are resolved by an **in-VMM dnssd responder** at the guest path
  `/var/run/mDNSResponder` that asks the host's resolver (§4).
- `YCODE_NO_NETWORK=1` turns all of it off: `socket(AF_INET/AF_INET6/
  PF_ROUTE)` fails with EAFNOSUPPORT, the mDNSResponder path is not
  served, the host store is empty (the behavior before this work).

## 2. IP sockets

### 2.1 Calls

| Call | Behavior |
|---|---|
| `socket` (97), `socket_delegate` (450) | AF_INET/AF_INET6 × SOCK_STREAM (protocol 0/TCP), SOCK_DGRAM (0/UDP/ICMP/ICMPv6), SOCK_RAW (passed to the host; an unprivileged host refuses: EPERM/EACCES). Another type: EPROTOTYPE; a protocol that does not fit: EPROTONOSUPPORT. An AF_INET6 socket is dual-stack (IPV6_V6ONLY 0, Darwin's default; the host is told explicitly). `socketpair` of an IP domain: EOPNOTSUPP |
| `bind` (104) | the host's `bind`; the address the host chose is kept for a restore (§6). A family-0 `sockaddr_in` counts as AF_INET (old binaries). Ports below 1024 need the host's permission (EACCES otherwise; Darwin allows them) |
| `listen` (106), `accept` (30/404) | the host's; `accept` waits (§2.4) unless non-blocking; the new descriptor inherits the listener's O_NONBLOCK (xnu); ECONNABORTED from the host is retried |
| `connect` (98/409) | datagram: sets or (AF_UNSPEC) clears the default destination. Stream: the host's non-blocking `connect`; EINPROGRESS for a non-blocking descriptor, else the call waits until it completes and returns its error. A second call while it runs: EALREADY; once connected: EISCONN |
| `connectx` (447) | `sa_endpoints_t` (srcif, srcaddr, dstaddr): binds to the interface and source when given, then connects. With CONNECT_RESUME_ON_READ_WRITE the call returns 0 at once (xnu completes it on the first read or write; Ycode starts the host connect at once). Initial data in the iovec is sent if the connection is already up; `*len` says how much. `*connid` = 1 |
| `disconnectx` (448) | shutdown of both directions |
| `send`/`sendto`/`sendmsg` (133, 28), `write`/`writev` | the host's `sendmsg` with MSG_DONTWAIT and MSG_NOSIGNAL; a blocking stream send loops until every byte is sent (or the send timeout passes, returning the partial count). EPIPE raises SIGPIPE in the guest thread unless SO_NOSIGPIPE, MSG_NOSIGNAL or F_SETNOSIGPIPE |
| `recv`/`recvfrom`/`recvmsg` (29, 27), `read`/`readv` | the host's `recvmsg`; MSG_WAITALL is done by the kernel; a datagram longer than the buffer sets MSG_TRUNC (and returns the bytes copied); a stream at its end returns 0 |
| `sendmsg_x`, `recvmsg_x` (481, 480) | each `msghdr_x` (56 bytes: a `msghdr` + `msg_datalen`) in turn; after the first, only what does not block; the count done is returned |
| `shutdown` (134) | the host's; ENOTCONN when not connected |
| `getsockname`, `getpeername` (32, 31) | the host's, converted (§2.2) |
| `setsockopt`, `getsockopt` (105, 118) | §2.3 |
| `ioctl` FIONBIO, FIONREAD, SIOCATMARK, interface requests (§3.2) | FIONREAD = the host's queued byte count (0 for a listener) |
| `fcntl` F_SETFL O_NONBLOCK, F_SETNOSIGPIPE | as for any descriptor; the host socket stays non-blocking |
| `fstat` | S_IFSOCK; `st_size` = bytes queued |

### 2.2 Translations

- **Addresses.** Darwin `sockaddr_in` (16 bytes) and `sockaddr_in6` (28)
  carry `sa_len` and a one-byte family (AF_INET 2, AF_INET6 30); Linux's
  carry a two-byte family (AF_INET 2, AF_INET6 10). The kernel converts
  both ways. `sin6_scope_id` is an interface index: guest indexes (§3.1)
  and host indexes are mapped.
- **errno.** Linux's networking errno values differ from Darwin's
  (EAGAIN 11 → 35, EINPROGRESS 115 → 36, EALREADY 114 → 37, ECONNREFUSED
  111 → 61, ECONNRESET 104 → 54, EADDRINUSE 98 → 48, EADDRNOTAVAIL 99 →
  49, ENETUNREACH 101 → 51, EHOSTUNREACH 113 → 65, ETIMEDOUT 110 → 60,
  EOPNOTSUPP 95 → 102 for sockets, and so on); every host result is
  translated (`SocketErrno.fromHost`).
- **Message flags.** MSG_OOB, PEEK, DONTROUTE and EOR are passed; WAITALL
  and DONTWAIT are applied by the kernel; MSG_TRUNC and MSG_CTRUNC come
  back translated.
- **Ancillary data.** Darwin `cmsghdr` is 12 bytes with 4-byte alignment;
  Linux's is 16 with 8. Received: SCM_TIMESTAMP (timeval re-laid),
  IP_PKTINFO (to IP_PKTINFO 26, IP_RECVDSTADDR and IP_RECVIF as asked),
  IP_TTL (int → IP_RECVTTL u_char), IP_TOS (→ IP_RECVTOS), IPV6_PKTINFO,
  IPV6_HOPLIMIT, IPV6_TCLASS, IPV6_PATHMTU, interface indexes mapped. Sent:
  IP_PKTINFO, IP_TOS, IP_TTL, IPV6_PKTINFO, IPV6_TCLASS, IPV6_HOPLIMIT,
  IPV6_DONTFRAG; SCM_RIGHTS on an IP socket: EINVAL; others are dropped.

### 2.3 Socket options

| Darwin option | Ycode |
|---|---|
| SO_NOSIGPIPE, SO_SNDTIMEO, SO_RCVTIMEO | kept by the kernel (timeouts bound the kernel's waits) |
| SO_TYPE, SO_ERROR, SO_NREAD, SO_NWRITE, SO_ACCEPTCONN | answered by the kernel (get only; a set is ENOPROTOOPT). SO_ERROR reports a pending error once (a failed non-blocking connect, a restore reset) |
| SO_SNDBUF, SO_RCVBUF | passed to the host; a get answers the value set (Linux doubles it), else half the host's |
| SO_REUSEADDR, SO_REUSEPORT, SO_KEEPALIVE, SO_BROADCAST, SO_DONTROUTE, SO_OOBINLINE, SO_DEBUG, SO_TIMESTAMP, SO_RCVLOWAT | the host's option of the same meaning |
| SO_LINGER (ticks, hz 100), SO_LINGER_SEC | the host's SO_LINGER in seconds; a lingering close happens off the kernel lock |
| IP_TOS, IP_TTL, IP_HDRINCL, IP_OPTIONS, IP_MULTICAST_IF/TTL/LOOP, IP_ADD/DROP_MEMBERSHIP (+ source variants), IP_RECVTTL, IP_RECVTOS | the host's (indexes mapped; u_char values accepted and answered as one byte) |
| IP_DONTFRAG | the host's IP_MTU_DISCOVER (DO / DONT) |
| IP_RECVDSTADDR, IP_RECVPKTINFO, IP_RECVIF | the host's IP_PKTINFO, translated on receive (§2.2) |
| IP_BOUND_IF, IPV6_BOUND_IF | the host's SO_BINDTOIFINDEX with the host index; without the privilege the binding is kept by the kernel only (the host routes by its table) |
| IP_MULTICAST_IFINDEX | the host's IP_MULTICAST_IF with an `ip_mreqn` |
| IPV6_V6ONLY, UNICAST/MULTICAST_HOPS, MULTICAST_IF/LOOP, JOIN/LEAVE_GROUP, CHECKSUM, RECVPKTINFO/PKTINFO, RECVHOPLIMIT/HOPLIMIT, RECVTCLASS/TCLASS, DONTFRAG, RECVPATHMTU/PATHMTU | the host's (RFC 3542 numbers differ between the systems) |
| TCP_NODELAY, TCP_MAXSEG, TCP_KEEPALIVE (idle), TCP_KEEPINTVL, TCP_KEEPCNT, TCP_NOTSENT_LOWAT | the host's |
| TCP_RXT_CONNDROPTIME | the host's TCP_USER_TIMEOUT (seconds → ms) |
| TCP_CONNECTION_INFO | built from the host's TCP_INFO (state, scales, options, RTO, MSS, ssthresh, cwnd in bytes, RTTs in ms, packet and byte counts) |
| Every other option at SOL_SOCKET, IPPROTO_IP, IPPROTO_IPV6, IPPROTO_TCP, IPPROTO_UDP (Darwin-only ones: SO_NET_SERVICE_TYPE, SO_TRAFFIC_CLASS, SO_NECP_*, TCP_NOPUSH, TCP_CONNECTIONTIMEOUT, TCP_FASTOPEN, private TCP options…), and a host option the host refuses with ENOPROTOOPT/EOPNOTSUPP | kept by the kernel: stored on set, read back on get (0 when never set) |

### 2.4 Blocking, readiness and the poller

A host socket never blocks. A guest call that must wait (accept, a
blocking connect, send with a full buffer, receive with nothing queued)
waits on the socket's `ObjectSignals` with the kernel lock released, as on
a pipe; a signal interrupts it (EINTR), SO_RCVTIMEO/SO_SNDTIMEO end it
(EAGAIN).

One host thread (`ycode-host-sockets`) waits in `epoll_wait` (a Darwin
host: `kevent`) on every host socket that has had a waiter or an
observer, registered edge-triggered for input, output and peer hang-up.
On an event it takes the socket's kernel lock and fires the socket's
signals, which wakes its waiters and makes kevent re-check its knotes and
select/poll re-scan. Sockets nobody has waited on are not registered; no
code path polls in a loop. epoll is reached through the C library's
symbols (Swift's Glibc module does not import `sys/epoll.h`).

Readiness (kevent EVFILT_READ/WRITE, select, poll) is read from the host
socket each time (`poll` with a zero timeout, FIONREAD, SIOCOUTQ):

- read: bytes ≥ SO_RCVLOWAT, end of stream (peer's FIN, also POLLRDHUP),
  an error, or a pending connection on a listener (data 1); EOF = the
  read side is closed.
- write: POLLOUT, hang-up or error; a stream socket that is not
  connected is not writable; a pending connect becomes connected (or its
  error pending) when the host says so. Data = SO_SNDBUF − unsent bytes.

`poll` (230, and `poll_nocancel` 417), unimplemented before (ENOSYS), is
implemented over the same readiness for every descriptor: POLLIN/
POLLRDNORM, POLLOUT/POLLWRBAND, POLLHUP at end of file, POLLNVAL for a
descriptor that is not open, negative descriptors skipped, host files
and the console always ready; it waits like select (observers, no
polling).

### 2.5 EVFILT_SOCK

Network.framework registers EVFILT_SOCK (-13) on every TCP connection and
uses it only after NOTE_CONNECTED. Ycode implements it for IP and local
sockets (xnu `filt_sockev_common` semantics): events NOTE_CONNECTED,
NOTE_DISCONNECTED, NOTE_READCLOSED, NOTE_WRITECLOSED (level events:
reported once until the knote's interest in them changes) and
NOTE_CONNRESET, masked by the knote's interest (`fflags`); data = the
pending socket error (with EV_EOF), else SOCKEV_CONNECTED (1) |
SOCKEV_DISCONNECTED (2); EV_EOF also for a closed direction. NOTE_TIMEOUT,
NOTE_SUSPEND/RESUME, keep-alive and adaptive-timeout events are never
raised.

## 3. Interfaces and routes

### 3.1 The interface model

The guest sees two interfaces, read from the host at most every five
seconds:

| Guest | Index | Mirrors | Flags | Addresses |
|---|---|---|---|---|
| `lo0` | 1 | the host's loopback | UP, LOOPBACK, RUNNING, MULTICAST (0x8049) | the host loopback's IPv4 (127.0.0.1/8), ::1/128, fe80::1/64 |
| `en0` | 2 | the host's **primary interface**: the interface of the host's IPv4 default route (lowest metric, `/proc/net/route`), else the first running non-loopback interface with an IPv4 address | UP, BROADCAST, SMART, RUNNING, SIMPLEX, MULTICAST (0x8863); type IFT_ETHER | that interface's IPv4 and IPv6 addresses, masks, broadcast; MTU; default routers (IPv4 and IPv6) |

`en0`'s link-layer address is a locally administered one derived from
the host interface's (FNV-1a), so the host's own is not shown. Other host
interfaces (bridges, containers, VPN tunnels) are not shown; traffic
still uses the host's routing, so a host VPN applies. The reference shows
the host's own interface list (`networking.md` §3.1); Ycode shows Darwin
names for the Linux host's interfaces, which `networking.md` §7 item 5
allows as long as every view agrees, and every view in this spec uses
this one model (`getifaddrs`, `if_nameindex`, routing answers, `ioctl`s,
store keys, dnssd interface indexes, scope ids).

Interface indexes are mapped both ways: guest 1 ↔ the host loopback's
index, guest 2 ↔ the primary's host index; a host index of an interface
not shown maps to 0.

### 3.2 sysctls and ioctls

- `sysctl {CTL_NET, PF_ROUTE, 0, af, op, arg}`: NET_RT_IFLIST (3) and
  NET_RT_IFLIST2 (6) (`if_msghdr` 112 / `if_msghdr2` 160 bytes + a
  `sockaddr_dl`, then one `ifa_msghdr` per address with NETMASK, IFA and
  BRD; `arg` = one interface index), NET_RT_DUMP (1), NET_RT_DUMP2 (7)
  and NET_RT_FLAGS (2) (`rt_msghdr`/`rt_msghdr2` 92 bytes + DST, GATEWAY
  — an address, or the interface's `sockaddr_dl` — and NETMASK).
  Routes: lo0's 127/8 and 127.0.0.1 and ::1; en0's default routes (UP,
  GATEWAY, STATIC, PRCLONING, GLOBAL) and its subnets (UP, CLONING).
  Sockaddrs are rounded to 4 bytes (xnu ROUNDUP32). `af` filters the
  family. Other `net.route` operations: ENOENT.
- Interface `ioctl`s on any socket (AF_INET, AF_INET6, AF_UNIX,
  PF_ROUTE), by name: SIOCGIFFLAGS, SIOCGIFMTU, SIOCGIFALTMTU,
  SIOCGIFADDR/NETMASK/BRDADDR (the first IPv4 address; EADDRNOTAVAIL
  without one), SIOCGIFMETRIC, SIOCGIFPHYS, SIOCGIFDEVMTU,
  SIOCGIFFUNCTIONALTYPE (loopback 1, wired 2), SIOCGIFEFLAGS, SIOCGIFCAP,
  SIOCGIFMEDIA/XMEDIA (Ethernet, active; loopback: EOPNOTSUPP),
  SIOCGIFLINKQUALITYMETRIC (good, 100; loopback off, -2), SIOCGIFDELEGATE,
  SIOCGIFEXPENSIVE, SIOCGIFCONSTRAINED, SIOCGIFULTRACONSTRAINED,
  SIOCGIFXFLAGS, SIOCGIFOPPORTUNISTIC, SIOCGIFLOWINTERNET,
  SIOCGIFTIMESTAMPENABLED, SIOCGIFLOWPOWER, SIOCGIFNOTRAFFICSHAPING (all
  0), the `in6_ifreq` requests SIOCGIFADDR_IN6, SIOCGIFNETMASK_IN6,
  SIOCGIFAFLAG_IN6 (no flags), SIOCGIFALIFETIME_IN6 (infinite), and
  SIOCGIFCONF (entries of 32 bytes, or 16 + `sa_len` when longer). An
  unknown name: ENXIO; another request: EOPNOTSUPP. SIOCATMARK on an IP
  socket asks the host.

### 3.3 PF_ROUTE sockets

`socket(PF_ROUTE, SOCK_RAW, proto)` (another type: EPROTOTYPE) gives a
routing socket. A written RTM_GET (4), RTM_GET_SILENT (0x11) or
RTM_GET_EXT (0x15) message is answered from the model by longest prefix:
an **RTM_GET** message (also for RTM_GET_SILENT, as the reference kernel
does, `networking.md` §3.6) queued on the same socket, with the
request's sequence, the writer's pid, the route's interface index, flags
| RTF_DONE, the interface MTU in `rmx_mtu`, no error, and DST, GATEWAY,
NETMASK (empty, 4 zero bytes, for a default route), and IFP (the
interface's `sockaddr_dl`) and IFA (its address of the family) when the
request named RTA_IFP or RTA_IFA. The default-route query of
Network.framework (0.0.0.0, DST and IFP) gets the 164-byte answer of the
reference. No route: the write fails with ESRCH (the message comes back
with that errno unless the request was silent). Other message types:
EPERM. Nothing else is sent (no RTM_IFINFO/NEWADDR change messages).
Routing sockets are stateless across a snapshot (unread answers dropped).

This answer alone decides whether a Network.framework path is satisfied
(`networking.md` §3.6): with it, `NWPathMonitor` reports satisfied on
en0, type wired.

### 3.4 The `com.apple.netsrc` kernel control

`socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)` gives a kernel control
socket (`KernelControl.swift`). CTLIOCGINFO (`_IOWR('N', 3, struct
ctl_info)`, 100 bytes) finds `com.apple.netsrc` (a fixed Ycode id); any
other name fails with ENOENT, as for a control nobody registered. After
`connect` with a `sockaddr_ctl` (32 bytes: len, AF_SYSTEM, AF_SYS_CONTROL,
the id, unit), each 36-byte request (version, interface scope, the
destination in a 28-byte `sockaddr_in`/`sockaddr_in6` union) queues one
reply (xnu `netsrc.h`): version 2, 56 bytes: the source address the host
would use (the local address of a host UDP socket connected to the
destination), minimum RTT, connection attempts and successes (0),
NETSRC_FLAG_ROUTEABLE when the guest has a route and the host a source,
the RFC 6724 default-policy label and precedence of source and destination
(IPv4: 4 and 35), and the guest interface index of the route; version 1,
40 bytes. Other PF_SYSTEM sockets (kernel events) still fail with
EAFNOSUPPORT. The guest copes without the control (`networking.md` §3.7);
it is there for parity. Kernel control sockets are recreated at restore,
connected, with no queued reply.

### 3.5 Not provided

- Kernel event sockets (PF_SYSTEM/SYSPROTO_EVENT), routing change
  messages, path updates when the host's network changes.
- SIOCGCONNINFO.
- NECP: the guest makes no NECP calls (`networking.md` §1).

## 4. DNS

### 4.1 The responder

A guest AF_UNIX `connect` to `/var/run/mDNSResponder` (or
`/private/var/run/mDNSResponder`) is accepted at once with no guest
listener (as the diagnosticd host socket, `launchd-sim.md` §8.1): the
peer is a host end (`HostSocketEndpoint`) that receives what the guest
writes, including SCM_RIGHTS descriptions, and writes answers into the
guest end's receive queue. One `DNSServiceConnection` per connection
speaks the dnssd IPC of open-source mDNSResponder (`dnssd_ipc.h`):

| Request | Answer |
|---|---|
| `connection_request` (1), `connection_delegate_request` (19) | status 0; the connection becomes shared |
| subordinate requests on a shared connection | the empty return-path string is skipped; the status goes to the socket passed with SCM_RIGHTS on the request's last byte (else to the connection); replies on the connection with the request's client context |
| `addrinfo_request` (15): flags, interface, protocol (1 IPv4, 2 IPv6, 0 both), name | status 0, then one `addrinfo_reply_op` (72) per address, A first: flags Add (+ MoreComing on all but the last), interface 2 (en0), error 0, the name, type, class IN, the address, TTL 60. A family without an address: one answer with error NoSuchRecord (-65554) and no data |
| `query_request` (8): flags, interface, name, type, class (+ TLVs, ignored) | status 0, then `query_reply_op` (68) per record (CNAMEs only with ReturnIntermediates); none: NoSuchRecord |
| `cancel_request` (63) | the subordinate with that context gets no more answers; no reply |
| `getproperty_request` (13) "DaemonVersion" | status 0, length 4, version |
| `getpid_request` (17) | Unsupported |
| enumeration, browse, resolve, register service/record, add/update/remove record, reconfirm, set domain, port mapping | status 0, never answered (no multicast DNS services are browsed or advertised) |
| anything else | status Unsupported (-65544) |

A bad header (version ≠ 1, data length > 70 000) closes the connection.
Answers are produced on a dispatch queue off the kernel lock and written
under it; a connection closed meanwhile gets nothing.

**SuppressUnusable** (flag 0x8000, sent by `getaddrinfo` and
Network.framework): addresses of a family the guest cannot route are not
answered (NoSuchRecord instead): IPv6 unless en0 has a non-link-local
IPv6 address and an IPv6 default router; IPv4 unless en0 has an IPv4
address and router. Loopback addresses are always answered. On a host
without routable IPv6 the guest therefore gets IPv4 only, as in the
reference.

### 4.2 The host resolver

- A and AAAA (`addrinfo_request`, and `query_request` of those types):
  the host's `getaddrinfo` per family (so `/etc/hosts`, `nsswitch` and
  the host's resolver configuration apply). A name that exists with
  addresses of the other family only is "no record", not "no name". TTL
  60 (the host call gives none).
- Other types (HTTPS, SRV, TXT, CNAME, PTR…): Ycode's DNS client: a
  recursive query with an EDNS(0) OPT record (1232-byte buffer) over UDP
  to each `nameserver` of the host's `/etc/resolv.conf` (two tries, 3 s),
  over TCP when the answer is truncated; names inside NS, CNAME, PTR, MX,
  SOA and SRV data are expanded (dnssd delivers uncompressed data).
- `res_query` in the guest sends its own UDP queries to the servers of
  the guest's DNS configuration (the host store, §5) or of
  `/etc/resolv.conf`; the host's `/etc/resolv.conf` is served read-only
  at the guest's `/etc/resolv.conf` (a single-file prefix of the guest
  file system). On a host with a local stub resolver (127.0.0.53) that
  address works from the guest, which shares the host's loopback.

## 5. The host dynamic store

`SCDynamicStoreHostService` (`scdynamicstore-host.md`) now holds the
guest's network state, built from the interface model:
`State:/Network/Interface` (the list), `…/Interface/<if>/IPv4`, `IPv6`
and `Link` (Active), `State:/Network/Global/IPv4` (PrimaryInterface en0,
PrimaryService, Router), `State:/Network/Global/IPv6` (with routable
IPv6), `State:/Network/Global/DNS` and `State:/Network/Service/<id>/DNS`
(the host's name servers), `State:/Network/Service/<id>` and `…/IPv4`
(`…/IPv6`), `State:/Network/Global/Proxies` (no proxy), `Setup:/Network/
Global/IPv4` (ServiceOrder), `Setup:/Network/Service/<id>` with
`Interface` (en0, Ethernet), `IPv4` (DHCP), `IPv6` (Automatic),
`Proxies`, `State:/Network/MulticastDNS` (the six reference domains) and
`State:/Network/PrivateDNS` (empty). One fixed service id. `configget`,
`configget_m` (keys and anchored patterns; values serialized per key as
`_SCSerializeMultiple` does) and `configlist` answer from it. The store
never changes (no change notification).

configd_sim's SimulatorSupport plug-in copies the service and interface
entities (its patterns do not cover the global ones); configd_sim then
computes `State:/Network/Global/*` and the DNS configuration itself
(observed in Ycode's guest store with `p_netpath`: Global/IPv4 and
Global/DNS with `__IF_INDEX__` 2, `__SCOPED__` proxies).
`SCNetworkReachability` reports 0x2 (reachable) for a host name.

## 6. Snapshots and warm boot

A host socket cannot be saved. The capture records each IP socket as an
`inetSocket` record (kind 29): domain, type, protocol, users, state,
flags, pending error, timeouts, the options kept and the options applied
(in order), buffer sizes, bound interface and address, a connected
datagram socket's peer, backlog. The restore makes a new host socket,
re-applies the options, and:

- a listening socket binds its address again and listens;
- a datagram socket binds again and reconnects to its peer;
- a stream socket that was connected or connecting is **reset**: no host
  socket; the next call reports ECONNRESET once (a blocked `connect`
  restarts and gets it), reads then return 0 (EOF), writes EPIPE,
  EVFILT_SOCK reports DISCONNECTED/READCLOSED/WRITECLOSED/CONNRESET;
- a fresh or bound stream socket binds again.

A bind that fails at restore (the port is taken on the host) resets the
socket too, with a restore warning. Connections to the DNS service are
reset (the guest end reads EOF; the dnssd client reconnects, as after an
mDNSResponder restart). PF_ROUTE sockets are recreated empty. Threads
blocked in `accept` or `connect` restart those calls.

## 7. Limits

- The guest can bind ports below 1024 only if the host allows it.
- Unprivileged hosts refuse raw sockets; ICMP datagram sockets depend on
  the host's `net.ipv4.ping_group_range` and receive without the IP header
  (Darwin's include it).
- SO_REUSEPORT has Linux semantics (load balancing between sockets).
- Interface binding (IP_BOUND_IF) without the host privilege does not
  restrict the route.
- Only the primary host interface is shown; path changes of the host's
  network are not announced (routing messages, notifications).
- No multicast DNS (Bonjour browse/register never answer).
- TCP_FASTOPEN and connectx's resume-on-read/write are not true TFO.

## 8. Verification

Guest probes (`SimShim/guest-tests/build-net.sh`, run as one-shots):

- `p_net`: options, TCP over IPv4/IPv6 loopback (listen, accept, data,
  FIONREAD, EOF, EPIPE without SIGPIPE), non-blocking connect with
  EVFILT_WRITE, EVFILT_READ data and EOF, select, poll (POLLHUP), UDP
  (IP_RECVDSTADDR, MSG_TRUNC, connected UDP), `getifaddrs`,
  `if_nametoindex`, interface ioctls, an HTTP GET to a host-side server
  on 127.0.0.1, to 1.1.1.1 by number and to a public name, a UDP DNS query
  to a public resolver, `getaddrinfo` (EAI_NONAME for `.invalid`),
  `DNSServiceGetAddrInfo`, `DNSServiceQueryRecord` (own and shared
  connection).
- `p_dispatch`: dispatch sources (workloop knotes) on AF_UNIX, TCP connect,
  a listener, TCP and UDP data.
- `p_netpath`: the guest store, reachability, the `nw_path` and one
  `nw_connection`.
- `p_urlsession`: NSURLSession data tasks.

Unit tests: `NetworkingTests` (translations, cmsg layouts, DNS and dnssd
codecs, the interface model's sysctls and ioctls, the kernel's routing
sysctl, PF_ROUTE RTM_GET and RTM_GET_SILENT, TCP lifecycle, non-blocking
connect with kevent, EVFILT_SOCK, netsrc, blocking accept/receive woken
by the host, UDP, poll, the DNS service end to end, a snapshot round trip), `SCDynamicStoreHostServiceTests`
(network keys).

### 8.1 Results (Thor, iOS 27.1 runtime, 2026-10-27)

| Check | Result |
|---|---|
| `p_net` | 39 of 39 (TCP to a host-side server on 127.0.0.1 and to public hosts by number and by name, UDP and connected UDP to a public resolver, IPv6 loopback, kevent/select/poll, interfaces, `getaddrinfo`, dnssd) |
| `p_dispatch` | 5 of 5 |
| `p_netpath` | the guest store has the network keys (and configd_sim's `Global` keys); reachability 0x2; `nw_path` satisfied on en0 (index 2, wired); `nw_connection` to port 443 ready |
| `p_urlsession` | HTTP 200 from the host-side server, `https://example.com/`, `https://www.apple.com/` (254 KB) |
| Safari | `https://example.com/` and `https://www.cloudflare.com/` drawn (launched with `--app-url`); also after a snapshot restore (the snapshot held 15 IP sockets) |
| Boot time (`timed.sh` pair, the same device, cold boot to the home screen) | 39.84 s before (the merge base), 38.72 s with networking: no cost |
| `getaddrinfo` | the first call in a process takes about 1.7 s, almost all of it library start-up in the process (FeatureFlags reads: about 400 `stat64`s), not DNS; the next call about 30 ms |

## Evidence

| Claim | Level |
|---|---|
| Darwin constants and layouts (socket, IP, IPv6, TCP options; `sockaddr_in/in6`, `cmsghdr`, `msghdr`, `msghdr_x`, `sa_endpoints_t`; `if_msghdr(2)`, `ifa_msghdr`, `rt_msghdr(2)`, `if_data(64)`, `sockaddr_dl`; `ifreq`, `ifconf`, `in6_ifreq`; `tcp_connection_info`; ioctl numbers) | 1 (public SDK headers, compiled sizes and offsets; xnu `sockio_private.h` for the private ioctls) |
| EVFILT_SOCK semantics, routing-socket semantics, `connectx`, kernel controls and netsrc (`ctl_info`, `sockaddr_ctl`, `netsrc_req`/`netsrc_repv1`/`netsrc_repv2`) | 1 (xnu `uipc_socket.c`, `rtsock.c`, `uipc_syscalls.c`, `kern_control.h`, `netsrc.h`); RFC 6724 policy table |
| dnssd IPC (header, operations, flags, TLVs, error return, replies) | 1 (mDNSResponder `dnssd_ipc.h`, `dnssd_ipc.c`, `dnssd_clientstub.c`, `uds_daemon.c`) |
| What the guest uses and needs (the default-route query decides path status; EVFILT_SOCK before a TCP connection is used; the store keys SimulatorSupport copies) | 3 (Ycode's own guest runs: traces of `p_urlsession`, `p_netpath`), and `networking.md` (3) |
| Linux values and behavior (errno, option numbers, `cmsghdr`, epoll, `/proc/net/route`) | 1 (Linux UAPI headers and man pages) |
| SystemConfiguration key and property names | 1 (public `SCSchemaDefinitions.h`, configd open source) |
