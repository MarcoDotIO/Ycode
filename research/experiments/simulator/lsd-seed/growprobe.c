// growprobe: our probe (stage 7, agent I4). Grows a buffer the way a
// vm_allocate / vm_copy / vm_deallocate pattern does (256 KiB steps to
// 16 MiB), writes a pattern after each step, and checks every word; also
// interleaves malloc traffic. Prints the first mismatch, if any.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>

static int check(const unsigned *p, size_t words, unsigned seed) {
    for (size_t i = 0; i < words; i++) if (p[i] != (unsigned)(i * 2654435761u + seed)) {
        printf("mismatch at word %zu (%p): %08x want %08x\n", i, (void *)&p[i], p[i], (unsigned)(i * 2654435761u + seed));
        return 1;
    }
    return 0;
}
int main(void) {
    vm_address_t buf = 0; vm_size_t size = 0x280000;
    if (vm_allocate(mach_task_self(), &buf, size, VM_FLAGS_ANYWHERE | VM_MAKE_TAG(43)) != KERN_SUCCESS) return 1;
    for (size_t i = 0; i < size / 4; i++) ((unsigned *)buf)[i] = (unsigned)(i * 2654435761u + 7);
    int bad = 0;
    vm_address_t regions[32]; int nregions = 0;
    for (int step = 0; step < 56 && !bad; step++) {
        vm_size_t nsize = size + 0x40000;
        vm_address_t nb = 0;
        kern_return_t kr = vm_allocate(mach_task_self(), &nb, nsize, VM_FLAGS_ANYWHERE | VM_MAKE_TAG(43));
        if (kr) { printf("vm_allocate %d\n", kr); return 1; }
        kr = vm_copy(mach_task_self(), buf, size, nb);
        if (kr) { printf("vm_copy %d\n", kr); return 1; }
        vm_deallocate(mach_task_self(), buf, size);
        void *noise[64]; for (int k = 0; k < 64; k++) { noise[k] = malloc(100 + k * 300); memset(noise[k], k, 100 + k * 300); }
        if (step % 3 == 0 && nregions < 32) {
            // A malloc-style region: 4 MiB aligned to 4 MiB, filled with a pattern.
            vm_address_t r = 0;
            kr = vm_map(mach_task_self(), &r, 0x400000, 0x3fffff, VM_FLAGS_ANYWHERE | VM_MAKE_TAG(2), MACH_PORT_NULL, 0,
                             0, VM_PROT_DEFAULT, VM_PROT_ALL, VM_INHERIT_DEFAULT);
            if (kr) { printf("mach_vm_map %d\n", kr); return 1; }
            for (size_t i = 0; i < 0x100000; i++) ((unsigned *)r)[i] = (unsigned)(i * 2654435761u + 1000 + nregions);
            regions[nregions++] = r;
        }
        for (int q = 0; q < nregions && !bad; q++) bad = check((unsigned *)regions[q], 0x100000, 1000 + q);
        bad = check((unsigned *)nb, size / 4, 7);
        for (size_t i = size / 4; i < nsize / 4; i++) ((unsigned *)nb)[i] = (unsigned)(i * 2654435761u + 7);
        for (int k = 0; k < 64; k++) free(noise[k]);
        printf("step %d: %#lx bytes at %#lx (%d regions, last %#llx) %s\n", step, (unsigned long)nsize, (unsigned long)nb, nregions, nregions ? (unsigned long long)regions[nregions-1] : 0ull, bad ? "BAD" : "ok");
        buf = nb; size = nsize;
    }
    return bad;
}
