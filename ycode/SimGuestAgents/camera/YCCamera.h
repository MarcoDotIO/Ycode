// libYcodeCamera.dylib: Ycode's guest capture layer (specs/simulator/camera.md
// "Ycode implementation"). Written from camera.md and Apple's public
// AVFoundation, CoreMedia, CoreVideo, IOSurface, QuartzCore and ImageIO
// documentation and SDK headers only: it uses no Apple-private class,
// method or symbol, and reaches AVFoundation only through public classes,
// public selectors and the public Objective-C runtime API.
//
// The library does not link AVFoundation (it would load it into every app):
// classes are found with objc_getClass, and AVFoundation's exported string
// constants with dlsym, once AVFoundation is in the process.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Logging (YCODE_CAMERA_DEBUG=1: every step on stderr)

extern BOOL YCDebug;
void YCLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#define YCTrace(...) do { if (YCDebug) YCLog(__VA_ARGS__); } while (0)

// MARK: - The host endpoint (YCHost.m; CameraGuestProtocol.swift)

/// One camera the host announces.
@interface YCCameraInfo : NSObject
@property(nonatomic, copy) NSString *uniqueID, *localizedName, *modelID, *manufacturer, *deviceType;
@property(nonatomic) NSInteger position;
/// Dictionaries: width, height, minFrameRate, maxFrameRate.
@property(nonatomic, copy) NSArray<NSDictionary *> *formats;
@end

/// One frame from the host: a host-made IOSurface of the ring.
typedef struct {
    uint32_t stream;
    uint64_t sequence;
    uint32_t surfaceID, slot, seed, width, height, pixelFormat, dropped, flags;
    uint64_t presentationTicks, durationTicks;
} YCFrameInfo;

enum {
    YCStatusOK = 0, YCStatusNoDevice = 1, YCStatusBusy = 2, YCStatusBadRequest = 3, YCStatusFailed = 4,
    YCEventInterrupted = 1, YCEventInterruptionEnded = 2, YCEventDisconnected = 3, YCEventReconnected = 4, YCEventFailed = 5,
};

typedef struct {
    uint32_t status, stream, width, height, fpsMilli, pixelFormat;
} YCStartReply;

/// The cameras (empty when the endpoint is absent).
NSArray<YCCameraInfo *> *YCHostDevices(void);
YCStartReply YCHostStart(uint32_t width, uint32_t height, double fps, OSType pixelFormat);
void YCHostStop(uint32_t stream);
void YCHostRelease(uint32_t stream, uint32_t slot, uint64_t sequence);
/// Called on the frame thread for each frame and event.
extern void (^_Nullable YCFrameHandler)(YCFrameInfo frame);
extern void (^_Nullable YCEventHandler)(uint32_t stream, uint32_t kind, uint32_t width, uint32_t height);

/// A pixel buffer backed by the frame's IOSurface (its release goes back to
/// the host when the buffer is freed). NULL if the surface is not found.
CVPixelBufferRef _Nullable YCCreatePixelBuffer(YCFrameInfo frame) CF_RETURNS_RETAINED;
/// Forgets the surfaces of earlier streams (IDs are reused).
void YCForgetSurfaces(void);

// MARK: - Pixels (YCPixels.c)

/// Rotation in degrees clockwise (0, 90, 180, 270), then a horizontal
/// mirror, of one plane of `bpe`-byte elements.
void yc_transform_plane(const uint8_t *src, size_t srcStride, size_t width, size_t height, size_t bpe,
                        uint8_t *dst, size_t dstStride, int angle, int mirror);
/// Bi-planar 4:2:0 (video or full range, BT.601) to BGRA (alpha 255).
void yc_420_to_bgra(const uint8_t *y, size_t yStride, const uint8_t *cbcr, size_t cStride, size_t width, size_t height,
                    int fullRange, uint8_t *dst, size_t dstStride);

// MARK: - The capture layer (YCCapture.m)

void YCInstallCaptureLayer(void);

NS_ASSUME_NONNULL_END
