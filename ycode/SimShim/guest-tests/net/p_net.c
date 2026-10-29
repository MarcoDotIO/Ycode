// Guest probe for host passthrough networking (specs/simulator/networking-ycode.md §8).
// Usage: p_net [host-port [public-host]]
//   host-port    a TCP port on 127.0.0.1 where a host-side HTTP server listens (0: skip)
//   public-host  a public name for the name-lookup and HTTP checks (default example.com)
// Prints one "ok <check>" or "FAIL <check>: <reason>" line per check and a summary.
#include <arpa/inet.h>
#include <dns_sd.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static int failures, passes;

static void ok(const char *what) {
    printf("ok %s\n", what);
    passes++;
}

static void bad(const char *what, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void bad(const char *what, const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    printf("FAIL %s: %s\n", what, buf);
    failures++;
}

#define CHECK(cond, what, ...) do { if (cond) ok(what); else bad(what, __VA_ARGS__); } while (0)

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static int set_nonblock(int fd, int on) {
    int fl = fcntl(fd, F_GETFL);
    return fcntl(fd, F_SETFL, on ? (fl | O_NONBLOCK) : (fl & ~O_NONBLOCK));
}

// Reads until EOF or `cap` bytes; returns the count.
static ssize_t read_all(int fd, char *buf, size_t cap) {
    size_t got = 0;
    while (got < cap) {
        ssize_t n = read(fd, buf + got, cap - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        got += (size_t)n;
    }
    return (ssize_t)got;
}

// HTTP/1.0 GET over a connected socket; returns the status code or -1.
static int http_get(int fd, const char *host, const char *path, size_t *body_bytes) {
    char req[512];
    int n = snprintf(req, sizeof req, "GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: ycode-p_net\r\nConnection: close\r\n\r\n", path, host);
    if (write(fd, req, (size_t)n) != n) return -1;
    static char resp[1 << 20];
    ssize_t got = read_all(fd, resp, sizeof resp - 1);
    if (got <= 12) return -1;
    resp[got] = 0;
    int status = 0;
    if (sscanf(resp, "HTTP/%*d.%*d %d", &status) != 1) return -1;
    char *body = strstr(resp, "\r\n\r\n");
    if (body_bytes) *body_bytes = body ? (size_t)(got - (body + 4 - resp)) : 0;
    return status;
}

// --- checks -------------------------------------------------------------

static void check_options(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { bad("socket(AF_INET, SOCK_STREAM)", "errno %d", errno); return; }
    ok("socket(AF_INET, SOCK_STREAM)");
    int one = 1, v = 0;
    socklen_t len = sizeof v;
    CHECK(setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) == 0 &&
          getsockopt(s, IPPROTO_TCP, TCP_NODELAY, &v, &len) == 0 && v != 0, "TCP_NODELAY", "errno %d v %d", errno, v);
    v = 0; len = sizeof v;
    CHECK(setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one) == 0 &&
          getsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &v, &len) == 0 && v != 0, "SO_KEEPALIVE", "errno %d v %d", errno, v);
    int idle = 30; v = 0; len = sizeof v;
    CHECK(setsockopt(s, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof idle) == 0 &&
          getsockopt(s, IPPROTO_TCP, TCP_KEEPALIVE, &v, &len) == 0 && v == 30, "TCP_KEEPALIVE", "errno %d v %d", errno, v);
    v = 0; len = sizeof v;
    CHECK(setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one) == 0 &&
          getsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &v, &len) == 0 && v == 1, "SO_NOSIGPIPE", "errno %d v %d", errno, v);
    v = 0; len = sizeof v;
    CHECK(setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) == 0 &&
          getsockopt(s, SOL_SOCKET, SO_REUSEPORT, &v, &len) == 0 && v != 0, "SO_REUSEPORT", "errno %d v %d", errno, v);
    int rcv = 65536; v = 0; len = sizeof v;
    CHECK(setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof rcv) == 0 &&
          getsockopt(s, SOL_SOCKET, SO_RCVBUF, &v, &len) == 0 && v == 65536, "SO_RCVBUF", "errno %d v %d", errno, v);
    v = -1; len = sizeof v;
    CHECK(getsockopt(s, SOL_SOCKET, SO_TYPE, &v, &len) == 0 && v == SOCK_STREAM, "SO_TYPE", "errno %d v %d", errno, v);
    // A Darwin-only option is accepted and read back.
    int tc = 0x1;
    v = 0; len = sizeof v;
    CHECK(setsockopt(s, SOL_SOCKET, 0x1086 /* SO_TRAFFIC_CLASS */, &tc, sizeof tc) == 0 &&
          getsockopt(s, SOL_SOCKET, 0x1086, &v, &len) == 0 && v == 1, "Darwin-only option kept", "errno %d v %d", errno, v);
    struct sockaddr_in sin;
    len = sizeof sin;
    CHECK(getpeername(s, (struct sockaddr *)&sin, &len) < 0 && errno == ENOTCONN, "getpeername unconnected ENOTCONN", "errno %d", errno);
    close(s);

    int s6 = socket(AF_INET6, SOCK_DGRAM, 0);
    v = -1; len = sizeof v;
    CHECK(s6 >= 0 && getsockopt(s6, IPPROTO_IPV6, IPV6_V6ONLY, &v, &len) == 0 && v == 0, "IPV6_V6ONLY default 0", "errno %d v %d", errno, v);
    CHECK(setsockopt(s6, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one) == 0 &&
          getsockopt(s6, IPPROTO_IPV6, IPV6_V6ONLY, &v, &len) == 0 && v == 1, "IPV6_V6ONLY set", "errno %d v %d", errno, v);
    close(s6);
    CHECK(socket(AF_INET, SOCK_STREAM, IPPROTO_UDP) < 0 && errno == EPROTONOSUPPORT, "stream+UDP EPROTONOSUPPORT", "errno %d", errno);
}

