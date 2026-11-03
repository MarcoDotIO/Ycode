/*
 * idsrelay: Ycode research probe (original Ycode code, no Apple code).
 * Runs on the Mac. A man-in-the-middle on the pairing transport between two
 * paired, booted simulators. The reference host gives each device a host-side
 * bootstrap name "com.apple.IDSSimRPC.remote.<peer UDID>" whose port is the
 * peer's "com.apple.IDSSimRPC.local" receive port (pairing-observations.md).
 * This tool does the same with ports of its own:
 *
 *   idsrelay <udidA> <udidB> <seconds> [--no-swap]
 *
 *   1. looks up "com.apple.IDSSimRPC.local" in A and in B (send rights),
 *   2. makes two receive ports, and (unless --no-swap) replaces the name
 *      "com.apple.IDSSimRPC.remote.<B>" in A and "...remote.<A>" in B with
 *      them (unregister, then register),
 *   3. forwards every message that arrives on them to the real peer port,
 *      unchanged except for the destination, and prints the header, the
 *      descriptors and the first 256 body bytes of each,
 *   4. after <seconds>, puts the reference ports back under those names.
 *
 * The daemons cache the port they looked up, so the caller restarts them
 * (or their peer) after step 2 for traffic to take the new path.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <mach/mach.h>
#include <dlfcn.h>

static id device(NSString *udid)
{
    NSError *e = nil;
    id ctx = ((id (*)(id, SEL, NSString *, NSError **))objc_msgSend)(NSClassFromString(@"SimServiceContext"),
        NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"), @"/Applications/Xcode.app/Contents/Developer", &e);
    id set = ((id (*)(id, SEL, NSError **))objc_msgSend)(ctx, NSSelectorFromString(@"defaultDeviceSetWithError:"), &e);
    NSDictionary *byUDID = ((id (*)(id, SEL))objc_msgSend)(set, NSSelectorFromString(@"devicesByUDID"));
    return byUDID[[[NSUUID alloc] initWithUUIDString:udid]];
}

static mach_port_t lookup(id dev, NSString *name)
{
    NSError *e = nil;
    mach_port_t p = ((mach_port_t (*)(id, SEL, NSString *, NSError **))objc_msgSend)(dev, NSSelectorFromString(@"lookup:error:"), name, &e);
    if (!p) printf("lookup %s failed: %s\n", name.UTF8String, e.description.UTF8String);
    return p;
}

static BOOL reg(id dev, mach_port_t port, NSString *name)
{
    NSError *e = nil;
    ((BOOL (*)(id, SEL, NSString *, NSError **))objc_msgSend)(dev, NSSelectorFromString(@"unregisterService:error:"), name, &e);
    e = nil;
    BOOL ok = ((BOOL (*)(id, SEL, mach_port_t, NSString *, NSError **))objc_msgSend)(dev,
        NSSelectorFromString(@"registerPort:service:error:"), port, name, &e);
    printf("register %s port 0x%x: %s %s\n", name.UTF8String, port, ok ? "ok" : "FAILED", ok ? "" : e.description.UTF8String);
    return ok;
}

static const char *dispName(unsigned d)
{
    switch (d) {
    case 0: return "none"; case 16: return "move-recv"; case 17: return "move-send"; case 18: return "move-send-once";
    case 19: return "copy-send"; case 20: return "make-send"; case 21: return "make-send-once"; default: return "?";
    }
}

static int g_seq;

static void dump(const char *dir, mach_msg_header_t *h)
{
    unsigned bits = h->msgh_bits;
    printf("#%d %s t=%.6f id=%d size=%u bits=0x%x remote=%s local=%s voucher=%s complex=%d\n", ++g_seq, dir,
           [NSDate date].timeIntervalSince1970, h->msgh_id, h->msgh_size, bits,
           dispName(MACH_MSGH_BITS_REMOTE(bits)), dispName(MACH_MSGH_BITS_LOCAL(bits)),
           dispName(MACH_MSGH_BITS_VOUCHER(bits)), (bits & MACH_MSGH_BITS_COMPLEX) ? 1 : 0);
    uint8_t *body = (uint8_t *)(h + 1);
    uint8_t *end = (uint8_t *)h + h->msgh_size;
    if (bits & MACH_MSGH_BITS_COMPLEX) {
        mach_msg_body_t *b = (mach_msg_body_t *)body;
        printf("  descriptors %u\n", b->msgh_descriptor_count);
        uint8_t *d = (uint8_t *)(b + 1);
        for (unsigned i = 0; i < b->msgh_descriptor_count; i++) {
            mach_msg_type_descriptor_t *t = (mach_msg_type_descriptor_t *)d;
            if (t->type == MACH_MSG_PORT_DESCRIPTOR) {
                mach_msg_port_descriptor_t *p = (mach_msg_port_descriptor_t *)d;
                printf("  [%u] port disposition=%s\n", i, dispName(p->disposition));
                d += sizeof(*p);
            } else if (t->type == MACH_MSG_OOL_DESCRIPTOR || t->type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
                mach_msg_ool_descriptor_t *o = (mach_msg_ool_descriptor_t *)d;
                printf("  [%u] ool size=%u copy=%u dealloc=%u first bytes:", i, o->size, o->copy, o->deallocate);
                for (unsigned k = 0; k < o->size && k < 64; k++) printf(" %02x", ((uint8_t *)o->address)[k]);
                printf("\n");
                const char *sv = getenv("YC_RELAY_SAVE");
                if (sv && o->address) {
                    char path[1024];
                    snprintf(path, sizeof path, "%s/%d-%s-%u.bin", sv, g_seq, dir, i);
                    FILE *f = fopen(path, "w");
                    if (f) { fwrite(o->address, 1, o->size, f); fclose(f); }
                }
                d += sizeof(*o);
            } else if (t->type == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
                mach_msg_ool_ports_descriptor_t *o = (mach_msg_ool_ports_descriptor_t *)d;
                printf("  [%u] ool-ports count=%u disposition=%s\n", i, o->count, dispName(o->disposition));
                d += sizeof(*o);
            } else {
                printf("  [%u] descriptor type %u\n", i, t->type);
                d += sizeof(mach_msg_guarded_port_descriptor_t);
            }
        }
        body = d;
    }
    size_t n = end > body ? (size_t)(end - body) : 0;
    printf("  inline body %zu bytes:", n);
    for (size_t i = 0; i < n && i < 256; i++) { if (i % 32 == 0) printf("\n   "); printf(" %02x", body[i]); }
    printf("\n");
}

/* Reply interception: for a request that carries a send-once reply right,
 * the relay substitutes a reply port of its own, so the reply passes through
 * it too and can be recorded. */
