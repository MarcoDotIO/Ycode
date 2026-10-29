// The guest side of `dev.ycode.camera` (camera.md "Ycode implementation";
// the wire format is CameraGuestProtocol.swift): requests on the host
// endpoint, the process's frame port and its receive thread, and pixel
// buffers made from the host's IOSurfaces with the public CoreVideo API.

#import "YCCamera.h"

// The Mach bootstrap look-up (launchd's public bootstrap API; the iOS SDK
// ships no header for it, the symbols are in libSystem).
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);

BOOL YCDebug = NO;

void YCLog(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    static CFAbsoluteTime start;
    if (start == 0) start = CFAbsoluteTimeGetCurrent();
    fprintf(stderr, "ycode-camera[%d] %.3f: %s\n", getpid(), CFAbsoluteTimeGetCurrent() - start, s.UTF8String);
    fflush(stderr);
}

@implementation YCCameraInfo
@end

void (^YCFrameHandler)(YCFrameInfo frame);
void (^YCEventHandler)(uint32_t stream, uint32_t kind, uint32_t width, uint32_t height);

// MARK: - Messages

#define YC_BASE 0x59434D00
enum { YCReqDevices = 1, YCReqStart = 2, YCReqStop = 3, YCReqRelease = 4, YCToFrame = 200, YCToEvent = 201 };

static const uint8_t kNDR[8] = {0, 0, 0, 0, 1, 0, 0, 0};

typedef struct {
    mach_msg_header_t header;
    uint8_t ndr[8];
    uint32_t w[16];
} YCSimpleMessage;

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port;
    uint8_t ndr[8];
    uint32_t w[8];
} YCPortMessage;

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_descriptor_t ool;
    uint8_t ndr[8];
    uint32_t w[4];
} YCOOLReply;

typedef union {
    YCSimpleMessage simple;
    YCOOLReply ool;
    uint8_t bytes[512];
} YCReceiveBuffer;

static pthread_mutex_t gCallLock = PTHREAD_MUTEX_INITIALIZER;
static mach_port_t gService = MACH_PORT_NULL;
static mach_port_t gReply = MACH_PORT_NULL;
static mach_port_t gFrames = MACH_PORT_NULL;
static BOOL gLookedUp = NO;

/// The endpoint (looked up once; nil when Ycode registered none).
static mach_port_t YCServicePort(void) {
    if (gLookedUp) return gService;
    gLookedUp = YES;
    const char *name = getenv("YCODE_CAMERA_SERVICE");
    if (!name || !*name) name = "dev.ycode.camera";
    kern_return_t kr = bootstrap_look_up(bootstrap_port, name, &gService);
    if (kr != KERN_SUCCESS) {
        gService = MACH_PORT_NULL;
        YCLog(@"no camera endpoint %s (bootstrap_look_up: %d)", name, kr);
    } else {
        YCTrace(@"camera endpoint %s: port 0x%x", name, gService);
    }
    return gService;
}

/// Sends `request` (its header filled here) and receives the reply into `reply`.
static kern_return_t YCCall(mach_msg_header_t *request, mach_msg_size_t size, int n, YCReceiveBuffer *reply) {
    mach_port_t service = YCServicePort();
    if (service == MACH_PORT_NULL) return MACH_SEND_INVALID_DEST;
    if (gReply == MACH_PORT_NULL) mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gReply);
    request->msgh_bits |= MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    request->msgh_size = size;
    request->msgh_remote_port = service;
    request->msgh_local_port = gReply;
    request->msgh_id = YC_BASE + n;
    // One buffer for the request and the reply (mach_msg receives into the
    // message it sent).
    memset(reply, 0, sizeof(*reply));
    memcpy(reply->bytes, request, size);
    kern_return_t kr = mach_msg(&reply->simple.header, MACH_SEND_MSG | MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_SEND_TIMEOUT, size,
                                sizeof(*reply), gReply, 20000, MACH_PORT_NULL);
    if (kr == MACH_RCV_TIMED_OUT) {
        // A late reply must not answer the next call: a new reply port.
        mach_port_mod_refs(mach_task_self(), gReply, MACH_PORT_RIGHT_RECEIVE, -1);
        gReply = MACH_PORT_NULL;
    }
    if (kr == KERN_SUCCESS && reply->simple.header.msgh_id != YC_BASE + 100 + n) {
        YCLog(@"request %d: unexpected reply id %d", n, reply->simple.header.msgh_id);
        mach_msg_destroy(&reply->simple.header);
        kr = MACH_RCV_INVALID_DATA;
    }
    return kr;
}

static void YCFillSimple(YCSimpleMessage *m, const uint32_t *words, int count) {
    memset(m, 0, sizeof(*m));
    memcpy(m->ndr, kNDR, 8);
    memcpy(m->w, words, sizeof(uint32_t) * (size_t)count);
}

