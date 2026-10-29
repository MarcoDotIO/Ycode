// CameraProbe.app (dev.ycode.CameraProbe): exercises the public capture API
// in Ycode's simulator (specs/simulator/camera.md "Ycode implementation",
// verification). Public AVFoundation, CoreMedia, CoreVideo, ImageIO and
// UIKit API only. One mode per launch (ycode-simd --launch
// dev.ycode.CameraProbe --app-arg <mode> [--app-arg …]):
//
//   discover                     default devices, discovery sessions, formats, authorization
//   status                       the authorization status only
//   request                      requests access (the system alert when not determined)
//   stream FMT W H SECONDS [preview] [angle A] [mirror]
//                                a session with a video data output (FMT 420v|420f|BGRA);
//                                frame count, rate, sizes, formats, time stamps; the
//                                last frame written to /tmp/camprobe-frame.png (and its
//                                center pixel); with "preview" also a full-screen preview
//                                layer that stays up after the counting
//   preview SECONDS              only a preview layer (no data output), for screenshots
//   photo                        one still from a photo output → /tmp/camprobe-photo.jpg
//   input                        only creates the device input (authorization error check)
//   outputs                      only creates a video data, movie file and photo output
//   picker                       presents UIImagePickerController with the camera source
//
// Every result line starts with "camprobe: " (stdout, and /tmp/camprobe.txt).

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>

static FILE *gOut;
static CFAbsoluteTime gStart;

static void say(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"camprobe: %7.3f %@\n", CFAbsoluteTimeGetCurrent() - gStart, s];
    fputs(line.UTF8String, stdout);
    fflush(stdout);
    if (gOut) {
        fputs(line.UTF8String, gOut);
        fflush(gOut);
    }
}

static NSString *fourcc(OSType t) {
    return [NSString stringWithFormat:@"%c%c%c%c", (char)(t >> 24), (char)(t >> 16), (char)(t >> 8), (char)t];
}

static OSType parseFormat(NSString *s) {
    if ([s isEqualToString:@"BGRA"]) return kCVPixelFormatType_32BGRA;
    if ([s isEqualToString:@"420f"]) return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
}

static NSString *statusName(AVAuthorizationStatus s) {
    switch (s) {
    case AVAuthorizationStatusNotDetermined: return @"not-determined";
    case AVAuthorizationStatusRestricted: return @"restricted";
    case AVAuthorizationStatusDenied: return @"denied";
    case AVAuthorizationStatusAuthorized: return @"authorized";
    }
    return @"?";
}

static void finish(int code) {
    say(@"done %d", code);
    if (gOut) fclose(gOut);
    exit(code);
}

// MARK: - Frames to PNG

static uint8_t clamp8(int v) { return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v); }