// A listener in the guest, a client in the guest: accept, data both ways, EOF.
static void check_loopback_tcp(int family) {
    const char *what = family == AF_INET ? "TCP loopback IPv4" : "TCP loopback IPv6";
    int l = socket(family, SOCK_STREAM, 0);
    struct sockaddr_storage ss;
    memset(&ss, 0, sizeof ss);
    socklen_t slen;
    if (family == AF_INET) {
        struct sockaddr_in *a = (struct sockaddr_in *)&ss;
        a->sin_len = sizeof *a; a->sin_family = AF_INET; a->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        slen = sizeof *a;
    } else {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)&ss;
        a->sin6_len = sizeof *a; a->sin6_family = AF_INET6; a->sin6_addr = in6addr_loopback;
        slen = sizeof *a;
    }
    if (l < 0 || bind(l, (struct sockaddr *)&ss, slen) < 0 || listen(l, 4) < 0) { bad(what, "listen: errno %d", errno); return; }
    socklen_t blen = sizeof ss;
    getsockname(l, (struct sockaddr *)&ss, &blen);
    unsigned port = ntohs(family == AF_INET ? ((struct sockaddr_in *)&ss)->sin_port : ((struct sockaddr_in6 *)&ss)->sin6_port);
    if (port == 0 || ss.ss_len != slen || ss.ss_family != family) {
        bad(what, "getsockname: port %u len %u family %u", port, ss.ss_len, ss.ss_family); close(l); return;
    }
    int c = socket(family, SOCK_STREAM, 0);
    if (connect(c, (struct sockaddr *)&ss, slen) < 0) { bad(what, "connect: errno %d", errno); return; }
    struct sockaddr_storage peer;
    socklen_t plen = sizeof peer;
    int a = accept(l, (struct sockaddr *)&peer, &plen);
    if (a < 0) { bad(what, "accept: errno %d", errno); return; }
    const char msg[] = "hello from the client";
    char buf[128];
    if (write(c, msg, sizeof msg) != sizeof msg) { bad(what, "write errno %d", errno); return; }
    if (read(a, buf, sizeof buf) != sizeof msg || memcmp(buf, msg, sizeof msg) != 0) { bad(what, "read mismatch"); return; }
    if (send(a, "pong", 4, 0) != 4 || recv(c, buf, sizeof buf, 0) != 4) { bad(what, "send/recv errno %d", errno); return; }
    int nread = -1;
    write(a, "xyz", 3);
    usleep(20000);
    ioctl(c, FIONREAD, &nread);
    recv(c, buf, sizeof buf, 0);
    shutdown(a, SHUT_WR);
    ssize_t eof = recv(c, buf, sizeof buf, 0);
    CHECK(eof == 0 && nread == 3 && plen == slen, what, "eof %zd FIONREAD %d peerlen %u", eof, nread, plen);
    // SIGPIPE suppressed by SO_NOSIGPIPE: write after the peer closed.
    int one = 1;
    setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    close(a);
    usleep(50000);
    errno = 0;
    ssize_t w1 = write(c, "a", 1);
    usleep(50000);
    ssize_t w2 = write(c, "b", 1);
    int e2 = errno;
    if (family == AF_INET) CHECK(w2 < 0 && (e2 == EPIPE || e2 == ECONNRESET), "EPIPE without SIGPIPE", "w1 %zd w2 %zd errno %d", w1, w2, e2);
    close(c);
    close(l);
}

