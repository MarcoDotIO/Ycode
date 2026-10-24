// byname_probe: sysctlbyname() for names given on the command line (Ycode
// research). Same build as cpufeat_probe.c. Shows whether the simulator's
// libsystem answers a name differently from the kernel OID walk.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        unsigned char buf[512]; size_t bl = sizeof buf;
        if (sysctlbyname(argv[i], buf, &bl, NULL, 0) != 0) { printf("%s = <err>\n", argv[i]); continue; }
        int text = bl > 0 && buf[bl - 1] == 0;
        for (size_t j = 0; j + 1 < bl; j++) if (buf[j] < 0x20 || buf[j] > 0x7e) text = 0;
        if (text) printf("%s = \"%s\"\n", argv[i], buf);
        else if (bl == 4) { uint32_t v; memcpy(&v, buf, 4); printf("%s = %u (4 bytes)\n", argv[i], v); }
        else if (bl == 8) { uint64_t v; memcpy(&v, buf, 8); printf("%s = %llu (8 bytes)\n", argv[i], (unsigned long long)v); }
        else { printf("%s = (%zu bytes) ", argv[i], bl); for (size_t j = 0; j < bl; j++) printf("%02x", buf[j]); printf("\n"); }
    }
    struct utsname u; uname(&u);
    printf("uname: %s %s %s %s\n", u.sysname, u.release, u.machine, u.version);
    return 0;
}
