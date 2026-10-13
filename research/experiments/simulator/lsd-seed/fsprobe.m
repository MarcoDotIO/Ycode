// fsprobe: our probe (stage 7, agent I4). For each path argument, prints what
// the public file-system interfaces report about it: stat, statfs, getattrlist
// volume attributes, NSURL volume resource values, and a directory listing.
// Used to compare the Mac's simulator (level 3) with Ycode.
// Build: see build.sh. Run: xcrun simctl spawn <dev> fsprobe <path>...
#import <Foundation/Foundation.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>

static void probe(const char *p) {
    printf("== %s\n", p);
    struct stat st;
    if (stat(p, &st) == 0) printf("stat: dev 0x%x ino %llu mode 0%o\n", (unsigned)st.st_dev, (unsigned long long)st.st_ino, st.st_mode);
    else printf("stat: errno %d\n", errno);
    struct statfs sf;
    if (statfs(p, &sf) == 0)
        printf("statfs: mnton '%s' from '%s' type '%s' flags 0x%x fsid {0x%x,0x%x}\n", sf.f_mntonname, sf.f_mntfromname,
               sf.f_fstypename, sf.f_flags, sf.f_fsid.val[0], sf.f_fsid.val[1]);
    else printf("statfs: errno %d\n", errno);
    struct attrlist al; memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_FSID;
    al.volattr = ATTR_VOL_INFO | ATTR_VOL_MOUNTPOINT | ATTR_VOL_NAME | ATTR_VOL_MOUNTFLAGS;
    unsigned char buf[4096]; memset(buf, 0, sizeof buf);
    int r = getattrlist(p, &al, buf, sizeof buf, 0);
    if (r == 0) {
        unsigned char *q = buf + 4;
        attribute_set_t *rs = (attribute_set_t *)q; q += sizeof(attribute_set_t);
        fsid_t fsid; memcpy(&fsid, q, sizeof fsid); q += sizeof fsid;
        attrreference_t *mp = (attrreference_t *)q; q += sizeof(attrreference_t);
        attrreference_t *nm = (attrreference_t *)q; q += sizeof(attrreference_t);
        uint32_t mf; memcpy(&mf, q, 4);
        printf("getattrlist(vol on object): returned cmn 0x%x vol 0x%x fsid {0x%x,0x%x} mountpoint '%s' name '%s' mountflags 0x%x\n",
               rs->commonattr, rs->volattr, fsid.val[0], fsid.val[1],
               rs->volattr & ATTR_VOL_MOUNTPOINT ? (char *)mp + mp->attr_dataoffset : "-",
               rs->volattr & ATTR_VOL_NAME ? (char *)nm + nm->attr_dataoffset : "-", mf);
    } else printf("getattrlist(vol on object): errno %d\n", errno);
    NSURL *u = [NSURL fileURLWithPath:@(p)];
    NSArray *keys = @[NSURLIsDirectoryKey, NSURLVolumeIdentifierKey, NSURLVolumeIsReadOnlyKey, NSURLVolumeIsLocalKey,
                      NSURLIsVolumeKey, NSURLVolumeIsRootFileSystemKey, NSURLVolumeNameKey, NSURLVolumeURLKey];
    NSError *e = nil;
    for (NSString *k in keys) {
        printf("url %s ...", k.UTF8String);
        id val = nil; e = nil;
        BOOL ok = [u getResourceValue:&val forKey:k error:&e];
        printf(" ok %d value %s error %s/%ld\n", ok, [[val description] UTF8String] ?: "(nil)",
               e ? e.domain.UTF8String : "-", (long)e.code);
        [u removeAllCachedResourceValues];
    }
    printf("listing ...\n");
    e = nil;
    NSArray *c = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:u includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                                  options:0 error:&e];
    if (c) printf("listing: %lu entries\n", (unsigned long)c.count);
    else printf("listing error: %s/%ld\n", e.domain.UTF8String, (long)e.code);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    @autoreleasepool {
        for (int i = 1; i < argc; i++) probe(argv[i]);
    }
    return 0;
}