// Non-blocking connect + kevent EVFILT_WRITE, then EVFILT_READ, select and poll.
static void check_nonblocking(void) {
    int l = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sin = {.sin_len = sizeof sin, .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(l, (struct sockaddr *)&sin, sizeof sin);
    listen(l, 4);
    socklen_t len = sizeof sin;
    getsockname(l, (struct sockaddr *)&sin, &len);

    int c = socket(AF_INET, SOCK_STREAM, 0);
    set_nonblock(c, 1);
    int r = connect(c, (struct sockaddr *)&sin, sizeof sin);
    int e = errno;
    int kq = kqueue();
    struct kevent ev;
    EV_SET(&ev, c, EVFILT_WRITE, EV_ADD | EV_ONESHOT, 0, 0, NULL);
    kevent(kq, &ev, 1, NULL, 0, NULL);
    struct timespec ts = {5, 0};
    struct kevent out;
    int n = kevent(kq, NULL, 0, &out, 1, &ts);
    int soerr = -1;
    len = sizeof soerr;
    getsockopt(c, SOL_SOCKET, SO_ERROR, &soerr, &len);
    CHECK((r == 0 || e == EINPROGRESS) && n == 1 && out.filter == EVFILT_WRITE && soerr == 0,
          "non-blocking connect + EVFILT_WRITE", "connect %d errno %d kevent %d filter %d so_error %d", r, e, n, out.filter, soerr);

    int a = accept(l, NULL, NULL);
    char buf[64];
    errno = 0;
    CHECK(recv(c, buf, sizeof buf, 0) < 0 && errno == EAGAIN, "non-blocking recv EAGAIN", "errno %d", errno);
    EV_SET(&ev, c, EVFILT_READ, EV_ADD, 0, 0, NULL);
    kevent(kq, &ev, 1, NULL, 0, NULL);
    ts.tv_sec = 0; ts.tv_nsec = 100000000;
    n = kevent(kq, NULL, 0, &out, 1, &ts);
    double t0 = now();
    write(a, "12345", 5);
    ts.tv_sec = 5;
    int n2 = kevent(kq, NULL, 0, &out, 1, &ts);
    CHECK(n == 0 && n2 == 1 && out.filter == EVFILT_READ && out.data == 5, "EVFILT_READ data", "before %d after %d filter %d data %lld",
          n, n2, out.filter, (long long)out.data);
    recv(c, buf, sizeof buf, 0);
    close(a);
    n2 = kevent(kq, NULL, 0, &out, 1, &ts);
    CHECK(n2 == 1 && (out.flags & EV_EOF), "EVFILT_READ EOF", "n %d flags 0x%x", n2, out.flags);
    (void)t0;

    // select and poll on a fresh pair.
    int c2 = socket(AF_INET, SOCK_STREAM, 0);
    connect(c2, (struct sockaddr *)&sin, sizeof sin);
    int a2 = accept(l, NULL, NULL);
    fd_set rs;
    FD_ZERO(&rs);
    FD_SET(c2, &rs);
    struct timeval tv = {0, 50000};
    int s0 = select(c2 + 1, &rs, NULL, NULL, &tv);
    write(a2, "!", 1);
    FD_ZERO(&rs);
    FD_SET(c2, &rs);
    tv.tv_sec = 5;
    int s1 = select(c2 + 1, &rs, NULL, NULL, &tv);
    CHECK(s0 == 0 && s1 == 1 && FD_ISSET(c2, &rs), "select readiness", "before %d after %d", s0, s1);
    recv(c2, buf, 1, 0);
    struct pollfd p = {.fd = c2, .events = POLLIN};
    int p0 = poll(&p, 1, 50);
    write(a2, "?", 1);
    int p1 = poll(&p, 1, 5000);
    CHECK(p0 == 0 && p1 == 1 && (p.revents & POLLIN), "poll readiness", "before %d after %d revents 0x%x", p0, p1, p.revents);
    close(a2);
    recv(c2, buf, 1, 0);
    p.revents = 0;
    int p2 = poll(&p, 1, 5000);
    CHECK(p2 == 1 && (p.revents & POLLHUP), "poll POLLHUP at EOF", "n %d revents 0x%x", p2, p.revents);
    close(c2);
    close(c);
    close(kq);
    close(l);
}

static void check_udp(void) {
    int a = socket(AF_INET, SOCK_DGRAM, 0), b = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(a, (struct sockaddr *)&sa, sizeof sa);
    socklen_t len = sizeof sa;
    getsockname(a, (struct sockaddr *)&sa, &len);
    int one = 1;
    setsockopt(a, IPPROTO_IP, IP_RECVDSTADDR, &one, sizeof one);
    const char msg[] = "datagram";
    ssize_t s = sendto(b, msg, sizeof msg, 0, (struct sockaddr *)&sa, sizeof sa);
    char buf[64], cbuf[128];
    struct sockaddr_in from;
    struct iovec iov = {buf, sizeof buf};
    struct msghdr m = {.msg_name = &from, .msg_namelen = sizeof from, .msg_iov = &iov, .msg_iovlen = 1,
                       .msg_control = cbuf, .msg_controllen = sizeof cbuf};
    ssize_t r = recvmsg(a, &m, 0);
    int dst = 0;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&m); c; c = CMSG_NXTHDR(&m, c)) {
        if (c->cmsg_level == IPPROTO_IP && c->cmsg_type == IP_RECVDSTADDR) {
            struct in_addr ia;
            memcpy(&ia, CMSG_DATA(c), sizeof ia);
            dst = ia.s_addr == htonl(INADDR_LOOPBACK);
        }
    }
    CHECK(s == sizeof msg && r == sizeof msg && memcmp(buf, msg, sizeof msg) == 0 && from.sin_family == AF_INET &&
          from.sin_len == sizeof from && dst, "UDP sendto/recvmsg + IP_RECVDSTADDR", "sent %zd got %zd family %d dst %d", s, r,
          from.sin_family, dst);
    // Truncation.
    sendto(b, "0123456789", 10, 0, (struct sockaddr *)&sa, sizeof sa);
    iov.iov_len = 4;
    m.msg_controllen = 0;
    m.msg_control = NULL;
    m.msg_namelen = sizeof from;
    r = recvmsg(a, &m, 0);
    CHECK(r == 4 && (m.msg_flags & MSG_TRUNC), "UDP MSG_TRUNC", "got %zd flags 0x%x", r, m.msg_flags);
    // Connected UDP.
    connect(b, (struct sockaddr *)&sa, sizeof sa);
    CHECK(send(b, "c", 1, 0) == 1 && recv(a, buf, sizeof buf, 0) == 1, "connected UDP", "errno %d", errno);
    close(a);
    close(b);
}

