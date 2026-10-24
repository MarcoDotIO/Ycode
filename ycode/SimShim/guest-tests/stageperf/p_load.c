/* Ycode performance probe: what does the loader do in one process start?
 * Original Ycode code (specs/simulator/boot-profile.md §6). Runs unchanged on
 * Apple's simulator (`xcrun simctl spawn`) and on Ycode (`--exec`), so the
 * two platforms can be compared for the same work.
 *
 *   p_load                 one line at main(): images loaded, wall time
 *                          since the kernel started the process, CPU time
 *                          used so far (the loader's work), and how the
 *                          clock/CPU values were obtained
 *   p_load list            the same, then every loaded image's path
 *   p_load deps <macho>    read <macho>'s dependent-library load commands
 *                          (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB,
 *                          LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB) from the
 *                          file and dlopen every absolute one, the way a
 *                          launch of <macho> would load its closure; prints
 *                          images before/after, wall and CPU time of the
 *                          loads
 *   p_load paths <macho>   print each of the image paths dyld recorded
 *                          (after `deps`) with a marker if the path names
 *                          a file that does not exist on disk
 * Output lines start with "load ". */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static double wall_s(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static double mono_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

/* CPU of the whole process (user + system), from getrusage. */
static double cpu_s(void)
{
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0)
        return -1;
    return (double)ru.ru_utime.tv_sec + (double)ru.ru_utime.tv_usec / 1e6 +
           (double)ru.ru_stime.tv_sec + (double)ru.ru_stime.tv_usec / 1e6;
}

/* CPU of the calling thread. */
static double thread_cpu_s(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t) != 0)
        return -1;
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

/* The kernel's start time of this process (wall clock), or 0. */
static double start_s(void)
{
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc kp;
    size_t len = sizeof kp;
    memset(&kp, 0, sizeof kp);
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len < sizeof kp)
        return 0;
    struct timeval tv = kp.kp_proc.p_un.__p_starttime;
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static void at_main(const char *tag, double t_main, double cpu_main, double tcpu_main)
{
    double st = start_s();
    printf("load %s images=%u since_start_s=%.3f cpu_s=%.3f thread_cpu_s=%.3f start_known=%d\n", tag,
           _dyld_image_count(), st > 0 ? t_main - st : -1.0, cpu_main, tcpu_main, st > 0);
}

/* Reads the dependent-library paths of a thin arm64 slice. */
static int read_deps(const char *path, char ***out)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("load error open %s: %s\n", path, strerror(errno));
        return -1;
    }
    struct stat st;
    fstat(fd, &st);
    size_t size = (size_t)st.st_size;
    uint8_t *buf = malloc(size);
    size_t got = 0;
    while (got < size) {
        ssize_t n = read(fd, buf + got, size - got);
        if (n <= 0)
            break;
        got += (size_t)n;
    }
    close(fd);
    uint8_t *base = buf;
    uint32_t magic = *(uint32_t *)buf;
    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        struct fat_header *fh = (struct fat_header *)buf;
        uint32_t n = OSSwapBigToHostInt32(fh->nfat_arch);
        struct fat_arch *fa = (struct fat_arch *)(fh + 1);
        base = NULL;
        for (uint32_t i = 0; i < n; i++)
            if (OSSwapBigToHostInt32((uint32_t)fa[i].cputype) == CPU_TYPE_ARM64)
                base = buf + OSSwapBigToHostInt32(fa[i].offset);
        if (!base) {
            printf("load error no arm64 slice\n");
            return -1;
        }
    }
    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    if (mh->magic != MH_MAGIC_64) {
        printf("load error not a 64-bit Mach-O\n");
        return -1;
    }
    char **list = calloc(mh->ncmds + 1, sizeof(char *));
    int count = 0;
    uint8_t *lc = (uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command *c = (struct load_command *)lc;
        if (c->cmd == LC_LOAD_DYLIB || c->cmd == LC_LOAD_WEAK_DYLIB || c->cmd == LC_REEXPORT_DYLIB ||
            c->cmd == LC_LOAD_UPWARD_DYLIB) {
            struct dylib_command *d = (struct dylib_command *)c;
            list[count++] = strdup((char *)c + d->dylib.name.offset);
        }
        lc += c->cmdsize;
    }
    *out = list;
    return count;
}

int main(int argc, char **argv)
{
    double t_main = wall_s(), cpu_main = cpu_s(), tcpu_main = thread_cpu_s();
    const char *mode = argc > 1 ? argv[1] : "";
    at_main("main", t_main, cpu_main, tcpu_main);
    if (strcmp(mode, "list") == 0) {
        for (uint32_t i = 0; i < _dyld_image_count(); i++)
            printf("load image %s\n", _dyld_get_image_name(i));
        return 0;
    }
    if ((strcmp(mode, "deps") == 0 || strcmp(mode, "paths") == 0) && argc > 2) {
        char **deps = NULL;
        int n = read_deps(argv[2], &deps);
        if (n < 0)
            return 1;
        uint32_t before = _dyld_image_count();
        double w0 = mono_s(), c0 = cpu_s(), t0 = thread_cpu_s();
        int ok = 0, absolute = 0;
        for (int i = 0; i < n; i++) {
            if (deps[i][0] != '/')
                continue;
            absolute++;
            if (dlopen(deps[i], RTLD_LAZY | RTLD_GLOBAL))
                ok++;
            else
                printf("load dlopen-failed %s: %s\n", deps[i], dlerror());
        }
        double w1 = mono_s(), c1 = cpu_s(), t1 = thread_cpu_s();
        uint32_t after = _dyld_image_count();
        printf("load deps direct=%d absolute=%d opened=%d images_before=%u images_after=%u wall_s=%.3f cpu_s=%.3f thread_cpu_s=%.3f\n",
               n, absolute, ok, before, after, w1 - w0, c1 - c0, t1 - t0);
        if (strcmp(mode, "paths") == 0) {
            int missing = 0;
            for (uint32_t i = 0; i < after; i++) {
                const char *p = _dyld_get_image_name(i);
                struct stat st;
                int exists = stat(p, &st) == 0;
                missing += !exists;
                printf("load path %s %s\n", exists ? "disk" : "nodisk", p);
            }
            printf("load paths images=%u nodisk=%d\n", after, missing);
        }
        return 0;
    }
    return 0;
}
