// Guest probe: dispatch sources on sockets (specs/simulator/networking-ycode.md §8).
// Dispatch sources are kevent knotes on workloops; this checks that socket
// readiness reaches them: AF_UNIX (control), TCP connect completion
// (EVFILT_WRITE), TCP data (EVFILT_READ), UDP data.
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int failures;

static void expect(const char *what, dispatch_source_type_t type, int fd, void (^trigger)(void)) {
    dispatch_semaphore_t fired = dispatch_semaphore_create(0);
    dispatch_queue_t q = dispatch_queue_create(what, NULL);
    dispatch_source_t s = dispatch_source_create(type, (uintptr_t)fd, 0, q);
    dispatch_source_set_event_handler(s, ^{
        dispatch_source_cancel(s);
        dispatch_semaphore_signal(fired);
    });
    dispatch_resume(s);
    if (trigger) trigger();
    long timedOut = dispatch_semaphore_wait(fired, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    printf("%s %s\n", timedOut ? "FAIL" : "ok", what);
    if (timedOut) failures++;
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    int sv[2];
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    int w1 = sv[1];
    expect("AF_UNIX read source", DISPATCH_SOURCE_TYPE_READ, sv[0], ^{ write(w1, "x", 1); });

    int l = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sin = {.sin_len = sizeof sin, .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(l, (struct sockaddr *)&sin, sizeof sin);
    listen(l, 4);
    socklen_t len = sizeof sin;
    getsockname(l, (struct sockaddr *)&sin, &len);
    int c = socket(AF_INET, SOCK_STREAM, 0);
    fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK);
    expect("TCP connect write source", DISPATCH_SOURCE_TYPE_WRITE, c, ^{ connect(c, (struct sockaddr *)&sin, sizeof sin); });
    int a = accept(l, NULL, NULL);
    expect("TCP accept read source (pending connection)", DISPATCH_SOURCE_TYPE_READ, l, ^{
        int c2 = socket(AF_INET, SOCK_STREAM, 0);
        connect(c2, (struct sockaddr *)&sin, sizeof sin);
    });
    expect("TCP read source", DISPATCH_SOURCE_TYPE_READ, c, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{ write(a, "y", 1); });
    });
    int u = socket(AF_INET, SOCK_DGRAM, 0), v = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in us = {.sin_len = sizeof us, .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(u, (struct sockaddr *)&us, sizeof us);
    len = sizeof us;
    getsockname(u, (struct sockaddr *)&us, &len);
    expect("UDP read source", DISPATCH_SOURCE_TYPE_READ, u, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
            sendto(v, "z", 1, 0, (struct sockaddr *)&us, sizeof us);
        });
    });
    printf("p_dispatch: %d failed\n", failures);
    return failures ? 1 : 0;
}
