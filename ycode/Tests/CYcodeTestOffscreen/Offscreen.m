// The offscreen guard; see include/CYcodeTestOffscreen.h.

#import "CYcodeTestOffscreen.h"
#import <objc/runtime.h>
#import <stdatomic.h>
#import <unistd.h>

#if !__has_feature(objc_arc)
#error "CYcodeTestOffscreen is built with ARC"
#endif

// MARK: State

// Each test bundle links its own copy of this file, and one process may load
// several bundles. The first copy to load installs the guard; it keeps the
// state in a dictionary attached to the NSWindow class (selectors are unique
// in a process, so every copy finds it), and the other copies only read it.
static NSMutableDictionary *shared;
static BOOL trace;
static NSMutableArray<NSString *> *suppressed;
static NSMutableArray<NSString *> *violations;
static NSMutableSet<NSNumber *> *reportedWindows;
static atomic_bool sentinelStarted;
static dispatch_source_t sentinel;

/// The gap between a moved window and the leftmost display.
static const CGFloat gap = 2000;

static void note(NSMutableArray<NSString *> *list, NSString *line) {
    @synchronized(shared) { [list addObject:line]; }
}

static NSArray<NSString *> *copyOf(NSMutableArray<NSString *> *list) {
    if (!list) return @[];
    @synchronized(shared) { return [list copy]; }
}

extern char *swift_demangle(const char *name, size_t length, char *out, size_t *outSize, uint32_t flags) __attribute__((weak_import));

/// The first frame of the calling stack in a test's Swift code, for notes.
static NSString *caller(void) {
    for (NSString *frame in [NSThread callStackSymbols]) {
        NSArray<NSString *> *parts = [frame componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (parts.count < 4) continue;
        NSString *symbol = parts[3];
        if (![symbol hasPrefix:@"$s"] || ![symbol containsString:@"Tests"]) continue;
        if (swift_demangle) {
            char *plain = swift_demangle(symbol.UTF8String, strlen(symbol.UTF8String), NULL, NULL, 0);
            if (plain) {
                NSString *out = @(plain);
                free(plain);
                return out;
            }
        }
        return symbol;
    }
    return @"(no test frame)";
}

static void suppress(NSString *what) {
    note(suppressed, what);
    if (trace) fprintf(stderr, "OffscreenGuard: suppressed %s from %s\n", what.UTF8String, caller().UTF8String);
}

// MARK: Displays

static BOOL touchesAScreen(NSRect r) {
    for (NSScreen *s in [NSScreen screens]) {
        if (NSIntersectsRect(r, s.frame)) return YES;
    }
    return NO;
}

NSRect YcodeOffscreenParkedFrame(NSRect r) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    if (screens.count == 0 || !touchesAScreen(r)) return r;
    CGFloat left = 0;
    for (NSScreen *s in screens) left = MIN(left, NSMinX(s.frame));
    r.origin.x = floor(left - gap - NSWidth(r));
    return r;
}

/// The window server's view: windows of this process on an active display.
NSArray<NSString *> *YcodeOffscreenWindowsOnDisplays(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    CGDirectDisplayID ids[32];
    uint32_t n = 0;
    if (CGGetActiveDisplayList(32, ids, &n) != kCGErrorSuccess || n == 0) return out;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!list) return out;
    pid_t me = getpid();
    for (NSDictionary *info in (__bridge NSArray *)list) {
        if ([info[(__bridge NSString *)kCGWindowOwnerPID] intValue] != me) continue;
        double alpha = [info[(__bridge NSString *)kCGWindowAlpha] doubleValue];
        if (alpha <= 0) continue;
        CGRect b;
        NSDictionary *bounds = info[(__bridge NSString *)kCGWindowBounds];
        if (!bounds || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &b)) continue;
        for (uint32_t i = 0; i < n; i++) {
            CGRect x = CGRectIntersection(b, CGDisplayBounds(ids[i]));
            if (!CGRectIsNull(x) && x.size.width >= 1 && x.size.height >= 1) {
                NSString *name = info[(__bridge NSString *)kCGWindowName];
                [out addObject:[NSString stringWithFormat:@"window %@ layer %@ at %@ alpha %.2f on display %u%@",
                                info[(__bridge NSString *)kCGWindowNumber], info[(__bridge NSString *)kCGWindowLayer],
                                NSStringFromRect(NSRectFromCGRect(b)), alpha, ids[i],
                                name.length ? [NSString stringWithFormat:@" named \"%@\"", name] : @""]];
                break;
            }
        }
    }
    CFRelease(list);
    return out;
}

