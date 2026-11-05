// dispatch.c - Ycode libSystem's small dispatch implementation
// (specs/macos/libsystem.md §7.2). Clean-room Ycode code on pthreads,
// written from Apple's public libdispatch documentation and the SDK's
// public type and constant facts (libsystem.md §4). A placeholder for the
// Apache-2.0 libdispatch (macos-apps.md §9 stage B).
#include "ycl.h"

#define FOREVER (~(uint64_t)0)
enum { MAX_WORKERS = 16 };
enum { KIND_QUEUE = 1, KIND_GROUP, KIND_SEMAPHORE, KIND_SOURCE };

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

// The queue whose work the calling thread is running (dispatch_assert_queue).
int pthread_key_create(unsigned long *, void (*)(void *));
void *pthread_getspecific(unsigned long);
int pthread_setspecific(unsigned long, const void *);
int pthread_main_np(void);
static unsigned long current_key;

void ycl_dispatch_init(void) { pthread_key_create(&current_key, 0); }

static struct queue *set_current(struct queue *q) {
    struct queue *old = pthread_getspecific(current_key);
    pthread_setspecific(current_key, q);
    return old;
}

static void *checked_malloc(size_t n) {
    void *p = malloc(n);
    if (!p) abort();
    return p;
}

// Waits on `cv` until `deadline` (nanoseconds of ycl_now_ns, or FOREVER).
// Returns 0 when woken, 1 when the deadline passed.
static uint64_t monotonic_deadline(uint64_t t);