/// BGRA bytes of a pixel buffer (4:2:0 converted with BT.601).
static NSData *bgraOf(CVPixelBufferRef pb, size_t *w, size_t *h) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb);
    NSMutableData *d = [NSMutableData dataWithLength:W * H * 4];
    uint8_t *o = d.mutableBytes;
    OSType f = CVPixelBufferGetPixelFormatType(pb);
    if (f == kCVPixelFormatType_32BGRA) {
        const uint8_t *b = CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        for (size_t y = 0; y < H; y++) memcpy(o + y * W * 4, b + y * bpr, W * 4);
    } else {
        BOOL full = f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        const uint8_t *Y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *C = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        for (size_t y = 0; y < H; y++) {
            for (size_t x = 0; x < W; x++) {
                double l = full ? Y[y * ys + x] : (Y[y * ys + x] - 16) * 255.0 / 219;
                double cb = C[(y / 2) * cs + (x & ~1UL)] - 128.0, cr = C[(y / 2) * cs + (x & ~1UL) + 1] - 128.0;
                if (!full) { cb *= 255.0 / 224; cr *= 255.0 / 224; }
                uint8_t *p = o + (y * W + x) * 4;
                p[2] = clamp8((int)lround(l + 1.402 * cr));
                p[1] = clamp8((int)lround(l - 0.344136 * cb - 0.714136 * cr));
                p[0] = clamp8((int)lround(l + 1.772 * cb));
                p[3] = 255;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    *w = W;
    *h = H;
    return d;
}

static BOOL writePNG(NSData *bgra, size_t w, size_t h, NSString *path) {
    CGDataProviderRef p = CGDataProviderCreateWithCFData((__bridge CFDataRef)bgra);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs, kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst, p, NULL,
                                   false, kCGRenderingIntentDefault);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    BOOL ok = NO;
    if (dest && img) {
        CGImageDestinationAddImage(dest, img, NULL);
        ok = CGImageDestinationFinalize(dest);
    }
    if (dest) CFRelease(dest);
    CGImageRelease(img);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(p);
    return ok;
}

// MARK: - The probe

@interface Probe : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate,
                             UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *preview;
@property(nonatomic, strong) NSArray<NSString *> *args;
@property(atomic) NSInteger frames, dropped;
@property(atomic) double firstPTS, lastPTS, minDelta, maxDelta;
@property(atomic) BOOL counting;
@property(nonatomic, strong) NSMutableSet *sizes, *formats;
@property(atomic) CVPixelBufferRef keep;
@end

@implementation Probe

- (void)discover {
    say(@"authorization %@", statusName([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]));
    AVCaptureDevice *video = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    say(@"default video: %@", video ? [NSString stringWithFormat:@"%@ | %@ | type %@ | position %ld | model %@ | manufacturer %@ | connected %d",
                                       video.localizedName, video.uniqueID, video.deviceType, (long)video.position, video.modelID,
                                       video.manufacturer, video.connected] : @"nil");
    AVCaptureDevice *audio = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    say(@"default audio: %@", audio ? audio.deviceType : @"nil");
    AVCaptureDevice *back = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionBack];
    AVCaptureDevice *front = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo
                                                                 position:AVCaptureDevicePositionFront];
    AVCaptureDevice *external = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeExternal mediaType:AVMediaTypeVideo
                                                                    position:AVCaptureDevicePositionUnspecified];
    say(@"wide back: %@; wide front: %@; external: %@", back.localizedName ?: @"nil", front.localizedName ?: @"nil",
        external.localizedName ?: @"nil");
    NSArray *types = @[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInUltraWideCamera,
                       AVCaptureDeviceTypeBuiltInTelephotoCamera, AVCaptureDeviceTypeBuiltInDualCamera,
                       AVCaptureDeviceTypeBuiltInTrueDepthCamera, AVCaptureDeviceTypeExternal, AVCaptureDeviceTypeMicrophone];
    AVCaptureDeviceDiscoverySession *all = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types mediaType:nil
                                                                                                   position:AVCaptureDevicePositionUnspecified];
    NSMutableArray *names = [NSMutableArray array];
    for (AVCaptureDevice *d in all.devices) [names addObject:[NSString stringWithFormat:@"%@(%@)", d.localizedName ?: @"-", d.deviceType]];
    say(@"discovery all: %lu [%@]", (unsigned long)all.devices.count, [names componentsJoinedByString:@", "]);
    AVCaptureDeviceDiscoverySession *videoOnly = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types mediaType:AVMediaTypeVideo
                                                                                                         position:AVCaptureDevicePositionUnspecified];
    say(@"discovery video: %lu", (unsigned long)videoOnly.devices.count);
    if (video) {
        for (AVCaptureDeviceFormat *f in video.formats) {
            CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
            AVFrameRateRange *r = f.videoSupportedFrameRateRanges.firstObject;
            say(@"format %@ %dx%d %.0f-%.0f fps", fourcc(CMFormatDescriptionGetMediaSubType(f.formatDescription)), d.width, d.height,
                r.minFrameRate, r.maxFrameRate);
        }
        CMVideoDimensions a = CMVideoFormatDescriptionGetDimensions(video.activeFormat.formatDescription);
        say(@"active format %dx%d, min frame duration %.4f s", a.width, a.height, CMTimeGetSeconds(video.activeVideoMinFrameDuration));
    }
    say(@"system preferred: %@", AVCaptureDevice.systemPreferredCamera.localizedName ?: @"nil");
    AVCaptureSession *s = [AVCaptureSession new];
    AVCaptureVideoDataOutput *o = [AVCaptureVideoDataOutput new];
    say(@"output pixel formats: %@", o.availableVideoCVPixelFormatTypes);
    say(@"session preset %@; can add output %d", s.sessionPreset, [s canAddOutput:o]);
}