// MARK: Moving windows

typedef void (*SetFrameIMP)(id, SEL, NSRect, BOOL);
static SetFrameIMP origSetFrame;

static void park(NSWindow *w, NSString *why) {
    NSRect f = w.frame, p = YcodeOffscreenParkedFrame(f);
    if (NSEqualRects(f, p)) return;
    origSetFrame(w, @selector(setFrame:display:), p, NO);
    @synchronized(shared) { shared[@"parks"] = @([shared[@"parks"] integerValue] + 1); }
    if (trace) {
        fprintf(stderr, "OffscreenGuard: moved %s \"%s\" (%s) from %s to %s; %s\n", NSStringFromClass(w.class).UTF8String,
                w.title.UTF8String, why.UTF8String, NSStringFromRect(f).UTF8String, NSStringFromRect(p).UTF8String, caller().UTF8String);
    }
}

static void startSentinel(void);

/// Ordering-in calls in progress (main thread): AppKit may place the window
/// while it orders it in, before it counts as visible.
static NSInteger orderingIn;

/// A frame given to this window would reach the window server now.
static BOOL placed(NSWindow *w) { return w.isVisible || orderingIn > 0; }

/// Who ordered each window in last (window number → class, title, test),
/// so the sentinel can name a window it finds without the main thread.
static NSMutableDictionary<NSNumber *, NSString *> *orderedBy;

/// Before a window is ordered in: off every display first.
static void beforeOrderIn(NSWindow *w, NSString *why) {
    startSentinel();
    if (w.windowNumber > 0) {
        NSString *who = [NSString stringWithFormat:@"%@ \"%@\" ordered in by %@ (%@)", NSStringFromClass(w.class), w.title, caller(), why];
        @synchronized(shared) { orderedBy[@(w.windowNumber)] = who; }
    }
    park(w, why);
    orderingIn += 1;
}

/// After anything that may have placed a visible window: off again if it is on.
static void afterChange(NSWindow *w, NSString *why) {
    if (placed(w)) park(w, why);
}

/// After the window was ordered in.
static void afterOrderIn(NSWindow *w, NSString *why) {
    orderingIn -= 1;
    afterChange(w, why);
}

/// Runs an ordering call with the window's ordering animation off. AppKit
/// draws a document window's appear and close animations (a fade and a
/// slight zoom) on a display even for a window off every display.
static void still(NSWindow *w, void (^call)(void)) {
    NSWindowAnimationBehavior saved = w.animationBehavior;
    if (saved != NSWindowAnimationBehaviorNone) w.animationBehavior = NSWindowAnimationBehaviorNone;
    call();
    if (saved != NSWindowAnimationBehaviorNone) w.animationBehavior = saved;
}

// MARK: The sentinel

static void sentinelTick(void) {
    NSArray<NSString *> *on = YcodeOffscreenWindowsOnDisplays();
    if (on.count == 0) return;
    for (NSString *line in on) {
        NSInteger number = [[line componentsSeparatedByString:@" "][1] integerValue];
        BOOL fresh;
        @synchronized(shared) {
            fresh = ![reportedWindows containsObject:@(number)];
            if (fresh) [reportedWindows addObject:@(number)];
        }
        if (!fresh) continue;
        NSString *who;
        @synchronized(shared) { who = orderedBy[@(number)]; }
        NSString *entry = who ? [line stringByAppendingFormat:@"; %@", who] : line;
        note(violations, entry);
        fprintf(stderr, "OffscreenGuard: a window of this test process is on a display: %s\n", entry.UTF8String);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!NSApp) return;
            NSWindow *w = [NSApp windowWithWindowNumber:number];
            if (!w) return;
            note(violations, [NSString stringWithFormat:@"window %ld is %@ \"%@\"", (long)number, NSStringFromClass(w.class), w.title]);
            park(w, @"sentinel");
        });
    }
}

