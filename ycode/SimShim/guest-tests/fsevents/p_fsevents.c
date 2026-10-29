// Guest probe: the data volume's capabilities and the host's file-event
// service, through public API only (specs/simulator/file-system-features.md,
// fsevents-host.md "Ycode implementation"): getattrlist volume capabilities,
// document IDs and write generation counts, clonefile, renamex_np
// RENAME_EXCL / RENAME_SWAP, and an FSEvents stream on a folder of the
// guest that sees the probe's own file operations.
//   p_fsevents <folder>     (the folder is made; it should be on the data volume)
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

// The public FSEvents API (FSEvents.h of the macOS SDK; the iOS SDK exports
// these functions from CoreServices but ships no header).
typedef UInt32 FSEventStreamCreateFlags;
typedef UInt32 FSEventStreamEventFlags;
typedef UInt64 FSEventStreamEventId;
typedef struct __FSEventStream *FSEventStreamRef;
typedef const struct __FSEventStream *ConstFSEventStreamRef;
typedef struct {
    CFIndex version;
    void *info;
    const void *(*retain)(const void *);
    void (*release)(const void *);
    CFStringRef (*copyDescription)(const void *);
} FSEventStreamContext;
typedef void (*FSEventStreamCallback)(ConstFSEventStreamRef, void *, size_t, void *, const FSEventStreamEventFlags *,
                                      const FSEventStreamEventId *);
enum {
    kFSEventStreamCreateFlagNone = 0, kFSEventStreamCreateFlagFileEvents = 0x10, kFSEventStreamCreateFlagMarkSelf = 0x20,
    kFSEventStreamEventFlagHistoryDone = 0x10, kFSEventStreamEventFlagItemCreated = 0x100,
    kFSEventStreamEventFlagItemRemoved = 0x200, kFSEventStreamEventFlagItemRenamed = 0x800,
    kFSEventStreamEventFlagItemModified = 0x1000, kFSEventStreamEventFlagItemXattrMod = 0x8000,
    kFSEventStreamEventFlagItemIsFile = 0x10000, kFSEventStreamEventFlagItemIsDir = 0x20000,
    kFSEventStreamEventFlagOwnEvent = 0x80000,
};
#define kFSEventStreamEventIdSinceNow 0xFFFFFFFFFFFFFFFFULL
extern FSEventStreamRef FSEventStreamCreate(CFAllocatorRef, FSEventStreamCallback, FSEventStreamContext *, CFArrayRef,
                                            FSEventStreamEventId, CFTimeInterval, FSEventStreamCreateFlags);
extern FSEventStreamEventId FSEventStreamGetLatestEventId(ConstFSEventStreamRef);
extern FSEventStreamEventId FSEventsGetCurrentEventId(void);
extern CFUUIDRef FSEventsCopyUUIDForDevice(dev_t);
extern void FSEventStreamRelease(FSEventStreamRef);
extern void FSEventStreamSetDispatchQueue(FSEventStreamRef, dispatch_queue_t);
extern void FSEventStreamInvalidate(FSEventStreamRef);
extern Boolean FSEventStreamStart(FSEventStreamRef);
extern void FSEventStreamFlushSync(FSEventStreamRef);
extern void FSEventStreamStop(FSEventStreamRef);

static int failures;
static void check(int ok, const char *what) {
    printf("%s %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) failures++;
}

struct caps_reply {
    uint32_t length;
    vol_capabilities_attr_t caps;
} __attribute__((packed));

static void capabilities(const char *path) {
    struct attrlist al = {.bitmapcount = ATTR_BIT_MAP_COUNT, .volattr = ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES};
    struct caps_reply r;
    int rc = getattrlist(path, &al, &r, sizeof r, 0);
    uint32_t f = r.caps.capabilities[VOL_CAPABILITIES_FORMAT], i = r.caps.capabilities[VOL_CAPABILITIES_INTERFACES];
    printf("capabilities of %s: rc %d format 0x%08x interfaces 0x%08x\n", path, rc, f, i);
    check(rc == 0 && (f & (VOL_CAP_FMT_DOCUMENT_ID | VOL_CAP_FMT_WRITE_GENERATION_COUNT)) ==
                         (VOL_CAP_FMT_DOCUMENT_ID | VOL_CAP_FMT_WRITE_GENERATION_COUNT) &&
              (i & (VOL_CAP_INT_CLONE | VOL_CAP_INT_RENAME_EXCL)) == (VOL_CAP_INT_CLONE | VOL_CAP_INT_RENAME_EXCL),
          "the four capability bits");
}

struct ids_reply {
    uint32_t length;
    uint32_t gen;
    uint32_t doc;
} __attribute__((packed));

static struct ids_reply ids(const char *path) {
    struct attrlist al = {.bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = ATTR_CMN_GEN_COUNT | ATTR_CMN_DOCUMENT_ID};
    struct ids_reply r = {0};
    if (getattrlist(path, &al, &r, sizeof r, FSOPT_ATTR_CMN_EXTENDED) != 0) printf("getattrlist %s: errno %d\n", path, errno);
    return r;
}

static void writefile(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    write(fd, text, strlen(text));
    close(fd);
}

static int readfile(const char *path, char *buf, size_t size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, size - 1);
    close(fd);
    buf[n < 0 ? 0 : n] = 0;
    return (int)n;
}

