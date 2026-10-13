// gabulk: our probe (stage 7, agent I4). getattrlistbulk(2) on a directory with
// the attribute groups and options given; hex-dumps the first records.
// Usage: gabulk <dir> <common> <dir> <file> <fork> <options> [records]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/attr.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 7) { fprintf(stderr, "usage\n"); return 2; }
    int fd = open(argv[1], O_RDONLY | O_DIRECTORY);
    if (fd < 0) { printf("open errno %d\n", errno); return 1; }
    struct attrlist al; memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = (attrgroup_t)strtoul(argv[2], 0, 0);
    al.dirattr = (attrgroup_t)strtoul(argv[3], 0, 0);
    al.fileattr = (attrgroup_t)strtoul(argv[4], 0, 0);
    al.forkattr = (attrgroup_t)strtoul(argv[5], 0, 0);
    unsigned long opts = strtoul(argv[6], 0, 0);
    int want = argc > 7 ? atoi(argv[7]) : 2;
    static unsigned char buf[65536];
    int n = getattrlistbulk(fd, &al, buf, sizeof buf, opts);
    printf("getattrlistbulk -> %d errno %d\n", n, n < 0 ? errno : 0);
    unsigned char *p = buf;
    for (int r = 0; r < n && r < want; r++) {
        unsigned len = *(unsigned *)p;
        printf("record %d length %u\n", r, len);
        for (unsigned i = 0; i < len; i += 16) {
            printf("%04x:", i);
            for (unsigned j = i; j < i + 16 && j < len; j++) printf(" %02x", p[j]);
            printf("\n");
        }
        p += len;
    }
    return 0;
}