static void startSentinel(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&sentinelStarted, &expected, true)) return;
    dispatch_queue_t q = dispatch_queue_create("dev.ycode.tests.offscreen-sentinel", DISPATCH_QUEUE_SERIAL);
    sentinel = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(sentinel, dispatch_time(DISPATCH_TIME_NOW, 0), 100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(sentinel, ^{ @autoreleasepool { sentinelTick(); } });
    dispatch_resume(sentinel);
}

static void checkAtExit(void) {
    if (!atomic_load(&sentinelStarted)) return;
    @autoreleasepool {
        NSMutableArray<NSString *> *all = [copyOf(violations) mutableCopy];
        [all addObjectsFromArray:YcodeOffscreenWindowsOnDisplays()];
        if (all.count == 0) return;
        fprintf(stderr, "OffscreenGuard: windows of this test process were on a display (ycode/README.md, \"Nothing on screen\"):\n");
        for (NSString *line in all) fprintf(stderr, "  %s\n", line.UTF8String);
        _exit(1);
    }
}

// MARK: Swizzling

static IMP replace(Class cls, SEL sel, id block) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        fprintf(stderr, "OffscreenGuard: %s has no %s\n", class_getName(cls), sel_getName(sel));
        return NULL;
    }
    IMP imp = imp_implementationWithBlock(block);
    IMP old = method_getImplementation(m);
    // An inherited method gets an override in `cls`; its own is replaced.
    if (class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) return old;
    return method_setImplementation(m, imp);
}

/// AppKit would move a window that touches no display back onto one: the
/// constraint to a screen keeps every frame as given, in NSWindow and in
/// each system subclass with a constraint of its own (panels). Ycode's own
/// overrides stay, so their tests still test them; the setters' check
/// catches one that would put a window on a display.
static void unconstrain(void) {
    Class W = [NSWindow class];
    SEL constrain = @selector(constrainFrameRect:toScreen:);
    NSRect (^keep)(NSWindow *, NSRect, NSScreen *) = ^NSRect(NSWindow *w, NSRect r, NSScreen *s) { return r; };
    method_setImplementation(class_getInstanceMethod(W, constrain), imp_implementationWithBlock(keep));
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        const char *image = class_getImageName(classes[i]);
        if (!image || strncmp(image, "/System/", 8) != 0) continue;
        Class sup = class_getSuperclass(classes[i]);
        while (sup && sup != W) sup = class_getSuperclass(sup);
        if (!sup) continue;
        unsigned int n = 0;
        Method *methods = class_copyMethodList(classes[i], &n);
        for (unsigned int j = 0; j < n; j++) {
            if (method_getName(methods[j]) == constrain) method_setImplementation(methods[j], imp_implementationWithBlock(keep));
        }
        free(methods);
    }
    free(classes);
}

