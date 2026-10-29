// The capture layer (camera.md "Ycode implementation"): makes the public
// capture API of AVFoundation work in an app process for the camera the
// host announces.
//
// - Discovery: AVCaptureDevice's class methods and AVCaptureDeviceDiscovery-
//   Session's `devices` add one device, an instance of YcodeCaptureDevice, a
//   subclass of AVCaptureDevice made at run time, whose public properties
//   answer from the host's device list. The microphone stays as the
//   runtime reports it.
// - Inputs: AVCaptureDeviceInput's initializers give a YcodeCaptureDeviceInput
//   for that device, after the authorization check the public API documents
//   (the guest's tccd answers it; camera.md §6).
// - Sessions: every AVCaptureSession's public methods are answered by this
//   layer (inputs, outputs, connections, presets, configuration, running,
//   interruption, notifications). A running session with the camera has a
//   host stream; its frames go to video data outputs as CMSampleBuffers
//   wrapping CVPixelBuffers backed by the host's IOSurfaces, to preview
//   layers, and to photo outputs.
//
// Only public classes, selectors, functions and constants are used.

#import "YCCamera.h"
#include <stdatomic.h>
#include <dlfcn.h>

id YCCreateInstance(Class cls) NS_RETURNS_RETAINED;
void YCUsePlainDealloc(Class cls);
void YCUseNSObjectBasics(Class cls);

// MARK: - Constants (AVFoundation's exported strings, read with dlsym)

static NSString *YCConst(const char *name, NSString *fallback) {
    NSString *__unsafe_unretained *p = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, name);
    return (p && *p) ? *p : fallback;
}

static NSString *kVideo, *kAudio, *kErrorDomain, *kErrorKey, *kReasonKey;
static NSString *kStartNote, *kStopNote, *kRuntimeErrorNote, *kInterruptedNote, *kInterruptionEndedNote;
static NSString *kConnectedNote, *kDisconnectedNote;
static NSString *kGravityAspect, *kGravityFill, *kGravityResize;
static NSString *kPresetHigh, *kPresetMedium, *kPresetLow, *kPresetPhoto, *kPresetInputPriority;
static NSString *kPreset352, *kPreset640, *kPreset1280, *kPreset1920, *kPreset3840, *kPresetIFrame960, *kPresetIFrame1280;
static NSString *kTypeWide, *kTypeExternal, *kCodecJPEG;

static void YCLoadConstants(void) {
    kVideo = YCConst("AVMediaTypeVideo", @"vide");
    kAudio = YCConst("AVMediaTypeAudio", @"soun");
    kErrorDomain = YCConst("AVFoundationErrorDomain", @"AVFoundationErrorDomain");
    kErrorKey = YCConst("AVCaptureSessionErrorKey", @"AVCaptureSessionErrorKey");
    kReasonKey = YCConst("AVCaptureSessionInterruptionReasonKey", @"AVCaptureSessionInterruptionReasonKey");
    kStartNote = YCConst("AVCaptureSessionDidStartRunningNotification", @"AVCaptureSessionDidStartRunningNotification");
    kStopNote = YCConst("AVCaptureSessionDidStopRunningNotification", @"AVCaptureSessionDidStopRunningNotification");
    kRuntimeErrorNote = YCConst("AVCaptureSessionRuntimeErrorNotification", @"AVCaptureSessionRuntimeErrorNotification");
    kInterruptedNote = YCConst("AVCaptureSessionWasInterruptedNotification", @"AVCaptureSessionWasInterruptedNotification");
    kInterruptionEndedNote = YCConst("AVCaptureSessionInterruptionEndedNotification", @"AVCaptureSessionInterruptionEndedNotification");
    kConnectedNote = YCConst("AVCaptureDeviceWasConnectedNotification", @"AVCaptureDeviceWasConnectedNotification");
    kDisconnectedNote = YCConst("AVCaptureDeviceWasDisconnectedNotification", @"AVCaptureDeviceWasDisconnectedNotification");
    kGravityAspect = YCConst("AVLayerVideoGravityResizeAspect", @"AVLayerVideoGravityResizeAspect");
    kGravityFill = YCConst("AVLayerVideoGravityResizeAspectFill", @"AVLayerVideoGravityResizeAspectFill");
    kGravityResize = YCConst("AVLayerVideoGravityResize", @"AVLayerVideoGravityResize");
    kPresetHigh = YCConst("AVCaptureSessionPresetHigh", @"AVCaptureSessionPresetHigh");
    kPresetMedium = YCConst("AVCaptureSessionPresetMedium", @"AVCaptureSessionPresetMedium");
    kPresetLow = YCConst("AVCaptureSessionPresetLow", @"AVCaptureSessionPresetLow");
    kPresetPhoto = YCConst("AVCaptureSessionPresetPhoto", @"AVCaptureSessionPresetPhoto");
    kPresetInputPriority = YCConst("AVCaptureSessionPresetInputPriority", @"AVCaptureSessionPresetInputPriority");
    kPreset352 = YCConst("AVCaptureSessionPreset352x288", @"AVCaptureSessionPreset352x288");
    kPreset640 = YCConst("AVCaptureSessionPreset640x480", @"AVCaptureSessionPreset640x480");
    kPreset1280 = YCConst("AVCaptureSessionPreset1280x720", @"AVCaptureSessionPreset1280x720");
    kPreset1920 = YCConst("AVCaptureSessionPreset1920x1080", @"AVCaptureSessionPreset1920x1080");
    kPreset3840 = YCConst("AVCaptureSessionPreset3840x2160", @"AVCaptureSessionPreset3840x2160");
    kPresetIFrame960 = YCConst("AVCaptureSessionPresetiFrame960x540", @"AVCaptureSessionPresetiFrame960x540");
    kPresetIFrame1280 = YCConst("AVCaptureSessionPresetiFrame1280x720", @"AVCaptureSessionPresetiFrame1280x720");
    kTypeWide = YCConst("AVCaptureDeviceTypeBuiltInWideAngleCamera", @"AVCaptureDeviceTypeBuiltInWideAngleCamera");
    kTypeExternal = YCConst("AVCaptureDeviceTypeExternal", @"AVCaptureDeviceTypeExternal");
    kCodecJPEG = YCConst("AVVideoCodecTypeJPEG", @"jpeg");
}

// MARK: - Runtime helpers

static char kStateKey;

static id YCState(id object) { return object ? objc_getAssociatedObject(object, &kStateKey) : nil; }
static void YCSetState(id object, id state) { objc_setAssociatedObject(object, &kStateKey, state, OBJC_ASSOCIATION_RETAIN); }

/// Replaces `sel` of `cls` (an inherited method gets its own override);
/// returns the implementation it had, or NULL when `cls` has no such method.
static IMP YCHook(Class cls, SEL sel, id block) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        YCTrace(@"hook: %@ has no -%@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    IMP old = method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) method_setImplementation(m, imp);
    return old;
}

static IMP YCHookC(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP old = method_getImplementation(m);
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) method_setImplementation(m, imp);
    return old;
}

static IMP YCHookClass(Class cls, SEL sel, id block) { return YCHook(object_getClass(cls), sel, block); }

/// An override in a subclass made here, with the superclass's type encoding
/// (skipped when the superclass has no such method on this system).
static void YCOverride(Class sub, SEL sel, id block) {
    Method m = class_getInstanceMethod(class_getSuperclass(sub), sel);
    if (!m) return;
    class_addMethod(sub, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m));
}

static Class YCSubclass(Class base, const char *name) {
    Class c = objc_allocateClassPair(base, name, 0);
    if (!c) return objc_getClass(name);
    YCUsePlainDealloc(c);
    YCUseNSObjectBasics(c);
    return c;
}

static NSError *YCError(NSInteger code, NSString *text, NSString *reason) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = text;
    if (reason) info[NSLocalizedFailureReasonErrorKey] = reason;
    return [NSError errorWithDomain:kErrorDomain code:code userInfo:info];
}

static void YCRaise(NSString *name, NSString *text) { @throw [NSException exceptionWithName:name reason:text userInfo:nil]; }

// MARK: - Classes

static Class AVDevice, AVFormat, AVRange, AVInput, AVPort, AVConnection, AVSession, AVOutput, AVVideoOutput, AVPhotoOutput;
static Class AVPreview, AVDiscovery, AVPhoto, AVResolved, AVPhotoSettings, AVMovieOutput;
static Class cDevice, cFormat, cRange, cInput, cPort, cConnection, cPhoto, cResolved;

static NSRecursiveLock *gLock;
static id gDevice;                 // the one camera (a YcodeCaptureDevice)
static YCCameraInfo *gInfo;

// MARK: - State objects

@interface YCDeviceState : NSObject
@property(nonatomic, copy) NSArray *formats;
@property(nonatomic, strong) id activeFormat;
@property(nonatomic) CMTime minDuration, maxDuration;
@property(nonatomic) NSInteger locks;
@property(nonatomic) BOOL connected, subjectAreaMonitoring;
@property(nonatomic) CGFloat zoom;
@property(nonatomic) NSInteger colorSpace;
@property(nonatomic, weak) id userPreferred;
@end
@implementation YCDeviceState
@end

@interface YCFormatState : NSObject {
@public
    CMVideoFormatDescriptionRef desc;
}
@property(nonatomic) int width, height;
@property(nonatomic) double minFPS, maxFPS;
@property(nonatomic) OSType subtype;
@property(nonatomic, copy) NSArray *ranges;
@end
@implementation YCFormatState
- (void)dealloc {
    if (desc) CFRelease(desc);
}
@end

@interface YCRangeState : NSObject
@property(nonatomic) double minFPS, maxFPS;
@end
@implementation YCRangeState
@end

@interface YCInputState : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic, copy) NSArray *ports;
@end
@implementation YCInputState
@end

@interface YCPortState : NSObject
@property(nonatomic, weak) id input;
@property(nonatomic) BOOL enabled;
@end
@implementation YCPortState
@end

@interface YCConnectionState : NSObject
@property(nonatomic, copy) NSArray *ports;
@property(nonatomic, weak) id output, previewLayer;
@property(nonatomic) BOOL enabled, mirrored, autoMirror;
@property(nonatomic) int angle;
@end
@implementation YCConnectionState
@end

@interface YCSessionState : NSObject
@property(nonatomic, strong) NSMutableArray *inputs, *outputs, *connections;
@property(nonatomic, strong) NSHashTable *previews, *noConnections;
@property(nonatomic, copy) NSString *preset;
@property(nonatomic) BOOL running, interrupted;
@property(nonatomic) NSInteger configDepth;
@property(nonatomic) YCStartReply stream, requested;
@end
@implementation YCSessionState
@end

@interface YCOutputState : NSObject {
@public
    _Atomic int busy;
    CVPixelBufferPoolRef pool;
    int poolW, poolH;
    OSType poolFormat;
}
@property(nonatomic, weak) id session;
@property(nonatomic, weak) id delegate;
@property(nonatomic, strong) dispatch_queue_t queue;
@end
@implementation YCOutputState
- (void)dealloc {
    if (pool) CVPixelBufferPoolRelease(pool);
}
@end

@interface YCPreviewState : NSObject {
@public
    _Atomic int busy;
}
@property(nonatomic, weak) id session;
@property(nonatomic, strong) id connection;
@property(nonatomic, strong) CALayer *content;
@property(nonatomic) BOOL noConnection;
@end
@implementation YCPreviewState
@end

@interface YCPhotoState : NSObject {
@public
    CGImageRef image;
    CVPixelBufferRef pixelBuffer;
}
@property(nonatomic, strong) NSData *data;
@property(nonatomic, strong) id resolved;
@property(nonatomic) CMTime timestamp;
@end
@implementation YCPhotoState
- (void)dealloc {
    if (image) CGImageRelease(image);
    if (pixelBuffer) CVPixelBufferRelease(pixelBuffer);
}
@end

@interface YCResolvedState : NSObject
@property(nonatomic) int64_t uniqueID;
@property(nonatomic) CMVideoDimensions dimensions;
@end
@implementation YCResolvedState
@end

@interface YCPhotoRequest : NSObject
@property(nonatomic, strong) id settings, output, connection, resolved;
@property(nonatomic, weak) id delegate;
@end
@implementation YCPhotoRequest
@end

static YCDeviceState *gDS;

static YCSessionState *SS(id session) {
    YCSessionState *s = YCState(session);
    if (!s && session) {
        s = [YCSessionState new];
        s.inputs = [NSMutableArray array];
        s.outputs = [NSMutableArray array];
        s.connections = [NSMutableArray array];
        s.previews = [NSHashTable weakObjectsHashTable];
        s.noConnections = [NSHashTable weakObjectsHashTable];
        s.preset = kPresetHigh;
        YCSetState(session, s);
    }
    return s;
}

static YCOutputState *OS(id output) {
    YCOutputState *s = YCState(output);
    if (!s && output) {
        s = [YCOutputState new];
        YCSetState(output, s);
    }
    return s;
}

static YCPreviewState *PS(id layer) {
    YCPreviewState *s = YCState(layer);
    if (!s && layer) {
        s = [YCPreviewState new];
        YCSetState(layer, s);
    }
    return s;
}

// MARK: - Formats

static id YCMakeRange(double minFPS, double maxFPS) {
    id r = YCCreateInstance(cRange);
    YCRangeState *s = [YCRangeState new];
    s.minFPS = minFPS;
    s.maxFPS = maxFPS;
    YCSetState(r, s);
    return r;
}

