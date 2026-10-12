/*
 * Ycode research probe helper (macOS): a dyld interposing library, loaded into
 * lsprobe with DYLD_INSERT_LIBRARIES. Original Ycode code. It logs the
 * libSystem calls that liblaunch_sim makes (its imports, level 4) and lets a
 * look-up of a name with our prefix resolve to lsprobe's port, so that the
 * library's control messages reach a port we serve. Contains no Apple code.
 */
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <dlfcn.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int fileport_makeport(int, mach_port_t *);
extern int posix_spawnattr_setarchpref_np(posix_spawnattr_t *, size_t, cpu_type_t *, cpu_subtype_t *, size_t *);

static FILE *out(void)
{
    FILE **o = (FILE **)dlsym(RTLD_MAIN_ONLY, "yc_interpose_out");
    return (o && *o) ? *o : stderr;
}
static mach_port_t our_port(void)
{
    mach_port_t *p = (mach_port_t *)dlsym(RTLD_MAIN_ONLY, "yc_interpose_port");
    return p ? *p : MACH_PORT_NULL;
}

static kern_return_t my_bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp)
{
    const char *pre = getenv("YC_NAME_PREFIX");
    if (!pre) pre = "com.ycode.";
    kern_return_t kr;
    mach_port_t p = our_port();
    if (name && p && !strncmp(name, pre, strlen(pre))) {
        mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
        *sp = p;
        kr = KERN_SUCCESS;
    } else {
        kr = bootstrap_look_up(bp, name, sp);
    }
    fprintf(out(), "-- (interposed) bootstrap_look_up(bp=0x%x%s, \"%s\") = %d, port 0x%x\n", bp,
            bp == bootstrap_port ? " = bootstrap_port" : "", name ? name : "(null)", kr, kr ? 0 : *sp);
    fflush(out());
    return kr;
}

static int my_fileport_makeport(int fd, mach_port_t *port)
{
    int r = fileport_makeport(fd, port);
    fprintf(out(), "-- (interposed) fileport_makeport(fd=%d) = %d, port 0x%x\n", fd, r, r ? 0 : *port);
    fflush(out());
    return r;
}

static int my_setarchpref(posix_spawnattr_t *a, size_t n, cpu_type_t *t, cpu_subtype_t *st, size_t *oc)
{
    fprintf(out(), "-- (interposed) posix_spawnattr_setarchpref_np(count=%zu", n);
    for (size_t i = 0; i < n && i < 8; i++) fprintf(out(), ", 0x%x/0x%x", t ? t[i] : 0, st ? st[i] : 0);
    fprintf(out(), ")\n");
    return posix_spawnattr_setarchpref_np(a, n, t, st, oc);
}

static mach_msg_return_t my_mach_msg(mach_msg_header_t *m, mach_msg_option_t opt, mach_msg_size_t ss,
                                     mach_msg_size_t rs, mach_port_name_t rn, mach_msg_timeout_t to,
                                     mach_port_name_t nt)
{
    int tr = getenv("YC_TRACE_MSG") != NULL;
    if (tr)
        fprintf(out(), "-- (interposed) mach_msg: opt=0x%x id=%d send_size=%u remote=0x%x local=0x%x bits=0x%x rcv_name=0x%x rcv_size=%u timeout=%u\n",
                opt, (opt & MACH_SEND_MSG) ? m->msgh_id : -1, ss, m->msgh_remote_port, m->msgh_local_port,
                m->msgh_bits, rn, rs, to);
    mach_msg_return_t r = mach_msg(m, opt, ss, rs, rn, to, nt);
    if (tr) {
        fprintf(out(), "-- (interposed) mach_msg returned 0x%x", r);
        if (r == 0 && (opt & MACH_RCV_MSG)) fprintf(out(), " (received id=%d size=%u)", m->msgh_id, m->msgh_size);
        fprintf(out(), "\n");
        fflush(out());
    }
    return r;
}

struct yc_interpose { const void *replacement; const void *original; };
__attribute__((used, section("__DATA,__interpose"))) static struct yc_interpose yc_tuples[] = {
    { (const void *)my_bootstrap_look_up, (const void *)bootstrap_look_up },
    { (const void *)my_fileport_makeport, (const void *)fileport_makeport },
    { (const void *)my_setarchpref, (const void *)posix_spawnattr_setarchpref_np },
    { (const void *)my_mach_msg, (const void *)mach_msg },
};
