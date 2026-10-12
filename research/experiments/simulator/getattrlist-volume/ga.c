// ga: our probe (stage 7): getattrlist volume attributes (ATTR_VOL_UUID) with
// and without ATTR_VOL_INFO, on a volume root and on a plain directory.
// Build: xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.0-simulator -o /tmp/ga ga.c
// Run:   xcrun simctl spawn booted /tmp/ga <path>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/attr.h>
#include <unistd.h>
int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/private/var";
    for (int info = 0; info < 2; info++) {
        struct attrlist al; memset(&al, 0, sizeof al);
        al.bitmapcount = ATTR_BIT_MAP_COUNT;
        al.volattr = ATTR_VOL_UUID | (info ? ATTR_VOL_INFO : 0);
        unsigned char buf[64]; memset(buf, 0, sizeof buf);
        int r = getattrlist(path, &al, buf, sizeof buf, 0);
        printf("%s volattr=0x%x -> %d errno %d len %u uuid-nonzero %d\n", path, al.volattr, r, r ? errno : 0,
               *(unsigned *)buf, buf[4] | buf[5] | buf[19]);
    }
    return 0;
}
