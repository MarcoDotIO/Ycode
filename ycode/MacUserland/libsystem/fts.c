// fts.c - file hierarchy traversal (fts(3)) for Ycode's libSystem
// (specs/macos/libsystem.md §12). Clean-room Ycode code from the fts(3)
// manual's description of the interface; FTS and FTSENT are the public
// <fts_compat.h> layouts (the ones programs built for releases before
// macOS 28 use).
//
// Ycode's traversal never changes the working directory (as if FTS_NOCHDIR
// were always given): fts_accpath is the full path. Each entry owns its
// path string and sits in a private node that also holds its child list.
// A directory's children are read when it is first left in preorder and
// freed when it is returned in postorder.
#include "ycl.h"

struct ycl_ftsent {
    struct ycl_ftsent *fts_cycle, *fts_parent, *fts_link;
    long fts_number;
    void *fts_pointer;
    char *fts_accpath, *fts_path;
    int fts_errno, fts_symfd;
    unsigned short fts_pathlen, fts_namelen;
    uint64_t fts_ino;
    int32_t fts_dev;
    uint16_t fts_nlink;
    short fts_level;
    unsigned short fts_info, fts_flags, fts_instr;
    void *fts_statp;
    char fts_name[1];
};

typedef struct {
    struct ycl_ftsent *fts_cur, *fts_child, **fts_array;
    int32_t fts_dev;
    char *fts_path;
    int fts_rfd, fts_pathlen, fts_nitems;
    int (*fts_compar)(const struct ycl_ftsent **, const struct ycl_ftsent **);
    int fts_options;
} FTS;

enum {
    COMFOLLOW = 0x1, LOGICAL = 0x2, NOSTAT = 0x8, PHYSICAL = 0x10, SEEDOT = 0x20, XDEV = 0x40,
    COMFOLLOWDIR = 0x400, NOSTAT_TYPE = 0x800,
    I_D = 1, I_DC = 2, I_DEFAULT = 3, I_DNR = 4, I_DOT = 5, I_DP = 6, I_ERR = 7, I_F = 8, I_INIT = 9, I_NS = 10,
    I_NSOK = 11, I_SL = 12, I_SLNONE = 13,
    S_AGAIN = 1, S_FOLLOW = 2, S_NOINSTR = 3, S_SKIP = 4,
    STAT_SIZE = 144, IFMT = 0170000, IFDIR = 0040000, IFLNK = 0120000, IFREG = 0100000,
    DT_DIR_ = 4, DT_REG_ = 8, DT_LNK_ = 10,
};

int stat(const char *, void *);
int lstat(const char *, void *);
void qsort(void *, size_t, size_t, int (*)(const void *, const void *));
size_t strlcat(char *, const char *, size_t);

struct ycl_dirent {
    uint64_t d_ino, d_seekoff;
    uint16_t d_reclen, d_namlen;
    uint8_t d_type;
    char d_name[1024];
};
void *opendir(const char *);
struct ycl_dirent *readdir(void *);
int closedir(void *);

static uint16_t mode_of(const void *st) { return *(const uint16_t *)((const char *)st + 4); }

struct node {
    struct ycl_ftsent *children;
    struct ycl_ftsent e;  // last: fts_name grows past the end
};

static struct ycl_ftsent **children_of(struct ycl_ftsent *e) {
    return &((struct node *)((char *)e - __builtin_offsetof(struct node, e)))->children;
}

static struct ycl_ftsent *new_entry(const char *dir, const char *name, size_t namelen, struct ycl_ftsent *parent,
                                    int with_stat) {
    size_t dirlen = dir ? strlen(dir) : 0;
    int slash = dirlen && dir[dirlen - 1] != '/';
    size_t pathlen = dirlen + (size_t)slash + namelen;
    struct node *n = calloc(1, sizeof *n + namelen);
    char *path = malloc(pathlen + 1);
    void *st = with_stat ? calloc(1, STAT_SIZE) : 0;
    if (!n || !path || (with_stat && !st)) {
        free(n);
        free(path);
        free(st);
        return 0;
    }
    struct ycl_ftsent *e = &n->e;
    if (dirlen) memcpy(path, dir, dirlen);
    if (slash) path[dirlen] = '/';
    memcpy(path + dirlen + slash, name, namelen);
    path[pathlen] = 0;
    memcpy(e->fts_name, name, namelen);
    e->fts_name[namelen] = 0;
    e->fts_namelen = (unsigned short)namelen;
    e->fts_path = e->fts_accpath = path;
    e->fts_pathlen = (unsigned short)(pathlen > 0xFFFF ? 0xFFFF : pathlen);
    e->fts_parent = parent;
    e->fts_level = parent ? (short)(parent->fts_level + 1) : 0;
    e->fts_statp = st;
    e->fts_instr = S_NOINSTR;
    e->fts_symfd = -1;
    return e;
}

static void free_entry(struct ycl_ftsent *e) {
    if (!e) return;
    free(e->fts_path);
    free(e->fts_statp);
    free((char *)e - __builtin_offsetof(struct node, e));
}

