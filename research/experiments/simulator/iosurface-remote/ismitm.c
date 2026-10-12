/*
 * ismitm: man-in-the-middle for com.apple.IOSurface.Remote (original Ycode
 * code, R5). Runs inside the simulator (simctl spawn). It spawns a program
 * whose bootstrap special port is a port we own (as bsmitm does, see
 * bootstrap-wire.md Appendix A), relays every bootstrap request to the real
 * bootstrap port, and in the reply to a look-up of the target name (legacy 207
 * or XPC 804) replaces the service's send right with a send right to our own
 * proxy port. The proxy (isproxy.h) records every message in both directions
 * and forwards it to the real host service.
 *
 * Usage: ismitm <log file> <program> [args...]
 * Env: YC_IS_NAME (default com.apple.IOSurface.Remote), YC_IS_MAPTEST=1,
 *      YC_IS_FAKE=1 (relay to our own test server, isserver.h, instead of the host service).
 */
#include "isproxy.h"
#include "isserver.h"
#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>

extern char **environ;
extern int posix_spawnattr_setspecialport_np(posix_spawnattr_t *, mach_port_t, int);

static mach_port_t g_fake, g_real;
static const char *g_name = "com.apple.IOSurface.Remote";

static void *bs_thread(void *arg)
{
    (void)arg;
    uint8_t *req = malloc(65536), *rep = malloc(65536);
    mach_port_t myreply;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &myreply);
    for (;;) {
        mach_msg_header_t *h = (mach_msg_header_t *)req;
        kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_VOUCHER, 0, 65536, g_fake, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr) { fprintf(g_isp_out, "bs: receive 0x%x\n", kr); break; }
        int target = memmem(req, h->msgh_size, g_name, strlen(g_name)) != NULL;
        /* Log only the routine and whether it names the target. */
        const char *nm = NULL;
        for (size_t o = 24; o + 5 < h->msgh_size; o += 4)
            if (!memcmp(req + o, "name\0\0\0\0", 8) && o + 16 < h->msgh_size) { nm = (const char *)req + o + 16; break; }
        fprintf(g_isp_out, "-- bootstrap request id=0x%x name=%.*s%s\n", h->msgh_id, nm ? 128 : 6, nm ? nm : "(none)",
                target ? "  [TARGET]" : "");
        mach_port_t orig = h->msgh_remote_port;
        unsigned otype = MACH_MSGH_BITS_REMOTE(h->msgh_bits);
        unsigned vt = MACH_MSGH_BITS_VOUCHER(h->msgh_bits);
        unsigned cx = h->msgh_bits & MACH_MSGH_BITS_COMPLEX;
        int want = MACH_PORT_VALID(orig);
        h->msgh_remote_port = g_real;
        h->msgh_local_port = want ? myreply : MACH_PORT_NULL;
        if (!vt) h->msgh_voucher_port = MACH_PORT_NULL;
        h->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, want ? MACH_MSG_TYPE_MAKE_SEND_ONCE : 0,
                                          vt ? MACH_MSG_TYPE_MOVE_SEND : 0, cx);
        if (cx) {
            size_t off = 28;
            uint32_t cnt = isp_rd32(req + 24);
            for (uint32_t i = 0; i < cnt; i++) {
                uint8_t ty = req[off + 11];
                if (ty == MACH_MSG_PORT_DESCRIPTOR) { off += 12; continue; }
                if (ty == MACH_MSG_OOL_DESCRIPTOR || ty == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) { req[off + 8] = 1; req[off + 9] = MACH_MSG_VIRTUAL_COPY; }
                off += 16;
            }
        }
        kr = mach_msg(h, MACH_SEND_MSG, h->msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
        if (kr || !want) { if (kr) fprintf(g_isp_out, "bs: forward 0x%x\n", kr); continue; }
        mach_msg_header_t *r = (mach_msg_header_t *)rep;
        kr = mach_msg(r, MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_VOUCHER, 0, 65536, myreply, 20000, MACH_PORT_NULL);
        if (kr) { fprintf(g_isp_out, "bs: reply 0x%x\n", kr); continue; }
        unsigned rvt = MACH_MSGH_BITS_VOUCHER(r->msgh_bits);
        unsigned rcx = r->msgh_bits & MACH_MSGH_BITS_COMPLEX;
        if (rcx) {
            size_t off = 28;
            uint32_t cnt = isp_rd32(rep + 24);
            for (uint32_t i = 0; i < cnt; i++) {
                uint8_t ty = rep[off + 11];
                if (ty == MACH_MSG_PORT_DESCRIPTOR) {
                    if (target && i == 0 && rep[off + 10] == 17) {
                        mach_port_t real = isp_rd32(rep + off);
                        if (getenv("YC_IS_FAKE")) {
                            /* Point the client at our own test server instead of the host's. */
                            mach_port_deallocate(mach_task_self(), real);
                            real = srv_start();
                            fprintf(g_isp_out, "-- (fake server mode)\n");
                        }
                        mach_port_t px = isp_service_proxy(real);
                        memcpy(rep + off, &px, 4);
                        rep[off + 10] = MACH_MSG_TYPE_MAKE_SEND;
                        fprintf(g_isp_out, "-- substituted service right 0x%x with proxy 0x%x\n", real, px);
                    }
                    off += 12;
                    continue;
                }
                if (ty == MACH_MSG_OOL_DESCRIPTOR || ty == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) { rep[off + 8] = 1; rep[off + 9] = MACH_MSG_VIRTUAL_COPY; }
                off += 16;
            }
        } else if (target) {
            fprintf(g_isp_out, "-- target look-up answered without a port (simple reply, id 0x%x)\n", r->msgh_id);
        }
        r->msgh_remote_port = orig;
        r->msgh_local_port = MACH_PORT_NULL;
        if (!rvt) r->msgh_voucher_port = MACH_PORT_NULL;
        r->msgh_bits = MACH_MSGH_BITS_SET(otype, 0, rvt ? MACH_MSG_TYPE_MOVE_SEND : 0, rcx);
        kr = mach_msg(r, MACH_SEND_MSG, r->msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
        if (kr) fprintf(g_isp_out, "bs: return 0x%x\n", kr);
        fflush(g_isp_out);
    }
    return NULL;
}