static void guardWindows(void) {
    Class W = [NSWindow class];
    origSetFrame = (SetFrameIMP)replace(W, @selector(setFrame:display:), ^(NSWindow *w, NSRect r, BOOL display) {
        if (placed(w)) {
            NSRect asked = r;
            r = YcodeOffscreenParkedFrame(r);
            if (trace && !NSEqualRects(asked, r)) {
                fprintf(stderr, "OffscreenGuard: kept %s \"%s\" off at %s instead of %s (setFrame:display:%s)\n",
                        NSStringFromClass(w.class).UTF8String, w.title.UTF8String, NSStringFromRect(r).UTF8String,
                        NSStringFromRect(asked).UTF8String, w.isVisible ? "" : ", ordering in");
            }
        }
        origSetFrame(w, @selector(setFrame:display:), r, display);
    });

    typedef void (*Animate)(id, SEL, NSRect, BOOL, BOOL);
    static Animate animate;
    animate = (Animate)replace(W, @selector(setFrame:display:animate:), ^(NSWindow *w, NSRect r, BOOL display, BOOL anim) {
        if (placed(w)) r = YcodeOffscreenParkedFrame(r);
        animate(w, @selector(setFrame:display:animate:), r, display, anim);
        afterChange(w, @"setFrame:display:animate:");
    });

    typedef void (*PointIMP)(id, SEL, NSPoint);
    static PointIMP origin, topLeft;
    origin = (PointIMP)replace(W, @selector(setFrameOrigin:), ^(NSWindow *w, NSPoint p) {
        if (placed(w)) p = YcodeOffscreenParkedFrame((NSRect){p, w.frame.size}).origin;
        origin(w, @selector(setFrameOrigin:), p);
        afterChange(w, @"setFrameOrigin:");
    });
    topLeft = (PointIMP)replace(W, @selector(setFrameTopLeftPoint:), ^(NSWindow *w, NSPoint p) {
        if (placed(w)) {
            NSSize s = w.frame.size;
            NSRect r = YcodeOffscreenParkedFrame(NSMakeRect(p.x, p.y - s.height, s.width, s.height));
            p = NSMakePoint(r.origin.x, NSMaxY(r));
        }
        topLeft(w, @selector(setFrameTopLeftPoint:), p);
        afterChange(w, @"setFrameTopLeftPoint:");
    });

    typedef void (*PlainIMP)(id, SEL);
    static PlainIMP center, regardless;
    center = (PlainIMP)replace(W, @selector(center), ^(NSWindow *w) {
        center(w, @selector(center));
        afterChange(w, @"center");
    });
    regardless = (PlainIMP)replace(W, @selector(orderFrontRegardless), ^(NSWindow *w) {
        beforeOrderIn(w, @"orderFrontRegardless");
        still(w, ^{ regardless(w, @selector(orderFrontRegardless)); });
        afterOrderIn(w, @"orderFrontRegardless");
    });

    typedef void (*SenderIMP)(id, SEL, id);
    static SenderIMP front, back, keyFront;
    front = (SenderIMP)replace(W, @selector(orderFront:), ^(NSWindow *w, id sender) {
        beforeOrderIn(w, @"orderFront:");
        still(w, ^{ front(w, @selector(orderFront:), sender); });
        afterOrderIn(w, @"orderFront:");
    });
    back = (SenderIMP)replace(W, @selector(orderBack:), ^(NSWindow *w, id sender) {
        beforeOrderIn(w, @"orderBack:");
        still(w, ^{ back(w, @selector(orderBack:), sender); });
        afterOrderIn(w, @"orderBack:");
    });
    keyFront = (SenderIMP)replace(W, @selector(makeKeyAndOrderFront:), ^(NSWindow *w, id sender) {
        beforeOrderIn(w, @"makeKeyAndOrderFront:");
        still(w, ^{ keyFront(w, @selector(makeKeyAndOrderFront:), sender); });
        afterOrderIn(w, @"makeKeyAndOrderFront:");
    });

    typedef void (*OrderIMP)(id, SEL, NSWindowOrderingMode, NSInteger);
    static OrderIMP order;
    order = (OrderIMP)replace(W, @selector(orderWindow:relativeTo:), ^(NSWindow *w, NSWindowOrderingMode place, NSInteger other) {
        if (place != NSWindowOut) beforeOrderIn(w, @"orderWindow:relativeTo:");
        still(w, ^{ order(w, @selector(orderWindow:relativeTo:), place, other); });
        if (place != NSWindowOut) afterOrderIn(w, @"orderWindow:relativeTo:");
    });

    static SenderIMP out;
    out = (SenderIMP)replace(W, @selector(orderOut:), ^(NSWindow *w, id sender) {
        still(w, ^{ out(w, @selector(orderOut:), sender); });
    });
    static PlainIMP closeIMP;
    closeIMP = (PlainIMP)replace(W, @selector(close), ^(NSWindow *w) {
        still(w, ^{ closeIMP(w, @selector(close)); });
    });

    typedef void (*BoolIMP)(id, SEL, BOOL);
    static BoolIMP visible;
    visible = (BoolIMP)replace(W, @selector(setIsVisible:), ^(NSWindow *w, BOOL flag) {
        if (flag) beforeOrderIn(w, @"setIsVisible:");
        still(w, ^{ visible(w, @selector(setIsVisible:), flag); });
        if (flag) afterOrderIn(w, @"setIsVisible:");
    });

    unconstrain();

    // Full screen and the Dock's minimize animation would show the window.
    replace(W, @selector(toggleFullScreen:), ^(NSWindow *w, id sender) {
        suppress([NSString stringWithFormat:@"toggleFullScreen: of %@", NSStringFromClass(w.class)]);
    });
    replace(W, @selector(miniaturize:), ^(NSWindow *w, id sender) {
        suppress([NSString stringWithFormat:@"miniaturize: of %@", NSStringFromClass(w.class)]);
    });
}

