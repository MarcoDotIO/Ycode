// dispatch.c - Ycode libSystem's small dispatch implementation
// (specs/macos/libsystem.md §7.2). Clean-room Ycode code on pthreads,
// written from Apple's public libdispatch documentation and the SDK's
// public type and constant facts (libsystem.md §4). A placeholder for the
// Apache-2.0 libdispatch (macos-apps.md §9 stage B).
#include "ycl.h"

#define FOREVER (~(uint64_t)0)
enum { MAX_WORKERS = 16 };
enum { KIND_QUEUE = 1, KIND_GROUP, KIND_SEMAPHORE };

struct object {
    int kind;
    int refs;        // 0: a static object (never freed)
    void *context;
    void (*finalizer)(void *);
};

struct sync_wait {
    int granted;
};

struct item {
    struct item *next;
    void (*fn)(void *);
    void *ctx;
    struct sync_wait *sync;  // a dispatch_sync marker (not heap-allocated)
};

struct queue {
    struct object o;
    int serial, is_main;
    struct item *head, *tail;
    int owned;  // a drain task, the main thread or a dispatch_sync caller holds the queue
    char label[64];
};

struct group {
    struct object o;
    long count;
    struct notify *notifies;
};

struct notify {
    struct notify *next;
    struct queue *queue;
    void (*fn)(void *);
    void *ctx;
};

struct semaphore {
    struct object o;
    long value;
    long waiters;
    pthread_mutex_t mu;
    pthread_cond_t cv;
};

// --- exported objects (the SDK takes their addresses) ---

YCL_EXPORT struct queue _dispatch_main_q = {{KIND_QUEUE, 0, 0, 0}, 1, 1, 0, 0, 0, "ycode.main-thread"};
YCL_EXPORT struct object _dispatch_queue_attr_concurrent = {0, 0, 0, 0};
static struct queue global_queues[4] = {
    {{KIND_QUEUE, 0, 0, 0}, 0, 0, 0, 0, 0, "ycode.global.background"},
    {{KIND_QUEUE, 0, 0, 0}, 0, 0, 0, 0, 0, "ycode.global.low"},
    {{KIND_QUEUE, 0, 0, 0}, 0, 0, 0, 0, 0, "ycode.global.default"},
    {{KIND_QUEUE, 0, 0, 0}, 0, 0, 0, 0, 0, "ycode.global.high"},
};

void ycl_block_invoke(void *block);
void *_Block_copy(const void *);
void _Block_release(const void *);
int pthread_cond_timedwait_relative_np(pthread_cond_t *, pthread_mutex_t *, const struct ycl_timespec *);

static pthread_mutex_t lock = YCL_PTHREAD_MUTEX_INITIALIZER;   // queues, groups, timers
static pthread_cond_t sync_cv = YCL_PTHREAD_COND_INITIALIZER;   // dispatch_sync hand-offs, groups
static pthread_cond_t main_cv = YCL_PTHREAD_COND_INITIALIZER;   // the main queue has work

void ycl_dispatch_init(void) {}

static void *checked_malloc(size_t n) {
    void *p = malloc(n);
    if (!p) abort();
    return p;
}

// Waits on `cv` until `deadline` (nanoseconds of ycl_now_ns, or FOREVER).
// Returns 0 when woken, 1 when the deadline passed.
static int wait_until(pthread_cond_t *cv, pthread_mutex_t *mu, uint64_t deadline) {
    if (deadline == FOREVER) {
        pthread_cond_wait(cv, mu);
        return 0;
    }
    uint64_t now = ycl_now_ns();
    if (now >= deadline) return 1;
    uint64_t left = deadline - now;
    struct ycl_timespec t = {(long)(left / 1000000000ull), (long)(left % 1000000000ull)};
    pthread_cond_timedwait_relative_np(cv, mu, &t);
    return 0;
}

// --- the worker pool ---

