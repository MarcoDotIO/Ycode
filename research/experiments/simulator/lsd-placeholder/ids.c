// ids: FILEID, PARENTID, OBJID, PAROBJID, DEVID, MOUNTSTATUS of each path (our probe).
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <sys/attr.h>
#include <unistd.h>
#include <errno.h>
int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    struct attrlist al = {0}; al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_OBJID | ATTR_CMN_PAROBJID | ATTR_CMN_FILEID | ATTR_CMN_PARENTID;
    al.dirattr = ATTR_DIR_MOUNTSTATUS;
    unsigned char b[256]; memset(b, 0, sizeof b);
    int r = getattrlist(argv[i], &al, b, sizeof b, FSOPT_NOFOLLOW);
    uint32_t *u = (uint32_t *)(b + 4);
    uint64_t fid, pid; memcpy(&fid, b + 28, 8); memcpy(&pid, b + 36, 8);
    printf("%s -> %d(e%d) dev %#x type %u objid %u/%u parobjid %u/%u fileid %llu parentid %llu mountstatus %u\n", argv[i], r, r ? errno : 0, u[0], u[1], u[2], u[3], u[4], u[5], fid, pid, *(uint32_t *)(b + 44));
  }
}