// A DNS query over UDP to a public resolver (numeric address, no lookup).
static void check_public_udp(void) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_port = htons(53)};
    inet_pton(AF_INET, "1.1.1.1", &sa.sin_addr);
    unsigned char q[] = {0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1};
    struct timeval tv = {5, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    sendto(s, q, sizeof q, 0, (struct sockaddr *)&sa, sizeof sa);
    unsigned char r[512];
    ssize_t n = recv(s, r, sizeof r, 0);
    CHECK(n > 12 && r[0] == 0x12 && r[1] == 0x34 && (r[2] & 0x80), "UDP to a public resolver", "n %zd errno %d", n, errno);
    close(s);
    // Connected UDP with send/recv and the message variants (as QUIC does).
    s = socket(AF_INET, SOCK_DGRAM, 0);
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    int c = connect(s, (struct sockaddr *)&sa, sizeof sa);
    q[0] = 0x56;
    struct iovec iov = {q, sizeof q};
    struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1};
    ssize_t sent = sendmsg(s, &m, 0);
    struct iovec riov = {r, sizeof r};
    struct msghdr rm = {.msg_iov = &riov, .msg_iovlen = 1};
    n = recvmsg(s, &rm, 0);
    CHECK(c == 0 && sent == (ssize_t)sizeof q && n > 12 && r[0] == 0x56, "connected UDP sendmsg/recvmsg to a public resolver",
          "connect %d sent %zd n %zd errno %d", c, sent, n, errno);
    close(s);
}

