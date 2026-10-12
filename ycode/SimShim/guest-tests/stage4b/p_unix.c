/* Ycode stage-4b probe: AF_UNIX stream socket between processes and
 * SCM_RIGHTS (processes.md section 5). The parent binds and listens on a
 * path under /tmp; the child connects, sends text, then passes the read
 * end of a pipe it has written to. The parent reads the text, then reads
 * the pipe's data through the received descriptor. Every wait is a
 * non-blocking poll loop with a deadline. Original Ycode code.
 * Prints: unix ok */
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>

#include "probe_util.h"

static const char TEXT[] = "hello over AF_UNIX";
static const char PIPE_TEXT[] = "data through the passed pipe";

static void make_addr(struct sockaddr_un *addr, const char *path)
{
    memset(addr, 0, sizeof *addr);
    addr->sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr->sun_path)
        probe_fail("socket path too long: %s", path);
    strcpy(addr->sun_path, path);
    addr->sun_len = (unsigned char)SUN_LEN(addr);
}

static void set_nonblocking(int fd)
{
    int fl = fcntl(fd, F_GETFL);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) != 0)
        probe_fail("fcntl(%d, O_NONBLOCK): %s", fd, strerror(errno));
}

static void write_all(int fd, const void *buf, size_t len, const char *what)
{
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            probe_fail("write %s: %s", what, n < 0 ? strerror(errno) : "wrote 0");
        p += n;
        len -= (size_t)n;
    }
}

static int child(const char *path)
{
    struct sockaddr_un addr;
    make_addr(&addr, path);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0)
        probe_fail("child: socket: %s", strerror(errno));
    if (connect(s, (struct sockaddr *)&addr, addr.sun_len) != 0)
        probe_fail("child: connect(%s): %s", path, strerror(errno));
    write_all(s, TEXT, sizeof TEXT - 1, "the text");

    int p[2];
    if (pipe(p) != 0)
        probe_fail("child: pipe: %s", strerror(errno));
    write_all(p[1], PIPE_TEXT, sizeof PIPE_TEXT - 1, "into the pipe");
    close(p[1]);

    char marker = 'R';
    struct iovec iov = {&marker, 1};
    union {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } control;
    memset(&control, 0, sizeof control);
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.buf;
    msg.msg_controllen = CMSG_LEN(sizeof(int));
    struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
    cm->cmsg_len = CMSG_LEN(sizeof(int));
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    memcpy(CMSG_DATA(cm), &p[0], sizeof(int));
    ssize_t n;
    while ((n = sendmsg(s, &msg, 0)) < 0 && errno == EINTR) {
    }
    if (n != 1)
        probe_fail("child: sendmsg(SCM_RIGHTS) = %zd (%s)", n, n < 0 ? strerror(errno) : "short");
    close(p[0]);
    close(s);
    return 0;
}