static CMTime YCDuration(double fps) {
    if (fps <= 0) return kCMTimeInvalid;
    double r = round(fps);
    return fabs(fps - r) < 1e-6 ? CMTimeMake(1, (int32_t)r) : CMTimeMake(1000, (int32_t)llround(fps * 1000));
}

static id YCMakeFormat(int w, int h, double minFPS, double maxFPS, OSType subtype) {
    id f = YCCreateInstance(cFormat);
    YCFormatState *s = [YCFormatState new];
    s.width = w;
    s.height = h;
    s.minFPS = minFPS;
    s.maxFPS = maxFPS;
    s.subtype = subtype;
    CMVideoFormatDescriptionCreate(kCFAllocatorDefault, subtype, w, h, NULL, &s->desc);
    s.ranges = @[YCMakeRange(minFPS, maxFPS)];
    YCSetState(f, s);
    return f;
}

static YCFormatState *FS(id format) { return [YCState(format) isKindOfClass:YCFormatState.class] ? YCState(format) : nil; }

/// The device's format for a size: exact, else the smallest that covers it,
/// else the largest; the `subtype` variant.
static id YCBestFormat(int w, int h, OSType subtype) {
    id exact = nil, cover = nil, largest = nil;
    for (id f in gDS.formats) {
        YCFormatState *s = FS(f);
        if (s.subtype != subtype) continue;
        if (s.width == w && s.height == h) exact = f;
        if (!cover && s.width >= w && s.height >= h) cover = f;
        largest = f;
    }
    return exact ?: cover ?: largest;
}

/// A preset's nominal size (camera.md "Ycode implementation": the host
/// camera has the sizes it has; the nearest format is used).
static BOOL YCPresetSize(NSString *preset, int *w, int *h) {
    struct { NSString *__unsafe_unretained p; int w, h; } table[] = {
        {kPresetHigh, 1920, 1080}, {kPresetMedium, 480, 360}, {kPresetLow, 192, 144}, {kPresetPhoto, 0, 0},
        {kPreset352, 352, 288}, {kPreset640, 640, 480}, {kPreset1280, 1280, 720}, {kPreset1920, 1920, 1080},
        {kPreset3840, 3840, 2160}, {kPresetIFrame960, 960, 540}, {kPresetIFrame1280, 1280, 720},
    };
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        if (![preset isEqualToString:table[i].p]) continue;
        *w = table[i].w;
        *h = table[i].h;
        if (table[i].p == kPresetPhoto) {
            // The largest 4:3 size, else the largest.
            for (id f in gDS.formats) {
                YCFormatState *s = FS(f);
                if (s.width * 3 == s.height * 4 && s.width * s.height >= *w * *h) {
                    *w = s.width;
                    *h = s.height;
                }
            }
            if (*w == 0) {
                YCFormatState *s = FS(gDS.formats.lastObject);
                *w = s.width;
                *h = s.height;
            }
        }
        if (table[i].p == kPresetHigh) {
            // The largest 16:9 size up to 1920x1080.
            int bw = 0, bh = 0;
            for (id f in gDS.formats) {
                YCFormatState *s = FS(f);
                if (s.width * 9 == s.height * 16 && s.width <= 1920 && s.width > bw) { bw = s.width; bh = s.height; }
            }
            if (bw) { *w = bw; *h = bh; }
        }
        return YES;
    }
    return NO;
}

static CMTime YCDefaultMinDuration(id format) {
    YCFormatState *s = FS(format);
    return YCDuration(MIN(30.0, s.maxFPS > 0 ? s.maxFPS : 30.0));
}

/// Every session whose inputs include the camera.
static NSArray *YCSessionsWithCamera(void);
static void YCReconfigure(id session);

static void YCSetActiveFormat(id format, BOOL fromApp) {
    if (!format || format == gDS.activeFormat) return;
    YCTrace(@"active format -> %@ (%s)", format, fromApp ? "app" : "preset");
    [gDevice willChangeValueForKey:@"activeFormat"];
    gDS.activeFormat = format;
    gDS.minDuration = YCDefaultMinDuration(format);
    gDS.maxDuration = gDS.minDuration;
    [gDevice didChangeValueForKey:@"activeFormat"];
    for (id session in YCSessionsWithCamera()) {
        YCSessionState *ss = SS(session);
        if (fromApp && ![ss.preset isEqualToString:kPresetInputPriority]) {
            YCTrace(@"session %p: preset -> input priority", session);
            [session willChangeValueForKey:@"sessionPreset"];
            ss.preset = kPresetInputPriority;
            [session didChangeValueForKey:@"sessionPreset"];
        }
        YCReconfigure(session);
    }
}

// MARK: - The device (YcodeCaptureDevice)

static BOOL YCIsVideo(NSString *mediaType) { return [mediaType isEqualToString:kVideo]; }

static NSString *YCDeviceTypeValue(void) {
    NSString *v = YCConst(gInfo.deviceType.UTF8String, nil);
    return v ?: gInfo.deviceType;
}

static void YCBuildDeviceClass(void) {
    Class c = cDevice;
    YCOverride(c, @selector(uniqueID), ^NSString *(id self) { return gInfo.uniqueID; });
    YCOverride(c, @selector(modelID), ^NSString *(id self) { return gInfo.modelID; });
    YCOverride(c, @selector(localizedName), ^NSString *(id self) { return gInfo.localizedName; });
    YCOverride(c, @selector(manufacturer), ^NSString *(id self) { return gInfo.manufacturer; });
    YCOverride(c, @selector(deviceType), ^NSString *(id self) { return YCDeviceTypeValue(); });
    YCOverride(c, @selector(position), ^AVCaptureDevicePosition(id self) { return (AVCaptureDevicePosition)gInfo.position; });
    YCOverride(c, @selector(hasMediaType:), ^BOOL(id self, NSString *t) { return YCIsVideo(t); });
    YCOverride(c, @selector(isConnected), ^BOOL(id self) { return gDS.connected; });
    YCOverride(c, @selector(isSuspended), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isInUseByAnotherApplication), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(formats), ^NSArray *(id self) { return gDS.formats; });
    YCOverride(c, @selector(activeFormat), ^id(id self) { return gDS.activeFormat; });
    YCOverride(c, @selector(setActiveFormat:), ^(id self, id format) {
        if (gDS.locks <= 0) YCRaise(NSGenericException, @"-[AVCaptureDevice setActiveFormat:] - the receiver must be locked for configuration with lockForConfiguration:");
        if (![gDS.formats containsObject:format]) YCRaise(NSInvalidArgumentException, @"-[AVCaptureDevice setActiveFormat:] - the format is not one of the device's formats");
        [gLock lock];
        YCSetActiveFormat(format, YES);
        [gLock unlock];
    });
    YCOverride(c, @selector(activeVideoMinFrameDuration), ^CMTime(id self) { return gDS.minDuration; });
    YCOverride(c, @selector(activeVideoMaxFrameDuration), ^CMTime(id self) { return gDS.maxDuration; });
    void (^setDuration)(id, CMTime, BOOL) = ^(id self, CMTime d, BOOL isMin) {
        if (gDS.locks <= 0) YCRaise(NSGenericException, @"-[AVCaptureDevice setActiveVideoMinFrameDuration:] - the receiver must be locked for configuration");
        YCFormatState *s = FS(gDS.activeFormat);
        CMTime value = d;
        if (!CMTIME_IS_VALID(d)) value = YCDefaultMinDuration(gDS.activeFormat);
        double seconds = CMTimeGetSeconds(value);
        if (CMTIME_IS_VALID(d) && (seconds < 1.0 / s.maxFPS - 1e-6 || seconds > 1.0 / s.minFPS + 1e-6))
            YCRaise(NSInvalidArgumentException, @"the frame duration is outside the active format's videoSupportedFrameRateRanges");
        NSString *key = isMin ? @"activeVideoMinFrameDuration" : @"activeVideoMaxFrameDuration";
        [self willChangeValueForKey:key];
        if (isMin) gDS.minDuration = value; else gDS.maxDuration = value;
        [self didChangeValueForKey:key];
        [gLock lock];
        if (isMin) for (id session in YCSessionsWithCamera()) YCReconfigure(session);
        [gLock unlock];
    };
    YCOverride(c, @selector(setActiveVideoMinFrameDuration:), ^(id self, CMTime d) { setDuration(self, d, YES); });
    YCOverride(c, @selector(setActiveVideoMaxFrameDuration:), ^(id self, CMTime d) { setDuration(self, d, NO); });
    YCOverride(c, @selector(lockForConfiguration:), ^BOOL(id self, NSError *__autoreleasing *error) {
        gDS.locks++;
        return YES;
    });
    YCOverride(c, @selector(unlockForConfiguration), ^(id self) { if (gDS.locks > 0) gDS.locks--; });
    YCOverride(c, @selector(supportsAVCaptureSessionPreset:), ^BOOL(id self, NSString *preset) {
        if ([preset isEqualToString:kPresetInputPriority]) return YES;
        int w = 0, h = 0;
        if (!YCPresetSize(preset, &w, &h)) return NO;
        if ([preset isEqualToString:kPresetHigh] || [preset isEqualToString:kPresetMedium] || [preset isEqualToString:kPresetLow]
            || [preset isEqualToString:kPresetPhoto]) return YES;
        for (id f in gDS.formats) if (FS(f).width == w && FS(f).height == h) return YES;
        return NO;
    });
    YCOverride(c, @selector(isVirtualDevice), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(constituentDevices), ^NSArray *(id self) { return @[]; });
    YCOverride(c, @selector(linkedDevices), ^NSArray *(id self) { return @[]; });
    // A webcam: no torch or flash, fixed focus, continuous automatic exposure and white balance.
    YCOverride(c, @selector(hasTorch), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(hasFlash), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isTorchAvailable), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isTorchActive), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isFlashAvailable), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(torchMode), ^AVCaptureTorchMode(id self) { return AVCaptureTorchModeOff; });
    YCOverride(c, @selector(torchLevel), ^float(id self) { return 0; });
    YCOverride(c, @selector(isTorchModeSupported:), ^BOOL(id self, AVCaptureTorchMode m) { return m == AVCaptureTorchModeOff; });
    YCOverride(c, @selector(focusMode), ^AVCaptureFocusMode(id self) { return AVCaptureFocusModeLocked; });
    YCOverride(c, @selector(isFocusModeSupported:), ^BOOL(id self, AVCaptureFocusMode m) { return m == AVCaptureFocusModeLocked; });
    YCOverride(c, @selector(isFocusPointOfInterestSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(focusPointOfInterest), ^CGPoint(id self) { return CGPointMake(0.5, 0.5); });
    YCOverride(c, @selector(isAdjustingFocus), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isAutoFocusRangeRestrictionSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isSmoothAutoFocusSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isLockingFocusWithCustomLensPositionSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(exposureMode), ^AVCaptureExposureMode(id self) { return AVCaptureExposureModeContinuousAutoExposure; });
    YCOverride(c, @selector(isExposureModeSupported:), ^BOOL(id self, AVCaptureExposureMode m) { return m == AVCaptureExposureModeContinuousAutoExposure; });
    YCOverride(c, @selector(isExposurePointOfInterestSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(exposurePointOfInterest), ^CGPoint(id self) { return CGPointMake(0.5, 0.5); });
    YCOverride(c, @selector(isAdjustingExposure), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(exposureTargetBias), ^float(id self) { return 0; });
    YCOverride(c, @selector(minExposureTargetBias), ^float(id self) { return 0; });
    YCOverride(c, @selector(maxExposureTargetBias), ^float(id self) { return 0; });
    YCOverride(c, @selector(whiteBalanceMode), ^AVCaptureWhiteBalanceMode(id self) { return AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance; });
    YCOverride(c, @selector(isWhiteBalanceModeSupported:), ^BOOL(id self, AVCaptureWhiteBalanceMode m) {
        return m == AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
    });
    YCOverride(c, @selector(isAdjustingWhiteBalance), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isLockingWhiteBalanceWithCustomDeviceGainsSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isLowLightBoostSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isLowLightBoostEnabled), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(videoZoomFactor), ^CGFloat(id self) { return 1; });
    YCOverride(c, @selector(setVideoZoomFactor:), ^(id self, CGFloat z) {
        if (z < 1 || z > 1) YCRaise(NSRangeException, @"videoZoomFactor must be between minAvailableVideoZoomFactor and maxAvailableVideoZoomFactor (1)");
    });
    YCOverride(c, @selector(minAvailableVideoZoomFactor), ^CGFloat(id self) { return 1; });
    YCOverride(c, @selector(maxAvailableVideoZoomFactor), ^CGFloat(id self) { return 1; });
    YCOverride(c, @selector(isRampingVideoZoom), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isSubjectAreaChangeMonitoringEnabled), ^BOOL(id self) { return gDS.subjectAreaMonitoring; });
    YCOverride(c, @selector(setSubjectAreaChangeMonitoringEnabled:), ^(id self, BOOL on) { gDS.subjectAreaMonitoring = on; });
    YCOverride(c, @selector(activeColorSpace), ^AVCaptureColorSpace(id self) { return (AVCaptureColorSpace)gDS.colorSpace; });
    YCOverride(c, @selector(setActiveColorSpace:), ^(id self, AVCaptureColorSpace s) { gDS.colorSpace = s; });
    YCOverride(c, @selector(isVideoHDREnabled), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(automaticallyAdjustsVideoHDREnabled), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(activeDepthDataFormat), ^id(id self) { return nil; });
    YCOverride(c, @selector(isCenterStageActive), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isPortraitEffectActive), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isGeometricDistortionCorrectionSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isEqual:), ^BOOL(id self, id other) { return self == other; });
    YCOverride(c, @selector(hash), ^NSUInteger(id self) { return gInfo.uniqueID.hash; });
    YCOverride(c, @selector(description), ^NSString *(id self) {
        return [NSString stringWithFormat:@"<YcodeCaptureDevice %p[%@][%@]>", self, gInfo.uniqueID, gInfo.localizedName];
    });
}