static void free_list(struct ycl_ftsent *e) {
    while (e) {
        struct ycl_ftsent *next = e->fts_link;
        free_entry(e);
        e = next;
    }
}

// Classifies `e` with stat information (follow: use stat, not lstat).
static void classify(FTS *fts, struct ycl_ftsent *e, int follow, int dtype) {
    if (!e->fts_statp) {
        // FTS_NOSTAT: the directory entry's type only.
        if (dtype == DT_DIR_) e->fts_info = I_D;
        else if ((fts->fts_options & NOSTAT_TYPE) && dtype == DT_REG_) e->fts_info = I_F;
        else if ((fts->fts_options & NOSTAT_TYPE) && dtype == DT_LNK_) e->fts_info = I_SL;
        else e->fts_info = I_NSOK;
        return;
    }
    int r = follow ? stat(e->fts_accpath, e->fts_statp) : lstat(e->fts_accpath, e->fts_statp);
    if (r != 0 && follow && ycl_errno == YCL_ENOENT && lstat(e->fts_accpath, e->fts_statp) == 0) {
        e->fts_info = I_SLNONE;
        e->fts_errno = 0;
        return;
    }
    if (r != 0) {
        e->fts_errno = ycl_errno;
        e->fts_info = I_NS;
        return;
    }
    const char *st = e->fts_statp;
    e->fts_dev = *(const int32_t *)st;
    e->fts_nlink = *(const uint16_t *)(st + 6);
    e->fts_ino = *(const uint64_t *)(st + 8);
    uint16_t mode = mode_of(st) & IFMT;
    if (mode == IFDIR) {
        int dot = e->fts_name[0] == '.' && (!e->fts_name[1] || (e->fts_name[1] == '.' && !e->fts_name[2]));
        e->fts_info = dot && e->fts_level > 0 ? I_DOT : I_D;
        for (struct ycl_ftsent *p = e->fts_parent; p && p->fts_level >= 0; p = p->fts_parent)
            if (p->fts_ino == e->fts_ino && p->fts_dev == e->fts_dev) {
                e->fts_info = I_DC;
                e->fts_cycle = p;
                break;
            }
    } else if (mode == IFLNK) {
        e->fts_info = I_SL;
    } else if (mode == IFREG) {
        e->fts_info = I_F;
    } else {
        e->fts_info = I_DEFAULT;
    }
}

static int compare_entries(const void *a, const void *b, FTS *fts) {
    return fts->fts_compar((const struct ycl_ftsent **)a, (const struct ycl_ftsent **)b);
}

static FTS *sort_fts;  // the FTS whose comparison qsort is calling (under sort_lock)
static os_unfair_lock sort_lock;
static int sort_trampoline(const void *a, const void *b) { return compare_entries(a, b, sort_fts); }

// Sorts a linked list with the FTS comparison; returns the new head.
static struct ycl_ftsent *sort_list(FTS *fts, struct ycl_ftsent *head) {
    if (!fts->fts_compar || !head || !head->fts_link) return head;
    size_t n = 0;
    for (struct ycl_ftsent *e = head; e; e = e->fts_link) n++;
    struct ycl_ftsent **array = malloc(n * sizeof *array);
    if (!array) return head;
    n = 0;
    for (struct ycl_ftsent *e = head; e; e = e->fts_link) array[n++] = e;
    os_unfair_lock_lock(&sort_lock);
    sort_fts = fts;
    qsort(array, n, sizeof *array, sort_trampoline);
    os_unfair_lock_unlock(&sort_lock);
    for (size_t i = 0; i + 1 < n; i++) array[i]->fts_link = array[i + 1];
    array[n - 1]->fts_link = 0;
    head = array[0];
    free(array);
    return head;
}

// The children of directory `dir`, classified and sorted; 0 if empty or
// unreadable (then dir becomes FTS_DNR with fts_errno set).
static struct ycl_ftsent *read_children(FTS *fts, struct ycl_ftsent *dir) {
    void *d = opendir(dir->fts_accpath);
    if (!d) {
        dir->fts_errno = ycl_errno;
        dir->fts_info = I_DNR;
        return 0;
    }
    struct ycl_ftsent *head = 0, **tail = &head;
    struct ycl_dirent *de;
    int with_stat = !(fts->fts_options & NOSTAT);
    while ((de = readdir(d))) {
        int dot = de->d_name[0] == '.' && (!de->d_name[1] || (de->d_name[1] == '.' && !de->d_name[2]));
        if (dot && !(fts->fts_options & SEEDOT)) continue;
        struct ycl_ftsent *e = new_entry(dir->fts_path, de->d_name, de->d_namlen, dir, with_stat);
        if (!e) break;
        classify(fts, e, (fts->fts_options & LOGICAL) != 0, de->d_type);
        if (dot) e->fts_info = I_DOT;
        *tail = e;
        tail = &e->fts_link;
    }
    closedir(d);
    return sort_list(fts, head);
}

