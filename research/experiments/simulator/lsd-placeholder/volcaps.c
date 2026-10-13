// volcaps: our probe: ATTR_VOL_CAPABILITIES and ATTR_VOL_ATTRIBUTES (decoded) and statfs of each path.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <sys/attr.h>
#include <sys/mount.h>
int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    struct attrlist al = {0}; al.bitmapcount = ATTR_BIT_MAP_COUNT; al.volattr = ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES | ATTR_VOL_ATTRIBUTES;
    unsigned char b[512]; memset(b, 0, sizeof b);
    int r = getattrlist(argv[i], &al, b, sizeof b, 0);
    uint32_t *u = (uint32_t *)(b + 4);
    printf("%s -> %d e%d\n  caps fmt %#010x int %#010x | valid fmt %#010x int %#010x\n", argv[i], r, r ? errno : 0, u[0], u[1], u[4], u[5]);
    printf("  attrs valid cmn %#x vol %#x dir %#x file %#x fork %#x | native cmn %#x vol %#x dir %#x file %#x fork %#x\n", u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15], u[16], u[17]);
    struct statfs s; if (statfs(argv[i], &s) == 0) printf("  statfs flags %#x type %s sub %u iosize %d bsize %u fsid %#x mnton %s from %s\n", s.f_flags, s.f_fstypename, s.f_fssubtype, s.f_iosize, s.f_bsize, s.f_fsid.val[0], s.f_mntonname, s.f_mntfromname);
  }
}
