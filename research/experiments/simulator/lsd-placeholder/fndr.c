#include <stdio.h>
#include <string.h>
#include <sys/attr.h>
#include <unistd.h>
int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    struct attrlist al = {0}; al.bitmapcount = ATTR_BIT_MAP_COUNT; al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_OBJTYPE | ATTR_CMN_FNDRINFO;
    unsigned char b[256]; memset(b, 0xee, sizeof b);
    int r = getattrlist(argv[i], &al, b, sizeof b, FSOPT_NOFOLLOW);
    unsigned *u = (unsigned *)b;
    printf("%s -> %d len %u returned %#x objtype %u fi:", argv[i], r, u[0], u[1], u[6]);
    for (int k = 28; k < 60 && k < (int)u[0]; k++) printf(" %02x", b[k]);
    printf("\n");
  }
}