NSArray<YCCameraInfo *> *YCHostDevices(void) {
    pthread_mutex_lock(&gCallLock);
    YCSimpleMessage m;
    uint32_t words[1] = {1};
    YCFillSimple(&m, words, 1);
    YCReceiveBuffer r;
    kern_return_t kr = YCCall(&m.header, (mach_msg_size_t)(sizeof(mach_msg_header_t) + 8 + 4), YCReqDevices, &r);
    NSData *data = nil;
    if (kr == KERN_SUCCESS && (r.ool.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) && r.ool.body.msgh_descriptor_count == 1) {
        data = [NSData dataWithBytes:r.ool.ool.address length:r.ool.ool.size];
        vm_deallocate(mach_task_self(), (vm_address_t)r.ool.ool.address, r.ool.ool.size);
    }
    pthread_mutex_unlock(&gCallLock);
    if (kr != KERN_SUCCESS) {
        if (kr != MACH_SEND_INVALID_DEST) YCLog(@"device list: mach_msg %d", kr);
        return @[];
    }
    NSDictionary *plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in plist[@"devices"]) {
        if (![d isKindOfClass:NSDictionary.class]) continue;
        YCCameraInfo *c = [YCCameraInfo new];
        c.uniqueID = d[@"uniqueID"] ?: @"dev.ycode.camera";
        c.localizedName = d[@"localizedName"] ?: @"Camera";
        c.modelID = d[@"modelID"] ?: @"Ycode Camera";
        c.manufacturer = d[@"manufacturer"] ?: @"Ycode";
        c.deviceType = d[@"deviceType"] ?: @"AVCaptureDeviceTypeBuiltInWideAngleCamera";
        c.position = [d[@"position"] integerValue];
        c.formats = d[@"formats"] ?: @[];
        [out addObject:c];
    }
    YCTrace(@"device list: %lu camera(s)", (unsigned long)out.count);
    return out;
}

// MARK: - Frames

static void *YCFrameThread(void *arg);

static void YCEnsureFramePort(void) {
    if (gFrames != MACH_PORT_NULL) return;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gFrames) != KERN_SUCCESS) {
        gFrames = MACH_PORT_NULL;
        return;
    }
    mach_port_limits_t limits = {.mpl_qlimit = 8};
    mach_port_set_attributes(mach_task_self(), gFrames, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits,
                             MACH_PORT_LIMITS_INFO_COUNT);
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&t, &attr, YCFrameThread, NULL);
    pthread_attr_destroy(&attr);
}

YCStartReply YCHostStart(uint32_t width, uint32_t height, double fps, OSType pixelFormat) {
    YCStartReply out = {YCStatusNoDevice, 0, 0, 0, 0, 0};
    pthread_mutex_lock(&gCallLock);
    YCEnsureFramePort();
    YCPortMessage m;
    memset(&m, 0, sizeof(m));
    m.header.msgh_bits = MACH_MSGH_BITS_COMPLEX;
    m.body.msgh_descriptor_count = 1;
    m.port.name = gFrames;
    m.port.disposition = MACH_MSG_TYPE_MAKE_SEND;
    m.port.type = MACH_MSG_PORT_DESCRIPTOR;
    memcpy(m.ndr, kNDR, 8);
    uint32_t words[6] = {0, width, height, (uint32_t)llround(fps * 1000), pixelFormat, 0};
    memcpy(m.w, words, sizeof(words));
    YCReceiveBuffer r;
    kern_return_t kr = gFrames == MACH_PORT_NULL ? KERN_FAILURE
        : YCCall(&m.header, (mach_msg_size_t)(offsetof(YCPortMessage, w) + sizeof(words)), YCReqStart, &r);
    pthread_mutex_unlock(&gCallLock);
    if (kr != KERN_SUCCESS) {
        YCLog(@"start: mach_msg %d", kr);
        return out;
    }
    out.status = r.simple.w[0];
    out.stream = r.simple.w[1];
    out.width = r.simple.w[2];
    out.height = r.simple.w[3];
    out.fpsMilli = r.simple.w[4];
    out.pixelFormat = r.simple.w[5];
    YCTrace(@"start %ux%u %.2f fps '%c%c%c%c': status %u, stream %u, %ux%u at %.3f fps", width, height, fps,
            (char)(pixelFormat >> 24), (char)(pixelFormat >> 16), (char)(pixelFormat >> 8), (char)pixelFormat,
            out.status, out.stream, out.width, out.height, out.fpsMilli / 1000.0);
    return out;
}

void YCHostStop(uint32_t stream) {
    pthread_mutex_lock(&gCallLock);
    YCSimpleMessage m;
    uint32_t words[1] = {stream};
    YCFillSimple(&m, words, 1);
    YCReceiveBuffer r;
    kern_return_t kr = YCCall(&m.header, (mach_msg_size_t)(sizeof(mach_msg_header_t) + 8 + 4), YCReqStop, &r);
    pthread_mutex_unlock(&gCallLock);
    YCTrace(@"stop stream %u: %d/%u", stream, kr, kr == KERN_SUCCESS ? r.simple.w[0] : 0);
}

