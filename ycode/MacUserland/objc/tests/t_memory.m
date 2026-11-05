// t_memory.m - reference counting conformance, manual retain/release
// (specs/macos/objc-runtime.md §6-§9): counts, the side table past the
// inline count, dealloc order, autorelease pools (nested, many pages),
// weak variables, associated objects, objc_storeStrong, @synchronized,
// custom retain/release, C++-style ivar destruction order.
#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdio.h>

id objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *);
id objc_retain(id);
void objc_release(id);
id objc_autorelease(id);
id objc_storeWeak(id *, id);
id objc_loadWeakRetained(id *);
id objc_initWeak(id *, id);
void objc_destroyWeak(id *);
void objc_storeStrong(id *, id);

static int deallocs = 0;

@interface Tracked : NSObject {
@public
    int tag;
}
+ (instancetype)tracked:(int)tag;
@end
@implementation Tracked
+ (instancetype)tracked:(int)t { Tracked *o = [[self alloc] init]; o->tag = t; return o; }
- (void)dealloc {
    deallocs++;
    printf("dealloc %d\n", tag);
    [super dealloc];
}
@end

@interface Counting : NSObject {
@public
    int retains, releases;
}
@end
@implementation Counting
- (id)retain { retains++; return [super retain]; }
- (oneway void)release { releases++; [super release]; }
@end

static char kAssocA, kAssocB, kAssocC;

int main(void) {
    // Basic counts.
    Tracked *a = [Tracked tracked:1];
    printf("rc %lu\n", (unsigned long)[a retainCount]);
    [a retain];
    [a retain];
    printf("rc %lu\n", (unsigned long)[a retainCount]);
    [a release];
    [a release];
    printf("rc %lu\n", (unsigned long)[a retainCount]);

    // Past the inline count (side table) and back.
    for (int i = 0; i < 40000; i++) objc_retain(a);
    printf("rc big %lu\n", (unsigned long)[a retainCount]);
    for (int i = 0; i < 40000; i++) objc_release(a);
    printf("rc back %lu deallocs %d\n", (unsigned long)[a retainCount], deallocs);
    [a release];
    printf("deallocs %d\n", deallocs);

    // Autorelease pools: nested, and one with enough objects for several pages.
    void *outer = objc_autoreleasePoolPush();
    [[Tracked tracked:10] autorelease];
    void *inner = objc_autoreleasePoolPush();
    [[Tracked tracked:11] autorelease];
    [[Tracked tracked:12] autorelease];
    printf("pop inner\n");
    objc_autoreleasePoolPop(inner);
    printf("pop outer\n");
    objc_autoreleasePoolPop(outer);
    deallocs = 0;
    @autoreleasepool {
        for (int i = 0; i < 3000; i++) {
            Tracked *t = [[Tracked alloc] init];
            t->tag = -1;
            [t autorelease];
        }
        printf("before drain %d\n", deallocs);
    }
    printf("after drain %d\n", deallocs);

    // Weak variables.
    Tracked *w = [Tracked tracked:20];
    id weak1 = nil, weak2 = nil;
    objc_initWeak(&weak1, w);
    objc_storeWeak(&weak2, w);
    id loaded = objc_loadWeakRetained(&weak1);
    printf("weak loaded same %d rc %lu\n", loaded == w, (unsigned long)[w retainCount]);
    objc_release(loaded);
    objc_storeWeak(&weak2, nil);
    [w release];
    printf("weak after dealloc %p %p\n", (void *)weak1, (void *)objc_loadWeakRetained(&weak1));
    objc_destroyWeak(&weak1);

    // Associated objects: retained values are released with the owner.
    Tracked *owner = [Tracked tracked:30];
    Tracked *v1 = [Tracked tracked:31];
    Tracked *v2 = [Tracked tracked:32];
    objc_setAssociatedObject(owner, &kAssocA, v1, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(owner, &kAssocB, v2, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(owner, &kAssocC, v1, OBJC_ASSOCIATION_RETAIN);
    printf("assoc get %d %d rc %lu\n", ((Tracked *)objc_getAssociatedObject(owner, &kAssocA))->tag,
           ((Tracked *)objc_getAssociatedObject(owner, &kAssocB))->tag, (unsigned long)[v1 retainCount]);
    objc_setAssociatedObject(owner, &kAssocC, nil, OBJC_ASSOCIATION_RETAIN);
    printf("assoc cleared rc %lu missing %p\n", (unsigned long)[v1 retainCount], (void *)objc_getAssociatedObject(owner, &kAssocC));
    [v1 release];
    printf("release owner\n");
    [owner release];
    [v2 release];

    // objc_storeStrong.
    id slot = nil;
    Tracked *s1 = [Tracked tracked:40];
    objc_storeStrong(&slot, s1);
    printf("storeStrong rc %lu\n", (unsigned long)[s1 retainCount]);
    [s1 release];
    objc_storeStrong(&slot, nil);

    // Custom retain/release are messaged by the ARC entry points.
    Counting *c = [Counting new];
    objc_retain(c);
    objc_release(c);
    objc_autorelease(objc_retain(c));
    printf("custom rr retains %d releases %d\n", c->retains, c->releases);

    // @synchronized nests.
    int n = 0;
    @synchronized(c) {
        @synchronized(c) {
            n++;
        }
        n++;
    }
    printf("synchronized %d\n", n);
    [c release];

    // Classes are not counted.
    printf("class rc same %d\n", objc_retain([Tracked class]) == [Tracked class]);
    objc_release([Tracked class]);
    printf("done\n");
    return 0;
}