int main(int argc, char **argv)
{
    probe_name = "p_unix";
    if (argc >= 3 && strcmp(argv[1], "child") == 0)
        return child(argv[2]);

    const char *self = probe_self_path(argv[0]);
    char path[104];
    snprintf(path, sizeof path, "/tmp/ycode-p_unix-%d.sock", (int)getpid());
    unlink(path);
    struct sockaddr_un addr;
    make_addr(&addr, path);
    int ls = socket(AF_UNIX, SOCK_STREAM, 0);
    if (ls < 0)
        probe_fail("socket: %s", strerror(errno));
    if (bind(ls, (struct sockaddr *)&addr, addr.sun_len) != 0)
        probe_fail("bind(%s): %s", path, strerror(errno));
    if (listen(ls, 4) != 0)
        probe_fail("listen: %s", strerror(errno));
    set_nonblocking(ls);

    const char *extra[] = {path, NULL};
    pid_t pid = -1;
    /* The child inherits the listening descriptor too; it only connects. */
    int err = probe_spawn(&pid, self, NULL, NULL, "child", extra);
    if (err != 0)
        probe_fail("posix_spawn: %d (%s)", err, strerror(err));

    int cs = -1;
    for (long waited = 0; cs < 0; waited += 5) {
        cs = accept(ls, NULL, NULL);
        if (cs >= 0)
            break;
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
            probe_fail("accept: %s", strerror(errno));
        if (waited >= PROBE_TIMEOUT_MS)
            probe_fail("no connection within %d ms", PROBE_TIMEOUT_MS);
        probe_sleep_ms(5);
    }
    set_nonblocking(cs);

    /* Read the text and the marker byte; take the descriptor from whichever
     * read carries the control message. */
    char data[128];
    size_t have = 0;
    int passed = -1;
    const size_t want = sizeof TEXT - 1 + 1;
    for (long waited = 0; have < want || passed < 0;) {
        union {
            char buf[CMSG_SPACE(sizeof(int)) * 4];
            struct cmsghdr align;
        } control;
        struct iovec iov = {data + have, sizeof data - have};
        struct msghdr msg;
        memset(&msg, 0, sizeof msg);
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.buf;
        msg.msg_controllen = sizeof control.buf;
        ssize_t n = recvmsg(cs, &msg, 0);
        if (n < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
                probe_fail("recvmsg: %s", strerror(errno));
            if (waited >= PROBE_TIMEOUT_MS)
                probe_fail("after %d ms: %zu bytes, descriptor %s", PROBE_TIMEOUT_MS, have,
                           passed >= 0 ? "received" : "missing");
            probe_sleep_ms(5);
            waited += 5;
            continue;
        }
        if (msg.msg_flags & MSG_CTRUNC)
            probe_fail("recvmsg: control data truncated");
        for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msg); cm != NULL; cm = CMSG_NXTHDR(&msg, cm)) {
            if (cm->cmsg_level != SOL_SOCKET || cm->cmsg_type != SCM_RIGHTS)
                probe_fail("unexpected control message level %d type %d", cm->cmsg_level, cm->cmsg_type);
            if (cm->cmsg_len != CMSG_LEN(sizeof(int)) || passed >= 0)
                probe_fail("expected exactly one passed descriptor (cmsg_len %u)", (unsigned)cm->cmsg_len);
            memcpy(&passed, CMSG_DATA(cm), sizeof(int));
        }
        if (n == 0 && (have < want || passed < 0))
            probe_fail("EOF after %zu bytes, descriptor %s", have, passed >= 0 ? "received" : "missing");
        have += (size_t)n;
        if (have > want)
            probe_fail("received %zu bytes, expected %zu", have, want);
    }
    if (memcmp(data, TEXT, sizeof TEXT - 1) != 0 || data[sizeof TEXT - 1] != 'R')
        probe_fail("received text \"%.*s\"", (int)have, data);
    if (passed < 0)
        probe_fail("no descriptor received");

    /* Read the pipe through the passed descriptor until EOF. */
    set_nonblocking(passed);
    char pipe_data[128];
    size_t got = 0;
    for (long waited = 0;;) {
        ssize_t n = read(passed, pipe_data + got, sizeof pipe_data - got);
        if (n > 0) {
            got += (size_t)n;
            if (got == sizeof pipe_data)
                probe_fail("too much data from the passed pipe");
            continue;
        }
        if (n == 0)
            break;
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
            probe_fail("read from the passed descriptor %d: %s", passed, strerror(errno));
        if (waited >= PROBE_TIMEOUT_MS)
            probe_fail("passed pipe: no EOF within %d ms (%zu bytes)", PROBE_TIMEOUT_MS, got);
        probe_sleep_ms(5);
        waited += 5;
    }
    if (got != sizeof PIPE_TEXT - 1 || memcmp(pipe_data, PIPE_TEXT, got) != 0)
        probe_fail("passed pipe gave \"%.*s\"", (int)got, pipe_data);

    probe_expect_exit(pid, 0, "child");
    close(passed);
    close(cs);
    close(ls);
    unlink(path);
    printf("unix ok\n");
    return 0;
}