- (AVCaptureDeviceInput *)makeInput {
    AVCaptureDevice *video = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!video) {
        say(@"input: no video device");
        return nil;
    }
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:video error:&error];
    say(@"input: %@ error %@ (%ld)", input ? @"made" : @"nil", error.domain ?: @"-", (long)error.code);
    return input;
}

- (void)stream {
    // stream FMT W H SECONDS [preview] [angle A] [mirror]
    OSType format = parseFormat(self.args.count > 1 ? self.args[1] : @"420v");
    int w = self.args.count > 2 ? self.args[2].intValue : 1280, h = self.args.count > 3 ? self.args[3].intValue : 720;
    double seconds = self.args.count > 4 ? self.args[4].doubleValue : 5;
    BOOL preview = [self.args containsObject:@"preview"];
    NSUInteger ai = [self.args indexOfObject:@"angle"];
    CGFloat angle = ai != NSNotFound && ai + 1 < self.args.count ? self.args[ai + 1].doubleValue : 0;
    BOOL mirror = [self.args containsObject:@"mirror"];
    AVCaptureDeviceInput *input = [self makeInput];
    if (!input) finish(2);
    AVCaptureDevice *device = input.device;
    AVCaptureSession *s = [AVCaptureSession new];
    self.session = s;
    [s beginConfiguration];
    [s addInput:input];
    AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
    out.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(format)};
    [out setSampleBufferDelegate:self queue:dispatch_queue_create("probe.frames", DISPATCH_QUEUE_SERIAL)];
    say(@"can add output %d", [s canAddOutput:out]);
    [s addOutput:out];
    for (AVCaptureDeviceFormat *f in device.formats) {
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
        if (d.width == w && d.height == h) {
            if ([device lockForConfiguration:nil]) {
                device.activeFormat = f;
                [device unlockForConfiguration];
            }
            break;
        }
    }
    AVCaptureConnection *c = [out connectionWithMediaType:AVMediaTypeVideo];
    if (angle != 0 && [c isVideoRotationAngleSupported:angle]) c.videoRotationAngle = angle;
    if (mirror) {
        c.automaticallyAdjustsVideoMirroring = NO;
        c.videoMirrored = YES;
    }
    say(@"connection: %@ active %d angle %.0f mirrored %d; preset %@", c ? @"yes" : @"no", c.active, c.videoRotationAngle,
        c.videoMirrored, s.sessionPreset);
    [s commitConfiguration];
    if (preview) [self showPreview:s];
    [[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:s queue:nil
                                                  usingBlock:^(NSNotification *n) {
        NSError *e = n.userInfo[AVCaptureSessionErrorKey];
        say(@"runtime error %ld %@", (long)e.code, e.localizedDescription);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionDidStartRunningNotification object:s queue:nil
                                                  usingBlock:^(NSNotification *n) { say(@"did start running"); }];
    self.sizes = [NSMutableSet set];
    self.formats = [NSMutableSet set];
    self.minDelta = 1e9;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    [s startRunning];
    say(@"startRunning returned after %.3f s; running %d", CFAbsoluteTimeGetCurrent() - t0, s.running);
    self.counting = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.counting = NO;
        double span = self.lastPTS - self.firstPTS;
        say(@"frames %ld in %.2f s of time stamps (%.2f fps); dropped %ld; pts delta %.4f..%.4f s; sizes %@; formats %@",
            (long)self.frames, span, self.frames > 1 ? (self.frames - 1) / span : 0, (long)self.dropped, self.minDelta, self.maxDelta,
            [self.sizes.allObjects componentsJoinedByString:@","], [self.formats.allObjects componentsJoinedByString:@","]);
        CVPixelBufferRef pb = self.keep;
        if (pb) {
            size_t W, H;
            NSData *bgra = bgraOf(pb, &W, &H);
            const uint8_t *p = (const uint8_t *)bgra.bytes + ((H / 2) * W + W / 2) * 4;
            say(@"last frame %zux%zu center BGRA %d %d %d; IOSurface-backed %d; png %d", W, H, p[0], p[1], p[2],
                CVPixelBufferGetIOSurface(pb) != NULL, writePNG(bgra, W, H, @"/tmp/camprobe-frame.png"));
            CVPixelBufferRelease(pb);
            self.keep = NULL;
        }
        if (!preview) {
            [s stopRunning];
            say(@"stopped; running %d", s.running);
            finish(self.frames > 0 ? 0 : 1);
        }
        say(@"preview stays up");
    });
}