#define MAXR 4096
static mach_port_t r_ours[MAXR], r_orig[MAXR]; static unsigned r_bits[MAXR]; static int r_n;

int main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc < 4) {
            printf("usage: idsrelay <udidA> <udidB> <seconds> [--no-swap | --prereg]\n"
                   "  --prereg: only register the name in A now (B may still be shut down);\n"
                   "            resolve B's local port when B is up, re-register if replaced\n");
            return 2;
        }
        dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
        NSString *ua = @(argv[1]), *ub = @(argv[2]);
        int secs = atoi(argv[3]);
        BOOL noswap = argc > 4 && !strcmp(argv[4], "--no-swap");
        BOOL prereg = argc > 4 && !strcmp(argv[4], "--prereg");
        id A = device(ua), B = device(ub);
        if (!A || !B) { printf("device not found\n"); return 1; }
        NSString *nameInA = [@"com.apple.IDSSimRPC.remote." stringByAppendingString:ub];
        NSString *nameInB = [@"com.apple.IDSSimRPC.remote." stringByAppendingString:ua];
        mach_port_t realA = lookup(A, @"com.apple.IDSSimRPC.local");
        mach_port_t realB = prereg ? MACH_PORT_NULL : lookup(B, @"com.apple.IDSSimRPC.local");
        mach_port_t curInA = prereg ? MACH_PORT_NULL : lookup(A, nameInA);
        mach_port_t curInB = prereg ? MACH_PORT_NULL : lookup(B, nameInB);
        printf("local A 0x%x local B 0x%x; current %s in A 0x%x, %s in B 0x%x\n", realA, realB,
               nameInA.UTF8String, curInA, nameInB.UTF8String, curInB);
        if (!realA || (!prereg && !realB)) return 1;
        if (noswap) return 0;
        mach_port_t set, toB, toA; /* toB: registered in A, forwards to B. */
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &set);
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &toB);
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &toA);
        mach_port_insert_right(mach_task_self(), toB, toB, MACH_MSG_TYPE_MAKE_SEND);
        mach_port_insert_right(mach_task_self(), toA, toA, MACH_MSG_TYPE_MAKE_SEND);
        mach_port_move_member(mach_task_self(), toB, set);
        mach_port_move_member(mach_task_self(), toA, set);
        reg(A, toB, nameInA);
        if (!prereg) reg(B, toA, nameInB);
        NSDate *stop = [NSDate dateWithTimeIntervalSinceNow:secs];
        NSDate *nextCheck = [NSDate date];
        size_t cap = 1 << 20;
        mach_msg_header_t *h = malloc(cap);
        while ([stop timeIntervalSinceNow] > 0) {
            if (prereg && [nextCheck timeIntervalSinceNow] <= 0) {
                nextCheck = [NSDate dateWithTimeIntervalSinceNow:1.0];
                NSError *e = nil;
                mach_port_t cur = ((mach_port_t (*)(id, SEL, NSString *, NSError **))objc_msgSend)(A, NSSelectorFromString(@"lookup:error:"), nameInA, &e);
                if (cur != toB) { printf("t=%.3f name in A now 0x%x (not ours): re-registering\n", [NSDate date].timeIntervalSince1970, cur); reg(A, toB, nameInA); }
                if (!realB) {
                    e = nil;
                    realB = ((mach_port_t (*)(id, SEL, NSString *, NSError **))objc_msgSend)(B, NSSelectorFromString(@"lookup:error:"), @"com.apple.IDSSimRPC.local", &e);
                    if (realB) printf("t=%.3f B local port resolved 0x%x\n", [NSDate date].timeIntervalSince1970, realB);
                }
            }
            kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_LARGE, 0, (mach_msg_size_t)cap, set, 200, MACH_PORT_NULL);
            if (kr == MACH_RCV_TIMED_OUT) continue;
            if (kr != KERN_SUCCESS) { printf("receive error 0x%x\n", kr); break; }
            mach_port_t on = h->msgh_local_port;
            unsigned bits = h->msgh_bits;
            mach_port_t voucher = h->msgh_voucher_port;
            if (voucher) { mach_port_deallocate(mach_task_self(), voucher); }
            h->msgh_voucher_port = MACH_PORT_NULL;
            int ri = -1;
            for (int i = 0; i < r_n; i++) if (r_ours[i] == on) { ri = i; break; }
            if (ri >= 0) {
                /* A reply on one of our reply ports: record and pass back. */
                dump("REPLY", h);
                h->msgh_bits = MACH_MSGH_BITS_SET(r_bits[ri], 0, 0, bits & MACH_MSGH_BITS_COMPLEX);
                h->msgh_remote_port = r_orig[ri];
                h->msgh_local_port = MACH_PORT_NULL;
                kr = mach_msg(h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, h->msgh_size, 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
                if (kr != KERN_SUCCESS) { printf("  reply forward error 0x%x\n", kr); mach_msg_destroy(h); }
                mach_port_mod_refs(mach_task_self(), r_ours[ri], MACH_PORT_RIGHT_RECEIVE, -1);
                r_ours[ri] = r_ours[--r_n]; r_orig[ri] = r_orig[r_n]; r_bits[ri] = r_bits[r_n];
                continue;
            }
            BOOL fromA = on == toB; /* arrived on the port A sends to */
            dump(fromA ? "A->B" : "B->A", h);
            mach_port_t target = fromA ? realB : realA;
            if (!target) { printf("  dropped: peer not up\n"); mach_msg_destroy(h); continue; }
            unsigned rdisp = MACH_MSGH_BITS_REMOTE(bits);
            mach_port_t reply = h->msgh_remote_port;
            unsigned localDisp = rdisp;
            if (reply && rdisp == MACH_MSG_TYPE_PORT_SEND_ONCE && r_n < MAXR) {
                mach_port_t ours;
                mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &ours);
                mach_port_move_member(mach_task_self(), ours, set);
                r_ours[r_n] = ours; r_orig[r_n] = reply; r_bits[r_n] = MACH_MSG_TYPE_MOVE_SEND_ONCE; r_n++;
                reply = ours; localDisp = MACH_MSG_TYPE_MAKE_SEND_ONCE;
            }
            h->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, localDisp, 0, bits & MACH_MSGH_BITS_COMPLEX);
            h->msgh_local_port = reply;
            h->msgh_remote_port = target;
            kr = mach_msg(h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, h->msgh_size, 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
            if (kr != KERN_SUCCESS) { printf("  forward error 0x%x\n", kr); mach_msg_destroy(h); }
        }
        if (curInA) { reg(A, curInA, nameInA); }
        if (curInB) { reg(B, curInB, nameInB); }
        printf("restored (prereg=%d)\n", prereg);
        return 0;
    }
}
