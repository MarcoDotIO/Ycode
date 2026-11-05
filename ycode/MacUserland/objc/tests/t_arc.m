// t_arc.m - ARC conformance (compiled with -fobjc-arc; specs/macos/
// objc-runtime.md §7-§9): strong and weak properties and locals, the
// return-value hand-off, objc_opt_* entry points, @autoreleasepool,
// copy properties, weak references cleared at dealloc, ivar destruction.
#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <stdio.h>

static int deallocs = 0;

@interface Node : NSObject <NSObject>
@property (nonatomic, strong) Node *next;
@property (nonatomic, weak) Node *parent;
@property (atomic, strong) Node *atomicChild;
@property (nonatomic, copy) Node *copied;
@property (nonatomic) int tag;
+ (instancetype)node:(int)tag;
- (Node *)makeChild:(int)tag;
@end

@implementation Node
+ (instancetype)node:(int)tag {
    Node *n = [[self alloc] init];
    n.tag = tag;
    return n;
}
- (Node *)makeChild:(int)tag {
    Node *c = [Node node:tag];
    c.parent = self;
    return c;   // returned +0 (autoreleased or handed off)
}
- (id)copyWithZone:(void *)zone {
    Node *n = [Node node:self.tag + 1000];
    return n;
}
- (void)dealloc {
    deallocs++;
    printf("dealloc %d\n", self.tag);
}
@end

@interface Holder : NSObject {
@public
    Node *a;
    Node *b;
    __weak Node *w;
}
@end
@implementation Holder
- (void)dealloc {
    printf("dealloc holder\n");
}
@end

static __weak Node *globalWeak;

int main(void) {
    @autoreleasepool {
        Node *root = [Node node:1];
        Node *child = [root makeChild:2];
        root.next = child;
        printf("child parent %d next %d\n", child.parent.tag, root.next.tag);
        root.atomicChild = [Node node:3];
        printf("atomic child %d\n", root.atomicChild.tag);
        root.copied = child;
        printf("copied %d same %d\n", root.copied.tag, root.copied == child);

        globalWeak = child;
        printf("weak alive %d\n", globalWeak.tag);
        root.next = nil;
        child = nil;
        printf("after clearing strong refs: weak %s\n", globalWeak ? "alive" : "nil");
        root = nil;
        printf("root released\n");
    }
    printf("pool drained: weak %s deallocs %d\n", globalWeak ? "alive" : "nil", deallocs);

    // objc_opt_* fast paths and overrides.
    Node *n = [Node new];
    printf("opt class %s self same %d kind %d responds %d %d\n", class_getName([n class]), [n self] == n,
           [n isKindOfClass:[NSObject class]], [n respondsToSelector:@selector(makeChild:)],
           [n respondsToSelector:@selector(missing)]);
    printf("class method new tag %d\n", [Node node:7].tag);

    // Ivars of a holder are released when it goes away, in some order; the
    // weak ivar is cleared.
    @autoreleasepool {
        Holder *h = [Holder new];
        h->a = [Node node:10];
        h->b = [Node node:11];
        h->w = h->a;
        printf("holder weak %d\n", h->w.tag);
        h = nil;
    }

    // Many autoreleased returns inside a loop with a pool per iteration.
    int sum = 0;
    for (int i = 0; i < 1000; i++) {
        @autoreleasepool {
            Node *c = [n makeChild:-1];
            sum += c.parent == n;
        }
    }
    printf("loop sum %d\n", sum);
    n = nil;
    printf("done\n");
    return 0;
}