- (void)showPreview:(AVCaptureSession *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer layerWithSession:s];
        layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        layer.frame = self.window.rootViewController.view.bounds;
        [self.window.rootViewController.view.layer addSublayer:layer];
        self.preview = layer;
        say(@"preview layer: session %d connection %@", layer.session == s, layer.connection ? @"yes" : @"no");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            say(@"previewing %d; %lu sublayers", layer.previewing, (unsigned long)layer.sublayers.count);
        });
    });
}

- (void)previewOnly {
    double seconds = self.args.count > 1 ? self.args[1].doubleValue : 30;
    AVCaptureDeviceInput *input = [self makeInput];
    if (!input) finish(2);
    AVCaptureSession *s = [AVCaptureSession new];
    self.session = s;
    [s addInput:input];
    [self showPreview:s];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [s startRunning];
        say(@"preview session running %d", s.running);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(0); });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c {
    if (!self.counting) return;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
    if (self.frames == 0) {
        self.firstPTS = pts;
        CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
        say(@"first frame: pts %.4f, host clock now %.4f (latency %.1f ms), duration %.4f s", pts, CMTimeGetSeconds(now),
            (CMTimeGetSeconds(now) - pts) * 1000, CMTimeGetSeconds(CMSampleBufferGetDuration(sb)));
    } else {
        double d = pts - self.lastPTS;
        if (d < self.minDelta) self.minDelta = d;
        if (d > self.maxDelta) self.maxDelta = d;
    }
    self.lastPTS = pts;
    self.frames++;
    @synchronized(self) {
        [self.sizes addObject:[NSString stringWithFormat:@"%zux%zu", CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)]];
        [self.formats addObject:fourcc(CVPixelBufferGetPixelFormatType(pb))];
    }
    CVPixelBufferRef old = self.keep;
    self.keep = CVPixelBufferRetain(pb);
    if (old) CVPixelBufferRelease(old);
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c {
    if (self.counting) self.dropped++;
}

// MARK: Photo

- (void)photo {
    AVCaptureDeviceInput *input = [self makeInput];
    if (!input) finish(2);
    AVCaptureSession *s = [AVCaptureSession new];
    self.session = s;
    [s addInput:input];
    AVCapturePhotoOutput *out = [AVCapturePhotoOutput new];
    [s addOutput:out];
    say(@"photo codecs %@", out.availablePhotoCodecTypes);
    [s startRunning];
    AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey: AVVideoCodecTypeJPEG}];
    say(@"capturing photo %lld", settings.uniqueID);
    [out capturePhotoWithSettings:settings delegate:self];
}