static void check_host_server(int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_port = htons((uint16_t)port),
                             .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (connect(s, (struct sockaddr *)&sa, sizeof sa) < 0) { bad("HTTP GET host server", "connect errno %d", errno); return; }
    size_t body = 0;
    int st = http_get(s, "127.0.0.1", "/", &body);
    CHECK(st == 200 && body > 0, "HTTP GET host server", "status %d body %zu", st, body);
    close(s);
}

static void check_public_tcp_numeric(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa = {.sin_len = sizeof sa, .sin_family = AF_INET, .sin_port = htons(80)};
    inet_pton(AF_INET, "1.1.1.1", &sa.sin_addr);
    if (connect(s, (struct sockaddr *)&sa, sizeof sa) < 0) { bad("HTTP GET 1.1.1.1 (numeric)", "connect errno %d", errno); return; }
    int st = http_get(s, "1.1.1.1", "/", NULL);
    CHECK(st >= 200 && st < 400, "HTTP GET 1.1.1.1 (numeric)", "status %d", st);
    close(s);
}

static void check_getaddrinfo(const char *host) {
    struct addrinfo hints = {.ai_socktype = SOCK_STREAM}, *res = NULL;
    double t0 = now();
    int r = getaddrinfo(host, "80", &hints, &res);
    double dt = now() - t0;
    int v4 = 0, v6 = 0;
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        if (a->ai_family == AF_INET) v4++;
        if (a->ai_family == AF_INET6) v6++;
    }
    char what[128];
    snprintf(what, sizeof what, "getaddrinfo(%s)", host);
    CHECK(r == 0 && v4 + v6 > 0, what, "error %d (%s) after %.2f s", r, gai_strerror(r), dt);
    printf("note getaddrinfo(%s): %d IPv4, %d IPv6, %.3f s\n", host, v4, v6, dt);
    if (r == 0) {
        struct addrinfo *again = NULL;
        t0 = now();
        int r2 = getaddrinfo(host, "443", &hints, &again);
        printf("note getaddrinfo(%s) again: error %d, %.3f s\n", host, r2, now() - t0);
        if (again) freeaddrinfo(again);
    }
    if (r != 0) return;
    // HTTP GET to the first address that connects.
    int got = 0;
    for (struct addrinfo *a = res; a && !got; a = a->ai_next) {
        int s = socket(a->ai_family, SOCK_STREAM, 0);
        if (connect(s, a->ai_addr, a->ai_addrlen) == 0) {
            int st = http_get(s, host, "/", NULL);
            snprintf(what, sizeof what, "HTTP GET %s (%s)", host, a->ai_family == AF_INET ? "IPv4" : "IPv6");
            CHECK(st >= 200 && st < 500, what, "status %d", st);
            got = 1;
        }
        close(s);
    }
    if (!got) bad("HTTP GET by name", "no address connected");
    freeaddrinfo(res);
    r = getaddrinfo("no-such-name.invalid", "80", &hints, &res);
    CHECK(r == EAI_NONAME, "getaddrinfo(no-such-name.invalid) EAI_NONAME", "error %d (%s)", r, gai_strerror(r));
}

