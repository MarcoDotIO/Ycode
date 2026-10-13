// urlprobe: our own probe (Ycode stage 9, agent J). For each path: stat/lstat,
// access(), NSURL resource values (all public keys), getattrlist with the
// attribute set LaunchServices' file nodes request (decoded), and fcntl/xattr
// answers. Used to compare the Mac's simulator (level 3) with Ycode.
#import <Foundation/Foundation.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
static void hexdump(const unsigned char *b, size_t n) {
  for (size_t i = 0; i < n; i += 16) { printf("    %04zx:", i); for (size_t j = i; j < i + 16 && j < n; j++) printf(" %02x", b[j]); printf("\n"); }
}
static void ga(const char *p, uint32_t cmn, uint32_t vol, uint32_t dir, uint32_t file, uint32_t fork, uint64_t opts) {
  struct attrlist al = {0}; al.bitmapcount = ATTR_BIT_MAP_COUNT; al.commonattr = cmn; al.volattr = vol; al.dirattr = dir; al.fileattr = file; al.forkattr = fork;
  unsigned char buf[2048]; memset(buf, 0xee, sizeof buf);
  int r = getattrlist(p, &al, buf, sizeof buf, opts);
  printf("  getattrlist [%#x,%#x,%#x,%#x,%#x] opts %#llx -> %d errno %d len %u\n", cmn, vol, dir, file, fork, opts, r, r ? errno : 0, r == 0 ? *(uint32_t *)buf : 0);
  if (r == 0) hexdump(buf, *(uint32_t *)buf > sizeof buf ? sizeof buf : *(uint32_t *)buf);
}
static void probe(const char *p) {
  printf("== %s\n", p);
  struct stat st;
  if (stat(p, &st) == 0) printf("  stat: dev %#x ino %llu mode 0%o nlink %u uid %u gid %u size %lld blocks %lld blksize %d flags %#x gen %u\n",
     (unsigned)st.st_dev, (unsigned long long)st.st_ino, st.st_mode, st.st_nlink, st.st_uid, st.st_gid, (long long)st.st_size, (long long)st.st_blocks, st.st_blksize, st.st_flags, st.st_gen);
  else printf("  stat: errno %d\n", errno);
  printf("  access R %d W %d X %d\n", access(p, R_OK), access(p, W_OK), access(p, X_OK));
  char v[64]; ssize_t xl = listxattr(p, NULL, 0, XATTR_NOFOLLOW); printf("  listxattr -> %zd errno %d\n", xl, xl < 0 ? errno : 0);
  ssize_t g = getxattr(p, "com.apple.installd.placeholder", v, 4, 0, 0); printf("  getxattr placeholder -> %zd errno %d\n", g, g < 0 ? errno : 0);
  NSURL *u = [NSURL fileURLWithPath:@(p)];
  NSArray *keys = @[NSURLNameKey, NSURLIsRegularFileKey, NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsVolumeKey, NSURLIsPackageKey,
    NSURLIsApplicationKey, NSURLIsSystemImmutableKey, NSURLIsUserImmutableKey, NSURLIsHiddenKey, NSURLHasHiddenExtensionKey,
    NSURLCreationDateKey, NSURLContentModificationDateKey, NSURLAttributeModificationDateKey, NSURLLinkCountKey, NSURLParentDirectoryURLKey,
    NSURLVolumeURLKey, NSURLTypeIdentifierKey, NSURLContentTypeKey, NSURLFileResourceIdentifierKey, NSURLVolumeIdentifierKey,
    NSURLPreferredIOBlockSizeKey, NSURLIsReadableKey, NSURLIsWritableKey, NSURLIsExecutableKey, NSURLPathKey, NSURLCanonicalPathKey,
    NSURLIsMountTriggerKey, NSURLGenerationIdentifierKey, NSURLDocumentIdentifierKey, NSURLAddedToDirectoryDateKey, NSURLFileResourceTypeKey,
    NSURLFileIdentifierKey, NSURLFileContentIdentifierKey, NSURLMayShareFileContentKey, NSURLMayHaveExtendedAttributesKey, NSURLIsPurgeableKey,
    NSURLIsSparseKey, NSURLFileSizeKey, NSURLFileAllocatedSizeKey, NSURLTotalFileSizeKey, NSURLTotalFileAllocatedSizeKey, NSURLIsAliasFileKey,
    NSURLFileProtectionKey, NSURLIsUbiquitousItemKey, NSURLUbiquitousItemDownloadingStatusKey, NSURLUbiquitousItemIsDownloadingKey,
    NSURLVolumeIsReadOnlyKey, NSURLVolumeIsLocalKey, NSURLVolumeIsInternalKey, NSURLVolumeIsRootFileSystemKey, NSURLVolumeNameKey,
    NSURLVolumeUUIDStringKey, NSURLVolumeSupportsFileCloningKey, NSURLVolumeIsEncryptedKey, NSURLVolumeLocalizedFormatDescriptionKey,
    NSURLVolumeTypeNameKey, NSURLVolumeSubtypeKey, NSURLVolumeMountFromLocationKey];
  NSError *err = nil;
  NSDictionary *d = [u resourceValuesForKeys:keys error:&err];
  if (!d) printf("  resourceValues error %s\n", err.description.UTF8String);
  for (NSString *k in keys) { id val = d[k]; NSString *s = [val description]; s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    printf("  %-44s %s\n", k.UTF8String, val ? s.UTF8String : "(none)"); }
  ga(p, 0xd61f9e0d, 0, 5, 1, 0x350, 0x25);
  ga(p, 0x8000000a | 0x40000, 0, 0, 0x200 | 0x4 | 0x2, 0, 0x1);
  ga(p, 0xd01fde0d, 0, 5, 1, 0x240, 0x25);
  ga(p, 0xd01f9e0d, 0, 5, 0x601, 0x240, 0x25);
  ga(p, 0xd81f9e0d, 0, 5, 1, 0x240, 0x25);
  ga(p, 0x8000008, 0, 0, 0, 0, 0);
}
int main(int argc, char **argv) { @autoreleasepool { for (int i = 1; i < argc; i++) probe(argv[i]); } return 0; }
