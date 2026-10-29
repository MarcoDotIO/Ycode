// Guest probe: kqueue EVFILT_VNODE through public API only
// (specs/simulator/threads-and-events.md §3.10): the notes a file and a
// directory get for the probe's own writes, size and mode changes,
// renames and deletes; accumulation until delivery, EV_CLEAR, EV_ONESHOT;
// a child process's write; a dispatch vnode source.
//   p_vnode <folder>                 the checks (the folder is made)
//   p_vnode watch <path> <seconds>   prints every note of <path> (a file or
//                                    directory, opened O_EVTONLY) as it comes
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int failures;
static void check(int ok, const char *what) {
    printf("%s %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) failures++;
}

#define ALL (NOTE_DELETE | NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_LINK | NOTE_RENAME | NOTE_REVOKE | NOTE_FUNLOCK)

static void names(unsigned f, char *out) {
    out[0] = 0;
    static const struct { unsigned bit; const char *name; } n[] = {
        {NOTE_DELETE, "DELETE"}, {NOTE_WRITE, "WRITE"}, {NOTE_EXTEND, "EXTEND"}, {NOTE_ATTRIB, "ATTRIB"},
        {NOTE_LINK, "LINK"}, {NOTE_RENAME, "RENAME"}, {NOTE_REVOKE, "REVOKE"}, {NOTE_FUNLOCK, "FUNLOCK"}};
    for (unsigned i = 0; i < sizeof n / sizeof n[0]; i++)
        if (f & n[i].bit) { if (out[0]) strcat(out, "|"); strcat(out, n[i].name); }
    if (!out[0]) strcpy(out, "-");
}

// The notes of `fd` in one zero-timeout scan of `kq` (0: none); other events are counted in *others.
static unsigned poll_notes(int kq, int fd, int *others) {
    struct kevent ev[8];
    struct timespec zero = {0, 0};
    int n = kevent(kq, NULL, 0, ev, 8, &zero);
    unsigned f = 0;
    for (int i = 0; i < n; i++) {
        if ((int)ev[i].ident == fd && ev[i].filter == EVFILT_VNODE) f |= ev[i].fflags;
        else if (others) (*others)++;
    }
    return f;
}

static int add(int kq, int fd, unsigned short flags, unsigned fflags) {
    struct kevent c;
    EV_SET(&c, fd, EVFILT_VNODE, flags, fflags, 0, NULL);
    return kevent(kq, &c, 1, NULL, 0, NULL);
}

static void expect_notes(int kq, int fd, unsigned want, const char *what) {
    unsigned got = poll_notes(kq, fd, NULL);
    char g[96], w[96], line[256];
    names(got, g);
    names(want, w);
    snprintf(line, sizeof line, "%s: %s (want %s)", what, g, w);
    check(got == want, line);
}

static int watch(const char *path, int seconds) {
    int fd = open(path, O_EVTONLY);
    if (fd < 0) { printf("watch: open %s: %s\n", path, strerror(errno)); return 1; }
    int kq = kqueue();
    if (add(kq, fd, EV_ADD | EV_CLEAR, ALL) != 0) { printf("watch: kevent: %s\n", strerror(errno)); return 1; }
    printf("watch: %s (fd %d)\n", path, fd);
    fflush(stdout);
    struct timeval start, now;
    gettimeofday(&start, NULL);
    for (;;) {
        gettimeofday(&now, NULL);
        long left = seconds - (now.tv_sec - start.tv_sec);
        if (left <= 0) break;
        struct timespec t = {left, 0};
        struct kevent ev;
        int n = kevent(kq, NULL, 0, &ev, 1, &t);
        if (n <= 0) continue;
        char f[96];
        names(ev.fflags, f);
        gettimeofday(&now, NULL);
        printf("watch: %s [wall %lld]\n", f, (long long)now.tv_sec * 1000 + now.tv_usec / 1000);
        fflush(stdout);
        if (ev.fflags & (NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)) {
            // The name now names another object: watch that.
            close(fd);
            for (int i = 0; i < 50 && (fd = open(path, O_EVTONLY)) < 0; i++) usleep(20000);
            if (fd < 0 || add(kq, fd, EV_ADD | EV_CLEAR, ALL) != 0) { printf("watch: lost %s\n", path); return 1; }
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "watch") == 0) return watch(argv[2], atoi(argv[3]));
    if (argc == 3 && strcmp(argv[1], "child-write") == 0) {
        int fd = open(argv[2], O_WRONLY | O_APPEND);
        return fd >= 0 && write(fd, "child", 5) == 5 ? 0 : 1;
    }
    if (argc != 2) { fprintf(stderr, "usage: p_vnode <folder> | watch <path> <seconds>\n"); return 64; }
    const char *dir = argv[1];
    char d[1024], f[1024], g[1024], sub[1024], other[1024], line[256];
    mkdir(dir, 0755);
    snprintf(d, sizeof d, "%s/vn-%d", dir, getpid());
    snprintf(f, sizeof f, "%s/file", d);
    snprintf(g, sizeof g, "%s/renamed", d);
    snprintf(sub, sizeof sub, "%s/sub", d);
    snprintf(other, sizeof other, "%s/vn-%d-other", dir, getpid());
    check(mkdir(d, 0755) == 0 && mkdir(other, 0755) == 0, "folders made");

    int kq = kqueue();
    int dfd = open(d, O_EVTONLY);
    check(kq >= 0 && dfd >= 0, "kqueue and directory open (O_EVTONLY)");
    check(add(kq, dfd, EV_ADD | EV_CLEAR, ALL) == 0, "EVFILT_VNODE on the directory");
    expect_notes(kq, dfd, 0, "directory, nothing yet");

    // A file is created in the directory.
    int fd = open(f, O_RDWR | O_CREAT | O_EXCL, 0644);
    check(fd >= 0, "file created");
    expect_notes(kq, dfd, NOTE_WRITE, "directory after a create");
    check(add(kq, fd, EV_ADD | EV_CLEAR, ALL) == 0, "EVFILT_VNODE on the file");

    check(write(fd, "hello", 5) == 5, "write");
    expect_notes(kq, fd, NOTE_WRITE | NOTE_EXTEND, "file after an extending write");
    check(pwrite(fd, "J", 1, 0) == 1, "pwrite inside");
    expect_notes(kq, fd, NOTE_WRITE, "file after a write inside it");
    expect_notes(kq, dfd, 0, "directory after the file's writes");
    check(fchmod(fd, 0600) == 0, "fchmod");
    expect_notes(kq, fd, NOTE_ATTRIB, "file after fchmod");
    check(ftruncate(fd, 4096) == 0, "ftruncate up");
    expect_notes(kq, fd, NOTE_ATTRIB | NOTE_EXTEND, "file after growing ftruncate");
    check(flock(fd, LOCK_EX) == 0 && flock(fd, LOCK_UN) == 0, "flock, unlock");
    expect_notes(kq, fd, NOTE_FUNLOCK, "file after flock unlock");

    // Accumulation: several changes, one event with every note.
    write(fd, "a", 1);
    fchmod(fd, 0644);
    expect_notes(kq, fd, NOTE_WRITE | NOTE_ATTRIB, "file after write + fchmod, one scan");

    // A child process's write reaches this process's knote.
    pid_t child;
    char *cargv[] = {argv[0], "child-write", f, NULL};
    int sp = posix_spawn(&child, argv[0], NULL, NULL, cargv, environ);
    int status = 0;
    if (sp == 0) waitpid(child, &status, 0);
    check(sp == 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0, "child wrote the file");
    expect_notes(kq, fd, NOTE_WRITE | NOTE_EXTEND, "file after the child's write");

    // Renames.
    check(rename(f, g) == 0, "rename in the directory");
    {
        int others = 0;
        unsigned dn = 0, fn = 0;
        struct kevent ev[8];
        struct timespec zero = {0, 0};
        int n = kevent(kq, NULL, 0, ev, 8, &zero);
        for (int i = 0; i < n; i++) {
            if ((int)ev[i].ident == fd) fn |= ev[i].fflags;
            else if ((int)ev[i].ident == dfd) dn |= ev[i].fflags;
            else others++;
        }
        char a[96], b[96];
        names(fn, a);
        names(dn, b);
        snprintf(line, sizeof line, "rename: file %s (want RENAME), directory %s (want WRITE)", a, b);
        check(fn == NOTE_RENAME && dn == NOTE_WRITE && others == 0, line);
    }
    check(mkdir(sub, 0755) == 0, "mkdir sub");
    expect_notes(kq, dfd, NOTE_WRITE | NOTE_LINK, "directory after mkdir");
    char moved[1100];
    snprintf(moved, sizeof moved, "%s/sub", other);
    check(rename(sub, moved) == 0 && rmdir(moved) == 0, "subdirectory moved out and removed");
    expect_notes(kq, dfd, NOTE_WRITE | NOTE_LINK, "directory after a subdirectory moved out");

    // EV_ONESHOT and a knote without EV_CLEAR.
    int fd2 = open(g, O_RDONLY);
    check(add(kq, fd2, EV_ADD | EV_ONESHOT, NOTE_WRITE) == 0, "EV_ONESHOT knote");
    write(fd, "b", 1);
    {
        struct kevent ev[8];
        struct timespec zero = {0, 0};
        int n = kevent(kq, NULL, 0, ev, 8, &zero), seen = 0;
        for (int i = 0; i < n; i++) if ((int)ev[i].ident == fd2) seen++;
        check(seen == 1, "EV_ONESHOT delivered once");
        struct kevent c;
        EV_SET(&c, fd2, EVFILT_VNODE, EV_DELETE, 0, 0, NULL);
        check(kevent(kq, &c, 1, NULL, 0, NULL) == -1 && errno == ENOENT, "EV_ONESHOT knote gone after delivery");
    }
    check(add(kq, fd2, EV_ADD, NOTE_ATTRIB) == 0, "knote without EV_CLEAR");
    fchmod(fd, 0600);
    expect_notes(kq, fd2, NOTE_ATTRIB, "without EV_CLEAR: first scan");
    expect_notes(kq, fd2, NOTE_ATTRIB, "without EV_CLEAR: fires again");
    close(fd2);

    // A dispatch vnode source (libdispatch's workloop path).
    {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block unsigned long seen = 0;
        dispatch_queue_t q = dispatch_queue_create("p_vnode", NULL);
        dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
                                                     DISPATCH_VNODE_WRITE | DISPATCH_VNODE_ATTRIB, q);
        dispatch_source_set_event_handler(s, ^{
            seen |= dispatch_source_get_data(s);
            dispatch_semaphore_signal(sem);
        });
        dispatch_activate(s);
        usleep(100000);
        write(fd, "c", 1);
        long r = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        check(r == 0 && (seen & DISPATCH_VNODE_WRITE), "dispatch vnode source fired for a write");
        dispatch_source_cancel(s);
        poll_notes(kq, fd, NULL);
    }

    // The file goes.
    check(unlink(g) == 0, "unlink");
    {
        // One scan: the file's and the directory's events come together.
        unsigned dn = 0, fn = 0;
        struct kevent ev[8];
        struct timespec zero = {0, 0};
        int n = kevent(kq, NULL, 0, ev, 8, &zero);
        for (int i = 0; i < n; i++) {
            if ((int)ev[i].ident == fd) fn |= ev[i].fflags;
            else if ((int)ev[i].ident == dfd) dn |= ev[i].fflags;
        }
        char a[96], b[96];
        names(fn, a);
        names(dn, b);
        snprintf(line, sizeof line, "unlink: file %s (want DELETE|LINK), directory %s (want WRITE)", a, b);
        check(fn == (NOTE_DELETE | NOTE_LINK) && dn == NOTE_WRITE, line);
    }
    close(fd);
    check(rmdir(d) == 0 && rmdir(other) == 0, "folders removed");
    expect_notes(kq, dfd, NOTE_DELETE | NOTE_LINK, "directory after rmdir");

    printf("p_vnode: %d failures\n", failures);
    return failures == 0 ? 0 : 1;
}
