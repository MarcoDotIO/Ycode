// Gauge's in-app agent for the Ycode simulator (specs/ide/profiler.md §3.1).
// Original Ycode code, built with the iOS simulator SDK's public headers.
//
// Inserted into an app launched under `ycode-simd --profile` (DYLD_INSERT_LIBRARIES).
// It interposes three public functions through dyld's interposing section
// (a `__DATA,__interpose` array of {replacement, original} pointer pairs):
//   os_log_create                     remembers each handle's subsystem and category
//   os_signpost_enabled               true while recording (the emit macros check it)
//   _os_signpost_emit_with_name_impl  writes one record, then calls the original
// Records go to the file named by YCODE_GAUGE_SIGNPOSTS, one write(2) each
// (O_APPEND), so a killed app loses nothing already written:
//   "YGS1", u16 record length, u8 type (0 event, 1 begin, 2 end), u8 0,
//   u64 mach_absolute_time, u64 signpost id, u64 thread id (pthread_threadid_np),
//   then subsystem, category, name and format as NUL-terminated strings.
// The message is the format string; argument values are not decoded.
#include <fcntl.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <os/log.h>
#include <os/signpost.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int gauge_fd = -1;

#define GAUGE_HANDLES 256
static struct { const void *log; char subsystem[96]; char category[64]; } gauge_handles[GAUGE_HANDLES];
static int gauge_handle_count;
static os_unfair_lock gauge_lock = OS_UNFAIR_LOCK_INIT;

__attribute__((constructor)) static void gauge_start(void) {
    const char *path = getenv("YCODE_GAUGE_SIGNPOSTS");
    if (path && *path) gauge_fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
}

static void copy_string(char *to, size_t size, const char *from) {
    if (!from) from = "";
    size_t n = strlen(from);
    if (n >= size) n = size - 1;
    memcpy(to, from, n);
    to[n] = 0;
}

static os_log_t gauge_os_log_create(const char *subsystem, const char *category) {
    os_log_t log = os_log_create(subsystem, category);
    os_unfair_lock_lock(&gauge_lock);
    int i = 0;
    while (i < gauge_handle_count && gauge_handles[i].log != (const void *)log) i++;
    if (i == gauge_handle_count && gauge_handle_count < GAUGE_HANDLES) {
        gauge_handles[i].log = (const void *)log;
        copy_string(gauge_handles[i].subsystem, sizeof(gauge_handles[i].subsystem), subsystem);
        copy_string(gauge_handles[i].category, sizeof(gauge_handles[i].category), category);
        gauge_handle_count++;
    }
    os_unfair_lock_unlock(&gauge_lock);
    return log;
}

static bool gauge_os_signpost_enabled(os_log_t log) {
    return gauge_fd >= 0 ? true : os_signpost_enabled(log);
}

static void gauge_emit(void *dso, os_log_t log, os_signpost_type_t type, os_signpost_id_t spid, const char *name,
                       const char *format, uint8_t *buf, uint32_t size) {
    if (gauge_fd >= 0) {
        uint8_t record[512];
        uint64_t now = mach_absolute_time(), tid = 0;
        pthread_threadid_np(NULL, &tid);
        const char *subsystem = "", *category = "";
        os_unfair_lock_lock(&gauge_lock);
        for (int i = 0; i < gauge_handle_count; i++) {
            if (gauge_handles[i].log == (const void *)log) { subsystem = gauge_handles[i].subsystem; category = gauge_handles[i].category; break; }
        }
        size_t p = 32;
        const char *strings[4] = {subsystem, category, name ? name : "", format ? format : ""};
        for (int i = 0; i < 4; i++) {
            size_t n = strlen(strings[i]);
            if (p + n + 1 > sizeof(record)) n = sizeof(record) - p - 1;
            memcpy(record + p, strings[i], n);
            record[p + n] = 0;
            p += n + 1;
            if (p >= sizeof(record)) break;
        }
        os_unfair_lock_unlock(&gauge_lock);
        memcpy(record, "YGS1", 4);
        record[4] = (uint8_t)(p & 0xFF);
        record[5] = (uint8_t)(p >> 8);
        record[6] = (uint8_t)(type & 0x03);
        record[7] = 0;
        memcpy(record + 8, &now, 8);
        uint64_t id = spid;
        memcpy(record + 16, &id, 8);
        memcpy(record + 24, &tid, 8);
        (void)write(gauge_fd, record, p);
    }
    _os_signpost_emit_with_name_impl(dso, log, type, spid, name, format, buf, size);
}

struct gauge_interpose { const void *replacement; const void *original; };
__attribute__((used, section("__DATA,__interpose"))) static const struct gauge_interpose gauge_interposers[] = {
    {(const void *)&gauge_os_log_create, (const void *)&os_log_create},
    {(const void *)&gauge_os_signpost_enabled, (const void *)&os_signpost_enabled},
    {(const void *)&gauge_emit, (const void *)&_os_signpost_emit_with_name_impl},
};
