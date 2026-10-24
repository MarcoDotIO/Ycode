// cpufeat_probe: prints the CPU-feature view a process gets (Ycode research).
// Build for the iOS simulator:
//   xcrun -sdk iphonesimulator clang -target arm64-apple-ios27.1-simulator -O1 \
//     -o cpufeat_probe cpufeat_probe.c && codesign -s - cpufeat_probe
// Run: xcrun simctl spawn <device> /path/to/cpufeat_probe
// Output: every sysctl under hw. / machdep. / kern.os* (OID walk), the raw
// bytes of hw.optional.arm.caps, and the commpage's CPU words (public layout,
// xnu osfmk/arm/cpu_capabilities.h; commpage base 0x0000000FFFFFC000).
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/sysctl.h>

static void print_oid(int *oid, size_t len) {
    int q[CTL_MAXNAME + 2] = {0, 1};
    memcpy(q + 2, oid, len * sizeof(int));
    char name[256]; size_t nl = sizeof name;
    if (sysctl(q, (u_int)(len + 2), name, &nl, NULL, 0) != 0) return;
    if (strncmp(name, "hw.", 3) && strncmp(name, "machdep.", 8) &&
        strncmp(name, "kern.os", 7) && strcmp(name, "kern.version")) return;
    q[1] = 4; // oidfmt
    unsigned char fmt[256]; size_t fl = sizeof fmt;
    if (sysctl(q, (u_int)(len + 2), fmt, &fl, NULL, 0) != 0) return;
    uint32_t kind; memcpy(&kind, fmt, 4);
    const char *f = (const char *)fmt + 4;
    unsigned char buf[4096]; size_t bl = sizeof buf;
    if (sysctl(oid, (u_int)len, buf, &bl, NULL, 0) != 0) { printf("%s = <err>\n", name); return; }
    unsigned type = kind & 0xf;
    printf("%s [%s,%zu] = ", name, f, bl);
    if (type == 3 /*STRING*/) { printf("\"%.*s\"\n", (int)bl, buf); return; }
    if ((type == 2 || type == 5 || type == 6) && (bl == 4 || bl == 8)) { // INT/QUAD/OPAQUE-size
        if (bl == 4) { int32_t v; memcpy(&v, buf, 4); printf("%d (0x%x)\n", v, (uint32_t)v); }
        else { int64_t v; memcpy(&v, buf, 8); printf("%lld (0x%llx)\n", (long long)v, (unsigned long long)v); }
        return;
    }
    for (size_t i = 0; i < bl && i < 64; i++) printf("%02x", buf[i]);
    printf("\n");
}

int main(void) {
    int q[CTL_MAXNAME + 2]; int cur[CTL_MAXNAME] = {1}; size_t curlen = 1;
    for (int n = 0; n < 20000; n++) {
        q[0] = 0; q[1] = 2; memcpy(q + 2, cur, curlen * sizeof(int));
        int next[CTL_MAXNAME]; size_t nl = sizeof next;
        if (sysctl(q, (u_int)(curlen + 2), next, &nl, NULL, 0) != 0) break;
        curlen = nl / sizeof(int); memcpy(cur, next, nl);
        print_oid(cur, curlen);
    }
    // hw.optional.arm.caps as raw bytes (bit n = CAP_BIT n, LSB first).
    unsigned char caps[64]; size_t cl = sizeof caps;
    if (sysctlbyname("hw.optional.arm.caps", caps, &cl, NULL, 0) == 0) {
        printf("CAPS len=%zu bits:", cl);
        for (size_t i = 0; i < cl * 8; i++) if (caps[i / 8] & (1u << (i % 8))) printf(" %zu", i);
        printf("\n");
    } else printf("CAPS <err>\n");
    // Commpage (read-only words; time fields skipped).
    const volatile unsigned char *cp = (const volatile unsigned char *)0x0000000FFFFFC000ULL;
    printf("COMMPAGE signature=\"%.16s\"\n", (const char *)cp);
    printf("COMMPAGE caps64@0x010=0x%016llx\n", (unsigned long long)*(const volatile uint64_t *)(cp + 0x010));
    printf("COMMPAGE version@0x01E=%u\n", *(const volatile uint16_t *)(cp + 0x01E));
    printf("COMMPAGE caps32@0x020=0x%08x\n", *(const volatile uint32_t *)(cp + 0x020));
    printf("COMMPAGE ncpus@0x022=%u\n", cp[0x022]);
    printf("COMMPAGE user_page_shift32@0x024=%u 64@0x025=%u\n", cp[0x024], cp[0x025]);
    printf("COMMPAGE cache_linesize@0x026=%u\n", *(const volatile uint16_t *)(cp + 0x026));
    printf("COMMPAGE cpu_clusters@0x02F=%u active@0x034=%u physical@0x035=%u logical@0x036=%u kernel_page_shift@0x037=%u\n",
           cp[0x02F], cp[0x034], cp[0x035], cp[0x036], cp[0x037]);
    printf("COMMPAGE memory_size@0x038=%llu\n", (unsigned long long)*(const volatile uint64_t *)(cp + 0x038));
    printf("COMMPAGE cpufamily@0x080=0x%08x\n", *(const volatile uint32_t *)(cp + 0x080));
    printf("COMMPAGE dev_firm@0x084=0x%08x\n", *(const volatile uint32_t *)(cp + 0x084));
    printf("COMMPAGE user_timebase@0x090=%u cont_hwclock@0x091=%u\n", cp[0x090], cp[0x091]);
    printf("COMMPAGE bytes 0x000-0x0ff (time fields included, informational):\n");
    for (int i = 0; i < 0x100; i++) { printf("%02x", cp[i]); if (i % 32 == 31) printf("\n"); }
    printf("COMMPAGE cpu_to_cluster@0x200:");
    for (int i = 0; i < 32; i++) printf(" %u", cp[0x200 + i]);
    printf("\n");
    return 0;
}