- (void)captureOutput:(AVCapturePhotoOutput *)output willBeginCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)r {
    say(@"will begin capture %lld (%dx%d)", r.uniqueID, r.photoDimensions.width, r.photoDimensions.height);
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    NSData *data = photo.fileDataRepresentation;
    CGImageRef img = photo.CGImageRepresentation;
    BOOL written = [data writeToFile:@"/tmp/camprobe-photo.jpg" atomically:YES];
    say(@"photo: error %ld, %lu bytes JPEG (%@), CGImage %zux%zu, written %d", (long)error.code, (unsigned long)data.length,
        data.length > 2 && ((const uint8_t *)data.bytes)[0] == 0xFF && ((const uint8_t *)data.bytes)[1] == 0xD8 ? @"FF D8" : @"?",
        img ? CGImageGetWidth(img) : 0, img ? CGImageGetHeight(img) : 0, written);
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)r
                error:(NSError *)error {
    say(@"capture finished %lld error %ld", r.uniqueID, (long)error.code);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.session stopRunning];
        finish(error ? 1 : 0);
    });
}

// MARK: Picker

- (void)picker {
    say(@"picker camera available %d, rear %d, front %d, media %@",
        [UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera],
        [UIImagePickerController isCameraDeviceAvailable:UIImagePickerControllerCameraDeviceRear],
        [UIImagePickerController isCameraDeviceAvailable:UIImagePickerControllerCameraDeviceFront],
        [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIImagePickerController *p = [UIImagePickerController new];
        p.sourceType = UIImagePickerControllerSourceTypeCamera;
        p.delegate = self;
        [self.window.rootViewController presentViewController:p animated:NO completion:^{ say(@"picker presented"); }];
    });
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    say(@"picker image %.0fx%.0f", img.size.width, img.size.height);
    finish(0);
}

// MARK: Run

- (void)run {
    NSString *mode = self.args.firstObject ?: @"discover";
    say(@"mode %@ (%@)", mode, [self.args componentsJoinedByString:@" "]);
    if ([mode isEqualToString:@"discover"]) {
        [self discover];
        finish(0);
    } else if ([mode isEqualToString:@"status"]) {
        say(@"authorization %@", statusName([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]));
        finish(0);
    } else if ([mode isEqualToString:@"request"]) {
        say(@"authorization before %@", statusName([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]));
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            say(@"request answered: granted %d, status %@", granted, statusName([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]));
            finish(0);
        }];
    } else if ([mode isEqualToString:@"outputs"]) {
        // The outputs alone (no input, no session): each one's creation.
        say(@"video data output %@", [AVCaptureVideoDataOutput new] ? @"made" : @"nil");
        say(@"movie file output %@", [AVCaptureMovieFileOutput new] ? @"made" : @"nil");
        say(@"photo output %@", [AVCapturePhotoOutput new] ? @"made" : @"nil");
        finish(0);
    } else if ([mode isEqualToString:@"input"]) {
        [self makeInput];
        finish(0);
    } else if ([mode isEqualToString:@"stream"]) {
        [self stream];
    } else if ([mode isEqualToString:@"preview"]) {
        [self previewOnly];
    } else if ([mode isEqualToString:@"photo"]) {
        [self photo];
    } else if ([mode isEqualToString:@"picker"]) {
        [self picker];
    } else {
        say(@"unknown mode");
        finish(64);
    }
}
@end

// The scene life cycle (required by the iOS 27 SDK: an app without a scene
// manifest is refused at launch). Info.plist names SceneDelegate.
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) Probe *probe;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.blackColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, 360, 40)];
    label.text = @"Ycode camera probe";
    label.textColor = UIColor.whiteColor;
    [vc.view addSubview:label];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    self.probe = [Probe new];
    self.probe.window = self.window;
    NSArray *args = [NSProcessInfo processInfo].arguments;
    self.probe.args = args.count > 1 ? [args subarrayWithRange:NSMakeRange(1, args.count - 1)] : @[];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.probe run]; });
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    c.delegateClass = SceneDelegate.class;
    return c;
}
@end

int main(int argc, char *argv[]) {
    gStart = CFAbsoluteTimeGetCurrent();
    gOut = fopen("/tmp/camprobe.txt", "a");
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