static int wait_until(pthread_cond_t *cv, pthread_mutex_t *mu, uint64_t deadline) {
    deadline = monotonic_deadline(deadline);
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
        struct queue *old = set_current(q);
        it->fn(it->ctx);
        set_current(old);
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

struct global_work {
    struct queue *queue;
    void (*fn)(void *);
    void *ctx;
};

static void run_global(void *arg) {
    struct global_work w = *(struct global_work *)arg;
    free(arg);
    struct queue *old = set_current(w.queue);
    w.fn(w.ctx);
    set_current(old);
}

YCL_EXPORT void dispatch_async_f(struct queue *q, void *ctx, void (*fn)(void *)) {
    if (!q->serial) {
        struct global_work *w = checked_malloc(sizeof *w);
        w->queue = q;
        w->fn = fn;
        w->ctx = ctx;
        pool_submit(run_global, w);
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
        struct queue *old = set_current(q);
        fn(ctx);
        set_current(old);
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
    struct queue *old = set_current(q);
    fn(ctx);
    set_current(old);
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

static void free_source(struct object *o);

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
    } else if (o->kind == KIND_SOURCE) {
        free_source(o);
    }
}

YCL_EXPORT void dispatch_set_context(struct object *o, void *context) { o->context = context; }
YCL_EXPORT void *dispatch_get_context(struct object *o) { return o->context; }
YCL_EXPORT void dispatch_set_finalizer_f(struct object *o, void (*fn)(void *)) { o->finalizer = fn; }

// --- time ---
//
// A dispatch_time_t is either monotonic nanoseconds (ycl_now_ns), FOREVER
// (~0), or a wall-clock time: bit 63 set and nanoseconds since 1970 in the
// rest; DISPATCH_WALLTIME_NOW (~1, the SDK's constant) is "the wall clock
// now". Deadlines are converted to monotonic time when they are waited for.

#define WALL_BIT (1ull << 63)
#define WALLTIME_NOW (~(uint64_t)1)

int __gettimeofday(struct ycl_timeval *, void *, uint64_t *);

static uint64_t wall_now_ns(void) {
    struct ycl_timeval tv;
    if (__gettimeofday(&tv, 0, 0) < 0) return 0;
    return (uint64_t)tv.tv_sec * 1000000000ull + (uint64_t)tv.tv_usec * 1000ull;
}

static uint64_t add_delta(uint64_t base, int64_t delta, uint64_t limit) {
    if (delta < 0) return (uint64_t)-delta > base ? 1 : base - (uint64_t)-delta;
    uint64_t t = base + (uint64_t)delta;
    return t < base || t >= limit ? limit - 1 : t;
}

// A monotonic deadline for any dispatch_time_t (FOREVER stays FOREVER).
static uint64_t monotonic_deadline(uint64_t t) {
    if (t == FOREVER) return FOREVER;
    if (t == WALLTIME_NOW) return ycl_now_ns();
    if (!(t & WALL_BIT)) return t;
    uint64_t wall = t & ~WALL_BIT, now_wall = wall_now_ns(), now = ycl_now_ns();
    return wall <= now_wall ? now : add_delta(now, (int64_t)(wall - now_wall), FOREVER);
}

YCL_EXPORT uint64_t dispatch_time(uint64_t when, int64_t delta) {
    if (when == FOREVER) return FOREVER;
    if (when == WALLTIME_NOW || (when & WALL_BIT)) {
        uint64_t base = when == WALLTIME_NOW ? wall_now_ns() : when & ~WALL_BIT;
        return WALL_BIT | add_delta(base, delta, WALL_BIT);
    }
    return add_delta(when == 0 ? ycl_now_ns() : when, delta, FOREVER);
}

YCL_EXPORT uint64_t dispatch_walltime(const struct ycl_timespec *when, int64_t delta) {
    uint64_t base = when ? (uint64_t)when->tv_sec * 1000000000ull + (uint64_t)when->tv_nsec : wall_now_ns();
    return WALL_BIT | add_delta(base, delta, WALL_BIT);
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

// --- timers: one thread with a deadline-ordered list; an entry either
//     submits a function (dispatch_after) or fires a timer source ---

struct source;
static void source_timer_fired(struct source *src, uint64_t generation);

struct timer {
    struct timer *next;
    uint64_t deadline;  // monotonic
    struct queue *queue;
    void (*fn)(void *);
    void *ctx;
    struct source *source;  // a timer source's arming, else 0
    uint64_t generation;    // the source's arming it belongs to
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
        if (t->source) source_timer_fired(t->source, t->generation);
        else dispatch_async_f(t->queue, t->ctx, t->fn);
        free(t);
        pthread_mutex_lock(&lock);
    }
    return 0;
}

// Called with `lock` held.
static void add_timer_locked(struct timer *t) {
    struct timer **at = &timers;
    while (*at && (*at)->deadline <= t->deadline) at = &(*at)->next;
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
}

YCL_EXPORT void dispatch_after_f(uint64_t when, struct queue *q, void *ctx, void (*fn)(void *)) {
    if (when == FOREVER) return;
    struct timer *t = checked_malloc(sizeof *t);
    memset(t, 0, sizeof *t);
    t->deadline = monotonic_deadline(when);
    t->queue = q;
    t->fn = fn;
    t->ctx = ctx;
    pthread_mutex_lock(&lock);
    add_timer_locked(t);
    pthread_mutex_unlock(&lock);
}

YCL_EXPORT void dispatch_after(uint64_t when, struct queue *q, void *block) {
    dispatch_after_f(when, q, _Block_copy(block), invoke_and_release);
}

// --- sources (timer and custom data sources) ---
//
// The type objects are exported data symbols: the SDK's
// DISPATCH_SOURCE_TYPE_* macros take their addresses.

struct source_type {
    int id;
};
enum { TYPE_TIMER = 1, TYPE_DATA_ADD, TYPE_DATA_OR, TYPE_DATA_REPLACE };
YCL_EXPORT const struct source_type _dispatch_source_type_timer = {TYPE_TIMER};
YCL_EXPORT const struct source_type _dispatch_source_type_data_add = {TYPE_DATA_ADD};
YCL_EXPORT const struct source_type _dispatch_source_type_data_or = {TYPE_DATA_OR};
YCL_EXPORT const struct source_type _dispatch_source_type_data_replace = {TYPE_DATA_REPLACE};

struct source {
    struct object o;
    const struct source_type *type;
    uintptr_t handle;
    unsigned long mask;
    struct queue *queue;
    void (*handler)(void *);
    void *handler_block;  // a copied block, run instead of handler when set
    void (*cancel_handler)(void *);
    void *cancel_block;
    void (*registration)(void *);
    void *registration_block;
    int suspend;          // 1 while inactive; dispatch_suspend adds
    int cancelled, cancel_done, registered;
    int delivery_pending;
    unsigned long data, last_data;
    uint64_t start, interval, generation;  // timers
};

static void retain_obj(struct object *o) {
    if (o && o->refs > 0) __atomic_fetch_add(&o->refs, 1, __ATOMIC_RELAXED);
}

void dispatch_release(struct object *o);

static void run_handler(void (*fn)(void *), void *block, void *context) {
    if (block) ycl_block_invoke(block);
    else if (fn) fn(context);
}

static void free_source(struct object *o) {
    struct source *src = (struct source *)o;
    if (src->handler_block) _Block_release(src->handler_block);
    if (src->cancel_block) _Block_release(src->cancel_block);
    if (src->registration_block) _Block_release(src->registration_block);
    free(src);
}

// Runs on the source's queue.
static void deliver(void *arg) {
    struct source *src = arg;
    pthread_mutex_lock(&lock);
    src->delivery_pending = 0;
    int cancelled = src->cancelled, suspended = src->suspend > 0;
    int registration = !src->registered && !cancelled && !suspended;
    if (registration) src->registered = 1;
    unsigned long data = 0;
    if (!cancelled && !suspended) {
        data = src->data;
        src->data = 0;
        src->last_data = data;
    }
    int run_cancel = cancelled && !src->cancel_done;
    if (run_cancel) src->cancel_done = 1;
    pthread_mutex_unlock(&lock);
    if (registration) run_handler(src->registration, src->registration_block, src->o.context);
    if (data) run_handler(src->handler, src->handler_block, src->o.context);
    if (run_cancel) run_handler(src->cancel_handler, src->cancel_block, src->o.context);
    dispatch_release(&src->o);
}

// Called with `lock` held: puts one delivery on the source's queue.
static void schedule_delivery_locked(struct source *src) {
    if (src->delivery_pending || src->suspend > 0) return;
    src->delivery_pending = 1;
    retain_obj(&src->o);
    if (src->queue->serial) {
        struct item *it = checked_malloc(sizeof *it);
        it->fn = deliver;
        it->ctx = src;
        it->sync = 0;
        push_locked(src->queue, it);
    } else {
        struct global_work *w = checked_malloc(sizeof *w);
        w->queue = src->queue;
        w->fn = deliver;
        w->ctx = src;
        pool_submit(run_global, w);  // takes pool_mu only
    }
}

// Called with `lock` held: (re)arms a timer source.
static void arm_timer_locked(struct source *src, uint64_t deadline) {
    src->generation++;
    if (src->cancelled || src->suspend > 0 || deadline == FOREVER) return;
    struct timer *t = checked_malloc(sizeof *t);
    memset(t, 0, sizeof *t);
    t->deadline = deadline;
    t->source = src;
    t->generation = src->generation;
    retain_obj(&src->o);
    add_timer_locked(t);
}

static void source_timer_fired(struct source *src, uint64_t generation) {
    pthread_mutex_lock(&lock);
    if (generation == src->generation && !src->cancelled) {
        src->data++;
        schedule_delivery_locked(src);
        if (src->interval != FOREVER && src->interval != 0) {
            uint64_t next = ycl_now_ns() + src->interval;
            arm_timer_locked(src, next);
        } else {
            src->generation++;  // one-shot: disarmed
        }
    }
    pthread_mutex_unlock(&lock);
    dispatch_release(&src->o);
}

YCL_EXPORT struct source *dispatch_source_create(const struct source_type *type, uintptr_t handle, unsigned long mask,
                                                 struct queue *q) {
    if (!type) return 0;
    struct source *src = checked_malloc(sizeof *src);
    memset(src, 0, sizeof *src);
    src->o.kind = KIND_SOURCE;
    src->o.refs = 1;
    src->type = type;
    src->handle = handle;
    src->mask = mask;
    src->queue = q ? q : dispatch_get_global_queue(0, 0);
    src->suspend = 1;  // inactive until dispatch_activate/dispatch_resume
    src->start = FOREVER;
    src->interval = FOREVER;
    return src;
}

YCL_EXPORT void dispatch_source_set_event_handler_f(struct source *src, void (*fn)(void *)) {
    pthread_mutex_lock(&lock);
    src->handler = fn;
    if (src->handler_block) _Block_release(src->handler_block);
    src->handler_block = 0;
    pthread_mutex_unlock(&lock);
}

YCL_EXPORT void dispatch_source_set_event_handler(struct source *src, void *block) {
    void *copy = block ? _Block_copy(block) : 0;
    pthread_mutex_lock(&lock);
    if (src->handler_block) _Block_release(src->handler_block);
    src->handler_block = copy;
    src->handler = 0;
    pthread_mutex_unlock(&lock);
}

YCL_EXPORT void dispatch_source_set_cancel_handler_f(struct source *src, void (*fn)(void *)) { src->cancel_handler = fn; }
YCL_EXPORT void dispatch_source_set_cancel_handler(struct source *src, void *block) {
    src->cancel_block = block ? _Block_copy(block) : 0;
}
YCL_EXPORT void dispatch_source_set_registration_handler_f(struct source *src, void (*fn)(void *)) {
    src->registration = fn;
}
YCL_EXPORT void dispatch_source_set_registration_handler(struct source *src, void *block) {
    src->registration_block = block ? _Block_copy(block) : 0;
}

YCL_EXPORT void dispatch_source_set_timer(struct source *src, uint64_t start, uint64_t interval, uint64_t leeway) {
    (void)leeway;
    pthread_mutex_lock(&lock);
    src->start = start;
    src->interval = interval;
    src->data = 0;
    arm_timer_locked(src, monotonic_deadline(start));
    pthread_mutex_unlock(&lock);
}

YCL_EXPORT void dispatch_source_merge_data(struct source *src, unsigned long value) {
    pthread_mutex_lock(&lock);
    if (!src->cancelled) {
        int type = src->type->id;
        if (type == TYPE_DATA_ADD) src->data += value;
        else if (type == TYPE_DATA_OR) src->data |= value;
        else src->data = value;
        if (src->data) schedule_delivery_locked(src);
    }
    pthread_mutex_unlock(&lock);
}

YCL_EXPORT unsigned long dispatch_source_get_data(struct source *src) { return src->last_data; }
YCL_EXPORT unsigned long dispatch_source_get_mask(struct source *src) { return src->mask; }
YCL_EXPORT uintptr_t dispatch_source_get_handle(struct source *src) { return src->handle; }
YCL_EXPORT long dispatch_source_testcancel(struct source *src) { return src->cancelled; }

YCL_EXPORT void dispatch_source_cancel(struct source *src) {
    pthread_mutex_lock(&lock);
    if (!src->cancelled) {
        src->cancelled = 1;
        src->generation++;  // disarms a pending timer
        if (src->suspend <= 0) schedule_delivery_locked(src);
    }
    pthread_mutex_unlock(&lock);
}

// Called with `lock` held: the source became active.
static void source_resumed_locked(struct source *src) {
    if (src->type->id == TYPE_TIMER && !src->cancelled && src->start != FOREVER)
        arm_timer_locked(src, monotonic_deadline(src->start));
    if (src->data || src->cancelled || !src->registered) schedule_delivery_locked(src);
}

YCL_EXPORT void dispatch_suspend(struct object *o) {
    if (!o) return;
    pthread_mutex_lock(&lock);
    if (o->kind == KIND_SOURCE) ((struct source *)o)->suspend++;
    pthread_mutex_unlock(&lock);
}

YCL_EXPORT void dispatch_resume(struct object *o) {
    if (!o) return;
    pthread_mutex_lock(&lock);
    if (o->kind == KIND_SOURCE) {
        struct source *src = (struct source *)o;
        if (src->suspend > 0 && --src->suspend == 0) source_resumed_locked(src);
    }
    pthread_mutex_unlock(&lock);
}

YCL_EXPORT void dispatch_activate(struct object *o) {
    if (!o) return;
    pthread_mutex_lock(&lock);
    if (o->kind == KIND_SOURCE) {
        struct source *src = (struct source *)o;
        if (!src->registered && src->suspend == 1) {
            src->suspend = 0;
            source_resumed_locked(src);
        }
    }
    pthread_mutex_unlock(&lock);
}

// --- queue identity checks ---

static void queue_assertion(const char *what, struct queue *q) {
    char message[160];
    snprintf(message, sizeof message, "BUG IN CLIENT OF LIBDISPATCH: %s \"%s\"\n", what, q ? q->label : "");
    write(2, message, strlen(message));
    abort();
}

static int on_queue(struct queue *q) {
    struct queue *current = pthread_getspecific(current_key);
    if (current == q) return 1;
    return q == &_dispatch_main_q && !current && pthread_main_np();
}

void ycl_dispatch_assert_queue(struct queue *q) __asm__("_dispatch_assert_queue$V2");
YCL_EXPORT void ycl_dispatch_assert_queue(struct queue *q) {
    if (!on_queue(q)) queue_assertion("Block was expected to execute on queue", q);
}
YCL_EXPORT void dispatch_assert_queue(struct queue *q) { ycl_dispatch_assert_queue(q); }

void ycl_dispatch_assert_queue_not(struct queue *q) __asm__("_dispatch_assert_queue_not$V2");
YCL_EXPORT void ycl_dispatch_assert_queue_not(struct queue *q) {
    if (on_queue(q)) queue_assertion("Block was expected not to execute on queue", q);
}
YCL_EXPORT void dispatch_assert_queue_not(struct queue *q) { ycl_dispatch_assert_queue_not(q); }

YCL_EXPORT struct queue *dispatch_get_current_queue(void) {
    struct queue *current = pthread_getspecific(current_key);
    if (current) return current;
    return pthread_main_np() ? &_dispatch_main_q : dispatch_get_global_queue(0, 0);
}

// --- object entry points of <os/object.h> and the voucher interface:
//     Ycode has no vouchers (importance and activity tracing), so there is
//     never a current voucher ---

YCL_EXPORT void *os_retain(void *object) {
    if (object) dispatch_retain(object);
    return object;
}
YCL_EXPORT void os_release(void *object) {
    if (object) dispatch_release(object);
}
YCL_EXPORT void *voucher_copy(void) { return 0; }
YCL_EXPORT void *voucher_copy_without_importance(void) { return 0; }
YCL_EXPORT void *voucher_adopt(void *voucher) {
    os_release(voucher);
    return 0;
}

// --- targets and attributes: Ycode's queues do not form hierarchies;
//     a target or QoS is accepted and does not change scheduling ---

YCL_EXPORT void dispatch_set_target_queue(struct object *o, struct queue *target) {
    (void)o;
    (void)target;
}
YCL_EXPORT const void *dispatch_queue_attr_make_with_qos_class(const void *attr, unsigned qos, int priority) {
    (void)qos;
    (void)priority;
    return attr;
}
YCL_EXPORT const void *dispatch_queue_attr_make_initially_inactive(const void *attr) { return attr; }
YCL_EXPORT const void *dispatch_queue_attr_make_with_autorelease_frequency(const void *attr, unsigned long f) {
    (void)f;
    return attr;
}
YCL_EXPORT struct queue *dispatch_queue_create_with_target(const char *label, const void *attr, struct queue *target) {
    (void)target;
    return dispatch_queue_create(label, attr);
}
YCL_EXPORT unsigned dispatch_queue_get_qos_class(struct queue *q, int *priority) {
    (void)q;
    if (priority) *priority = 0;
    return 0x15;  // QOS_CLASS_DEFAULT
}
