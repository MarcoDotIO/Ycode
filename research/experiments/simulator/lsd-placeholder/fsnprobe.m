// fsnprobe: our own probe (Ycode stage 9, agent J): LaunchServices' file node
// (class FSNode, found by name at run time) for each path, and the answers of
// its no-argument BOOL getters and simple value getters. Mac vs Ycode.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
static void boolGetter(id n, const char *name) {
  SEL s = sel_registerName(name);
  if (![n respondsToSelector:s]) { printf("  %-28s (none)\n", name); return; }
  printf("  %-28s %d\n", name, ((BOOL (*)(id, SEL))objc_msgSend)(n, s));
}
int main(int argc, char **argv) {
  @autoreleasepool {
    Class c = objc_getClass("FSNode");
    if (!c) { printf("no FSNode\n"); return 1; }
    printf("simulatorRootPath %s\n", [[((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("simulatorRootPath")) description] UTF8String]);
    const char *cls[] = { "rootVolumeNode", "prebootVolumeNode", "systemDataVolumeNode", "userDataVolumeNode" };
    for (int i = 0; i < 4; i++) printf("+%s %s\n", cls[i], [[((id (*)(id, SEL))objc_msgSend)(c, sel_registerName(cls[i])) description] UTF8String]);
    for (int i = 1; i < argc; i++) {
      NSError *err = nil;
      id n = ((id (*)(id, SEL, id, unsigned long long, NSError **))objc_msgSend)([c alloc], sel_registerName("initWithURL:flags:error:"),
              [NSURL fileURLWithPath:@(argv[i])], 0, &err);
      printf("== %s\n  node %s err %s\n", argv[i], [[n description] UTF8String], err ? err.description.UTF8String : "nil");
      if (!n) continue;
      const char *bools[] = { "isDirectory", "isRegularFile", "isSymbolicLink", "isHidden", "isBusyDirectory", "isOnLocalVolume", "canIssueIO",
        "hasHiddenExtension", "hasPackageBit", "isAVCHDCollection", "isAliasFile", "isExecutable", "isExecutableModeFile", "isMountTrigger",
        "isOnDiskImage", "isResolvable", "isSecuredSystemContent", "isSideFault", "isVolume", 0 };
      for (int k = 0; bools[k]; k++) boolGetter(n, bools[k]);
      unsigned long long v = 0; NSError *e = nil;
      if (((BOOL (*)(id, SEL, unsigned long long *, NSError **))objc_msgSend)(n, sel_registerName("getDeviceNumber:error:"), &v, &e)) printf("  device %llu\n", v);
      if (((BOOL (*)(id, SEL, unsigned long long *, NSError **))objc_msgSend)(n, sel_registerName("getFileIdentifier:error:"), &v, &e)) printf("  fileid %llu\n", v); else printf("  fileid err %s\n", e.description.UTF8String);
      e = nil;
      for (NSString *key in @[NSURLFileIdentifierKey, NSURLFileResourceIdentifierKey, NSURLGenerationIdentifierKey, @"_NSURLInodeNumberKey", NSURLFileContentIdentifierKey, NSURLVolumeIdentifierKey]) {
        id val = nil; e = nil;
        BOOL ok = ((BOOL (*)(id, SEL, id *, id, unsigned long long, NSError **))objc_msgSend)(n, sel_registerName("getResourceValue:forKey:options:error:"), &val, key, 0, &e);
        printf("  rv %-36s ok %d %s %s\n", key.UTF8String, ok, [[val description] UTF8String], e ? e.description.UTF8String : "");
      }
      if (((BOOL (*)(id, SEL, unsigned long long *, NSError **))objc_msgSend)(n, sel_registerName("getInodeNumber:error:"), &v, &e)) printf("  inode %llu\n", v);
      if (((BOOL (*)(id, SEL, unsigned long long *, NSError **))objc_msgSend)(n, sel_registerName("getLength:error:"), &v, &e)) printf("  length %llu\n", v); else printf("  length err %s\n", e.description.UTF8String);
      uint32_t t = 0, cr = 0; e = nil;
      if (((BOOL (*)(id, SEL, uint32_t *, uint32_t *, NSError **))objc_msgSend)(n, sel_registerName("getHFSType:creator:error:"), &t, &cr, &e)) printf("  hfs type %08x creator %08x\n", t, cr); else printf("  hfs err %s\n", e.description.UTF8String);
      unsigned char fi[32] = {0}; e = nil;
      if (((BOOL (*)(id, SEL, void *, NSError **))objc_msgSend)(n, sel_registerName("getFinderInfo:error:"), fi, &e)) { printf("  finderinfo"); for (int k = 0; k < 16; k++) printf(" %02x", fi[k]); printf("\n"); } else printf("  finderinfo err %s\n", e.description.UTF8String);
      e = nil; id vol = ((id (*)(id, SEL, unsigned long long, NSError **))objc_msgSend)(n, sel_registerName("volumeNodeWithFlags:error:"), 0, &e);
      printf("  volume %s err %s\n", [[vol description] UTF8String], e ? e.description.UTF8String : "nil");
      e = nil; id sf = ((id (*)(id, SEL, NSError **))objc_msgSend)(n, sel_registerName("sideFaultResourceValuesWithError:"), &e);
      printf("  sideFaultValues %s err %s\n", [[sf description] UTF8String], e ? e.description.UTF8String : "nil");
      e = nil; id di = ((id (*)(id, SEL, unsigned long long, NSError **))objc_msgSend)(n, sel_registerName("diskImageURLWithFlags:error:"), 0, &e);
      printf("  diskImageURL %s err %s\n", [[di description] UTF8String], e ? e.description.UTF8String : "nil");
    }
  }
  return 0;
}