static int dnssd_answers, dnssd_done;

static void addrinfo_cb(DNSServiceRef ref, DNSServiceFlags flags, uint32_t ifi, DNSServiceErrorType err, const char *name,
                        const struct sockaddr *addr, uint32_t ttl, void *ctx) {
    (void)ref; (void)ifi; (void)ctx;
    char text[64] = "";
    if (err == 0 && addr) {
        if (addr->sa_family == AF_INET) inet_ntop(AF_INET, &((const struct sockaddr_in *)addr)->sin_addr, text, sizeof text);
        else inet_ntop(AF_INET6, &((const struct sockaddr_in6 *)addr)->sin6_addr, text, sizeof text);
        dnssd_answers++;
    }
    printf("note DNSServiceGetAddrInfo %s: err %d flags 0x%x %s ttl %u\n", name, err, flags, text, ttl);
    if (!(flags & kDNSServiceFlagsMoreComing)) dnssd_done = 1;
}

static void query_cb(DNSServiceRef ref, DNSServiceFlags flags, uint32_t ifi, DNSServiceErrorType err, const char *name,
                     uint16_t rrtype, uint16_t rrclass, uint16_t rdlen, const void *rdata, uint32_t ttl, void *ctx) {
    (void)ref; (void)ifi; (void)rrclass; (void)rdata; (void)ctx;
    printf("note DNSServiceQueryRecord %s: err %d type %u rdlen %u ttl %u\n", name, err, rrtype, rdlen, ttl);
    if (err == 0) dnssd_answers++;
    if (!(flags & kDNSServiceFlagsMoreComing)) dnssd_done = 1;
}

static int run_dnssd(DNSServiceRef ref) {
    int fd = DNSServiceRefSockFD(ref);
    double t0 = now();
    while (!dnssd_done && now() - t0 < 10) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        if (poll(&p, 1, 1000) == 1) {
            if (DNSServiceProcessResult(ref) != kDNSServiceErr_NoError) break;
        }
    }
    DNSServiceRefDeallocate(ref);
    return dnssd_done;
}

