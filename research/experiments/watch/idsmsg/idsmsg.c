/*
 * idsmsg: Ycode research probe (original Ycode code, no Apple code).
 * A recorder for the pairing transport's Mach messages, inserted with
 * DYLD_INSERT_LIBRARIES into every job of a throwaway boot
 * (SIMCTL_CHILD_DYLD_INSERT_LIBRARIES). It does nothing except in the
 * process named by YC_IDS_ONLY (default "ids_simd").
 *
 * It interposes the exported mach_msg() and records, for every call that
 * sends to or receives from any port, the header (id, size, dispositions),
 * the descriptors (port dispositions, OOL sizes), the inline body bytes and
 * (YC_IDS_SAVE=1) each OOL region to <dir>/<pid>-<seq>-<n>.bin. Calls that
 * only touch the process's own bootstrap traffic are recorded too; the
 * reader filters by message id.
 *
 * Env: YC_IDS_DIR=<dir>   log to <dir>/<process>-<pid>.log (required)
 *      YC_IDS_ONLY=name   process to record (default ids_simd)
 *      YC_IDS_SAVE=1      also write OOL regions to files (first 4 KiB each)
 */
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>

extern const char *getprogname(void);
/* The watchOS SDK marks mach_msg unavailable; the symbol exists in the
 * simulator's libsystem_kernel. Bind to it under our own name. */
extern mach_msg_return_t yc_mach_msg(mach_msg_header_t *, mach_msg_option_t, mach_msg_size_t, mach_msg_size_t,
                                     mach_port_name_t, mach_msg_timeout_t, mach_port_name_t) __asm__("_mach_msg");

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##orig __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig };

static FILE *g_out;
static int g_on = -1, g_save;
static const char *g_dir;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned g_seq;

static void init_once(void)
{
    if (g_on >= 0) return;
    const char *only = getenv("YC_IDS_ONLY");
    g_dir = getenv("YC_IDS_DIR");
    g_on = g_dir && !strcmp(getprogname(), only ? only : "ids_simd");
    if (!g_on) return;
    g_save = getenv("YC_IDS_SAVE") != NULL;
    char path[1024];
    snprintf(path, sizeof path, "%s/%s-%d.log", g_dir, getprogname(), getpid());
    g_out = fopen(path, "a");
    if (!g_out) { g_on = 0; return; }
    setvbuf(g_out, NULL, _IOLBF, 0);
}

static double now(void)
{
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void record(const char *dir, mach_msg_header_t *h, unsigned seq)
{
    unsigned bits = h->msgh_bits;
    fprintf(g_out, "%u %s t=%.6f id=%d size=%u bits=0x%x remote=0x%x local=0x%x rbits=%u lbits=%u vbits=%u complex=%d\n",
            seq, dir, now(), h->msgh_id, h->msgh_size, bits, h->msgh_remote_port, h->msgh_local_port,
            MACH_MSGH_BITS_REMOTE(bits), MACH_MSGH_BITS_LOCAL(bits), MACH_MSGH_BITS_VOUCHER(bits),
            (bits & MACH_MSGH_BITS_COMPLEX) ? 1 : 0);
    uint8_t *body = (uint8_t *)(h + 1), *end = (uint8_t *)h + h->msgh_size;
    if (bits & MACH_MSGH_BITS_COMPLEX) {
        mach_msg_body_t *b = (mach_msg_body_t *)body;
        uint8_t *d = (uint8_t *)(b + 1);
        fprintf(g_out, "  descriptors %u\n", b->msgh_descriptor_count);
        for (unsigned i = 0; i < b->msgh_descriptor_count && d < end; i++) {
            mach_msg_type_descriptor_t *t = (mach_msg_type_descriptor_t *)d;
            if (t->type == MACH_MSG_PORT_DESCRIPTOR) {
                mach_msg_port_descriptor_t *p = (mach_msg_port_descriptor_t *)d;
                fprintf(g_out, "  [%u] port name=0x%x disposition=%u\n", i, p->name, p->disposition);
                d += sizeof(*p);
            } else if (t->type == MACH_MSG_OOL_DESCRIPTOR || t->type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
                mach_msg_ool_descriptor_t *o = (mach_msg_ool_descriptor_t *)d;
                fprintf(g_out, "  [%u] ool type=%u size=%u copy=%u dealloc=%u\n", i, t->type, o->size, o->copy, o->deallocate);
                if (g_save && o->address && o->size) {
                    char path[1024];
                    snprintf(path, sizeof path, "%s/%s-%d-%u-%u.bin", g_dir, getprogname(), getpid(), seq, i);
                    FILE *f = fopen(path, "w");
                    if (f) { fwrite(o->address, 1, o->size < 4096 ? o->size : 4096, f); fclose(f); }
                }
                d += sizeof(*o);
            } else if (t->type == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
                mach_msg_ool_ports_descriptor_t *o = (mach_msg_ool_ports_descriptor_t *)d;
                fprintf(g_out, "  [%u] ool-ports count=%u disposition=%u\n", i, o->count, o->disposition);
                d += sizeof(*o);
            } else {
                fprintf(g_out, "  [%u] descriptor type %u\n", i, t->type);
                d += sizeof(mach_msg_guarded_port_descriptor_t);
            }
        }
        body = d;
    }
    size_t n = end > body ? (size_t)(end - body) : 0;
    fprintf(g_out, "  inline %zu:", n);
    for (size_t i = 0; i < n && i < 96; i++) fprintf(g_out, " %02x", body[i]);
    fprintf(g_out, "\n");
}

static mach_msg_return_t my_mach_msg(mach_msg_header_t *msg, mach_msg_option_t option, mach_msg_size_t send_size,
                                     mach_msg_size_t rcv_size, mach_port_name_t rcv_name, mach_msg_timeout_t timeout,
                                     mach_port_name_t notify)
{
    init_once();
    unsigned seq = 0;
    if (g_on && (option & MACH_SEND_MSG)) {
        pthread_mutex_lock(&g_lock); seq = ++g_seq; record("send", msg, seq); pthread_mutex_unlock(&g_lock);
    }
    mach_msg_return_t kr = yc_mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
    if (g_on) {
        pthread_mutex_lock(&g_lock);
        if (option & MACH_SEND_MSG) fprintf(g_out, "%u send-result kr=0x%x\n", seq, kr);
        if ((option & MACH_RCV_MSG) && kr == MACH_MSG_SUCCESS) { unsigned r = ++g_seq; record("recv", msg, r); }
        else if (option & MACH_RCV_MSG) fprintf(g_out, "rcv kr=0x%x\n", kr);
        pthread_mutex_unlock(&g_lock);
    }
    return kr;
}
INTERPOSE(my_mach_msg, yc_mach_msg)