static void guardModals(void) {
    replace([NSAlert class], @selector(runModal), ^NSModalResponse(NSAlert *a) {
        suppress([NSString stringWithFormat:@"NSAlert runModal \"%@\"", a.messageText]);
        return NSModalResponseCancel;
    });
    replace([NSApplication class], @selector(runModalForWindow:), ^NSModalResponse(NSApplication *app, NSWindow *w) {
        suppress([NSString stringWithFormat:@"runModalForWindow: %@ \"%@\"", NSStringFromClass(w.class), w.title]);
        return NSModalResponseCancel;
    });
    // Open panels inherit these; an own implementation is replaced too.
    for (Class P in @[[NSSavePanel class], [NSOpenPanel class]]) {
        replace(P, @selector(runModal), ^NSModalResponse(NSSavePanel *p) {
            suppress([NSString stringWithFormat:@"%@ runModal", NSStringFromClass(p.class)]);
            return NSModalResponseCancel;
        });
        replace(P, @selector(beginSheetModalForWindow:completionHandler:), ^(NSSavePanel *p, NSWindow *w, void (^done)(NSModalResponse)) {
            suppress([NSString stringWithFormat:@"%@ beginSheetModalForWindow:", NSStringFromClass(p.class)]);
            if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(NSModalResponseCancel); });
        });
        replace(P, @selector(beginWithCompletionHandler:), ^(NSSavePanel *p, void (^done)(NSModalResponse)) {
            suppress([NSString stringWithFormat:@"%@ beginWithCompletionHandler:", NSStringFromClass(p.class)]);
            if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(NSModalResponseCancel); });
        });
    }
}

static void guardMenus(void) {
    replace([NSMenu class], @selector(popUpMenuPositioningItem:atLocation:inView:),
            ^BOOL(NSMenu *m, NSMenuItem *item, NSPoint at, NSView *view) {
        suppress([NSString stringWithFormat:@"popUpMenuPositioningItem: \"%@\" (%ld items)", m.title, (long)m.numberOfItems]);
        return NO;
    });
    Class meta = object_getClass([NSMenu class]);
    replace(meta, @selector(popUpContextMenu:withEvent:forView:), ^(id cls, NSMenu *m, NSEvent *e, NSView *v) {
        suppress([NSString stringWithFormat:@"popUpContextMenu: \"%@\"", m.title]);
    });
    replace(meta, @selector(popUpContextMenu:withEvent:forView:withFont:), ^(id cls, NSMenu *m, NSEvent *e, NSView *v, NSFont *f) {
        suppress([NSString stringWithFormat:@"popUpContextMenu: \"%@\"", m.title]);
    });
    replace([NSPopUpButtonCell class], @selector(performClickWithFrame:inView:), ^(NSPopUpButtonCell *c, NSRect r, NSView *v) {
        suppress([NSString stringWithFormat:@"pop-up button menu \"%@\"", c.title]);
    });
}

static void guardApp(void) {
    replace([NSApplication class], @selector(activateIgnoringOtherApps:), ^(NSApplication *app, BOOL flag) {
        suppress(@"activateIgnoringOtherApps:");
    });
    if ([NSApplication instancesRespondToSelector:@selector(activate)]) {
        replace([NSApplication class], @selector(activate), ^(NSApplication *app) { suppress(@"activate"); });
    }
}

static NSError *notOpened(void) { return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]; }