YCL_EXPORT FTS *fts_open(char *const *paths, int options,
                         int (*compar)(const struct ycl_ftsent **, const struct ycl_ftsent **)) {
    FTS *fts = calloc(1, sizeof *fts);
    struct ycl_ftsent *root_parent = new_entry(0, "", 0, 0, 0);
    if (!fts || !root_parent) {
        free(fts);
        free_entry(root_parent);
        ycl_errno = YCL_ENOMEM;
        return 0;
    }
    if (!(options & (LOGICAL | PHYSICAL))) options |= PHYSICAL;
    fts->fts_options = options;
    fts->fts_compar = compar;
    root_parent->fts_level = -1;
    root_parent->fts_info = I_INIT;
    struct ycl_ftsent *head = 0, **tail = &head;
    for (; paths && *paths; paths++) {
        struct ycl_ftsent *e = new_entry(0, *paths, strlen(*paths), root_parent, 1);
        if (!e) break;
        e->fts_level = 0;
        int follow = (options & (LOGICAL | COMFOLLOW)) != 0;
        classify(fts, e, follow, 0);
        if ((options & COMFOLLOWDIR) && e->fts_info == I_SL) {
            classify(fts, e, 1, 0);
            if (e->fts_info != I_D) classify(fts, e, 0, 0);
        }
        *tail = e;
        tail = &e->fts_link;
    }
    head = sort_list(fts, head);
    *children_of(root_parent) = head;  // the roots, for fts_read and fts_close
    fts->fts_child = root_parent;       // Ycode: the root parent owns every entry
    fts->fts_cur = 0;
    if (head) fts->fts_dev = head->fts_dev;
    return fts;
}

static struct ycl_ftsent *first_root(FTS *fts) { return fts->fts_child ? *children_of(fts->fts_child) : 0; }

YCL_EXPORT struct ycl_ftsent *fts_read(FTS *fts) {
    struct ycl_ftsent *cur = fts->fts_cur;
    if (!cur) {
        cur = first_root(fts);
        fts->fts_cur = cur;
        return cur;
    }
    unsigned short instr = cur->fts_instr;
    cur->fts_instr = S_NOINSTR;
    if (instr == S_AGAIN) {
        classify(fts, cur, (fts->fts_options & LOGICAL) != 0, 0);
        return cur;
    }
    if (instr == S_FOLLOW && (cur->fts_info == I_SL || cur->fts_info == I_SLNONE)) {
        classify(fts, cur, 1, 0);
        if (cur->fts_info == I_D) return cur;
    }
    // Descend into a preorder directory.
    if (cur->fts_info == I_D && instr != S_SKIP &&
        !((fts->fts_options & XDEV) && cur->fts_level > 0 && cur->fts_dev != fts->fts_dev)) {
        struct ycl_ftsent **list = children_of(cur);
        if (!*list) *list = read_children(fts, cur);
        if (*list) {
            fts->fts_cur = *list;
            return *list;
        }
        if (cur->fts_info == I_DNR) return cur;  // unreadable: reported instead of the postorder visit
        cur->fts_info = I_DP;
        return cur;
    }
    // Move to the next sibling, or up to the parent's postorder visit.
    for (;;) {
        if (cur->fts_link) {
            fts->fts_cur = cur->fts_link;
            return fts->fts_cur;
        }
        struct ycl_ftsent *parent = cur->fts_parent;
        if (!parent || parent->fts_level < 0) {
            fts->fts_cur = cur;
            ycl_errno = 0;
            return 0;  // the traversal is over
        }
        if (parent->fts_info == I_D) {
            free_list(*children_of(parent));
            *children_of(parent) = 0;
            parent->fts_info = I_DP;
            fts->fts_cur = parent;
            return parent;
        }
        cur = parent;
    }
}

YCL_EXPORT int fts_set(FTS *fts, struct ycl_ftsent *e, int instr) {
    (void)fts;
    if (instr != 0 && instr != S_AGAIN && instr != S_FOLLOW && instr != S_NOINSTR && instr != S_SKIP) {
        ycl_errno = YCL_EINVAL;
        return -1;
    }
    e->fts_instr = (unsigned short)(instr ? instr : S_NOINSTR);
    return 0;
}

// The children of the current directory as a list the caller may read until
// the next fts call; Ycode reads them afresh and frees them on the next call.
YCL_EXPORT struct ycl_ftsent *fts_children(FTS *fts, int options) {
    (void)options;
    struct ycl_ftsent *cur = fts->fts_cur;
    if (!cur) return first_root(fts);
    if (cur->fts_info != I_D) {
        ycl_errno = 0;
        return 0;
    }
    struct ycl_ftsent **list = children_of(cur);
    if (!*list) *list = read_children(fts, cur);
    return *list;
}

static void free_tree(struct ycl_ftsent *e) {
    while (e) {
        struct ycl_ftsent *next = e->fts_link;
        free_tree(*children_of(e));
        free_entry(e);
        e = next;
    }
}

YCL_EXPORT int fts_close(FTS *fts) {
    if (!fts) return 0;
    struct ycl_ftsent *root_parent = fts->fts_child;
    if (root_parent) {
        free_tree(*children_of(root_parent));
        free_entry(root_parent);
    }
    free(fts);
    return 0;
}