struct task {
    struct task *next;
    void (*fn)(void *);
    void *ctx;
};
static pthread_mutex_t pool_mu = YCL_PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pool_cv = YCL_PTHREAD_COND_INITIALIZER;
static struct task *pool_head, *pool_tail;
static int pool_idle, pool_threads;

static void *worker(void *unused) {
    (void)unused;
    pthread_mutex_lock(&pool_mu);
    for (;;) {
        while (!pool_head) {
            pool_idle++;
            pthread_cond_wait(&pool_cv, &pool_mu);
            pool_idle--;
        }
        struct task *t = pool_head;
        pool_head = t->next;
        if (!pool_head) pool_tail = 0;
        pthread_mutex_unlock(&pool_mu);
        t->fn(t->ctx);
        free(t);
        pthread_mutex_lock(&pool_mu);
    }
    return 0;
}

static void pool_submit(void (*fn)(void *), void *ctx) {
    struct task *t = checked_malloc(sizeof *t);
    t->next = 0;
    t->fn = fn;
    t->ctx = ctx;
    pthread_mutex_lock(&pool_mu);
    if (pool_tail) pool_tail->next = t;
    else pool_head = t;
    pool_tail = t;
    if (pool_idle > 0) {
        pthread_cond_signal(&pool_cv);
    } else if (pool_threads < MAX_WORKERS) {
        pthread_t thread;
        if (pthread_create(&thread, 0, worker, 0) == 0) {
            pool_threads++;
            pthread_detach(thread);
        }
    }
    pthread_mutex_unlock(&pool_mu);
}

// --- queues ---

static void drain(void *arg);
static int main_turn;  // the main queue was scheduled and waits for dispatch_main

// Called with `lock` held: the queue was idle and now has work.
static void schedule_locked(struct queue *q) {
    q->owned = 1;
    if (q->is_main) {
        main_turn = 1;  // the main thread owns it now (dispatch_main)
        pthread_cond_broadcast(&main_cv);
    }
    else pool_submit(drain, q);  // takes pool_mu, never `lock`, so no inversion
}

// Runs a serial queue's items in order until it is empty, or until a
// dispatch_sync marker hands the queue to its waiting caller. The caller
// owns the queue and holds `lock`. Whoever owns the queue keeps draining
// it, so a queue never waits for a free worker while its dispatch_sync
// callers occupy the workers.
static void drain_locked(struct queue *q) {
    for (;;) {
        struct item *it = q->head;
        if (!it) {
            q->owned = 0;
            break;
        }
        q->head = it->next;
        if (!q->head) q->tail = 0;
        if (it->sync) {
            it->sync->granted = 1;  // the caller now owns the queue
            pthread_cond_broadcast(&sync_cv);
            break;
        }
        pthread_mutex_unlock(&lock);
        it->fn(it->ctx);
        free(it);
        pthread_mutex_lock(&lock);
    }
}

static void drain(void *arg) {
    pthread_mutex_lock(&lock);
    drain_locked(arg);
    pthread_mutex_unlock(&lock);
}

static void push_locked(struct queue *q, struct item *it) {
    it->next = 0;
    if (q->tail) q->tail->next = it;
    else q->head = it;
    q->tail = it;
    if (!q->owned) schedule_locked(q);
}

YCL_EXPORT void dispatch_async_f(struct queue *q, void *ctx, void (*fn)(void *)) {
    if (!q->serial) {
        pool_submit(fn, ctx);
        return;
    }
    struct item *it = checked_malloc(sizeof *it);
    it->fn = fn;
    it->ctx = ctx;
    it->sync = 0;
    pthread_mutex_lock(&lock);
    push_locked(q, it);
    pthread_mutex_unlock(&lock);
}

