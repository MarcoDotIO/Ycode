// mtlwatch: a diagnostic dylib for Ycode's own simulator (visionos.md §7.2
// R1). Inserted into guest processes (DYLD_INSERT_LIBRARIES through
// ycode-simd's --env), it wraps the MTLDevice that MTLCreateSystemDefaultDevice
// and MTLCopyAllDevices return in a forwarding proxy and records, per
// process, every device selector called and its first results: nil object
// results, BOOL answers and errors. Public API only (Foundation, Metal,
// the ObjC runtime's NSProxy/NSInvocation forwarding, dyld interposing).
// Output: $MTLWATCH_DIR/mtlwatch.<process>.<pid> (default /tmp).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <unistd.h>

static FILE *out;
static NSMutableDictionary<NSString *, NSNumber *> *seen;

static void openLog(void) {
    if (out) return;
    const char *dir = getenv("MTLWATCH_DIR");
    char path[1024];
    snprintf(path, sizeof path, "%s/mtlwatch.%s.%d", dir && *dir ? dir : "/tmp", getprogname(), getpid());
    out = fopen(path, "w");
    if (out) setvbuf(out, NULL, _IOLBF, 0);
    seen = [NSMutableDictionary new];
}

@interface MTLWatchProxy : NSProxy
@property(nonatomic, strong) id target;
@end

@implementation MTLWatchProxy
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [self.target methodSignatureForSelector:sel]; }
- (BOOL)respondsToSelector:(SEL)sel { return [self.target respondsToSelector:sel]; }
- (BOOL)conformsToProtocol:(Protocol *)p { return [self.target conformsToProtocol:p]; }
- (BOOL)isKindOfClass:(Class)c { return [self.target isKindOfClass:c]; }
- (NSString *)description { return [self.target description]; }
- (void)forwardInvocation:(NSInvocation *)inv {
    [inv invokeWithTarget:self.target];
    NSString *name = NSStringFromSelector(inv.selector);
    const char *rt = inv.methodSignature.methodReturnType;
    NSString *result = nil;
    BOOL interesting = NO;
    if (rt[0] == '@') {
        __unsafe_unretained id r = nil;
        [inv getReturnValue:&r];
        result = r ? @"object" : @"NIL";
        interesting = (r == nil);
    } else if (rt[0] == 'B' || rt[0] == 'c') {
        BOOL b = NO;
        [inv getReturnValue:&b];
        result = b ? @"YES" : @"NO";
    } else if (rt[0] == 'Q' || rt[0] == 'q' || rt[0] == 'L' || rt[0] == 'I' || rt[0] == 'i') {
        unsigned long long v = 0;
        [inv getReturnValue:&v];
        result = [NSString stringWithFormat:@"%llu", v];
    } else {
        result = [NSString stringWithFormat:@"(%s)", rt];
    }
    // Arguments: the first object argument (a descriptor) and a BOOL/int one.
    NSMutableString *args = [NSMutableString string];
    NSUInteger n = inv.methodSignature.numberOfArguments;
    for (NSUInteger i = 2; i < n && i < 6; i++) {
        const char *at = [inv.methodSignature getArgumentTypeAtIndex:i];
        if (at[0] == '@') {
            __unsafe_unretained id a = nil;
            [inv getArgument:&a atIndex:(NSInteger)i];
            NSString *d = [[a description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if (d.length > 600) d = [d substringToIndex:600];
            [args appendFormat:@" arg%lu=%@", (unsigned long)i, d];
        } else if (at[0] == 'Q' || at[0] == 'q') {
            unsigned long long v = 0;
            [inv getArgument:&v atIndex:(NSInteger)i];
            [args appendFormat:@" arg%lu=%llu", (unsigned long)i, v];
        } else if (at[0] == '^' && i == n - 1) {
            // an NSError ** out-parameter
            NSError *__autoreleasing *ep = NULL;
            [inv getArgument:&ep atIndex:(NSInteger)i];
            if (ep && *ep) [args appendFormat:@" error=%@", (*ep).localizedDescription];
        }
    }
    @synchronized([MTLWatchProxy class]) {
        NSString *key = [name stringByAppendingString:result];
        NSUInteger count = seen[key].unsignedIntegerValue + 1;
        seen[key] = @(count);
        if (count <= 3 || interesting) {
            fprintf(out, "%s -> %s%s\n", name.UTF8String, result.UTF8String, interesting || count == 1 ? args.UTF8String : "");
        }
    }
}
@end

static id wrap(id device) {
    if (!device) return nil;
    openLog();
    if (!out) return device;
    MTLWatchProxy *p = [MTLWatchProxy alloc];
    p.target = device;
    fprintf(out, "device %s wrapped\n", [[device name] UTF8String]);
    return p;
}

static id<MTLDevice> watched_MTLCreateSystemDefaultDevice(void) { return wrap(MTLCreateSystemDefaultDevice()); }

static NSArray<id<MTLDevice>> *watched_MTLCopyAllDevices(void) {
    NSArray *all = MTLCopyAllDevices();
    NSMutableArray *w = [NSMutableArray array];
    for (id d in all) [w addObject:wrap(d)];
    return w;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; } interposers[] = {
    {(const void *)watched_MTLCreateSystemDefaultDevice, (const void *)MTLCreateSystemDefaultDevice},
    {(const void *)watched_MTLCopyAllDevices, (const void *)MTLCopyAllDevices},
};