static void YCBuildFormatClasses(void) {
    Class c = cFormat;
    YCOverride(c, @selector(mediaType), ^NSString *(id self) { return kVideo; });
    YCOverride(c, @selector(formatDescription), ^CMFormatDescriptionRef(id self) { return FS(self)->desc; });
    YCOverride(c, @selector(videoSupportedFrameRateRanges), ^NSArray *(id self) { return FS(self).ranges; });
    YCOverride(c, @selector(videoFieldOfView), ^float(id self) { return 70.0f; });
    YCOverride(c, @selector(isVideoBinned), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isVideoStabilizationModeSupported:), ^BOOL(id self, AVCaptureVideoStabilizationMode m) {
        return m == AVCaptureVideoStabilizationModeOff;
    });
    YCOverride(c, @selector(isVideoHDRSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(videoMaxZoomFactor), ^CGFloat(id self) { return 1; });
    YCOverride(c, @selector(videoZoomFactorUpscaleThreshold), ^CGFloat(id self) { return 1; });
    YCOverride(c, @selector(minExposureDuration), ^CMTime(id self) { return CMTimeMake(1, 10000); });
    YCOverride(c, @selector(maxExposureDuration), ^CMTime(id self) { return YCDuration(FS(self).minFPS); });
    YCOverride(c, @selector(minISO), ^float(id self) { return 100; });
    YCOverride(c, @selector(maxISO), ^float(id self) { return 800; });
    YCOverride(c, @selector(highResolutionStillImageDimensions), ^CMVideoDimensions(id self) {
        return (CMVideoDimensions){FS(self).width, FS(self).height};
    });
    YCOverride(c, @selector(supportedMaxPhotoDimensions), ^NSArray *(id self) {
        CMVideoDimensions d = {FS(self).width, FS(self).height};
        return @[[NSValue valueWithBytes:&d objCType:@encode(CMVideoDimensions)]];
    });
    YCOverride(c, @selector(isHighestPhotoQualitySupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isMultiCamSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(autoFocusSystem), ^AVCaptureAutoFocusSystem(id self) { return AVCaptureAutoFocusSystemNone; });
    YCOverride(c, @selector(supportedColorSpaces), ^NSArray *(id self) { return @[@(AVCaptureColorSpace_sRGB)]; });
    YCOverride(c, @selector(supportedDepthDataFormats), ^NSArray *(id self) { return @[]; });
    YCOverride(c, @selector(isPortraitEffectSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(isCenterStageSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(description), ^NSString *(id self) {
        YCFormatState *s = FS(self);
        OSType t = s.subtype;
        return [NSString stringWithFormat:@"<YcodeCaptureDeviceFormat %p 'vide'/'%c%c%c%c' %4dx%4d, { %.0f-%.0f fps}>", self,
                (char)(t >> 24), (char)(t >> 16), (char)(t >> 8), (char)t, s.width, s.height, s.minFPS, s.maxFPS];
    });
    Class r = cRange;
    YCOverride(r, @selector(minFrameRate), ^Float64(id self) { return ((YCRangeState *)YCState(self)).minFPS; });
    YCOverride(r, @selector(maxFrameRate), ^Float64(id self) { return ((YCRangeState *)YCState(self)).maxFPS; });
    YCOverride(r, @selector(minFrameDuration), ^CMTime(id self) { return YCDuration(((YCRangeState *)YCState(self)).maxFPS); });
    YCOverride(r, @selector(maxFrameDuration), ^CMTime(id self) { return YCDuration(((YCRangeState *)YCState(self)).minFPS); });
    YCOverride(r, @selector(description), ^NSString *(id self) {
        YCRangeState *s = YCState(self);
        return [NSString stringWithFormat:@"<YcodeFrameRateRange %p: %.0f - %.0f>", self, s.minFPS, s.maxFPS];
    });
}

static void YCMakeDevice(YCCameraInfo *info) {
    gInfo = info;
    gDS = [YCDeviceState new];
    gDS.connected = YES;
    gDS.zoom = 1;
    NSMutableArray *formats = [NSMutableArray array];
    for (NSDictionary *d in info.formats) {
        int w = [d[@"width"] intValue], h = [d[@"height"] intValue];
        double lo = [d[@"minFrameRate"] doubleValue], hi = [d[@"maxFrameRate"] doubleValue];
        if (w <= 0 || h <= 0) continue;
        // As on a device: a video-range and a full-range format per size.
        [formats addObject:YCMakeFormat(w, h, lo, hi, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)];
        [formats addObject:YCMakeFormat(w, h, lo, hi, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)];
    }
    gDS.formats = formats;
    gDevice = YCCreateInstance(cDevice);
    int w = 0, h = 0;
    YCPresetSize(kPresetHigh, &w, &h);
    gDS.activeFormat = YCBestFormat(w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    gDS.minDuration = YCDefaultMinDuration(gDS.activeFormat);
    gDS.maxDuration = gDS.minDuration;
    YCTrace(@"device %@ (%@, %@, position %ld): %lu formats, active %@", info.localizedName, info.uniqueID, info.deviceType,
            (long)info.position, (unsigned long)formats.count, gDS.activeFormat);
}

// MARK: - Discovery (AVCaptureDevice class methods, discovery sessions)

static BOOL YCMatchesPosition(AVCaptureDevicePosition p) { return p == AVCaptureDevicePositionUnspecified || p == gInfo.position; }

static BOOL YCMatchesType(NSString *type) { return [type isEqualToString:YCDeviceTypeValue()]; }

static char kDiscoveryKey;

/// Debug: which image called a class-method hook (YCODE_CAMERA_DEBUG).
static void YCTraceCaller(const char *what, void *ra) {
    if (!YCDebug) return;
    Dl_info info;
    const char *image = ra && dladdr(ra, &info) && info.dli_fname ? info.dli_fname : "?";
    const char *slash = strrchr(image, '/');
    YCLog(@"%s from %s", what, slash ? slash + 1 : image);
}
#define YCCALLER(what) YCTraceCaller(what, __builtin_return_address(0))

/// Whether a call comes from the runtime's own capture frameworks
/// (AVFoundation, AVFCapture). They get the runtime's answers: their
/// objects for a device are private, and a photo output's initializer that
/// was handed the layer's device through a discovery session crashed. Apps,
/// their libraries and the Swift overlay get the camera.
static BOOL YCFromRuntime(void *ra) {
    static _Atomic(uintptr_t) runtimeBases[4];
    static _Atomic(uintptr_t) otherBases[16];
    Dl_info info;
    if (!ra || !dladdr(ra, &info) || !info.dli_fbase) return NO;
    uintptr_t base = (uintptr_t)info.dli_fbase;
    for (int i = 0; i < 4; i++) if (atomic_load(&runtimeBases[i]) == base) return YES;
    for (int i = 0; i < 16; i++) if (atomic_load(&otherBases[i]) == base) return NO;
    const char *f = info.dli_fname ? info.dli_fname : "";
    BOOL runtime = strstr(f, "/AVFCapture.framework/") || strstr(f, "/AVFoundation.framework/");
    _Atomic(uintptr_t) *slots = runtime ? runtimeBases : otherBases;
    int n = runtime ? 4 : 16;
    for (int i = 0; i < n; i++) {
        uintptr_t zero = 0;
        if (atomic_compare_exchange_strong(&slots[i], &zero, base)) break;
    }
    return runtime;
}
#define YCRUNTIME_CALLER() YCFromRuntime(__builtin_return_address(0))

static void YCHookDiscovery(void) {
    static IMP oDefault, oDefaultType, oDevices, oDevicesWith, oWithID, oSystem, oUser, oDiscovery, oDiscoveryDevices;
    oDefault = YCHookClass(AVDevice, @selector(defaultDeviceWithMediaType:), ^id(id self, NSString *mediaType) {
        YCCALLER("+defaultDeviceWithMediaType:");
        if (YCIsVideo(mediaType) && !YCRUNTIME_CALLER()) return gDevice;
        return ((id (*)(id, SEL, id))oDefault)(self, @selector(defaultDeviceWithMediaType:), mediaType);
    });
    oDefaultType = YCHookClass(AVDevice, @selector(defaultDeviceWithDeviceType:mediaType:position:),
                               ^id(id self, NSString *type, NSString *mediaType, AVCaptureDevicePosition position) {
        YCCALLER("+defaultDeviceWithDeviceType:mediaType:position:");
        if (YCMatchesType(type) && (!mediaType || YCIsVideo(mediaType)) && YCMatchesPosition(position) && !YCRUNTIME_CALLER()) return gDevice;
        return ((id (*)(id, SEL, id, id, AVCaptureDevicePosition))oDefaultType)(
            self, @selector(defaultDeviceWithDeviceType:mediaType:position:), type, mediaType, position);
    });
    oDevices = YCHookClass(AVDevice, @selector(devices), ^NSArray *(id self) {
        YCCALLER("+devices");
        NSArray *a = ((id (*)(id, SEL))oDevices)(self, @selector(devices)) ?: @[];
        return YCRUNTIME_CALLER() ? a : [a arrayByAddingObject:gDevice];
    });
    oDevicesWith = YCHookClass(AVDevice, @selector(devicesWithMediaType:), ^NSArray *(id self, NSString *mediaType) {
        YCCALLER("+devicesWithMediaType:");
        NSArray *a = ((id (*)(id, SEL, id))oDevicesWith)(self, @selector(devicesWithMediaType:), mediaType) ?: @[];
        return YCIsVideo(mediaType) && !YCRUNTIME_CALLER() ? [a arrayByAddingObject:gDevice] : a;
    });
    oWithID = YCHookClass(AVDevice, @selector(deviceWithUniqueID:), ^id(id self, NSString *uid) {
        YCCALLER("+deviceWithUniqueID:");
        if ([uid isEqualToString:gInfo.uniqueID] && !YCRUNTIME_CALLER()) return gDevice;
        return ((id (*)(id, SEL, id))oWithID)(self, @selector(deviceWithUniqueID:), uid);
    });
    oSystem = YCHookClass(AVDevice, @selector(systemPreferredCamera), ^id(id self) {
        YCCALLER("+systemPreferredCamera");
        if (YCRUNTIME_CALLER()) return oSystem ? ((id (*)(id, SEL))oSystem)(self, @selector(systemPreferredCamera)) : nil;
        return gDevice;
    });
    oUser = YCHookClass(AVDevice, @selector(userPreferredCamera), ^id(id self) {
        YCCALLER("+userPreferredCamera");
        if (YCRUNTIME_CALLER()) return oUser ? ((id (*)(id, SEL))oUser)(self, @selector(userPreferredCamera)) : nil;
        return gDS.userPreferred ?: gDevice;
    });
    YCHookClass(AVDevice, @selector(setUserPreferredCamera:), ^(id self, id device) { gDS.userPreferred = device; });

    oDiscovery = YCHookClass(AVDiscovery, @selector(discoverySessionWithDeviceTypes:mediaType:position:),
                             ^id(id self, NSArray *types, NSString *mediaType, AVCaptureDevicePosition position) {
        YCCALLER("+discoverySessionWithDeviceTypes:mediaType:position:");
        BOOL runtime = YCRUNTIME_CALLER();
        id s = ((id (*)(id, SEL, id, id, AVCaptureDevicePosition))oDiscovery)(
            self, @selector(discoverySessionWithDeviceTypes:mediaType:position:), types, mediaType, position);
        BOOL match = NO;
        for (NSString *t in types) if (YCMatchesType(t)) match = YES;
        match = match && (!mediaType || YCIsVideo(mediaType)) && YCMatchesPosition(position) && !runtime;
        if (s) objc_setAssociatedObject(s, &kDiscoveryKey, @(match), OBJC_ASSOCIATION_RETAIN);
        return s;
    });
    oDiscoveryDevices = YCHook(AVDiscovery, @selector(devices), ^NSArray *(id self) {
        NSArray *a = ((id (*)(id, SEL))oDiscoveryDevices)(self, @selector(devices)) ?: @[];
        BOOL match = [objc_getAssociatedObject(self, &kDiscoveryKey) boolValue] && !YCRUNTIME_CALLER();
        return match ? [a arrayByAddingObject:gDevice] : a;
    });
}

// MARK: - Inputs and ports

static id YCMakePort(id input) {
    id p = YCCreateInstance(cPort);
    YCPortState *s = [YCPortState new];
    s.input = input;
    s.enabled = YES;
    YCSetState(p, s);
    return p;
}

static BOOL YCIsOurInput(id input) { return input && object_getClass(input) == cInput; }
static BOOL YCIsOurPort(id port) { return port && object_getClass(port) == cPort; }

/// The authorization the public API documents for creating an input
/// (camera.md §7.2 C, step 9): denied or restricted → the "not authorized"
/// error; not determined → the system asks (the guest's tccd shows its
/// alert) and the input is made; frames are withheld until it is granted.
static id YCMakeInput(NSError *__autoreleasing *error) {
    AVAuthorizationStatus status = [AVDevice authorizationStatusForMediaType:kVideo];
    YCTrace(@"input: authorization status %ld", (long)status);
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
        if (error) *error = YCError(AVErrorApplicationIsNotAuthorizedToUseDevice, [NSString stringWithFormat:@"Cannot use %@", gInfo.localizedName],
                                    @"This app is not authorized to use the camera.");
        return nil;
    }
    if (status == AVAuthorizationStatusNotDetermined) {
        [AVDevice requestAccessForMediaType:kVideo completionHandler:^(BOOL granted) {
            YCTrace(@"input: access %@", granted ? @"granted" : @"denied");
        }];
    }
    id input = YCCreateInstance(cInput);
    YCInputState *s = [YCInputState new];
    s.device = gDevice;
    s.ports = @[YCMakePort(input)];
    YCSetState(input, s);
    return input;
}

static IMP oInputInit;
static NS_RETURNS_RETAINED id YCInputInit(__attribute__((ns_consumed)) id self, SEL _cmd, id device, NSError *__autoreleasing *error) {
    if (device && device == gDevice) {
        self = nil;
        return YCMakeInput(error);
    }
    typedef NS_RETURNS_RETAINED id (*Init)(__attribute__((ns_consumed)) id, SEL, id, NSError *__autoreleasing *);
    return ((Init)oInputInit)(self, _cmd, device, error);
}

static void YCBuildInputClasses(void) {
    Class c = cInput;
    YCOverride(c, @selector(device), ^id(id self) { return ((YCInputState *)YCState(self)).device; });
    YCOverride(c, @selector(ports), ^NSArray *(id self) { return ((YCInputState *)YCState(self)).ports; });
    YCOverride(c, @selector(portsWithMediaType:sourceDeviceType:sourceDevicePosition:),
               ^NSArray *(id self, NSString *mediaType, NSString *type, AVCaptureDevicePosition position) {
        if ((mediaType && !YCIsVideo(mediaType)) || (type && !YCMatchesType(type)) || !YCMatchesPosition(position)) return @[];
        return ((YCInputState *)YCState(self)).ports;
    });
    YCOverride(c, @selector(unifiedAutoExposureDefaultsEnabled), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(videoMinFrameDurationOverride), ^CMTime(id self) { return kCMTimeInvalid; });
    YCOverride(c, @selector(isLockedVideoFrameDurationSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(description), ^NSString *(id self) {
        return [NSString stringWithFormat:@"<YcodeCaptureDeviceInput %p: %@>", self, gInfo.localizedName];
    });
    Class p = cPort;
    YCOverride(p, @selector(input), ^id(id self) { return ((YCPortState *)YCState(self)).input; });
    YCOverride(p, @selector(mediaType), ^NSString *(id self) { return kVideo; });
    YCOverride(p, @selector(formatDescription), ^CMFormatDescriptionRef(id self) { return FS(gDS.activeFormat)->desc; });
    YCOverride(p, @selector(isEnabled), ^BOOL(id self) { return ((YCPortState *)YCState(self)).enabled; });
    YCOverride(p, @selector(setEnabled:), ^(id self, BOOL on) { ((YCPortState *)YCState(self)).enabled = on; });
    YCOverride(p, @selector(clock), ^CMClockRef(id self) { return CMClockGetHostTimeClock(); });
    YCOverride(p, @selector(sourceDeviceType), ^NSString *(id self) { return YCDeviceTypeValue(); });
    YCOverride(p, @selector(sourceDevicePosition), ^AVCaptureDevicePosition(id self) { return (AVCaptureDevicePosition)gInfo.position; });
    YCOverride(p, @selector(description), ^NSString *(id self) {
        return [NSString stringWithFormat:@"<YcodeCaptureInputPort %p: vide>", self];
    });
    oInputInit = YCHookC(AVInput, @selector(initWithDevice:error:), (IMP)YCInputInit);
}

// MARK: - Connections

static YCConnectionState *CS(id connection) {
    id s = YCState(connection);
    return [s isKindOfClass:YCConnectionState.class] ? s : nil;
}

static id YCMakeConnection(NSArray *ports, id output, id layer) {
    id c = YCCreateInstance(cConnection);
    YCConnectionState *s = [YCConnectionState new];
    s.ports = ports;
    s.output = output;
    s.previewLayer = layer;
    s.enabled = YES;
    s.autoMirror = YES;
    // A front camera's preview is mirrored, as on a device.
    s.mirrored = layer != nil && gInfo.position == AVCaptureDevicePositionFront;
    s.angle = 0;
    YCSetState(c, s);
    return c;
}

static int YCAngleForOrientation(AVCaptureVideoOrientation o) {
    switch (o) {
    case AVCaptureVideoOrientationPortrait: return 90;
    case AVCaptureVideoOrientationPortraitUpsideDown: return 270;
    case AVCaptureVideoOrientationLandscapeLeft: return 180;
    default: return 0;
    }
}

static void YCBuildConnectionClass(void) {
    Class c = cConnection;
    YCOverride(c, @selector(inputPorts), ^NSArray *(id self) { return CS(self).ports; });
    YCOverride(c, @selector(output), ^id(id self) { return CS(self).output; });
    YCOverride(c, @selector(videoPreviewLayer), ^id(id self) { return CS(self).previewLayer; });
    YCOverride(c, @selector(isEnabled), ^BOOL(id self) { return CS(self).enabled; });
    YCOverride(c, @selector(setEnabled:), ^(id self, BOOL on) {
        [gLock lock];
        CS(self).enabled = on;
        [gLock unlock];
    });
    YCOverride(c, @selector(isActive), ^BOOL(id self) {
        YCConnectionState *s = CS(self);
        BOOL ports = NO;
        for (id p in s.ports) if (((YCPortState *)YCState(p)).enabled) ports = YES;
        return s.enabled && ports;
    });
    YCOverride(c, @selector(audioChannels), ^NSArray *(id self) { return @[]; });
    YCOverride(c, @selector(isVideoMirroringSupported), ^BOOL(id self) { return YES; });
    YCOverride(c, @selector(isVideoMirrored), ^BOOL(id self) { return CS(self).mirrored; });
    YCOverride(c, @selector(setVideoMirrored:), ^(id self, BOOL on) {
        if (CS(self).autoMirror) YCRaise(NSInvalidArgumentException, @"-[AVCaptureConnection setVideoMirrored:] cannot be set while automaticallyAdjustsVideoMirroring is YES");
        CS(self).mirrored = on;
    });
    YCOverride(c, @selector(automaticallyAdjustsVideoMirroring), ^BOOL(id self) { return CS(self).autoMirror; });
    YCOverride(c, @selector(setAutomaticallyAdjustsVideoMirroring:), ^(id self, BOOL on) {
        YCConnectionState *s = CS(self);
        s.autoMirror = on;
        if (on) s.mirrored = s.previewLayer != nil && gInfo.position == AVCaptureDevicePositionFront;
    });
    YCOverride(c, @selector(isVideoRotationAngleSupported:), ^BOOL(id self, CGFloat a) {
        return a == 0 || a == 90 || a == 180 || a == 270;
    });
    YCOverride(c, @selector(videoRotationAngle), ^CGFloat(id self) { return CS(self).angle; });
    YCOverride(c, @selector(setVideoRotationAngle:), ^(id self, CGFloat a) {
        if (!(a == 0 || a == 90 || a == 180 || a == 270)) YCRaise(NSInvalidArgumentException, @"Unsupported videoRotationAngle");
        CS(self).angle = (int)a;
    });
    YCOverride(c, @selector(isVideoOrientationSupported), ^BOOL(id self) { return YES; });
    YCOverride(c, @selector(videoOrientation), ^AVCaptureVideoOrientation(id self) {
        switch (CS(self).angle) {
        case 90: return AVCaptureVideoOrientationPortrait;
        case 180: return AVCaptureVideoOrientationLandscapeLeft;
        case 270: return AVCaptureVideoOrientationPortraitUpsideDown;
        default: return AVCaptureVideoOrientationLandscapeRight;
        }
    });
    YCOverride(c, @selector(setVideoOrientation:), ^(id self, AVCaptureVideoOrientation o) { CS(self).angle = YCAngleForOrientation(o); });
    YCOverride(c, @selector(isVideoStabilizationSupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(preferredVideoStabilizationMode), ^AVCaptureVideoStabilizationMode(id self) { return AVCaptureVideoStabilizationModeOff; });
    YCOverride(c, @selector(setPreferredVideoStabilizationMode:), ^(id self, AVCaptureVideoStabilizationMode m) { (void)m; });
    YCOverride(c, @selector(activeVideoStabilizationMode), ^AVCaptureVideoStabilizationMode(id self) { return AVCaptureVideoStabilizationModeOff; });
    YCOverride(c, @selector(isCameraIntrinsicMatrixDeliverySupported), ^BOOL(id self) { return NO; });
    YCOverride(c, @selector(videoMaxScaleAndCropFactor), ^CGFloat(id self) { return 1; });
    YCOverride(c, @selector(videoScaleAndCropFactor), ^CGFloat(id self) { return 1; });
    YCOverride(c, @selector(description), ^NSString *(id self) {
        YCConnectionState *s = CS(self);
        return [NSString stringWithFormat:@"<YcodeCaptureConnection %p: [vide] -> %@ (enabled %d, angle %d, mirrored %d)>", self,
                s.output ?: s.previewLayer, s.enabled, s.angle, s.mirrored];
    });
}

static IMP oConnInitOutput, oConnInitLayer;
static NS_RETURNS_RETAINED id YCConnectionInitOutput(__attribute__((ns_consumed)) id self, SEL _cmd, NSArray *ports, id output) {
    BOOL ours = NO;
    for (id p in ports) if (YCIsOurPort(p)) ours = YES;
    if (ours) {
        self = nil;
        return YCMakeConnection(ports, output, nil);
    }
    typedef NS_RETURNS_RETAINED id (*Init)(__attribute__((ns_consumed)) id, SEL, id, id);
    return ((Init)oConnInitOutput)(self, _cmd, ports, output);
}
static NS_RETURNS_RETAINED id YCConnectionInitLayer(__attribute__((ns_consumed)) id self, SEL _cmd, id port, id layer) {
    if (YCIsOurPort(port)) {
        self = nil;
        return YCMakeConnection(@[port], nil, layer);
    }
    typedef NS_RETURNS_RETAINED id (*Init)(__attribute__((ns_consumed)) id, SEL, id, id);
    return ((Init)oConnInitLayer)(self, _cmd, port, layer);
}

// MARK: - Sessions

static __weak id gStreamSession;   // the session the host stream serves
static uint32_t gStreamID;
/// Frames delivered on the current stream (photos wait for kPhotoSettleFrames).
static uint64_t gStreamFrames;
/// A still comes from the 10th frame of a stream or later: a webcam's first
/// frames after it opens are dark while its automatic exposure starts.
static const uint64_t kPhotoSettleFrames = 10;
static NSHashTable *gSessions;     // every session that had an input

static NSArray *YCSessionsWithCamera(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (id s in gSessions.allObjects) {
        for (id i in SS(s).inputs) if (YCIsOurInput(i)) { [out addObject:s]; break; }
    }
    return out;
}

static BOOL YCAcceptsVideo(id output) {
    return [output isKindOfClass:AVVideoOutput] || (AVPhotoOutput && [output isKindOfClass:AVPhotoOutput])
        || (AVMovieOutput && [output isKindOfClass:AVMovieOutput]);
}

static id YCConnectionFor(YCSessionState *ss, id output) {
    for (id c in ss.connections) if (CS(c).output == output) return c;
    return nil;
}

/// Connections between the camera's ports and every output and preview
/// layer that has none (inputs and outputs added "with no connections" are left out).
static void YCConnectAll(id session) {
    YCSessionState *ss = SS(session);
    for (id input in ss.inputs) {
        if (!YCIsOurInput(input) || [ss.noConnections containsObject:input]) continue;
        NSArray *ports = ((YCInputState *)YCState(input)).ports;
        for (id output in ss.outputs) {
            if ([ss.noConnections containsObject:output] || !YCAcceptsVideo(output) || YCConnectionFor(ss, output)) continue;
            [ss.connections addObject:YCMakeConnection(ports, output, nil)];
        }
        for (id layer in ss.previews.allObjects) {
            YCPreviewState *ps = PS(layer);
            if (ps.noConnection || ps.connection) continue;
            ps.connection = YCMakeConnection(ports, nil, layer);
            [ss.connections addObject:ps.connection];
        }
    }
}

static void YCDisconnect(id session, id inputOrOutput) {
    YCSessionState *ss = SS(session);
    NSMutableArray *keep = [NSMutableArray array];
    for (id c in ss.connections) {
        YCConnectionState *cs = CS(c);
        BOOL gone = cs.output == inputOrOutput;
        for (id p in cs.ports) if (((YCPortState *)YCState(p)).input == inputOrOutput) gone = YES;
        if (gone) {
            id layer = cs.previewLayer;
            if (layer && PS(layer).connection == c) PS(layer).connection = nil;
        } else {
            [keep addObject:c];
        }
    }
    ss.connections = keep;
}

static BOOL YCSessionUsesCamera(YCSessionState *ss) {
    for (id i in ss.inputs) if (YCIsOurInput(i)) return YES;
    return NO;
}

/// What the host stream must deliver for this session: the active format's
/// size, the frame rate of activeVideoMinFrameDuration, and the first video
/// data output's pixel format (else the format's own; BGRA when only
/// preview layers and photo outputs consume frames).
static void YCStreamConfiguration(YCSessionState *ss, uint32_t *w, uint32_t *h, double *fps, OSType *format) {
    YCFormatState *f = FS(gDS.activeFormat);
    *w = (uint32_t)f.width;
    *h = (uint32_t)f.height;
    double seconds = CMTimeGetSeconds(gDS.minDuration);
    *fps = seconds > 0 ? 1.0 / seconds : 30;
    OSType chosen = 0;
    BOOL anyVideoOutput = NO;
    for (id c in ss.connections) {
        id output = CS(c).output;
        if (!output || ![output isKindOfClass:AVVideoOutput] || !CS(c).enabled) continue;
        anyVideoOutput = YES;
        NSDictionary *settings = [(AVCaptureVideoDataOutput *)output videoSettings];
        NSNumber *pf = settings[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey];
        if (pf && !chosen) chosen = (OSType)pf.unsignedIntValue;
    }
    if (!chosen) chosen = anyVideoOutput ? f.subtype : kCVPixelFormatType_32BGRA;
    if (chosen != kCVPixelFormatType_32BGRA && chosen != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        && chosen != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) chosen = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    *format = chosen;
}

static void YCPost(NSString *name, id object, NSDictionary *info) {
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:object userInfo:info];
}

static void YCPostRuntimeError(id session, NSInteger code, NSString *text) {
    YCPost(kRuntimeErrorNote, session, @{kErrorKey: YCError(code, text, nil)});
}

static void YCSetRunning(id session, BOOL running) {
    YCSessionState *ss = SS(session);
    if (ss.running == running) return;
    [session willChangeValueForKey:@"running"];
    ss.running = running;
    [session didChangeValueForKey:@"running"];
}

static void YCSetInterrupted(id session, BOOL interrupted) {
    YCSessionState *ss = SS(session);
    if (ss.interrupted == interrupted) return;
    [session willChangeValueForKey:@"interrupted"];
    ss.interrupted = interrupted;
    [session didChangeValueForKey:@"interrupted"];
}

/// Starts (or restarts with a new configuration) the host stream for a
/// session. Returns the host's status.
static uint32_t YCStartStream(id session) {
    YCSessionState *ss = SS(session);
    uint32_t w, h;
    double fps;
    OSType format;
    YCStreamConfiguration(ss, &w, &h, &fps, &format);
    id previous = gStreamSession;
    if (previous && previous != session) {
        // One stream per process: the other session is interrupted.
        YCSetInterrupted(previous, YES);
        YCPost(kInterruptedNote, previous, @{kReasonKey: @(AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient)});
    }
    YCForgetSurfaces();
    ss.requested = (YCStartReply){0, 0, w, h, (uint32_t)llround(fps * 1000), format};
    YCStartReply r = YCHostStart(w, h, fps, format);
    if (r.status != YCStatusOK) return r.status;
    ss.stream = r;
    gStreamSession = session;
    gStreamFrames = 0;
    gStreamID = r.stream;
    return YCStatusOK;
}

static void YCStopStream(id session) {
    if (gStreamSession != session || !gStreamID) return;
    uint32_t id = gStreamID;
    gStreamID = 0;
    gStreamSession = nil;
    YCHostStop(id);
}

/// After a configuration change: a running session's stream follows it
/// (restarted only when what it asks the host for changed).
static void YCReconfigure(id session) {
    YCSessionState *ss = SS(session);
    if (ss.configDepth > 0 || !ss.running || ss.interrupted) return;
    if (!YCSessionUsesCamera(ss)) {
        YCStopStream(session);
        return;
    }
    uint32_t w, h;
    double fps;
    OSType format;
    YCStreamConfiguration(ss, &w, &h, &fps, &format);
    YCStartReply q = ss.requested;
    if (gStreamSession == session && gStreamID && q.width == w && q.height == h && q.pixelFormat == format
        && q.fpsMilli == (uint32_t)llround(fps * 1000)) return;
    YCStartStream(session);
}

static void YCApplyPreset(id session) {
    YCSessionState *ss = SS(session);
    if ([ss.preset isEqualToString:kPresetInputPriority] || !YCSessionUsesCamera(ss)) return;
    int w = 0, h = 0;
    if (!YCPresetSize(ss.preset, &w, &h)) return;
    id f = YCBestFormat(w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if (f != gDS.activeFormat) YCSetActiveFormat(f, NO);
}

static NSString *YCDescribe(id object) { return object ? NSStringFromClass([object class]) : @"nil"; }

static void YCHookSessionClass(Class cls) {
    YCHook(cls, @selector(inputs), ^NSArray *(id self) {
        [gLock lock];
        NSArray *a = [SS(self).inputs copy];
        [gLock unlock];
        return a;
    });
    YCHook(cls, @selector(outputs), ^NSArray *(id self) {
        [gLock lock];
        NSArray *a = [SS(self).outputs copy];
        [gLock unlock];
        return a;
    });
    YCHook(cls, @selector(connections), ^NSArray *(id self) {
        [gLock lock];
        NSArray *a = [SS(self).connections copy];
        [gLock unlock];
        return a;
    });
    BOOL (^canAddInput)(id, id) = ^BOOL(id self, id input) {
        if (!input || [SS(self).inputs containsObject:input]) return NO;
        if (YCIsOurInput(input)) return !YCSessionUsesCamera(SS(self));
        return [input isKindOfClass:AVInput];
    };
    YCHook(cls, @selector(canAddInput:), ^BOOL(id self, id input) {
        [gLock lock];
        BOOL ok = canAddInput(self, input);
        [gLock unlock];
        return ok;
    });
    void (^addInput)(id, id, BOOL) = ^(id self, id input, BOOL connect) {
        [gLock lock];
        if (!canAddInput(self, input)) {
            [gLock unlock];
            YCRaise(NSInvalidArgumentException, [NSString stringWithFormat:@"-[AVCaptureSession addInput:] Can't add %@", YCDescribe(input)]);
        }
        YCSessionState *ss = SS(self);
        [ss.inputs addObject:input];
        if (!connect) [ss.noConnections addObject:input];
        [gSessions addObject:self];
        YCApplyPreset(self);
        YCConnectAll(self);
        YCReconfigure(self);
        [gLock unlock];
        YCTrace(@"session %p: input %@ added", self, input);
    };
    YCHook(cls, @selector(addInput:), ^(id self, id input) { addInput(self, input, YES); });
    YCHook(cls, @selector(addInputWithNoConnections:), ^(id self, id input) { addInput(self, input, NO); });
    YCHook(cls, @selector(removeInput:), ^(id self, id input) {
        [gLock lock];
        YCSessionState *ss = SS(self);
        if ([ss.inputs containsObject:input]) {
            [ss.inputs removeObject:input];
            YCDisconnect(self, input);
            YCReconfigure(self);
        }
        [gLock unlock];
    });
    BOOL (^canAddOutput)(id, id) = ^BOOL(id self, id output) {
        if (!output || [SS(self).outputs containsObject:output] || ![output isKindOfClass:AVOutput]) return NO;
        id other = OS(output).session;
        return !other || other == self;
    };
    YCHook(cls, @selector(canAddOutput:), ^BOOL(id self, id output) {
        [gLock lock];
        BOOL ok = canAddOutput(self, output);
        [gLock unlock];
        return ok;
    });
    void (^addOutput)(id, id, BOOL) = ^(id self, id output, BOOL connect) {
        [gLock lock];
        if (!canAddOutput(self, output)) {
            [gLock unlock];
            YCRaise(NSInvalidArgumentException, [NSString stringWithFormat:@"-[AVCaptureSession addOutput:] Can't add %@", YCDescribe(output)]);
        }
        YCSessionState *ss = SS(self);
        [ss.outputs addObject:output];
        OS(output).session = self;
        if (!connect) [ss.noConnections addObject:output];
        [gSessions addObject:self];
        YCConnectAll(self);
        YCReconfigure(self);
        [gLock unlock];
        YCTrace(@"session %p: output %@ added", self, output);
    };
    YCHook(cls, @selector(addOutput:), ^(id self, id output) { addOutput(self, output, YES); });
    YCHook(cls, @selector(addOutputWithNoConnections:), ^(id self, id output) { addOutput(self, output, NO); });
    YCHook(cls, @selector(removeOutput:), ^(id self, id output) {
        [gLock lock];
        YCSessionState *ss = SS(self);
        if ([ss.outputs containsObject:output]) {
            [ss.outputs removeObject:output];
            OS(output).session = nil;
            YCDisconnect(self, output);
            YCReconfigure(self);
        }
        [gLock unlock];
    });
    YCHook(cls, @selector(canAddConnection:), ^BOOL(id self, id connection) {
        return CS(connection) != nil && ![SS(self).connections containsObject:connection];
    });
    YCHook(cls, @selector(addConnection:), ^(id self, id connection) {
        YCConnectionState *cs = CS(connection);
        if (!cs) YCRaise(NSInvalidArgumentException, @"-[AVCaptureSession addConnection:] Can't add a connection that has no camera port");
        [gLock lock];
        YCSessionState *ss = SS(self);
        if (![ss.connections containsObject:connection]) [ss.connections addObject:connection];
        if (cs.previewLayer) {
            PS(cs.previewLayer).connection = connection;
            PS(cs.previewLayer).session = self;
            [ss.previews addObject:cs.previewLayer];
        }
        YCReconfigure(self);
        [gLock unlock];
    });
    YCHook(cls, @selector(removeConnection:), ^(id self, id connection) {
        [gLock lock];
        [SS(self).connections removeObject:connection];
        YCReconfigure(self);
        [gLock unlock];
    });
    YCHook(cls, @selector(sessionPreset), ^NSString *(id self) { return SS(self).preset; });
    BOOL (^canSetPreset)(id, NSString *) = ^BOOL(id self, NSString *preset) {
        if ([preset isEqualToString:kPresetInputPriority]) return YES;
        int w = 0, h = 0;
        if (!YCPresetSize(preset, &w, &h)) return NO;
        if (!gDevice || !YCSessionUsesCamera(SS(self))) return YES;
        return [gDevice supportsAVCaptureSessionPreset:preset];
    };
    YCHook(cls, @selector(canSetSessionPreset:), ^BOOL(id self, NSString *preset) { return canSetPreset(self, preset); });
    YCHook(cls, @selector(setSessionPreset:), ^(id self, NSString *preset) {
        if (!canSetPreset(self, preset)) YCRaise(NSInvalidArgumentException, [NSString stringWithFormat:@"-[AVCaptureSession setSessionPreset:] Can't set session preset %@", preset]);
        [gLock lock];
        SS(self).preset = [preset copy];
        YCApplyPreset(self);
        YCReconfigure(self);
        [gLock unlock];
    });
    YCHook(cls, @selector(beginConfiguration), ^(id self) {
        [gLock lock];
        SS(self).configDepth++;
        [gLock unlock];
    });
    YCHook(cls, @selector(commitConfiguration), ^(id self) {
        [gLock lock];
        YCSessionState *ss = SS(self);
        if (ss.configDepth > 0) ss.configDepth--;
        YCReconfigure(self);
        [gLock unlock];
    });
    YCHook(cls, @selector(isRunning), ^BOOL(id self) { return SS(self).running; });
    YCHook(cls, @selector(isInterrupted), ^BOOL(id self) { return SS(self).interrupted; });
    YCHook(cls, @selector(startRunning), ^(id self) {
        [gLock lock];
        YCSessionState *ss = SS(self);
        if (ss.running) {
            [gLock unlock];
            return;
        }
        [gSessions addObject:self];
        if (YCSessionUsesCamera(ss)) {
            uint32_t status = YCStartStream(self);
            if (status != YCStatusOK) {
                [gLock unlock];
                YCLog(@"session %p: the camera did not start (host status %u)", self, status);
                if (status == YCStatusBusy)
                    YCPostRuntimeError(self, AVErrorDeviceInUseByAnotherApplication, @"The camera is in use by another program on the host.");
                else if (status == YCStatusNoDevice)
                    YCPostRuntimeError(self, AVErrorDeviceNotConnected, @"The host has no camera.");
                else
                    YCPostRuntimeError(self, AVErrorUnknown, @"The camera could not start.");
                return;
            }
        }
        YCSetInterrupted(self, NO);
        YCSetRunning(self, YES);
        [gLock unlock];
        YCTrace(@"session %p: running (stream %u)", self, gStreamID);
        YCPost(kStartNote, self, nil);
    });
    YCHook(cls, @selector(stopRunning), ^(id self) {
        [gLock lock];
        YCSessionState *ss = SS(self);
        if (!ss.running) {
            [gLock unlock];
            return;
        }
        YCStopStream(self);
        YCSetRunning(self, NO);
        [gLock unlock];
        YCTrace(@"session %p: stopped", self);
        YCPost(kStopNote, self, nil);
    });
}

// MARK: - Outputs

/// The session an output was added to (nil before: the runtime's own
/// answers apply, as during the output's initializer).
static id YCOutputSession(id output) {
    YCOutputState *s = YCState(output);
    return [s isKindOfClass:YCOutputState.class] ? s.session : nil;
}

static void YCHookOutputs(void) {
    static IMP oSetDelegate, oConnections, oConnectionWith;
    oConnections = YCHook(AVOutput, @selector(connections), ^NSArray *(id self) {
        if (!YCOutputSession(self)) return ((NSArray *(*)(id, SEL))oConnections)(self, @selector(connections));
        [gLock lock];
        id session = OS(self).session;
        NSMutableArray *a = [NSMutableArray array];
        if (session) for (id c in SS(session).connections) if (CS(c).output == self) [a addObject:c];
        [gLock unlock];
        return a;
    });
    oConnectionWith = YCHook(AVOutput, @selector(connectionWithMediaType:), ^id(id self, NSString *mediaType) {
        if (!YCOutputSession(self)) return ((id (*)(id, SEL, id))oConnectionWith)(self, @selector(connectionWithMediaType:), mediaType);
        if (!YCIsVideo(mediaType)) return nil;
        [gLock lock];
        id session = OS(self).session;
        id found = session ? YCConnectionFor(SS(session), self) : nil;
        [gLock unlock];
        return found;
    });
    oSetDelegate = YCHook(AVVideoOutput, @selector(setSampleBufferDelegate:queue:), ^(id self, id delegate, dispatch_queue_t queue) {
        ((void (*)(id, SEL, id, dispatch_queue_t))oSetDelegate)(self, @selector(setSampleBufferDelegate:queue:), delegate, queue);
        YCOutputState *os = OS(self);
        os.delegate = delegate;
        os.queue = queue;
        [gLock lock];
        if (os.session) YCReconfigure(os.session);
        [gLock unlock];
    });
    YCHook(AVVideoOutput, @selector(setVideoSettings:), ^(id self, NSDictionary *settings) {
        // Kept here (the stream follows them); nil until set, as in the runtime.
        objc_setAssociatedObject(self, @selector(videoSettings), settings, OBJC_ASSOCIATION_COPY);
        [gLock lock];
        if (OS(self).session) YCReconfigure(OS(self).session);
        [gLock unlock];
    });
    YCHook(AVVideoOutput, @selector(videoSettings), ^NSDictionary *(id self) {
        return objc_getAssociatedObject(self, @selector(videoSettings));
    });
}

// MARK: - Frames to outputs

static NSInteger gAuthorization = -1;
static uint64_t gAuthorizationChecked;

static BOOL YCAuthorized(void) {
    if (gAuthorization == AVAuthorizationStatusAuthorized) return YES;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (gAuthorization < 0 || now - gAuthorizationChecked > 1000000000ull) {
        gAuthorizationChecked = now;
        NSInteger was = gAuthorization;
        gAuthorization = [AVDevice authorizationStatusForMediaType:kVideo];
        if (was != gAuthorization) YCTrace(@"frames: authorization status %ld", (long)gAuthorization);
    }
    return gAuthorization == AVAuthorizationStatusAuthorized;
}

static CMSampleBufferRef YCSampleBuffer(CVPixelBufferRef pb, CMSampleTimingInfo timing) {
    CMVideoFormatDescriptionRef fd = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fd) != noErr) return NULL;
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fd, &timing, &sb);
    CFRelease(fd);
    return sb;
}

static CVPixelBufferRef YCPoolBuffer(YCOutputState *os, int w, int h, OSType format) {
    if (!os->pool || os->poolW != w || os->poolH != h || os->poolFormat != format) {
        if (os->pool) CVPixelBufferPoolRelease(os->pool);
        os->pool = NULL;
        NSDictionary *attrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(format), (id)kCVPixelBufferWidthKey: @(w),
                                (id)kCVPixelBufferHeightKey: @(h), (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &os->pool);
        os->poolW = w;
        os->poolH = h;
        os->poolFormat = format;
    }
    CVPixelBufferRef out = NULL;
    if (os->pool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, os->pool, &out);
    return out;
}

/// The frame rotated, mirrored and in `format` (BGRA from 4:2:0 or as the
/// stream); NULL when nothing needs to change.
static CVPixelBufferRef YCTransform(YCOutputState *os, CVPixelBufferRef src, int angle, BOOL mirror, OSType format) {
    OSType have = CVPixelBufferGetPixelFormatType(src);
    if (format != kCVPixelFormatType_32BGRA) format = have;  // 4:2:0 variants are delivered as streamed
    if (angle == 0 && !mirror && format == have) return NULL;
    int w = (int)CVPixelBufferGetWidth(src), h = (int)CVPixelBufferGetHeight(src);
    int ow = (angle == 90 || angle == 270) ? h : w, oh = (angle == 90 || angle == 270) ? w : h;
    CVPixelBufferRef dst = YCPoolBuffer(os, ow, oh, format);
    if (!dst) return NULL;
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    if (format == have && have == kCVPixelFormatType_32BGRA) {
        yc_transform_plane(CVPixelBufferGetBaseAddress(src), CVPixelBufferGetBytesPerRow(src), (size_t)w, (size_t)h, 4,
                           CVPixelBufferGetBaseAddress(dst), CVPixelBufferGetBytesPerRow(dst), angle, mirror);
    } else if (format == have) {
        yc_transform_plane(CVPixelBufferGetBaseAddressOfPlane(src, 0), CVPixelBufferGetBytesPerRowOfPlane(src, 0), (size_t)w, (size_t)h, 1,
                           CVPixelBufferGetBaseAddressOfPlane(dst, 0), CVPixelBufferGetBytesPerRowOfPlane(dst, 0), angle, mirror);
        yc_transform_plane(CVPixelBufferGetBaseAddressOfPlane(src, 1), CVPixelBufferGetBytesPerRowOfPlane(src, 1),
                           (size_t)(w + 1) / 2, (size_t)(h + 1) / 2, 2, CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                           CVPixelBufferGetBytesPerRowOfPlane(dst, 1), angle, mirror);
    } else {
        // 4:2:0 to BGRA, then the rotation.
        size_t stride = (size_t)w * 4;
        uint8_t *tmp = (angle == 0 && !mirror) ? NULL : malloc(stride * (size_t)h);
        uint8_t *target = tmp ?: CVPixelBufferGetBaseAddress(dst);
        yc_420_to_bgra(CVPixelBufferGetBaseAddressOfPlane(src, 0), CVPixelBufferGetBytesPerRowOfPlane(src, 0),
                       CVPixelBufferGetBaseAddressOfPlane(src, 1), CVPixelBufferGetBytesPerRowOfPlane(src, 1), (size_t)w, (size_t)h,
                       have == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, target, tmp ? stride : CVPixelBufferGetBytesPerRow(dst));
        if (tmp) {
            yc_transform_plane(tmp, stride, (size_t)w, (size_t)h, 4, CVPixelBufferGetBaseAddress(dst), CVPixelBufferGetBytesPerRow(dst), angle, mirror);
            free(tmp);
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVBufferPropagateAttachments(src, dst);
    return dst;
}

static void YCDropped(id output, id connection, id delegate, dispatch_queue_t queue, CMSampleTimingInfo timing, CFStringRef reason) {
    if (![delegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) return;
    CMSampleBufferRef sb = NULL;
    if (CMSampleBufferCreate(kCFAllocatorDefault, NULL, true, NULL, NULL, NULL, 0, 1, &timing, 0, NULL, &sb) != noErr || !sb) return;
    CMSetAttachment(sb, kCMSampleBufferAttachmentKey_DroppedFrameReason, reason, kCMAttachmentMode_ShouldNotPropagate);
    dispatch_async(queue, ^{
        [delegate captureOutput:output didDropSampleBuffer:sb fromConnection:connection];
        CFRelease(sb);
    });
}

static void YCDeliverVideo(id output, id connection, CVPixelBufferRef pb, CMSampleBufferRef sb, CMSampleTimingInfo timing,
                           uint32_t droppedBefore) {
    YCOutputState *os = OS(output);
    id delegate = os.delegate;
    dispatch_queue_t queue = os.queue;
    if (!delegate || !queue) return;
    if (droppedBefore) YCDropped(output, connection, delegate, queue, timing, kCMSampleBufferDroppedFrameReason_OutOfBuffers);
    if (atomic_load(&os->busy) > 0 && [(AVCaptureVideoDataOutput *)output alwaysDiscardsLateVideoFrames]) {
        YCDropped(output, connection, delegate, queue, timing, kCMSampleBufferDroppedFrameReason_FrameWasLate);
        return;
    }
    YCConnectionState *cs = CS(connection);
    NSDictionary *settings = [(AVCaptureVideoDataOutput *)output videoSettings];
    NSNumber *pf = settings[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey];
    CVPixelBufferRef changed = YCTransform(os, pb, cs.angle, cs.mirrored, pf ? (OSType)pf.unsignedIntValue : CVPixelBufferGetPixelFormatType(pb));
    CMSampleBufferRef out = changed ? YCSampleBuffer(changed, timing) : (CMSampleBufferRef)CFRetain(sb);
    if (changed) CVPixelBufferRelease(changed);
    if (!out) return;
    atomic_fetch_add(&os->busy, 1);
    dispatch_async(queue, ^{
        if ([delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
            [delegate captureOutput:output didOutputSampleBuffer:out fromConnection:connection];
        CFRelease(out);
        atomic_fetch_sub(&os->busy, 1);
    });
}

// MARK: - Images (preview, photos)

static void YCFreeBytes(void *info, const void *data, size_t size) {
    (void)info;
    (void)size;
    free((void *)data);
}

/// The frame as BGRA bytes, rotated and mirrored; `*w`, `*h` the result's size.
static uint8_t *YCBGRA(CVPixelBufferRef pb, int angle, BOOL mirror, int *w, int *h) {
    int sw = (int)CVPixelBufferGetWidth(pb), sh = (int)CVPixelBufferGetHeight(pb);
    OSType f = CVPixelBufferGetPixelFormatType(pb);
    size_t stride = (size_t)sw * 4;
    uint8_t *bgra = malloc(stride * (size_t)sh);
    if (!bgra) return NULL;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (f == kCVPixelFormatType_32BGRA) {
        const uint8_t *base = CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        for (int y = 0; y < sh; y++) memcpy(bgra + (size_t)y * stride, base + (size_t)y * bpr, stride);
    } else {
        yc_420_to_bgra(CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                       CVPixelBufferGetBaseAddressOfPlane(pb, 1), CVPixelBufferGetBytesPerRowOfPlane(pb, 1), (size_t)sw, (size_t)sh,
                       f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, bgra, stride);
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    *w = sw;
    *h = sh;
    if (angle == 0 && !mirror) return bgra;
    int ow = (angle == 90 || angle == 270) ? sh : sw, oh = (angle == 90 || angle == 270) ? sw : sh;
    uint8_t *out = malloc((size_t)ow * 4 * (size_t)oh);
    if (out) yc_transform_plane(bgra, stride, (size_t)sw, (size_t)sh, 4, out, (size_t)ow * 4, angle, mirror);
    free(bgra);
    *w = ow;
    *h = oh;
    return out;
}

static CGImageRef YCImage(uint8_t *bgra, int w, int h) CF_RETURNS_RETAINED;
static CGImageRef YCImage(uint8_t *bgra, int w, int h) {
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bgra, (size_t)w * 4 * (size_t)h, YCFreeBytes);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, cs,
                                   kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst, provider, NULL, false,
                                   kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    return img;
}

// MARK: - Preview layers

static dispatch_queue_t gPreviewQueue;

static NSString *YCGravity(id layer) {
    NSString *g = [(AVCaptureVideoPreviewLayer *)layer videoGravity];
    if ([g isEqualToString:kGravityFill]) return kCAGravityResizeAspectFill;
    if ([g isEqualToString:kGravityResize]) return kCAGravityResize;
    return kCAGravityResizeAspect;
}

static void YCLayoutContent(CALayer *layer, YCPreviewState *ps) {
    CALayer *content = ps.content;
    if (!content) return;
    YCConnectionState *cs = CS(ps.connection);
    int angle = cs ? cs.angle : 0;
    BOOL mirror = cs ? cs.mirrored : NO;
    CGRect b = layer.bounds;
    content.transform = CATransform3DIdentity;
    content.bounds = (angle == 90 || angle == 270) ? CGRectMake(0, 0, b.size.height, b.size.width) : CGRectMake(0, 0, b.size.width, b.size.height);
    content.position = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    CATransform3D t = CATransform3DMakeRotation((CGFloat)angle * (CGFloat)M_PI / 180, 0, 0, 1);
    if (mirror) t = CATransform3DConcat(t, CATransform3DMakeScale(-1, 1, 1));
    content.transform = t;
    content.contentsGravity = YCGravity(layer);
}

static void YCRenderPreview(CALayer *layer, CVPixelBufferRef pb) {
    YCPreviewState *ps = PS(layer);
    int expected = 0;
    if (!atomic_compare_exchange_strong(&ps->busy, &expected, 1)) return;
    CVPixelBufferRetain(pb);
    dispatch_async(gPreviewQueue, ^{
        int w = 0, h = 0;
        uint8_t *bytes = YCBGRA(pb, 0, NO, &w, &h);
        CVPixelBufferRelease(pb);
        CGImageRef img = bytes ? YCImage(bytes, w, h) : NULL;
        dispatch_async(dispatch_get_main_queue(), ^{
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            if (!ps.content) {
                ps.content = [CALayer layer];
                ps.content.masksToBounds = YES;
                ps.content.name = @"dev.ycode.camera.preview";
                // Below anything the app draws over the preview.
                [layer insertSublayer:ps.content atIndex:0];
            }
            YCLayoutContent(layer, ps);
            ps.content.contents = (__bridge id)img;
            [CATransaction commit];
            if (img) CGImageRelease(img);
            atomic_store(&ps->busy, 0);
        });
    });
}

static IMP oPreviewInit;

static void YCAttachPreview(id layer, id session, BOOL connect) {
    [gLock lock];
    YCPreviewState *ps = PS(layer);
    id old = ps.session;
    if (old && old != session) {
        YCSessionState *oss = SS(old);
        [oss.previews removeObject:layer];
        if (ps.connection) [oss.connections removeObject:ps.connection];
        ps.connection = nil;
    }
    ps.session = session;
    ps.noConnection = !connect;
    if (session) {
        [SS(session).previews addObject:layer];
        [gSessions addObject:session];
        YCConnectAll(session);
        YCReconfigure(session);
    }
    [gLock unlock];
}

static NS_RETURNS_RETAINED id YCPreviewInit(__attribute__((ns_consumed)) id self, SEL _cmd, id session) {
    typedef NS_RETURNS_RETAINED id (*Init)(__attribute__((ns_consumed)) id, SEL, id);
    self = ((Init)oPreviewInit)(self, _cmd, nil);
    if (self) YCAttachPreview(self, session, YES);
    return self;
}

static NS_RETURNS_RETAINED id YCPreviewInitNoConnection(__attribute__((ns_consumed)) id self, SEL _cmd, id session) {
    typedef NS_RETURNS_RETAINED id (*Init)(__attribute__((ns_consumed)) id, SEL, id);
    self = ((Init)oPreviewInit)(self, @selector(initWithSession:), nil);
    if (self) YCAttachPreview(self, session, NO);
    return self;
}

static void YCHookPreview(void) {
    static IMP oLayout, oSetGravity;
    oPreviewInit = YCHookC(AVPreview, @selector(initWithSession:), (IMP)YCPreviewInit);
    YCHookC(AVPreview, @selector(initWithSessionWithNoConnection:), (IMP)YCPreviewInitNoConnection);
    YCHook(AVPreview, @selector(session), ^id(id self) { return PS(self).session; });
    YCHook(AVPreview, @selector(setSession:), ^(id self, id session) { YCAttachPreview(self, session, YES); });
    YCHook(AVPreview, @selector(setSessionWithNoConnection:), ^(id self, id session) { YCAttachPreview(self, session, NO); });
    YCHook(AVPreview, @selector(connection), ^id(id self) { return PS(self).connection; });
    YCHook(AVPreview, @selector(isPreviewing), ^BOOL(id self) {
        YCPreviewState *ps = PS(self);
        return ps.session && SS(ps.session).running && CS(ps.connection).enabled;
    });
    oLayout = YCHook(AVPreview, @selector(layoutSublayers), ^(id self) {
        ((void (*)(id, SEL))oLayout)(self, @selector(layoutSublayers));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        YCLayoutContent(self, PS(self));
        [CATransaction commit];
    });
    oSetGravity = YCHook(AVPreview, @selector(setVideoGravity:), ^(id self, NSString *g) {
        ((void (*)(id, SEL, id))oSetGravity)(self, @selector(setVideoGravity:), g);
        YCLayoutContent(self, PS(self));
    });
    // Point conversions for an unrotated preview (aspect fit, fill, resize).
    YCHook(AVPreview, @selector(captureDevicePointOfInterestForPoint:), ^CGPoint(id self, CGPoint p) {
        CGRect b = [(CALayer *)self bounds];
        YCStartReply r = gStreamSession ? SS(gStreamSession).stream : (YCStartReply){0};
        double iw = r.width ?: 16, ih = r.height ?: 9;
        NSString *g = YCGravity(self);
        double sx = b.size.width / iw, sy = b.size.height / ih;
        double s = [g isEqualToString:kCAGravityResizeAspectFill] ? MAX(sx, sy) : MIN(sx, sy);
        if ([g isEqualToString:kCAGravityResize]) return CGPointMake(p.x / b.size.width, p.y / b.size.height);
        double ox = (b.size.width - iw * s) / 2, oy = (b.size.height - ih * s) / 2;
        return CGPointMake((p.x - ox) / (iw * s), (p.y - oy) / (ih * s));
    });
}

// MARK: - Photos

static dispatch_queue_t gPhotoQueue;
static NSMutableArray<YCPhotoRequest *> *gPhotoRequests;

static void YCBuildPhotoClasses(void) {
    Class r = cResolved;
    YCOverride(r, @selector(uniqueID), ^int64_t(id self) { return ((YCResolvedState *)YCState(self)).uniqueID; });
    YCOverride(r, @selector(photoDimensions), ^CMVideoDimensions(id self) { return ((YCResolvedState *)YCState(self)).dimensions; });
    YCOverride(r, @selector(rawPhotoDimensions), ^CMVideoDimensions(id self) { return (CMVideoDimensions){0, 0}; });
    YCOverride(r, @selector(previewDimensions), ^CMVideoDimensions(id self) { return (CMVideoDimensions){0, 0}; });
    YCOverride(r, @selector(embeddedThumbnailDimensions), ^CMVideoDimensions(id self) { return (CMVideoDimensions){0, 0}; });
    YCOverride(r, @selector(livePhotoMovieDimensions), ^CMVideoDimensions(id self) { return (CMVideoDimensions){0, 0}; });
    YCOverride(r, @selector(isFlashEnabled), ^BOOL(id self) { return NO; });
    YCOverride(r, @selector(isRedEyeReductionEnabled), ^BOOL(id self) { return NO; });
    YCOverride(r, @selector(isStillImageStabilizationEnabled), ^BOOL(id self) { return NO; });
    YCOverride(r, @selector(isVirtualDeviceFusionEnabled), ^BOOL(id self) { return NO; });
    YCOverride(r, @selector(isDualCameraFusionEnabled), ^BOOL(id self) { return NO; });
    YCOverride(r, @selector(expectedPhotoCount), ^NSUInteger(id self) { return 1; });
    YCOverride(r, @selector(isContentAwareDistortionCorrectionEnabled), ^BOOL(id self) { return NO; });
    YCOverride(r, @selector(isFastCapturePrioritizationEnabled), ^BOOL(id self) { return NO; });
    YCOverride(r, @selector(isDeferredPhotoDeliveryEnabled), ^BOOL(id self) { return NO; });
    YCOverride(r, @selector(photoProcessingTimeRange), ^CMTimeRange(id self) { return CMTimeRangeMake(kCMTimeZero, kCMTimeZero); });
    Class p = cPhoto;
    YCOverride(p, @selector(fileDataRepresentation), ^NSData *(id self) { return ((YCPhotoState *)YCState(self)).data; });
    YCOverride(p, @selector(fileDataRepresentationWithCustomizer:), ^NSData *(id self, id customizer) {
        (void)customizer;
        return ((YCPhotoState *)YCState(self)).data;
    });
    YCOverride(p, @selector(CGImageRepresentation), ^CGImageRef(id self) { return ((YCPhotoState *)YCState(self))->image; });
    YCOverride(p, @selector(previewCGImageRepresentation), ^CGImageRef(id self) { return NULL; });
    YCOverride(p, @selector(pixelBuffer), ^CVPixelBufferRef(id self) { return ((YCPhotoState *)YCState(self))->pixelBuffer; });
    YCOverride(p, @selector(previewPixelBuffer), ^CVPixelBufferRef(id self) { return NULL; });
    YCOverride(p, @selector(timestamp), ^CMTime(id self) { return ((YCPhotoState *)YCState(self)).timestamp; });
    YCOverride(p, @selector(metadata), ^NSDictionary *(id self) { return @{(id)kCGImagePropertyOrientation: @1}; });
    YCOverride(p, @selector(resolvedSettings), ^id(id self) { return ((YCPhotoState *)YCState(self)).resolved; });
    YCOverride(p, @selector(photoCount), ^NSInteger(id self) { return 1; });
    YCOverride(p, @selector(isRawPhoto), ^BOOL(id self) { return NO; });
    YCOverride(p, @selector(depthData), ^id(id self) { return nil; });
    YCOverride(p, @selector(portraitEffectsMatte), ^id(id self) { return nil; });
    YCOverride(p, @selector(embeddedThumbnailPhotoFormat), ^NSDictionary *(id self) { return nil; });
    YCOverride(p, @selector(sourceDeviceType), ^NSString *(id self) { return YCDeviceTypeValue(); });
    YCOverride(p, @selector(cameraCalibrationData), ^id(id self) { return nil; });
}

static id YCMakeResolved(int64_t uniqueID, int w, int h) {
    id r = YCCreateInstance(cResolved);
    YCResolvedState *s = [YCResolvedState new];
    s.uniqueID = uniqueID;
    s.dimensions = (CMVideoDimensions){w, h};
    YCSetState(r, s);
    return r;
}

static void YCCallPhotoDelegate(id delegate, SEL sel, id output, id arg, NSError *error, int args) {
    if (![delegate respondsToSelector:sel]) return;
    if (args == 2) ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, output, arg);
    else ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, sel, output, arg, error);
}

static void YCFinishPhoto(YCPhotoRequest *rq, CVPixelBufferRef pb, CMTime pts) {
    id delegate = rq.delegate, output = rq.output, resolved = rq.resolved;
    YCConnectionState *cs = CS(rq.connection);
    int w = 0, h = 0;
    uint8_t *bytes = YCBGRA(pb, cs.angle, cs.mirrored, &w, &h);
    YCPhotoState *st = [YCPhotoState new];
    st.timestamp = pts;
    ((YCResolvedState *)YCState(resolved)).dimensions = (CMVideoDimensions){w, h};
    st.resolved = resolved;
    NSDictionary *format = [(AVCapturePhotoSettings *)rq.settings format];
    BOOL uncompressed = format[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey] != nil;
    if (bytes && uncompressed) {
        CVPixelBufferRef out = NULL;
        NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)w, (size_t)h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &out) == kCVReturnSuccess) {
            CVPixelBufferLockBaseAddress(out, 0);
            uint8_t *base = CVPixelBufferGetBaseAddress(out);
            size_t bpr = CVPixelBufferGetBytesPerRow(out);
            for (int y = 0; y < h; y++) memcpy(base + (size_t)y * bpr, bytes + (size_t)y * (size_t)w * 4, (size_t)w * 4);
            CVPixelBufferUnlockBaseAddress(out, 0);
            st->pixelBuffer = out;
        }
    }
    if (bytes) {
        st->image = YCImage(bytes, w, h);
        if (!uncompressed) {
            NSMutableData *jpeg = [NSMutableData data];
            CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
            if (dest) {
                NSDictionary *props = @{(id)kCGImageDestinationLossyCompressionQuality: @0.9, (id)kCGImagePropertyOrientation: @1};
                CGImageDestinationAddImage(dest, st->image, (__bridge CFDictionaryRef)props);
                if (CGImageDestinationFinalize(dest)) st.data = jpeg;
                CFRelease(dest);
            }
        }
    }
    id photo = YCCreateInstance(cPhoto);
    YCSetState(photo, st);
    NSError *error = st->image ? nil : YCError(AVErrorUnknown, @"The photo could not be made.", nil);
    YCTrace(@"photo %lld: %dx%d, %lu bytes of JPEG", ((YCResolvedState *)YCState(resolved)).uniqueID, w, h, (unsigned long)st.data.length);
    YCCallPhotoDelegate(delegate, @selector(captureOutput:willCapturePhotoForResolvedSettings:), output, resolved, nil, 2);
    YCCallPhotoDelegate(delegate, @selector(captureOutput:didCapturePhotoForResolvedSettings:), output, resolved, nil, 2);
    YCCallPhotoDelegate(delegate, @selector(captureOutput:didFinishProcessingPhoto:error:), output, photo, error, 3);
    YCCallPhotoDelegate(delegate, @selector(captureOutput:didFinishCaptureForResolvedSettings:error:), output, resolved, error, 3);
}

static void YCHookPhotoOutput(void) {
    static IMP oCapture;
    oCapture = YCHook(AVPhotoOutput, @selector(capturePhotoWithSettings:delegate:), ^(id self, id settings, id delegate) {
        [gLock lock];
        id session = OS(self).session;
        id connection = session ? YCConnectionFor(SS(session), self) : nil;
        BOOL running = session && SS(session).running && gStreamSession == session;
        [gLock unlock];
        if (!connection) {
            ((void (*)(id, SEL, id, id))oCapture)(self, @selector(capturePhotoWithSettings:delegate:), settings, delegate);
            return;
        }
        int64_t uid = [(AVCapturePhotoSettings *)settings uniqueID];
        YCFormatState *f = FS(gDS.activeFormat);
        id resolved = YCMakeResolved(uid, f.width, f.height);
        dispatch_async(gPhotoQueue, ^{
            YCCallPhotoDelegate(delegate, @selector(captureOutput:willBeginCaptureForResolvedSettings:), self, resolved, nil, 2);
            if (!running) {
                NSError *e = YCError(AVErrorSessionNotRunning, @"Cannot Record", @"The session is not running.");
                YCCallPhotoDelegate(delegate, @selector(captureOutput:didFinishCaptureForResolvedSettings:error:), self, resolved, e, 3);
            }
        });
        if (!running) return;
        YCPhotoRequest *rq = [YCPhotoRequest new];
        rq.settings = settings;
        rq.delegate = delegate;
        rq.output = self;
        rq.connection = connection;
        rq.resolved = resolved;
        [gLock lock];
        [gPhotoRequests addObject:rq];
        [gLock unlock];
    });
    // Before the output is added to a session the runtime answers (its
    // initializer reads these; answering for it crashed the runtime).
    static IMP oCodecs, oPixelFormats, oFlashModes, oMaxDimensions;
    oCodecs = YCHook(AVPhotoOutput, @selector(availablePhotoCodecTypes), ^NSArray *(id self) {
        if (!YCOutputSession(self)) return ((NSArray *(*)(id, SEL))oCodecs)(self, @selector(availablePhotoCodecTypes));
        return @[kCodecJPEG];
    });
    oPixelFormats = YCHook(AVPhotoOutput, @selector(availablePhotoPixelFormatTypes), ^NSArray *(id self) {
        if (!YCOutputSession(self)) return ((NSArray *(*)(id, SEL))oPixelFormats)(self, @selector(availablePhotoPixelFormatTypes));
        return @[@(kCVPixelFormatType_32BGRA)];
    });
    oFlashModes = YCHook(AVPhotoOutput, @selector(supportedFlashModes), ^NSArray *(id self) {
        if (!YCOutputSession(self)) return ((NSArray *(*)(id, SEL))oFlashModes)(self, @selector(supportedFlashModes));
        return @[@(AVCaptureFlashModeOff)];
    });
    oMaxDimensions = YCHook(AVPhotoOutput, @selector(maxPhotoDimensions), ^CMVideoDimensions(id self) {
        if (!YCOutputSession(self)) return ((CMVideoDimensions (*)(id, SEL))oMaxDimensions)(self, @selector(maxPhotoDimensions));
        YCFormatState *f = FS(gDS.activeFormat);
        return (CMVideoDimensions){f.width, f.height};
    });
}

// MARK: - The frame path

static void YCHandleFrame(YCFrameInfo f) {
    if (f.stream != gStreamID || !gStreamID) {
        YCHostRelease(f.stream, f.slot, f.sequence);
        return;
    }
    if (!YCAuthorized()) {
        YCHostRelease(f.stream, f.slot, f.sequence);
        return;
    }
    CVPixelBufferRef pb = YCCreatePixelBuffer(f);
    if (!pb) {
        YCHostRelease(f.stream, f.slot, f.sequence);
        return;
    }
    // From here the frame goes back to the host when the pixel buffer is freed.
    CMSampleTimingInfo timing = {CMClockMakeHostTimeFromSystemUnits(f.durationTicks), CMClockMakeHostTimeFromSystemUnits(f.presentationTicks),
                                 kCMTimeInvalid};
    CMSampleBufferRef sb = YCSampleBuffer(pb, timing);
    [gLock lock];
    id session = gStreamSession;
    YCSessionState *ss = session ? SS(session) : nil;
    NSArray *connections = ss.running && !ss.interrupted ? [ss.connections copy] : @[];
    NSArray *previews = ss.running && !ss.interrupted ? ss.previews.allObjects : @[];
    NSArray *photos = nil;
    gStreamFrames++;
    if (gPhotoRequests.count && ss.running && gStreamFrames > kPhotoSettleFrames) {
        photos = [gPhotoRequests copy];
        [gPhotoRequests removeAllObjects];
    }
    [gLock unlock];
    static uint64_t count;
    if (YCDebug && (count++ % 150) == 0)
        YCLog(@"frame %llu: surface %u %ux%u, %lu connections, %lu previews", f.sequence, f.surfaceID, f.width, f.height,
              (unsigned long)connections.count, (unsigned long)previews.count);
    if (sb) {
        for (id c in connections) {
            YCConnectionState *cs = CS(c);
            id output = cs.output;
            if (!output || !cs.enabled || ![output isKindOfClass:AVVideoOutput]) continue;
            YCDeliverVideo(output, c, pb, sb, timing, f.dropped);
        }
        CFRelease(sb);
    }
    for (CALayer *layer in previews) {
        YCPreviewState *ps = PS(layer);
        if (CS(ps.connection).enabled) YCRenderPreview(layer, pb);
    }
    for (YCPhotoRequest *rq in photos) {
        CVPixelBufferRetain(pb);
        dispatch_async(gPhotoQueue, ^{
            YCFinishPhoto(rq, pb, timing.presentationTimeStamp);
            CVPixelBufferRelease(pb);
        });
    }
    CVPixelBufferRelease(pb);
}

static void YCHandleEvent(uint32_t stream, uint32_t kind, uint32_t width, uint32_t height) {
    (void)width;
    (void)height;
    [gLock lock];
    id session = stream == gStreamID ? gStreamSession : nil;
    [gLock unlock];
    switch (kind) {
    case YCEventInterrupted:
        if (!session) return;
        YCSetInterrupted(session, YES);
        YCPost(kInterruptedNote, session, @{kReasonKey: @(AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient)});
        break;
    case YCEventInterruptionEnded:
        if (!session) return;
        YCSetInterrupted(session, NO);
        YCPost(kInterruptionEndedNote, session, nil);
        break;
    case YCEventDisconnected:
        [gDevice willChangeValueForKey:@"connected"];
        gDS.connected = NO;
        [gDevice didChangeValueForKey:@"connected"];
        YCPost(kDisconnectedNote, gDevice, nil);
        if (session) {
            YCPostRuntimeError(session, AVErrorDeviceWasDisconnected, @"The camera was disconnected.");
            [gLock lock];
            YCStopStream(session);
            YCSetRunning(session, NO);
            [gLock unlock];
            YCPost(kStopNote, session, nil);
        }
        break;
    case YCEventReconnected:
        [gDevice willChangeValueForKey:@"connected"];
        gDS.connected = YES;
        [gDevice didChangeValueForKey:@"connected"];
        YCPost(kConnectedNote, gDevice, nil);
        break;
    case YCEventFailed:
        if (!session) return;
        YCPostRuntimeError(session, AVErrorMediaServicesWereReset, @"The camera stream ended.");
        [gLock lock];
        YCStopStream(session);
        YCSetRunning(session, NO);
        [gLock unlock];
        YCPost(kStopNote, session, nil);
        break;
    }
}

// MARK: - App lifecycle (interruption in the background, as on a device)

static void YCObserveLifecycle(void) {
    NSString *background = YCConst("UIApplicationDidEnterBackgroundNotification", @"UIApplicationDidEnterBackgroundNotification");
    NSString *foreground = YCConst("UIApplicationWillEnterForegroundNotification", @"UIApplicationWillEnterForegroundNotification");
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:background object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n;
        [gLock lock];
        id session = gStreamSession;
        if (session && SS(session).running && !SS(session).interrupted) {
            YCStopStream(session);
            gStreamSession = session;  // remembered for the return
            YCSetInterrupted(session, YES);
            [gLock unlock];
            YCPost(kInterruptedNote, session, @{kReasonKey: @(AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground)});
            return;
        }
        [gLock unlock];
    }];
    [nc addObserverForName:foreground object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n;
        [gLock lock];
        id session = gStreamSession;
        if (session && SS(session).running && SS(session).interrupted && !gStreamID) {
            gStreamSession = nil;
            if (YCStartStream(session) == YCStatusOK) {
                YCSetInterrupted(session, NO);
                [gLock unlock];
                YCPost(kInterruptionEndedNote, session, nil);
                return;
            }
        }
        [gLock unlock];
    }];
}