YCL_EXPORT void dispatch_sync_f(struct queue *q, void *ctx, void (*fn)(void *)) {
    if (!q->serial) {
        fn(ctx);
        return;
    }
    pthread_mutex_lock(&lock);
    if (q->owned || q->head) {
        struct sync_wait w = {0};
        struct item marker = {0, 0, 0, &w};
        push_locked(q, &marker);
        while (!w.granted) pthread_cond_wait(&sync_cv, &lock);
    } else {
        q->owned = 1;
    }
    pthread_mutex_unlock(&lock);
    fn(ctx);
    pthread_mutex_lock(&lock);
    drain_locked(q);  // the caller still owns the queue: it runs what came in meanwhile
    pthread_mutex_unlock(&lock);
}

static void invoke_and_release(void *block) {
    ycl_block_invoke(block);
    _Block_release(block);
}

YCL_EXPORT void dispatch_async(struct queue *q, void *block) { dispatch_async_f(q, _Block_copy(block), invoke_and_release); }
YCL_EXPORT void dispatch_sync(struct queue *q, void *block) { dispatch_sync_f(q, block, ycl_block_invoke); }
YCL_EXPORT void dispatch_barrier_async(struct queue *q, void *block) { dispatch_async(q, block); }
YCL_EXPORT void dispatch_barrier_sync(struct queue *q, void *block) { dispatch_sync(q, block); }

YCL_EXPORT struct queue *dispatch_get_global_queue(long identifier, unsigned long flags) {
    (void)flags;
    switch (identifier) {
    case 2: case 0x21: case 0x19: return &global_queues[3];
    case -2: case 0x11: return &global_queues[1];
    case -32768: case 0x09: return &global_queues[0];
    default: return &global_queues[2];
    }
}

YCL_EXPORT struct queue *dispatch_queue_create(const char *label, const void *attr) {
    struct queue *q = checked_malloc(sizeof *q);
    memset(q, 0, sizeof *q);
    q->o.kind = KIND_QUEUE;
    q->o.refs = 1;
    q->serial = attr != (const void *)&_dispatch_queue_attr_concurrent;
    if (label) strlcpy(q->label, label, sizeof q->label);
    return q;
}

YCL_EXPORT const char *dispatch_queue_get_label(struct queue *q) { return q ? q->label : ""; }

// The main thread serves the main queue from here on (it never returns).
YCL_EXPORT void dispatch_main(void) {
    for (;;) {
        pthread_mutex_lock(&lock);
        while (!main_turn) pthread_cond_wait(&main_cv, &lock);
        main_turn = 0;
        drain_locked(&_dispatch_main_q);
        pthread_mutex_unlock(&lock);
    }
}

// --- objects ---

YCL_EXPORT void dispatch_retain(struct object *o) {
    if (o && o->refs > 0) __atomic_fetch_add(&o->refs, 1, __ATOMIC_RELAXED);
}

YCL_EXPORT void dispatch_release(struct object *o) {
    if (!o || o->refs <= 0) return;
    if (__atomic_sub_fetch(&o->refs, 1, __ATOMIC_ACQ_REL) != 0) return;
    if (o->finalizer) o->finalizer(o->context);
    // Queues are kept (an item may still run on one); groups and semaphores go.
    if (o->kind == KIND_SEMAPHORE) {
        pthread_mutex_destroy(&((struct semaphore *)o)->mu);
        pthread_cond_destroy(&((struct semaphore *)o)->cv);
        free(o);
    } else if (o->kind == KIND_GROUP) {
        free(o);
    }
}

YCL_EXPORT void dispatch_set_context(struct object *o, void *context) { o->context = context; }
YCL_EXPORT void *dispatch_get_context(struct object *o) { return o->context; }
YCL_EXPORT void dispatch_set_finalizer_f(struct object *o, void (*fn)(void *)) { o->finalizer = fn; }

// --- time ---

YCL_EXPORT uint64_t dispatch_time(uint64_t when, int64_t delta) {
    if (when == FOREVER) return FOREVER;
    uint64_t base = when == 0 ? ycl_now_ns() : when;
    if (delta < 0) return (uint64_t)-delta > base ? 1 : base - (uint64_t)-delta;
    uint64_t t = base + (uint64_t)delta;
    return t < base || t == FOREVER ? FOREVER - 1 : t;
}