// Events received by the stream's callback.
#define MAX_EVENTS 256
static char eventPaths[MAX_EVENTS][256];
static FSEventStreamEventFlags eventFlags[MAX_EVENTS];
static FSEventStreamEventId eventIDs[MAX_EVENTS];
static int eventCount;

static void callback(ConstFSEventStreamRef stream, void *info, size_t n, void *paths, const FSEventStreamEventFlags flags[],
                     const FSEventStreamEventId ids[]) {
    (void)stream; (void)info;
    char **p = paths;
    for (size_t i = 0; i < n && eventCount < MAX_EVENTS; i++, eventCount++) {
        snprintf(eventPaths[eventCount], sizeof eventPaths[0], "%s", p[i]);
        eventFlags[eventCount] = flags[i];
        eventIDs[eventCount] = ids[i];
    }
}

static FSEventStreamEventFlags flagsFor(const char *path) {
    FSEventStreamEventFlags f = 0;
    for (int i = 0; i < eventCount; i++) if (strcmp(eventPaths[i], path) == 0) f |= eventFlags[i];
    return f;
}

static FSEventStreamRef makeStream(const char *folder, FSEventStreamEventId since, FSEventStreamCreateFlags flags,
                                   dispatch_queue_t q) {
    CFStringRef s = CFStringCreateWithCString(NULL, folder, kCFStringEncodingUTF8);
    CFArrayRef list = CFArrayCreate(NULL, (const void **)&s, 1, &kCFTypeArrayCallBacks);
    FSEventStreamRef stream = FSEventStreamCreate(NULL, callback, NULL, list, since, 0.2, flags);
    CFRelease(list);
    CFRelease(s);
    FSEventStreamSetDispatchQueue(stream, q);
    return stream;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) { printf("usage: p_fsevents <folder>\n"); return 64; }
    char dir[900], path[1024], other[1024], text[64];
    snprintf(dir, sizeof dir, "%s", argv[1]);
    mkdir(dir, 0755);
    capabilities(dir);
    capabilities("/System/Library");

    // Write generation counts and document IDs.
    snprintf(path, sizeof path, "%s/doc", dir);
    writefile(path, "one");
    struct ids_reply a = ids(path);
    int fd = open(path, O_WRONLY | O_APPEND);
    write(fd, "!", 1);
    struct ids_reply b = ids(path);
    write(fd, "?", 1);
    close(fd);
    struct ids_reply c = ids(path);
    printf("generation counts %u %u %u, document id %u\n", a.gen, b.gen, c.gen, a.doc);
    check(a.gen != 0 && a.gen != b.gen && b.gen != c.gen && ids(path).gen == c.gen, "write generation count changes with each write");
    check(chflags(path, UF_TRACKED) == 0, "chflags UF_TRACKED");
    uint32_t doc = ids(path).doc;
    snprintf(other, sizeof other, "%s/doc.tmp", dir);
    writefile(other, "two");
    check(rename(other, path) == 0 && ids(path).doc == doc && doc != 0, "a safe save keeps the document id");

    // clonefile.
    snprintf(other, sizeof other, "%s/clone", dir);
    unlink(other);
    check(clonefile(path, other, 0) == 0 && readfile(other, text, sizeof text) == 3 && strcmp(text, "two") == 0, "clonefile");
    check(clonefile(path, other, 0) == -1 && errno == EEXIST, "clonefile onto an existing name: EEXIST");

    // renamex_np.
    check(renamex_np(path, other, RENAME_EXCL) == -1 && errno == EEXIST, "RENAME_EXCL onto an existing name: EEXIST");
    writefile(other, "three");
    check(renamex_np(path, other, RENAME_SWAP) == 0 && readfile(path, text, sizeof text) == 5, "RENAME_SWAP");
    snprintf(other, sizeof other, "%s/fresh", dir);
    unlink(other);
    check(renamex_np(path, other, RENAME_EXCL) == 0, "RENAME_EXCL onto a free name");

    // The file-event service.
    CFUUIDRef uuid = FSEventsCopyUUIDForDevice(0);
    check(uuid == NULL, "no UUID for device 0");
    struct stat st;
    stat(dir, &st);
    uuid = FSEventsCopyUUIDForDevice(st.st_dev);
    CFStringRef us = uuid ? CFUUIDCreateString(NULL, uuid) : NULL;
    char ustr[64] = "(none)";
    if (us) CFStringGetCString(us, ustr, sizeof ustr, kCFStringEncodingUTF8);
    FSEventStreamEventId now = FSEventsGetCurrentEventId();
    printf("device 0x%x uuid %s current id %llu\n", st.st_dev, ustr, now);
    check(uuid != NULL && now != 0, "device UUID and current event id");

    dispatch_queue_t q = dispatch_queue_create("p_fsevents", NULL);
    FSEventStreamRef stream = makeStream(dir, kFSEventStreamEventIdSinceNow,
                                         kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagMarkSelf, q);
    check(FSEventStreamStart(stream), "FSEventStreamStart");
    snprintf(path, sizeof path, "%s/new.txt", dir);
    writefile(path, "hello");
    chmod(path, 0600);
    setxattr(path, "com.example.probe", "x", 1, 0, 0);
    snprintf(other, sizeof other, "%s/renamed.txt", dir);
    rename(path, other);
    char sub[1024];
    snprintf(sub, sizeof sub, "%s/sub", dir);
    mkdir(sub, 0755);
    rmdir(sub);
    usleep(1000 * 1000);
    FSEventStreamFlushSync(stream);
    dispatch_sync(q, ^{});
    FSEventStreamStop(stream);
    int seen = 0;
    dispatch_sync(q, ^{});
    seen = eventCount;
    for (int i = 0; i < seen; i++) printf("event %llu 0x%08x %s\n", eventIDs[i], (unsigned)eventFlags[i], eventPaths[i]);
    char rpath[1024], rother[1024], rsub[1024];
    // Event paths are as the stream registered its folder (realpath form).
    char real[1024];
    realpath(dir, real);
    snprintf(rpath, sizeof rpath, "%s/new.txt", real);
    snprintf(rother, sizeof rother, "%s/renamed.txt", real);
    snprintf(rsub, sizeof rsub, "%s/sub", real);
    // (or as the probe passed it, if the client library maps them back)
    FSEventStreamEventFlags fNew = flagsFor(rpath) | flagsFor(path), fRenamed = flagsFor(rother) | flagsFor(other),
                            fSub = flagsFor(rsub) | flagsFor(sub);
    check((fNew & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile |
                   kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagOwnEvent)) ==
              (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile |
               kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagOwnEvent),
          "events of the new file: created, modified, renamed, own");
    check(fNew & kFSEventStreamEventFlagItemXattrMod, "extended attribute event");
    check(fRenamed & kFSEventStreamEventFlagItemRenamed, "event of the new name");
    check((fSub & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)) ==
              (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir),
          "directory created and removed");
    FSEventStreamEventId last = FSEventStreamGetLatestEventId(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);

    // A stream since an earlier id: HistoryDone.
    eventCount = 0;
    stream = makeStream(dir, last > 0 ? last - 1 : 1, kFSEventStreamCreateFlagNone, q);
    check(FSEventStreamStart(stream), "FSEventStreamStart since an id");
    usleep(500 * 1000);
    FSEventStreamFlushSync(stream);
    dispatch_sync(q, ^{});
    int history = 0;
    for (int i = 0; i < eventCount; i++) if (eventFlags[i] & kFSEventStreamEventFlagHistoryDone) history++;
    check(history == 1, "HistoryDone");
    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);

    printf("%s: %d failures\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}