/* Copy the child's stdout lines into the log, so probe markers line up with traffic. */
static int g_pipe[2];
static void *out_thread(void *arg)
{
    (void)arg;
    FILE *in = fdopen(g_pipe[0], "r");
    char line[2048];
    while (in && fgets(line, sizeof line, in)) { fprintf(g_isp_out, "PROBE| %s", line); fflush(g_isp_out); }
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: ismitm <log> <program> [args]\n"); return 2; }
    if (getenv("YC_IS_NAME")) g_name = getenv("YC_IS_NAME");
    FILE *out = fopen(argv[1], "w");
    if (!out) { perror(argv[1]); return 1; }
    setvbuf(out, NULL, _IOLBF, 0);
    isp_start(out);
    task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &g_real);
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_fake);
    mach_port_insert_right(mach_task_self(), g_fake, g_fake, MACH_MSG_TYPE_MAKE_SEND);
    pthread_t t;
    pthread_create(&t, NULL, bs_thread, NULL);
    posix_spawnattr_t a;
    posix_spawnattr_init(&a);
    posix_spawnattr_setspecialport_np(&a, g_fake, TASK_BOOTSTRAP_PORT);
    pid_t pid;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    pipe(g_pipe);
    posix_spawn_file_actions_adddup2(&fa, g_pipe[1], 1);
    posix_spawn_file_actions_adddup2(&fa, g_pipe[1], 2);
    posix_spawn_file_actions_addclose(&fa, g_pipe[0]);
    pthread_t ot;
    pthread_create(&ot, NULL, out_thread, NULL);
    int e = posix_spawn(&pid, argv[2], &fa, &a, argv + 2, environ);
    close(g_pipe[1]);
    if (e) { fprintf(out, "spawn %s: %s\n", argv[2], strerror(e)); return 1; }
    fprintf(out, "spawned %d %s\n", pid, argv[2]);
    int st = 0;
    waitpid(pid, &st, 0);
    usleep(500000);
    fprintf(out, "child exit status 0x%x\n", st);
    fflush(out);
    return 0;
}