// Wall-clock times are taken relative to now (libsystem.md §7.2).
YCL_EXPORT uint64_t dispatch_walltime(const struct ycl_timespec *when, int64_t delta) {
    (void)when;
    return dispatch_time(0, delta);
}

// --- groups ---

YCL_EXPORT struct group *dispatch_group_create(void) {
    struct group *g = checked_malloc(sizeof *g);
    memset(g, 0, sizeof *g);
    g->o.kind = KIND_GROUP;
    g->o.refs = 1;
    return g;
}

YCL_EXPORT void dispatch_group_enter(struct group *g) {
    pthread_mutex_lock(&lock);
    g->count++;
    pthread_mutex_unlock(&lock);
}

YCL_EXPORT void dispatch_group_leave(struct group *g) {
    pthread_mutex_lock(&lock);
    struct notify *ready = 0;
    if (--g->count == 0) {
        ready = g->notifies;
        g->notifies = 0;
        pthread_cond_broadcast(&sync_cv);
    }
    pthread_mutex_unlock(&lock);
    while (ready) {
        struct notify *n = ready;
        ready = n->next;
        dispatch_async_f(n->queue, n->ctx, n->fn);
        free(n);
    }
}

YCL_EXPORT long dispatch_group_wait(struct group *g, uint64_t deadline) {
    long result = 0;
    pthread_mutex_lock(&lock);
    while (g->count > 0) {
        if (wait_until(&sync_cv, &lock, deadline)) {
            result = 1;
            break;
        }
    }
    pthread_mutex_unlock(&lock);
    return result;
}

YCL_EXPORT void dispatch_group_notify_f(struct group *g, struct queue *q, void *ctx, void (*fn)(void *)) {
    pthread_mutex_lock(&lock);
    if (g->count > 0) {
        struct notify *n = checked_malloc(sizeof *n);
        n->queue = q;
        n->fn = fn;
        n->ctx = ctx;
        n->next = g->notifies;
        g->notifies = n;
        pthread_mutex_unlock(&lock);
        return;
    }
    pthread_mutex_unlock(&lock);
    dispatch_async_f(q, ctx, fn);
}

YCL_EXPORT void dispatch_group_notify(struct group *g, struct queue *q, void *block) {
    dispatch_group_notify_f(g, q, _Block_copy(block), invoke_and_release);
}

struct group_work {
    struct group *group;
    void (*fn)(void *);
    void *ctx;
};

static void group_trampoline(void *arg) {
    struct group_work w = *(struct group_work *)arg;
    free(arg);
    w.fn(w.ctx);
    dispatch_group_leave(w.group);
}

YCL_EXPORT void dispatch_group_async_f(struct group *g, struct queue *q, void *ctx, void (*fn)(void *)) {
    struct group_work *w = checked_malloc(sizeof *w);
    w->group = g;
    w->fn = fn;
    w->ctx = ctx;
    dispatch_group_enter(g);
    dispatch_async_f(q, w, group_trampoline);
}

YCL_EXPORT void dispatch_group_async(struct group *g, struct queue *q, void *block) {
    dispatch_group_async_f(g, q, _Block_copy(block), invoke_and_release);
}

// --- semaphores ---

YCL_EXPORT struct semaphore *dispatch_semaphore_create(long value) {
    if (value < 0) return 0;
    struct semaphore *s = checked_malloc(sizeof *s);
    memset(s, 0, sizeof *s);
    s->o.kind = KIND_SEMAPHORE;
    s->o.refs = 1;
    s->value = value;
    pthread_mutex_init(&s->mu, 0);
    pthread_cond_init(&s->cv, 0);
    return s;
}

