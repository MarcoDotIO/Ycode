// idregs_probe: reads the EL0-readable cache geometry registers (DCZID_EL0,
// CTR_EL0) with SIGILL protection (Ycode research). Same build as
// cpufeat_probe.c. DCZID_EL0 bits[3:0] = log2(words) of the DC ZVA block,
// bit 4 = DZP (DC ZVA prohibited). CTR_EL0 DminLine bits[19:16],
// IminLine bits[3:0] = log2(words).
#include <stdio.h>
#include <stdint.h>
#include <signal.h>
#include <setjmp.h>
static sigjmp_buf jb;
static void onill(int s) { (void)s; siglongjmp(jb, 1); }
int main(void) {
    signal(SIGILL, onill);
    uint64_t v;
    if (!sigsetjmp(jb, 1)) { __asm__ volatile("mrs %0, dczid_el0" : "=r"(v));
        printf("DCZID_EL0=0x%llx zva_block=%u bytes DZP=%llu\n", (unsigned long long)v, 4u << (v & 15), (unsigned long long)((v >> 4) & 1)); }
    else printf("DCZID_EL0 SIGILL\n");
    if (!sigsetjmp(jb, 1)) { __asm__ volatile("mrs %0, ctr_el0" : "=r"(v));
        printf("CTR_EL0=0x%llx dminline=%u bytes iminline=%u bytes\n", (unsigned long long)v, 4u << ((v >> 16) & 15), 4u << (v & 15)); }
    else printf("CTR_EL0 SIGILL\n");
    return 0;
}