// MARK: - Installation

void YCInstallCaptureLayer(void) {
    YCDebug = getenv("YCODE_CAMERA_DEBUG") && strcmp(getenv("YCODE_CAMERA_DEBUG"), "0") != 0;
    AVDevice = objc_getClass("AVCaptureDevice");
    AVFormat = objc_getClass("AVCaptureDeviceFormat");
    AVRange = objc_getClass("AVFrameRateRange");
    AVInput = objc_getClass("AVCaptureDeviceInput");
    AVPort = objc_getClass("AVCaptureInputPort");
    AVConnection = objc_getClass("AVCaptureConnection");
    AVSession = objc_getClass("AVCaptureSession");
    AVOutput = objc_getClass("AVCaptureOutput");
    AVVideoOutput = objc_getClass("AVCaptureVideoDataOutput");
    AVPhotoOutput = objc_getClass("AVCapturePhotoOutput");
    AVMovieOutput = objc_getClass("AVCaptureMovieFileOutput");
    AVPreview = objc_getClass("AVCaptureVideoPreviewLayer");
    AVDiscovery = objc_getClass("AVCaptureDeviceDiscoverySession");
    AVPhoto = objc_getClass("AVCapturePhoto");
    AVResolved = objc_getClass("AVCaptureResolvedPhotoSettings");
    AVPhotoSettings = objc_getClass("AVCapturePhotoSettings");
    if (!AVDevice || !AVFormat || !AVRange || !AVInput || !AVPort || !AVConnection || !AVSession || !AVOutput || !AVVideoOutput
        || !AVPreview || !AVDiscovery) {
        YCLog(@"AVFoundation's capture classes are missing; no camera");
        return;
    }
    // Debug: YCODE_CAMERA_SKIP names parts not to install (all, classes, discovery,
    // photo, sessions, outputs, preview, connections), to find which one a failure needs.
    const char *skipEnv = getenv("YCODE_CAMERA_SKIP");
    NSString *skip = skipEnv ? @(skipEnv) : @"";
    BOOL (^skipping)(NSString *) = ^BOOL(NSString *part) {
        BOOL yes = [[skip componentsSeparatedByString:@","] containsObject:part];
        if (yes) YCLog(@"debug: not installing %@", part);
        return yes;
    };
    YCLoadConstants();
    NSArray<YCCameraInfo *> *cameras = YCHostDevices();
    if (cameras.count == 0) {
        YCLog(@"the host announces no camera; the reference behavior stays");
        return;
    }
    if (skipping(@"all")) return;
    gLock = [NSRecursiveLock new];
    gSessions = [NSHashTable weakObjectsHashTable];
    gPhotoRequests = [NSMutableArray array];
    gPreviewQueue = dispatch_queue_create("dev.ycode.camera.preview", DISPATCH_QUEUE_SERIAL);
    gPhotoQueue = dispatch_queue_create("dev.ycode.camera.photo", DISPATCH_QUEUE_SERIAL);
    cDevice = YCSubclass(AVDevice, "YcodeCaptureDevice");
    cFormat = YCSubclass(AVFormat, "YcodeCaptureDeviceFormat");
    cRange = YCSubclass(AVRange, "YcodeFrameRateRange");
    cInput = YCSubclass(AVInput, "YcodeCaptureDeviceInput");
    cPort = YCSubclass(AVPort, "YcodeCaptureInputPort");
    cConnection = YCSubclass(AVConnection, "YcodeCaptureConnection");
    if (skipping(@"classes")) return;
    if (AVPhoto && AVResolved && !skipping(@"photo")) {
        cPhoto = YCSubclass(AVPhoto, "YcodeCapturePhoto");
        cResolved = YCSubclass(AVResolved, "YcodeCaptureResolvedPhotoSettings");
    }
    YCBuildDeviceClass();
    YCBuildFormatClasses();
    YCBuildInputClasses();
    YCBuildConnectionClass();
    if (cPhoto) YCBuildPhotoClasses();
    for (Class c in @[cDevice, cFormat, cRange, cInput, cPort, cConnection]) objc_registerClassPair(c);
    if (cPhoto) {
        objc_registerClassPair(cPhoto);
        objc_registerClassPair(cResolved);
    }
    YCMakeDevice(cameras.firstObject);
    if (!skipping(@"discovery")) YCHookDiscovery();
    if (!skipping(@"sessions")) {
        YCHookSessionClass(AVSession);
        Class multi = objc_getClass("AVCaptureMultiCamSession");
        if (multi) YCHookSessionClass(multi);
    }
    if (!skipping(@"outputs")) YCHookOutputs();
    if (!skipping(@"preview")) YCHookPreview();
    if (AVPhotoOutput && cPhoto) YCHookPhotoOutput();
    if (!skipping(@"connections")) {
        oConnInitOutput = YCHookC(AVConnection, @selector(initWithInputPorts:output:), (IMP)YCConnectionInitOutput);
        oConnInitLayer = YCHookC(AVConnection, @selector(initWithInputPort:videoPreviewLayer:), (IMP)YCConnectionInitLayer);
    }
    YCFrameHandler = ^(YCFrameInfo f) { YCHandleFrame(f); };
    YCEventHandler = ^(uint32_t stream, uint32_t kind, uint32_t w, uint32_t h) { YCHandleEvent(stream, kind, w, h); };
    YCObserveLifecycle();
    YCLog(@"camera layer installed: %@ (%@), %lu formats", gInfo.localizedName, gInfo.modelID, (unsigned long)gDS.formats.count);
}