YCL_EXPORT long dispatch_semaphore_wait(struct semaphore *s, uint64_t deadline) {
    long result = 0;
    pthread_mutex_lock(&s->mu);
    s->waiters++;
    while (s->value <= 0) {
        if (wait_until(&s->cv, &s->mu, deadline)) {
            result = 1;
            break;
        }
    }
    s->waiters--;
    if (!result) s->value--;
    pthread_mutex_unlock(&s->mu);
    return result;
}

YCL_EXPORT long dispatch_semaphore_signal(struct semaphore *s) {
    pthread_mutex_lock(&s->mu);
    s->value++;
    long woke = s->waiters > 0;
    if (woke) pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mu);
    return woke;
}

// --- once and apply ---

YCL_EXPORT void dispatch_once_f(long *predicate, void *ctx, void (*fn)(void *)) {
    if (__atomic_load_n(predicate, __ATOMIC_ACQUIRE) == ~0L) return;
    long expected = 0;
    if (__atomic_compare_exchange_n(predicate, &expected, 1L, 0, __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE)) {
        fn(ctx);
        __atomic_store_n(predicate, ~0L, __ATOMIC_RELEASE);  // the SDK's inline fast path tests for ~0
        return;
    }
    while (__atomic_load_n(predicate, __ATOMIC_ACQUIRE) != ~0L) sched_yield();
}

YCL_EXPORT void dispatch_once(long *predicate, void *block) { dispatch_once_f(predicate, block, ycl_block_invoke); }

// Iterations run on the caller's thread, in order (allowed: dispatch_apply
// does not promise concurrency).
YCL_EXPORT void dispatch_apply_f(size_t count, struct queue *q, void *ctx, void (*fn)(void *, size_t)) {
    (void)q;
    for (size_t i = 0; i < count; i++) fn(ctx, i);
}

struct block_header {
    void *isa;
    int flags, reserved;
    void (*invoke)(void *, size_t);
};
YCL_EXPORT void dispatch_apply(size_t count, struct queue *q, void *block) {
    (void)q;
    void (*invoke)(void *, size_t) = ((struct block_header *)block)->invoke;
    for (size_t i = 0; i < count; i++) invoke(block, i);
}

// --- dispatch_after: one timer thread ---

struct timer {
    struct timer *next;
    uint64_t deadline;
    struct queue *queue;
    void (*fn)(void *);
    void *ctx;
};
static struct timer *timers;
static int timer_thread_started;
static pthread_cond_t timer_cv = YCL_PTHREAD_COND_INITIALIZER;

static void *timer_thread(void *unused) {
    (void)unused;
    pthread_mutex_lock(&lock);
    for (;;) {
        if (!timers) {
            pthread_cond_wait(&timer_cv, &lock);
            continue;
        }
        if (!wait_until(&timer_cv, &lock, timers->deadline) && ycl_now_ns() < timers->deadline) continue;
        struct timer *t = timers;
        timers = t->next;
        pthread_mutex_unlock(&lock);
        dispatch_async_f(t->queue, t->ctx, t->fn);
        free(t);
        pthread_mutex_lock(&lock);
    }
    return 0;
}

YCL_EXPORT void dispatch_after_f(uint64_t when, struct queue *q, void *ctx, void (*fn)(void *)) {
    if (when == FOREVER) return;
    struct timer *t = checked_malloc(sizeof *t);
    t->deadline = when;
    t->queue = q;
    t->fn = fn;
    t->ctx = ctx;
    pthread_mutex_lock(&lock);
    struct timer **at = &timers;
    while (*at && (*at)->deadline <= when) at = &(*at)->next;
    t->next = *at;
    *at = t;
    if (!timer_thread_started) {
        pthread_t thread;
        if (pthread_create(&thread, 0, timer_thread, 0) == 0) {
            timer_thread_started = 1;
            pthread_detach(thread);
        }
    }
    pthread_cond_signal(&timer_cv);
    pthread_mutex_unlock(&lock);
}

YCL_EXPORT void dispatch_after(uint64_t when, struct queue *q, void *block) {
    dispatch_after_f(when, q, _Block_copy(block), invoke_and_release);
}