static void guardWorkspace(void) {
    Class S = [NSWorkspace class];
    replace(S, @selector(openURL:), ^BOOL(NSWorkspace *ws, NSURL *url) {
        suppress([NSString stringWithFormat:@"NSWorkspace openURL: %@", url]);
        return YES;
    });
    replace(S, @selector(openURL:configuration:completionHandler:),
            ^(NSWorkspace *ws, NSURL *url, NSWorkspaceOpenConfiguration *c, void (^done)(NSRunningApplication *, NSError *)) {
        suppress([NSString stringWithFormat:@"NSWorkspace openURL:configuration: %@", url]);
        if (done) done(nil, notOpened());
    });
    replace(S, @selector(openURLs:withApplicationAtURL:configuration:completionHandler:),
            ^(NSWorkspace *ws, NSArray<NSURL *> *urls, NSURL *app, NSWorkspaceOpenConfiguration *c,
              void (^done)(NSRunningApplication *, NSError *)) {
        suppress([NSString stringWithFormat:@"NSWorkspace openURLs: %@ with %@", urls, app]);
        if (done) done(nil, notOpened());
    });
    replace(S, @selector(openApplicationAtURL:configuration:completionHandler:),
            ^(NSWorkspace *ws, NSURL *app, NSWorkspaceOpenConfiguration *c, void (^done)(NSRunningApplication *, NSError *)) {
        suppress([NSString stringWithFormat:@"NSWorkspace openApplicationAtURL: %@", app]);
        if (done) done(nil, notOpened());
    });
    replace(S, @selector(activateFileViewerSelectingURLs:), ^(NSWorkspace *ws, NSArray<NSURL *> *urls) {
        suppress([NSString stringWithFormat:@"NSWorkspace activateFileViewerSelectingURLs: %@", urls]);
    });
    replace(S, @selector(selectFile:inFileViewerRootedAtPath:), ^BOOL(NSWorkspace *ws, NSString *path, NSString *root) {
        suppress([NSString stringWithFormat:@"NSWorkspace selectFile: %@", path]);
        return YES;
    });
}

// MARK: Public

BOOL YcodeOffscreenIsActive(void) { return shared != nil; }
NSArray<NSString *> *YcodeOffscreenSuppressed(void) { return copyOf(suppressed); }
NSArray<NSString *> *YcodeOffscreenViolations(void) {
    void (^start)(void) = shared[@"startSentinel"];
    if (start) start();
    return copyOf(violations);
}
NSInteger YcodeOffscreenParkCount(void) {
    if (!shared) return 0;
    @synchronized(shared) { return [shared[@"parks"] integerValue]; }
}

// Runs when the test bundle loads, before any test.
__attribute__((constructor)) static void install(void) {
    NSDictionary<NSString *, NSString *> *env = [[NSProcessInfo processInfo] environment];
    if ([env[@"YCODE_TESTS_ON_SCREEN"] isEqualToString:@"1"]) {
        fprintf(stderr, "OffscreenGuard: off (YCODE_TESTS_ON_SCREEN=1): test windows may appear on screen\n");
        return;
    }
    trace = [env[@"YCODE_OFFSCREEN_TRACE"] isEqualToString:@"1"];
    Class W = [NSWindow class];
    SEL key = @selector(ycodeOffscreenGuardState);
    NSMutableDictionary *installed = objc_getAssociatedObject(W, key);
    if (installed) {
        // Another bundle's copy guards this process; share its state.
        shared = installed;
        suppressed = shared[@"suppressed"];
        violations = shared[@"violations"];
        reportedWindows = shared[@"reported"];
        return;
    }
    suppressed = [NSMutableArray array];
    violations = [NSMutableArray array];
    reportedWindows = [NSMutableSet set];
    orderedBy = [NSMutableDictionary dictionary];
    shared = [@{@"suppressed": suppressed, @"violations": violations, @"reported": reportedWindows, @"parks": @0,
                @"startSentinel": [^{ startSentinel(); } copy]} mutableCopy];
    objc_setAssociatedObject(W, key, shared, OBJC_ASSOCIATION_RETAIN);
    guardWindows();
    guardModals();
    guardMenus();
    guardApp();
    guardWorkspace();
    atexit(checkAtExit);
}