void YCHostRelease(uint32_t stream, uint32_t slot, uint64_t sequence) {
    mach_port_t service = YCServicePort();
    if (service == MACH_PORT_NULL) return;
    YCSimpleMessage m;
    uint32_t words[4] = {stream, slot, (uint32_t)sequence, (uint32_t)(sequence >> 32)};
    YCFillSimple(&m, words, 4);
    m.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    m.header.msgh_size = (mach_msg_size_t)(sizeof(mach_msg_header_t) + 8 + 16);
    m.header.msgh_remote_port = service;
    m.header.msgh_id = YC_BASE + YCReqRelease;
    kern_return_t kr = mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, m.header.msgh_size, 0, MACH_PORT_NULL, 2000,
                                MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) YCLog(@"release of frame %llu failed: %d", sequence, kr);
}

static void *YCFrameThread(void *arg) {
    (void)arg;
    pthread_setname_np("dev.ycode.camera.frames");
    for (;;) {
        @autoreleasepool {
            YCReceiveBuffer b;
            kern_return_t kr = mach_msg(&b.simple.header, MACH_RCV_MSG, 0, sizeof(b), gFrames, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
            if (kr != KERN_SUCCESS) {
                YCLog(@"frame receive failed: %d", kr);
                usleep(100000);
                continue;
            }
            const uint32_t *w = b.simple.w;
            if (b.simple.header.msgh_id == YC_BASE + YCToFrame) {
                YCFrameInfo f = {
                    .stream = w[0], .sequence = (uint64_t)w[1] | (uint64_t)w[2] << 32, .surfaceID = w[3], .slot = w[4],
                    .seed = w[5], .width = w[6], .height = w[7], .pixelFormat = w[8], .dropped = w[9], .flags = w[10],
                    .presentationTicks = (uint64_t)w[11] | (uint64_t)w[12] << 32,
                    .durationTicks = (uint64_t)w[13] | (uint64_t)w[14] << 32,
                };
                void (^handler)(YCFrameInfo) = YCFrameHandler;
                if (handler) handler(f);
                else YCHostRelease(f.stream, f.slot, f.sequence);
            } else if (b.simple.header.msgh_id == YC_BASE + YCToEvent) {
                YCTrace(@"event %u for stream %u (%ux%u)", w[1], w[0], w[2], w[3]);
                void (^handler)(uint32_t, uint32_t, uint32_t, uint32_t) = YCEventHandler;
                if (handler) handler(w[0], w[1], w[2], w[3]);
            }
            mach_msg_destroy(&b.simple.header);
        }
    }
    return NULL;
}

// MARK: - Pixel buffers

/// Sends the frame back to the host when its pixel buffer is freed.
@interface YCFrameToken : NSObject
@property(nonatomic) uint32_t stream, slot;
@property(nonatomic) uint64_t sequence;
@end

@implementation YCFrameToken
- (void)dealloc {
    YCHostRelease(_stream, _slot, _sequence);
}
@end

static NSMutableDictionary<NSNumber *, id> *gSurfaces;
static pthread_mutex_t gSurfaceLock = PTHREAD_MUTEX_INITIALIZER;

void YCForgetSurfaces(void) {
    pthread_mutex_lock(&gSurfaceLock);
    [gSurfaces removeAllObjects];
    pthread_mutex_unlock(&gSurfaceLock);
}

static IOSurfaceRef YCSurface(uint32_t surfaceID) {
    pthread_mutex_lock(&gSurfaceLock);
    if (!gSurfaces) gSurfaces = [NSMutableDictionary dictionary];
    id s = gSurfaces[@(surfaceID)];
    if (!s) {
        IOSurfaceRef found = IOSurfaceLookup(surfaceID);
        if (found) {
            s = (__bridge_transfer id)found;
            gSurfaces[@(surfaceID)] = s;
        }
    }
    pthread_mutex_unlock(&gSurfaceLock);
    return (__bridge IOSurfaceRef)s;
}

CVPixelBufferRef YCCreatePixelBuffer(YCFrameInfo frame) {
    IOSurfaceRef surface = YCSurface(frame.surfaceID);
    if (!surface) {
        YCLog(@"frame %llu: no IOSurface %u", frame.sequence, frame.surfaceID);
        return NULL;
    }
    CVPixelBufferRef pb = NULL;
    CVReturn rc = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &pb);
    if (rc != kCVReturnSuccess || !pb) {
        YCLog(@"frame %llu: CVPixelBufferCreateWithIOSurface %d", frame.sequence, rc);
        return NULL;
    }
    // The host's conversion (camera-host.md §4): BT.601 Y'CbCr; sRGB-like primaries and transfer.
    if (frame.pixelFormat != kCVPixelFormatType_32BGRA) {
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
    }
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    YCFrameToken *token = [YCFrameToken new];
    token.stream = frame.stream;
    token.slot = frame.slot;
    token.sequence = frame.sequence;
    CVBufferSetAttachment(pb, CFSTR("dev.ycode.camera.frame"), (__bridge CFTypeRef)token, kCVAttachmentMode_ShouldNotPropagate);
    return pb;
}
