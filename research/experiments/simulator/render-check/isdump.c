/*
 * isdump: R5's isserver.h test IOSurface server (../iosurface-remote) run as a
 * launchd job, plus a dump facility (Ycode research R6, original code). This
 * is the host-side capture Ycode needs: the framebuffer library reports a
 * surface ID, and the service that owns the surface memory saves its pixels.
 *
 * isserver_r6.h is R5's isserver.h plus one switch (YC_SRV_FREEZESEED).
 * Usage: isdump -checkin <service name>   (as a launchd job, like isserve)
 * Env:   YC_SRV_DUMPDIR=<dir>  every 250 ms, if <dir>/req exists, read lines
 *          "<name> <surface id>"  -> <dir>/<name>.raw + <dir>/<name>.txt
 *          "list"                  -> <dir>/surfaces.txt (id size format name)
 *        and remove req. Other YC_SRV_* switches as in isserver.h.
 * Concurrency: the dump thread walks the server's surface list without a
 * lock (research tool; the display buffers it reads are long-lived).
 */
#include "isserver_r6.h"
static mach_port_t (*const isdump_unused)(void) __attribute__((unused)) = srv_start;
#include <unistd.h>
#include <mach/mach_time.h>
extern kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);

static const char *g_dir;

static void surf_name(srv_surface *s, char *buf, size_t n)
{
    snprintf(buf, n, "-");
    CFTypeRef v = s->values ? CFDictionaryGetValue(s->values, CFSTR("IOSurfaceName")) : NULL;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, buf, n, kCFStringEncodingUTF8);
}

static void dump(const char *name, uint32_t id)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/%s.txt", g_dir, name);
    FILE *t = fopen(path, "w");
    srv_surface *s = srv_find_id(id);
    if (!s) { if (t) { fprintf(t, "error=no surface %u\n", id); fclose(t); } return; }
    snprintf(path, sizeof path, "%s/%s.raw", g_dir, name);
    FILE *r = fopen(path, "wb");
    size_t len = (size_t)s->bpr * s->height;
    if (len > s->mapsize) len = s->mapsize;
    if (r) { fwrite((const void *)s->mem, 1, len, r); fclose(r); }
    char nm[128]; surf_name(s, nm, sizeof nm);
    if (t) {
        fprintf(t, "surface_id=%u\nwidth=%u\nheight=%u\nbytes_per_row=%u\npixel_format=0x%08x\n"
                   "bytes_per_element=%u\nalloc_size=%llu\nseed=%u\nuse_count=%d\nlocks=%d\nname=%s\ndump_ticks=%llu\n",
                s->id, s->width, s->height, s->bpr, s->fmt, s->bpe, (unsigned long long)s->alloc, s->seed,
                s->use, s->locks, nm, (unsigned long long)mach_absolute_time());
        fclose(t);
    }
}

static void list(void)
{
    char path[1024];
    snprintf(path, sizeof path, "%s/surfaces.txt", g_dir);
    FILE *f = fopen(path, "w");
    if (!f) return;
    for (srv_surface *s = g_srv_surfaces; s; s = s->next) {
        char nm[128]; surf_name(s, nm, sizeof nm);
        fprintf(f, "%u %ux%u bpr %u fmt 0x%08x seed %u use %d refs %d name %s\n",
                s->id, s->width, s->height, s->bpr, s->fmt, s->seed, s->use, s->refs, nm);
    }
    fclose(f);
}

static void *dump_thread(void *arg)
{
    char req[1024];
    snprintf(req, sizeof req, "%s/req", g_dir);
    for (;;) {
        usleep(250000);
        FILE *f = fopen(req, "r");
        if (!f) continue;
        char line[256];
        while (fgets(line, sizeof line, f)) {
            char name[128]; unsigned id;
            if (!strncmp(line, "list", 4)) list();
            else if (sscanf(line, "%127s %u", name, &id) == 2 && !strchr(name, '/')) dump(name, id);
        }
        fclose(f);
        unlink(req);
    }
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc < 3 || strcmp(argv[1], "-checkin")) return 2;
    mach_port_t rcv = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_check_in(bootstrap_port, argv[2], &rcv);
    printf("isdump: check-in %s -> %d\n", argv[2], kr);
    fflush(stdout);
    if (kr) return 1;
    g_dir = getenv("YC_SRV_DUMPDIR");
    if (g_dir && *g_dir) { pthread_t th; pthread_create(&th, NULL, dump_thread, NULL); pthread_detach(th); }
    srv_start_on(rcv);
    for (;;) sleep(3600);
}