static void check_dnssd(const char *host) {
    DNSServiceRef ref;
    dnssd_answers = dnssd_done = 0;
    DNSServiceErrorType e = DNSServiceGetAddrInfo(&ref, 0, 0, kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6, host,
                                                  addrinfo_cb, NULL);
    if (e != 0) { bad("DNSServiceGetAddrInfo", "error %d", e); return; }
    CHECK(run_dnssd(ref) && dnssd_answers > 0, "DNSServiceGetAddrInfo", "done %d answers %d", dnssd_done, dnssd_answers);
    dnssd_answers = dnssd_done = 0;
    e = DNSServiceQueryRecord(&ref, 0, 0, host, kDNSServiceType_A, kDNSServiceClass_IN, query_cb, NULL);
    if (e != 0) { bad("DNSServiceQueryRecord A", "error %d", e); return; }
    CHECK(run_dnssd(ref) && dnssd_answers > 0, "DNSServiceQueryRecord A", "done %d answers %d", dnssd_done, dnssd_answers);
    // A shared connection (subordinate requests, error socket passed with SCM_RIGHTS).
    DNSServiceRef shared, sub;
    dnssd_answers = dnssd_done = 0;
    e = DNSServiceCreateConnection(&shared);
    if (e == 0) {
        sub = shared;
        e = DNSServiceQueryRecord(&sub, kDNSServiceFlagsShareConnection, 0, host, kDNSServiceType_AAAA, kDNSServiceClass_IN,
                                  query_cb, NULL);
    }
    CHECK(e == 0 && run_dnssd(shared), "DNSServiceQueryRecord AAAA on a shared connection", "error %d done %d", e, dnssd_done);
}

static void check_interfaces(void) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) { bad("getifaddrs", "errno %d", errno); return; }
    int lo = 0, en = 0, link = 0;
    for (struct ifaddrs *i = list; i; i = i->ifa_next) {
        char text[64] = "-";
        if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET) inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, text, sizeof text);
        if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET6) inet_ntop(AF_INET6, &((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr, text, sizeof text);
        if (i->ifa_addr && i->ifa_addr->sa_family == AF_LINK) { link++; strcpy(text, "link"); }
        printf("note ifaddr %s family %d flags 0x%x %s\n", i->ifa_name, i->ifa_addr ? i->ifa_addr->sa_family : -1, i->ifa_flags, text);
        if (!strcmp(i->ifa_name, "lo0") && i->ifa_addr && i->ifa_addr->sa_family == AF_INET) lo++;
        if (!strcmp(i->ifa_name, "en0") && i->ifa_addr && i->ifa_addr->sa_family == AF_INET) en++;
    }
    freeifaddrs(list);
    CHECK(lo == 1 && en >= 1 && link >= 2, "getifaddrs lo0 + en0", "lo0 %d en0 %d link %d", lo, en, link);
    unsigned idx = if_nametoindex("en0");
    char name[IF_NAMESIZE] = "";
    CHECK(idx == 2 && if_indextoname(idx, name) && !strcmp(name, "en0") && if_nametoindex("lo0") == 1, "if_nametoindex",
          "en0 %u lo0 %u", idx, if_nametoindex("lo0"));
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strcpy(ifr.ifr_name, "en0");
    int r1 = ioctl(s, SIOCGIFFLAGS, &ifr);
    short flags = ifr.ifr_flags;
    int r2 = ioctl(s, SIOCGIFMTU, &ifr);
    CHECK(r1 == 0 && (flags & IFF_UP) && (flags & IFF_RUNNING) && r2 == 0 && ifr.ifr_mtu >= 1280, "SIOCGIFFLAGS/SIOCGIFMTU",
          "r %d/%d flags 0x%x mtu %d", r1, r2, flags, ifr.ifr_mtu);
    close(s);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    int port = argc > 1 ? atoi(argv[1]) : 0;
    const char *host = argc > 2 ? argv[2] : "example.com";
    double t0 = now();
    check_options();
    check_loopback_tcp(AF_INET);
    check_loopback_tcp(AF_INET6);
    check_nonblocking();
    check_udp();
    check_interfaces();
    if (port > 0) check_host_server(port);
    check_public_tcp_numeric();
    check_public_udp();
    check_getaddrinfo(host);
    check_dnssd(host);
    printf("p_net: %d ok, %d failed, %.2f s\n", passes, failures, now() - t0);
    return failures ? 1 : 0;
}
