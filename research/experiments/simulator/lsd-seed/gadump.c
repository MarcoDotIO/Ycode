// gadump: our probe (stage 7, agent I4). Calls getattrlist(2) with the
// attribute groups and options given on the command line and hex-dumps the
// reply, so the Mac's simulator (level 3) and Ycode can be compared byte for byte.
// Usage: gadump <path> <common> <vol> <dir> <file> <fork> <options> [bufsize]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/attr.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 8) { fprintf(stderr, "usage\n"); return 2; }
    struct attrlist al; memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = (attrgroup_t)strtoul(argv[2], 0, 0);
    al.volattr = (attrgroup_t)strtoul(argv[3], 0, 0);
    al.dirattr = (attrgroup_t)strtoul(argv[4], 0, 0);
    al.fileattr = (attrgroup_t)strtoul(argv[5], 0, 0);
    al.forkattr = (attrgroup_t)strtoul(argv[6], 0, 0);
    unsigned long opts = strtoul(argv[7], 0, 0);
    size_t size = argc > 8 ? strtoul(argv[8], 0, 0) : 1024;
    unsigned char *buf = calloc(1, size);
    int r = getattrlist(argv[1], &al, buf, size, (unsigned)opts);
    printf("getattrlist -> %d errno %d\n", r, r ? errno : 0);
    if (r == 0) {
        unsigned len = *(unsigned *)buf;
        printf("length %u\n", len);
        for (unsigned i = 0; i < len && i < size; i += 16) {
            printf("%04x:", i);
            for (unsigned j = i; j < i + 16 && j < len && j < size; j++) printf(" %02x", buf[j]);
            printf("\n");
        }
    }
    return 0;
}
