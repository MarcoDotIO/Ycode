// ARProbe: black-box probe of ARKit's public API behaviour on a simulator.
// Our own code. It calls only public ARKit/UIKit/SceneKit/SpriteKit API and
// prints one "ARPROBE ..." line per observation to stderr.
//
// Launch arguments:
//   -ui scn|sk|coach|none   which view to leave on screen after the API probes
#import <UIKit/UIKit.h>
#import <ARKit/ARKit.h>
#import <SceneKit/SceneKit.h>
#import <SpriteKit/SpriteKit.h>
#import <Metal/Metal.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <QuartzCore/QuartzCore.h>
#import <pthread.h>

static CFTimeInterval gStart;

static void P(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void P(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "ARPROBE t=%.3f %s\n", CACurrentMediaTime() - gStart, s.UTF8String);
    fflush(stderr);
}

static NSString *ThreadDesc(void) {
    const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    return [NSString stringWithFormat:@"main=%d queue=%s", [NSThread isMainThread], label ? label : "?"];
}

static NSString *ErrDesc(NSError *e) {
    if (!e) return @"nil";
    NSMutableArray *keys = [NSMutableArray array];
    for (id k in e.userInfo) [keys addObject:[k description]];
    [keys sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"domain=%@ code=%ld userInfoKeys=[%@] desc=\"%@\" reason=\"%@\" suggestion=\"%@\"",
            e.domain, (long)e.code, [keys componentsJoinedByString:@","], e.localizedDescription,
            e.localizedFailureReason ?: @"", e.localizedRecoverySuggestion ?: @""];
}

static NSString *FormatDesc(ARVideoFormat *f) {
    if (!f) return @"nil";
    return [NSString stringWithFormat:@"%.0fx%.0f@%ld pos=%ld type=%@ hdr=%d hiRes=%d",
            f.imageResolution.width, f.imageResolution.height, (long)f.framesPerSecond,
            (long)f.captureDevicePosition, f.captureDeviceType, f.isVideoHDRSupported,
            f.isRecommendedForHighResolutionFrameCapturing];
}

static NSString *TrackingDesc(ARCamera *c) {
    return [NSString stringWithFormat:@"state=%ld reason=%ld", (long)c.trackingState, (long)c.trackingStateReason];
}

#pragma mark - Session observer

@interface Obs : NSObject <ARSessionDelegate>
@property (nonatomic, copy) NSString *tag;
@property (nonatomic) NSInteger frames;
@end

@implementation Obs
- (void)session:(ARSession *)s didFailWithError:(NSError *)e {
    P(@"[%@] didFailWithError %@ %@ currentFrame=%@ configuration=%@", self.tag, ErrDesc(e), ThreadDesc(),
      s.currentFrame ? @"set" : @"nil", s.configuration ? NSStringFromClass([s.configuration class]) : @"nil");
}
- (void)session:(ARSession *)s cameraDidChangeTrackingState:(ARCamera *)c {
    P(@"[%@] cameraDidChangeTrackingState %@ %@", self.tag, TrackingDesc(c), ThreadDesc());
}
- (void)sessionWasInterrupted:(ARSession *)s { P(@"[%@] sessionWasInterrupted %@", self.tag, ThreadDesc()); }
- (void)sessionInterruptionEnded:(ARSession *)s { P(@"[%@] sessionInterruptionEnded %@", self.tag, ThreadDesc()); }
- (BOOL)sessionShouldAttemptRelocalization:(ARSession *)s {
    P(@"[%@] sessionShouldAttemptRelocalization %@", self.tag, ThreadDesc());
    return NO;
}
- (void)session:(ARSession *)s didOutputAudioSampleBuffer:(CMSampleBufferRef)b { P(@"[%@] didOutputAudioSampleBuffer", self.tag); }
- (void)session:(ARSession *)s didOutputCollaborationData:(ARCollaborationData *)d { P(@"[%@] didOutputCollaborationData", self.tag); }
- (void)session:(ARSession *)s didChangeGeoTrackingStatus:(ARGeoTrackingStatus *)st {
    P(@"[%@] didChangeGeoTrackingStatus state=%ld reason=%ld", self.tag, (long)st.state, (long)st.stateReason);
}
- (void)session:(ARSession *)s didChangeViewRotationAngle:(CGFloat)a { P(@"[%@] didChangeViewRotationAngle %f", self.tag, a); }
- (void)session:(ARSession *)s didUpdateFrame:(ARFrame *)f {
    if (self.frames++ < 3) {
        CVPixelBufferRef pb = f.capturedImage;
        P(@"[%@] didUpdateFrame ts=%f img=%zux%zu fmt=%u %@ %@", self.tag, f.timestamp, CVPixelBufferGetWidth(pb),
          CVPixelBufferGetHeight(pb), (unsigned)CVPixelBufferGetPixelFormatType(pb), TrackingDesc(f.camera), ThreadDesc());
    }
}
- (void)session:(ARSession *)s didAddAnchors:(NSArray<ARAnchor *> *)a { P(@"[%@] didAddAnchors %lu", self.tag, (unsigned long)a.count); }
- (void)session:(ARSession *)s didUpdateAnchors:(NSArray<ARAnchor *> *)a { P(@"[%@] didUpdateAnchors %lu", self.tag, (unsigned long)a.count); }
- (void)session:(ARSession *)s didRemoveAnchors:(NSArray<ARAnchor *> *)a { P(@"[%@] didRemoveAnchors %lu", self.tag, (unsigned long)a.count); }
@end

#pragma mark - Probes

static NSArray<Class> *ConfigClasses(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in @[ @"ARWorldTrackingConfiguration", @"AROrientationTrackingConfiguration", @"ARFaceTrackingConfiguration",
                           @"ARImageTrackingConfiguration", @"ARObjectScanningConfiguration", @"ARBodyTrackingConfiguration",
                           @"ARPositionalTrackingConfiguration", @"ARGeoTrackingConfiguration" ]) {
        Class c = NSClassFromString(n);
        if (c) [out addObject:c]; else P(@"class-missing %@", n);
    }
    return out;
}

static void ProbeConfigClass(Class C) {
    NSString *n = NSStringFromClass(C);
    P(@"cfg %@ isSupported=%d", n, [C isSupported]);
    @try {
        NSArray *fmts = [C supportedVideoFormats];
        P(@"cfg %@ supportedVideoFormats.count=%lu", n, (unsigned long)fmts.count);
        for (ARVideoFormat *f in fmts) P(@"cfg %@ format %@", n, FormatDesc(f));
    } @catch (NSException *ex) { P(@"cfg %@ supportedVideoFormats EXCEPTION %@: %@", n, ex.name, ex.reason); }
    for (NSNumber *sem in @[ @1, @3, @4, @8, @16 ]) {
        @try { P(@"cfg %@ supportsFrameSemantics(%@)=%d", n, sem, [C supportsFrameSemantics:sem.unsignedIntegerValue]); }
        @catch (NSException *ex) { P(@"cfg %@ supportsFrameSemantics(%@) EXCEPTION %@", n, sem, ex.reason); }
    }
    @try { P(@"cfg %@ configurableCaptureDeviceForPrimaryCamera=%@", n, [C configurableCaptureDeviceForPrimaryCamera]); }
    @catch (NSException *ex) { P(@"cfg %@ configurableCaptureDevice EXCEPTION %@", n, ex.reason); }
    @try { P(@"cfg %@ recommendedVideoFormatFor4KResolution=%@", n, FormatDesc([C recommendedVideoFormatFor4KResolution])); }
    @catch (NSException *ex) { P(@"cfg %@ rec4K EXCEPTION %@", n, ex.reason); }
    @try { P(@"cfg %@ recommendedVideoFormatForHighResolutionFrameCapturing=%@", n, FormatDesc([C recommendedVideoFormatForHighResolutionFrameCapturing])); }
    @catch (NSException *ex) { P(@"cfg %@ recHiRes EXCEPTION %@", n, ex.reason); }

    for (NSString *sel in @[ @"supportsUserFaceTracking", @"supportsAppClipCodeTracking", @"supportedNumberOfTrackedFaces", @"supportsWorldTracking" ]) {
        if ([C respondsToSelector:NSSelectorFromString(sel)]) {
            @try { P(@"cfg %@ +%@=%@", n, sel, [C valueForKey:sel]); }
            @catch (NSException *ex) { P(@"cfg %@ +%@ EXCEPTION %@", n, sel, ex.reason); }
        }
    }
    if ([C respondsToSelector:@selector(supportsSceneReconstruction:)]) {
        P(@"cfg %@ supportsSceneReconstruction(mesh)=%d (meshWithClassification)=%d", n,
          [(id)C supportsSceneReconstruction:ARSceneReconstructionMesh],
          [(id)C supportsSceneReconstruction:ARSceneReconstructionMeshWithClassification]);
    }

    ARConfiguration *cfg = nil;
    @try { cfg = [[C alloc] init]; } @catch (NSException *ex) { P(@"cfg %@ init EXCEPTION %@: %@", n, ex.name, ex.reason); return; }
    P(@"cfg %@ instance=%@", n, cfg ? @"ok" : @"nil");
    if (!cfg) return;
    @try { P(@"cfg %@ default videoFormat=%@", n, FormatDesc(cfg.videoFormat)); }
    @catch (NSException *ex) { P(@"cfg %@ videoFormat EXCEPTION %@: %@", n, ex.name, ex.reason); }
    for (NSString *key in @[ @"worldAlignment", @"lightEstimationEnabled", @"providesAudioData", @"frameSemantics", @"videoHDRAllowed",
                             @"autoFocusEnabled", @"planeDetection", @"environmentTexturing", @"wantsHDREnvironmentTextures",
                             @"maximumNumberOfTrackedImages", @"maximumNumberOfTrackedFaces", @"collaborationEnabled",
                             @"userFaceTrackingEnabled", @"sceneReconstruction", @"worldTrackingEnabled",
                             @"automaticImageScaleEstimationEnabled", @"automaticSkeletonScaleEstimationEnabled",
                             @"appClipCodeTrackingEnabled", @"environmentTexturingEnabled", @"initialWorldMap" ]) {
        @try {
            id v = [cfg valueForKey:key];
            P(@"cfg %@ default %@=%@", n, key, v ?: @"nil");
        } @catch (NSException *ex) { (void)ex; }
    }
    for (NSString *key in @[ @"detectionImages", @"trackingImages", @"detectionObjects", @"trackingObjects" ]) {
        @try { id v = [cfg valueForKey:key]; P(@"cfg %@ default %@=%@", n, key, v ? [NSString stringWithFormat:@"set(count=%lu)", (unsigned long)[v count]] : @"nil"); }
        @catch (NSException *ex) { (void)ex; }
    }
    ARConfiguration *cp = [cfg copy];
    P(@"cfg %@ copy class=%@ sameObject=%d", n, NSStringFromClass([cp class]), cp == cfg);
    P(@"cfg %@ description=%@", n, [[cfg description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
}

static void ProbeSetters(void) {
    // Write 1/YES to every scalar property and read it back: does the object store values?
    for (Class C in ConfigClasses()) {
        ARConfiguration *cfg = [[C alloc] init];
        NSMutableArray *res = [NSMutableArray array];
        for (NSString *key in @[ @"worldAlignment", @"lightEstimationEnabled", @"providesAudioData", @"videoHDRAllowed", @"autoFocusEnabled",
                                 @"planeDetection", @"environmentTexturing", @"wantsHDREnvironmentTextures", @"maximumNumberOfTrackedImages",
                                 @"maximumNumberOfTrackedFaces", @"collaborationEnabled", @"worldTrackingEnabled",
                                 @"automaticImageScaleEstimationEnabled", @"automaticSkeletonScaleEstimationEnabled", @"appClipCodeTrackingEnabled",
                                 @"environmentTexturingEnabled" ]) {
            @try {
                [cfg setValue:@1 forKey:key];
                [res addObject:[NSString stringWithFormat:@"%@=%@", key, [cfg valueForKey:key]]];
            } @catch (NSException *ex) { (void)ex; }
        }
        ARConfiguration *cp = [cfg copy];
        P(@"setters %@ %@ copy.lightEstimationEnabled=%d", NSStringFromClass(C), [res componentsJoinedByString:@" "], cp.lightEstimationEnabled);
    }
    ARImageTrackingConfiguration *it = [ARImageTrackingConfiguration new];
    it.trackingImages = [NSSet set];
    P(@"setters image trackingImages after empty set=%@", it.trackingImages ? @"set" : @"nil");
}

static void ProbeSetUnsupportedSemantics(void) {
    ARWorldTrackingConfiguration *c = [ARWorldTrackingConfiguration new];
    @try {
        c.frameSemantics = ARFrameSemanticSceneDepth;
        P(@"set-semantics sceneDepth on world config: no exception, value=%lu", (unsigned long)c.frameSemantics);
    } @catch (NSException *ex) { P(@"set-semantics sceneDepth EXCEPTION %@: %@", ex.name, ex.reason); }
    @try {
        c.sceneReconstruction = ARSceneReconstructionMesh;
        P(@"set sceneReconstruction mesh: no exception, value=%lu", (unsigned long)c.sceneReconstruction);
    } @catch (NSException *ex) { P(@"set sceneReconstruction EXCEPTION %@: %@", ex.name, ex.reason); }
    @try {
        c.userFaceTrackingEnabled = YES;
        P(@"set userFaceTrackingEnabled: no exception, value=%d", c.userFaceTrackingEnabled);
    } @catch (NSException *ex) { P(@"set userFaceTrackingEnabled EXCEPTION %@: %@", ex.name, ex.reason); }
    @try {
        c.planeDetection = ARPlaneDetectionHorizontal | ARPlaneDetectionVertical;
        c.environmentTexturing = AREnvironmentTexturingAutomatic;
        P(@"set planeDetection=%lu envTex=%ld ok", (unsigned long)c.planeDetection, (long)c.environmentTexturing);
    } @catch (NSException *ex) { P(@"set plane/env EXCEPTION %@: %@", ex.name, ex.reason); }
    @try {
        c.detectionImages = nil; // null_resettable
        P(@"detectionImages after nil=%@", c.detectionImages ? [NSString stringWithFormat:@"set(count=%lu)", (unsigned long)c.detectionImages.count] : @"nil");
    } @catch (NSException *ex) { P(@"detectionImages nil EXCEPTION %@", ex.reason); }
}

static void ProbeData(void) {
    // Anchors
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = (simd_float4){ 0.1f, 0.2f, -0.5f, 1 };
    ARAnchor *a = [[ARAnchor alloc] initWithName:@"probe" transform:m];
    P(@"anchor id=%@ name=%@ sessionIdentifier=%@ t=(%f,%f,%f)", a.identifier, a.name, a.sessionIdentifier,
      a.transform.columns[3].x, a.transform.columns[3].y, a.transform.columns[3].z);
    ARAnchor *ac = [a copy];
    P(@"anchor copy sameObject=%d sameId=%d isEqual=%d class=%@", ac == a, [ac.identifier isEqual:a.identifier], [ac isEqual:a], NSStringFromClass([ac class]));
    ARAnchor *b = [[ARAnchor alloc] initWithTransform:m];
    P(@"anchor(noname) name=%@", b.name ?: @"nil");
    NSError *err = nil;
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:a requiringSecureCoding:YES error:&err];
    P(@"anchor archive bytes=%lu err=%@", (unsigned long)d.length, ErrDesc(err));
    if (d) {
        id plist = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL];
        NSArray *objs = plist[@"$objects"];
        for (id o in objs) {
            if ([o isKindOfClass:[NSDictionary class]]) {
                NSMutableArray *ks = [NSMutableArray array];
                for (id k in o) {
                    id v = o[k];
                    NSString *vd = [v isKindOfClass:[NSData class]] ? [NSString stringWithFormat:@"<data %lu>", (unsigned long)[v length]] : [[v description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                    [ks addObject:[NSString stringWithFormat:@"%@=%@", k, vd]];
                }
                [ks sortUsingSelector:@selector(compare:)];
                P(@"anchor archive object {%@}", [ks componentsJoinedByString:@"; "]);
            } else {
                P(@"anchor archive value %@", [[o description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
            }
        }
        ARAnchor *back = [NSKeyedUnarchiver unarchivedObjectOfClass:[ARAnchor class] fromData:d error:&err];
        P(@"anchor unarchive ok=%d sameId=%d name=%@ err=%@", back != nil, [back.identifier isEqual:a.identifier], back.name, ErrDesc(err));
    }
    AREnvironmentProbeAnchor *ep = [[AREnvironmentProbeAnchor alloc] initWithTransform:m extent:(simd_float3){ 1, 1, 1 }];
    P(@"envprobe extent=(%f,%f,%f) texture=%@", ep.extent.x, ep.extent.y, ep.extent.z, ep.environmentTexture);
    AREnvironmentProbeAnchor *ep2 = [[AREnvironmentProbeAnchor alloc] initWithTransform:m];
    P(@"envprobe(initWithTransform) extent=(%f,%f,%f)", ep2.extent.x, ep2.extent.y, ep2.extent.z);
    ARGeoAnchor *g = [[ARGeoAnchor alloc] initWithCoordinate:CLLocationCoordinate2DMake(37.3349, -122.0090)];
    P(@"geoanchor coord=(%f,%f) altitude=%f altitudeSource=%ld transform.t=(%f,%f,%f) isTracked=%d", g.coordinate.latitude, g.coordinate.longitude,
      g.altitude, (long)g.altitudeSource, g.transform.columns[3].x, g.transform.columns[3].y, g.transform.columns[3].z, g.isTracked);
    ARGeoAnchor *g2 = [[ARGeoAnchor alloc] initWithCoordinate:CLLocationCoordinate2DMake(37.3349, -122.0090) altitude:10];
    P(@"geoanchor(alt) altitude=%f altitudeSource=%ld", g2.altitude, (long)g2.altitudeSource);

    // Raycast query
    ARRaycastQuery *q = [[ARRaycastQuery alloc] initWithOrigin:(simd_float3){ 0, 0, 0 } direction:(simd_float3){ 0, 0, -2 }
                                                allowingTarget:ARRaycastTargetEstimatedPlane alignment:ARRaycastTargetAlignmentAny];
    P(@"raycastquery dir=(%f,%f,%f) target=%ld align=%ld", q.direction.x, q.direction.y, q.direction.z, (long)q.target, (long)q.targetAlignment);

    // Face geometry from blend shapes
    ARFaceGeometry *fg = [[ARFaceGeometry alloc] initWithBlendShapes:@{}];
    P(@"facegeometry(neutral)=%@ vertexCount=%lu triangleCount=%lu texCount=%lu", fg ? @"ok" : @"nil", (unsigned long)fg.vertexCount,
      (unsigned long)fg.triangleCount, (unsigned long)fg.textureCoordinateCount);
    ARFaceGeometry *fg2 = [[ARFaceGeometry alloc] initWithBlendShapes:@{ ARBlendShapeLocationJawOpen : @1.0 }];
    P(@"facegeometry(jawOpen)=%@", fg2 ? @"ok" : @"nil");

    // Skeleton definitions
    for (ARSkeletonDefinition *def in @[ ARSkeletonDefinition.defaultBody3DSkeletonDefinition ?: (id)[NSNull null],
                                         ARSkeletonDefinition.defaultBody2DSkeletonDefinition ?: (id)[NSNull null] ]) {
        if ((id)def == [NSNull null]) { P(@"skeletondef nil"); continue; }
        P(@"skeletondef jointCount=%lu neutral3D=%@ rootIndex=%lu headIndex=%lu bogusIndex=%lu", (unsigned long)def.jointCount,
          def.neutralBodySkeleton3D ? @"set" : @"nil", (unsigned long)[def indexForJointName:ARSkeletonJointNameRoot],
          (unsigned long)[def indexForJointName:ARSkeletonJointNameHead], (unsigned long)[def indexForJointName:@"no_such_joint"]);
        NSMutableArray *pairs = [NSMutableArray array];
        for (NSUInteger i = 0; i < def.jointCount; i++)
            [pairs addObject:[NSString stringWithFormat:@"%lu:%@<%@", (unsigned long)i, def.jointNames[i], def.parentIndices[i]]];
        P(@"skeletondef joints %@", [pairs componentsJoinedByString:@" "]);
        ARSkeleton3D *n3 = def.neutralBodySkeleton3D;
        if (n3) {
            simd_float4x4 r = [n3 modelTransformForJointName:ARSkeletonJointNameRoot];
            simd_float4x4 h = [n3 modelTransformForJointName:ARSkeletonJointNameHead];
            simd_float4x4 lf = [n3 modelTransformForJointName:ARSkeletonJointNameLeftFoot];
            simd_float4x4 bad = [n3 modelTransformForJointName:@"no_such_joint"];
            P(@"neutral3D root=(%f,%f,%f) head=(%f,%f,%f) leftFoot=(%f,%f,%f) bogus00=%f jointCount=%lu tracked0=%d",
              r.columns[3].x, r.columns[3].y, r.columns[3].z, h.columns[3].x, h.columns[3].y, h.columns[3].z,
              lf.columns[3].x, lf.columns[3].y, lf.columns[3].z, bad.columns[0].x, (unsigned long)n3.jointCount, [n3 isJointTracked:0]);
        }
    }

    // Classification / matte generator
    P(@"ARPlaneAnchor.isClassificationSupported=%d", ARPlaneAnchor.isClassificationSupported);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    P(@"metal device=%@", dev ? dev.name : @"nil");
    if (dev) {
        @try {
            ARMatteGenerator *mg = [[ARMatteGenerator alloc] initWithDevice:dev matteResolution:ARMatteResolutionHalf];
            P(@"mattegenerator=%@", mg ? @"ok" : @"nil");
        } @catch (NSException *ex) { P(@"mattegenerator EXCEPTION %@: %@", ex.name, ex.reason); }
        SCNGeometry *sfg = [ARSCNFaceGeometry faceGeometryWithDevice:dev];
        P(@"ARSCNFaceGeometry=%@", sfg ? @"ok" : @"nil");
        SCNGeometry *spg = [ARSCNPlaneGeometry planeGeometryWithDevice:dev];
        P(@"ARSCNPlaneGeometry=%@", spg ? @"ok" : @"nil");
    }

    // Reference images
    size_t W = 256, H = 256;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, W * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    for (size_t y = 0; y < H; y += 16)
        for (size_t x = 0; x < W; x += 16) {
            CGFloat v = (((x ^ y) * 2654435761u) >> 7) % 255 / 255.0;
            CGContextSetRGBFillColor(ctx, v, 1 - v, (x * y % 7) / 7.0, 1);
            CGContextFillRect(ctx, CGRectMake(x, y, 16, 16));
        }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    ARReferenceImage *ri = [[ARReferenceImage alloc] initWithCGImage:img orientation:kCGImagePropertyOrientationUp physicalWidth:0.2];
    P(@"refimage physicalSize=%fx%f name=%@ group=%@", ri.physicalSize.width, ri.physicalSize.height, ri.name, ri.resourceGroupName);
    [ri validateWithCompletionHandler:^(NSError *e) { P(@"refimage validate err=%@ %@", ErrDesc(e), ThreadDesc()); }];
    CGContextSetRGBFillColor(ctx, 0.5, 0.5, 0.5, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, W, H));
    CGImageRef flat = CGBitmapContextCreateImage(ctx);
    ARReferenceImage *ri2 = [[ARReferenceImage alloc] initWithCGImage:flat orientation:kCGImagePropertyOrientationUp physicalWidth:0.1];
    [ri2 validateWithCompletionHandler:^(NSError *e) { P(@"refimage(flat) validate err=%@ %@", ErrDesc(e), ThreadDesc()); }];
    P(@"referenceImagesInGroupNamed(missing)=%@", [ARReferenceImage referenceImagesInGroupNamed:@"NoSuchGroup" bundle:nil]);
    CGImageRelease(img); CGImageRelease(flat); CGContextRelease(ctx); CGColorSpaceRelease(cs);

    // Reference object from a bogus archive
    NSURL *bogus = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"bogus.arobject"]];
    [[NSData dataWithBytes:"not an archive" length:14] writeToURL:bogus atomically:YES];
    err = nil;
    ARReferenceObject *ro = [[ARReferenceObject alloc] initWithArchiveURL:bogus error:&err];
    P(@"refobject(bogus)=%@ err=%@", ro ? @"ok" : @"nil", ErrDesc(err));
    err = nil;
    ro = [[ARReferenceObject alloc] initWithArchiveURL:[NSURL fileURLWithPath:@"/nonexistent.referenceobject"] error:&err];
    P(@"refobject(missing)=%@ err=%@", ro ? @"ok" : @"nil", ErrDesc(err));

    // World map from garbage
    err = nil;
    ARWorldMap *wm = [NSKeyedUnarchiver unarchivedObjectOfClass:[ARWorldMap class] fromData:[NSData dataWithBytes:"xx" length:2] error:&err];
    P(@"worldmap(garbage)=%@ err=%@", wm ? @"ok" : @"nil", ErrDesc(err));

    // Camera authorisation and devices
    P(@"AVCapture video auth=%ld audio auth=%ld defaultVideoDevice=%@", (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo],
      (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio], [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo]);
    P(@"Info NSCameraUsageDescription=%@ UIRequiredDeviceCapabilities=%@",
      [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSCameraUsageDescription"] ? @"present" : @"absent",
      [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIRequiredDeviceCapabilities"]);
}

#pragma mark - Sessions

static NSMutableArray *gKeep;

static void RunSession(NSString *tag, ARConfiguration *cfg, dispatch_queue_t q, ARSessionRunOptions opts) {
    ARSession *s = [ARSession new];
    Obs *o = [Obs new];
    o.tag = tag;
    s.delegate = o;
    if (q) s.delegateQueue = q;
    [gKeep addObject:s]; [gKeep addObject:o];
    NSUUID *before = s.identifier;
    P(@"[%@] before run identifier=%@ currentFrame=%@ configuration=%@ viewRotationAngle=%f", tag, before, s.currentFrame,
      s.configuration, s.viewRotationAngle);
    @try {
        [s runWithConfiguration:cfg options:opts];
        P(@"[%@] run returned identifierChanged=%d configuration=%@ currentFrame=%@", tag, ![s.identifier isEqual:before],
          s.configuration ? NSStringFromClass([s.configuration class]) : @"nil", s.currentFrame ? @"set" : @"nil");
    } @catch (NSException *ex) { P(@"[%@] run EXCEPTION %@: %@", tag, ex.name, ex.reason); }
}

static void SessionCallsWhileFailed(void) {
    ARSession *s = [ARSession new];
    Obs *o = [Obs new]; o.tag = @"calls"; s.delegate = o;
    [gKeep addObject:s]; [gKeep addObject:o];
    simd_float4x4 m = matrix_identity_float4x4;
    ARAnchor *a = [[ARAnchor alloc] initWithTransform:m];
    @try { [s addAnchor:a]; P(@"[calls] addAnchor (not running) ok sessionIdentifier=%@", a.sessionIdentifier); }
    @catch (NSException *ex) { P(@"[calls] addAnchor EXCEPTION %@", ex.reason); }
    @try { [s removeAnchor:a]; P(@"[calls] removeAnchor ok"); } @catch (NSException *ex) { P(@"[calls] removeAnchor EXCEPTION %@", ex.reason); }
    @try { [s setWorldOrigin:m]; P(@"[calls] setWorldOrigin ok"); } @catch (NSException *ex) { P(@"[calls] setWorldOrigin EXCEPTION %@", ex.reason); }
    @try { [s pause]; P(@"[calls] pause (never run) ok"); } @catch (NSException *ex) { P(@"[calls] pause EXCEPTION %@", ex.reason); }
    [s getCurrentWorldMapWithCompletionHandler:^(ARWorldMap *wm, NSError *e) {
        P(@"[calls] getCurrentWorldMap map=%@ err=%@ %@", wm ? @"set" : @"nil", ErrDesc(e), ThreadDesc());
    }];
    ARRaycastQuery *q = [[ARRaycastQuery alloc] initWithOrigin:(simd_float3){ 0, 0, 0 } direction:(simd_float3){ 0, -1, 0 }
                                                allowingTarget:ARRaycastTargetEstimatedPlane alignment:ARRaycastTargetAlignmentAny];
    @try { P(@"[calls] raycast results=%lu", (unsigned long)[s raycast:q].count); } @catch (NSException *ex) { P(@"[calls] raycast EXCEPTION %@", ex.reason); }
    @try {
        ARTrackedRaycast *tr = [s trackedRaycast:q updateHandler:^(NSArray *r) { P(@"[calls] trackedRaycast update %lu", (unsigned long)r.count); }];
        P(@"[calls] trackedRaycast=%@", tr ? @"object" : @"nil");
        [tr stopTracking];
    } @catch (NSException *ex) { P(@"[calls] trackedRaycast EXCEPTION %@", ex.reason); }
    [s getGeoLocationForPoint:(simd_float3){ 0, 0, 0 } completionHandler:^(CLLocationCoordinate2D c, CLLocationDistance alt, NSError *e) {
        P(@"[calls] getGeoLocationForPoint coord=(%f,%f) alt=%f err=%@ %@", c.latitude, c.longitude, alt, ErrDesc(e), ThreadDesc());
    }];
    [s captureHighResolutionFrameWithCompletion:^(ARFrame *f, NSError *e) {
        P(@"[calls] captureHighResolutionFrame frame=%@ err=%@ %@", f ? @"set" : @"nil", ErrDesc(e), ThreadDesc());
    }];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [s createReferenceObjectWithTransform:m center:(simd_float3){ 0, 0, 0 } extent:(simd_float3){ 0.2, 0.2, 0.2 }
                        completionHandler:^(ARReferenceObject *ro, NSError *e) {
                            P(@"[calls] createReferenceObject obj=%@ err=%@ %@", ro ? @"set" : @"nil", ErrDesc(e), ThreadDesc());
                        }];
#pragma clang diagnostic pop
    [ARGeoTrackingConfiguration checkAvailabilityWithCompletionHandler:^(BOOL ok, NSError *e) {
        P(@"geo checkAvailability ok=%d err=%@ %@", ok, ErrDesc(e), ThreadDesc());
    }];
    [ARGeoTrackingConfiguration checkAvailabilityAtCoordinate:CLLocationCoordinate2DMake(37.7749, -122.4194)
                                            completionHandler:^(BOOL ok, NSError *e) {
                                                P(@"geo checkAvailabilityAtCoordinate(SF) ok=%d err=%@ %@", ok, ErrDesc(e), ThreadDesc());
                                            }];
}

#pragma mark - UI

@interface SCNDel : NSObject <ARSCNViewDelegate, ARSKViewDelegate, ARCoachingOverlayViewDelegate>
@end
@implementation SCNDel
- (void)session:(ARSession *)s didFailWithError:(NSError *)e { P(@"[view] didFailWithError %@ %@", ErrDesc(e), ThreadDesc()); }
- (void)session:(ARSession *)s cameraDidChangeTrackingState:(ARCamera *)c { P(@"[view] cameraDidChangeTrackingState %@", TrackingDesc(c)); }
- (void)sessionWasInterrupted:(ARSession *)s { P(@"[view] sessionWasInterrupted"); }
- (void)coachingOverlayViewWillActivate:(ARCoachingOverlayView *)v { P(@"[coach] willActivate"); }
- (void)coachingOverlayViewDidDeactivate:(ARCoachingOverlayView *)v { P(@"[coach] didDeactivate"); }
- (void)coachingOverlayViewDidRequestSessionReset:(ARCoachingOverlayView *)v { P(@"[coach] didRequestSessionReset"); }
@end

@interface VC : UIViewController
@property (nonatomic, copy) NSString *ui;
@property (nonatomic, strong) SCNDel *del;
@end

@implementation VC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.del = [SCNDel new];
    UILabel *label = [UILabel new];
    label.text = [NSString stringWithFormat:@"ARProbe ui=%@", self.ui];
    label.textColor = UIColor.labelColor;
    label.frame = CGRectMake(20, 60, 350, 30);
    if ([self.ui isEqualToString:@"scn"]) {
        ARSCNView *v = [[ARSCNView alloc] initWithFrame:self.view.bounds];
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        v.delegate = self.del;
        v.debugOptions = ARSCNDebugOptionShowWorldOrigin | ARSCNDebugOptionShowFeaturePoints;
        v.showsStatistics = YES;
        SCNScene *scene = [SCNScene scene];
        SCNNode *box = [SCNNode nodeWithGeometry:[SCNBox boxWithWidth:0.1 height:0.1 length:0.1 chamferRadius:0]];
        box.geometry.firstMaterial.diffuse.contents = UIColor.redColor;
        box.position = SCNVector3Make(0, 0, -0.5);
        [scene.rootNode addChildNode:box];
        v.scene = scene;
        [self.view addSubview:v];
        P(@"[scn] view session=%@ session.delegate=%@ automaticallyUpdatesLighting=%d rendersCameraGrain=%d rendersMotionBlur=%d pointOfView=%@ backgroundContents=%@",
          v.session ? @"set" : @"nil", v.session.delegate, v.automaticallyUpdatesLighting, v.rendersCameraGrain, v.rendersMotionBlur,
          v.pointOfView, v.scene.background.contents);
        [v.session runWithConfiguration:[ARWorldTrackingConfiguration new]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            P(@"[scn] after 2s pointOfView=%@ currentFrame=%@ session.delegate=%@ viewRotationAngle=%f", v.pointOfView, v.session.currentFrame ? @"set" : @"nil",
              v.session.delegate, v.session.viewRotationAngle);
            ARRaycastQuery *q = [v raycastQueryFromPoint:v.center allowingTarget:ARRaycastTargetEstimatedPlane alignment:ARRaycastTargetAlignmentAny];
            P(@"[scn] raycastQueryFromPoint=%@", q ? @"query" : @"nil");
        });
    } else if ([self.ui isEqualToString:@"sk"]) {
        ARSKView *v = [[ARSKView alloc] initWithFrame:self.view.bounds];
        v.delegate = self.del;
        v.showsFPS = YES;
        [v presentScene:[SKScene sceneWithSize:self.view.bounds.size]];
        [self.view addSubview:v];
        P(@"[sk] view session=%@", v.session ? @"set" : @"nil");
        [v.session runWithConfiguration:[ARWorldTrackingConfiguration new]];
    } else if ([self.ui isEqualToString:@"coach"] || [self.ui isEqualToString:@"coachscn"]) {
        ARSCNView *v = nil;
        ARSession *s;
        if ([self.ui isEqualToString:@"coachscn"]) {
            v = [[ARSCNView alloc] initWithFrame:self.view.bounds];
            v.delegate = self.del;
            [self.view addSubview:v];
            s = v.session;
        } else {
            s = [ARSession new];
        }
        ARCoachingOverlayView *c = [[ARCoachingOverlayView alloc] initWithFrame:self.view.bounds];
        c.delegate = self.del;
        P(@"[coach] defaults goal=%ld activatesAutomatically=%d isActive=%d session=%@", (long)c.goal, c.activatesAutomatically, c.isActive, c.session);
        c.session = s;
        c.goal = ARCoachingGoalHorizontalPlane;
        [self.view addSubview:c];
        ARWorldTrackingConfiguration *cfg = [ARWorldTrackingConfiguration new];
        cfg.planeDetection = ARPlaneDetectionHorizontal;
        [s runWithConfiguration:cfg];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            P(@"[coach] after 1.5s isActive=%d hidden=%d", c.isActive, c.hidden);
            [c setActive:YES animated:NO];
            P(@"[coach] after setActive:YES isActive=%d hidden=%d", c.isActive, c.hidden);
        });
        (void)v;
    }
    [self.view addSubview:label];
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    NSString *ui = [NSUserDefaults.standardUserDefaults stringForKey:@"ui"] ?: @"none";
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    VC *vc = [VC new];
    vc.ui = ui;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    P(@"scene connected ui=%@", ui);
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    gKeep = [NSMutableArray array];
    NSString *probe = [NSUserDefaults.standardUserDefaults stringForKey:@"probe"] ?: @"all";
    P(@"BEGIN probe=%@ system=%@ %@ model=%@", probe, UIDevice.currentDevice.systemName, UIDevice.currentDevice.systemVersion, UIDevice.currentDevice.model);
    if ([probe isEqualToString:@"consts"]) {
        // String values of public constants (interop identifiers).
        P(@"const ARErrorDomain=%@ ARReferenceObjectArchiveExtension=%@", ARErrorDomain, ARReferenceObjectArchiveExtension);
        P(@"const ARSCNDebugOptionShowWorldOrigin=%llu ARSCNDebugOptionShowFeaturePoints=%llu",
          (unsigned long long)ARSCNDebugOptionShowWorldOrigin, (unsigned long long)ARSCNDebugOptionShowFeaturePoints);
        NSArray *bs = @[ ARBlendShapeLocationBrowDownLeft, ARBlendShapeLocationBrowDownRight, ARBlendShapeLocationBrowInnerUp,
            ARBlendShapeLocationBrowOuterUpLeft, ARBlendShapeLocationBrowOuterUpRight, ARBlendShapeLocationCheekPuff,
            ARBlendShapeLocationCheekSquintLeft, ARBlendShapeLocationCheekSquintRight, ARBlendShapeLocationEyeBlinkLeft,
            ARBlendShapeLocationEyeBlinkRight, ARBlendShapeLocationEyeLookDownLeft, ARBlendShapeLocationEyeLookDownRight,
            ARBlendShapeLocationEyeLookInLeft, ARBlendShapeLocationEyeLookInRight, ARBlendShapeLocationEyeLookOutLeft,
            ARBlendShapeLocationEyeLookOutRight, ARBlendShapeLocationEyeLookUpLeft, ARBlendShapeLocationEyeLookUpRight,
            ARBlendShapeLocationEyeSquintLeft, ARBlendShapeLocationEyeSquintRight, ARBlendShapeLocationEyeWideLeft,
            ARBlendShapeLocationEyeWideRight, ARBlendShapeLocationJawForward, ARBlendShapeLocationJawLeft, ARBlendShapeLocationJawOpen,
            ARBlendShapeLocationJawRight, ARBlendShapeLocationMouthClose, ARBlendShapeLocationMouthDimpleLeft,
            ARBlendShapeLocationMouthDimpleRight, ARBlendShapeLocationMouthFrownLeft, ARBlendShapeLocationMouthFrownRight,
            ARBlendShapeLocationMouthFunnel, ARBlendShapeLocationMouthLeft, ARBlendShapeLocationMouthLowerDownLeft,
            ARBlendShapeLocationMouthLowerDownRight, ARBlendShapeLocationMouthPressLeft, ARBlendShapeLocationMouthPressRight,
            ARBlendShapeLocationMouthPucker, ARBlendShapeLocationMouthRight, ARBlendShapeLocationMouthRollLower,
            ARBlendShapeLocationMouthRollUpper, ARBlendShapeLocationMouthShrugLower, ARBlendShapeLocationMouthShrugUpper,
            ARBlendShapeLocationMouthSmileLeft, ARBlendShapeLocationMouthSmileRight, ARBlendShapeLocationMouthStretchLeft,
            ARBlendShapeLocationMouthStretchRight, ARBlendShapeLocationMouthUpperUpLeft, ARBlendShapeLocationMouthUpperUpRight,
            ARBlendShapeLocationNoseSneerLeft, ARBlendShapeLocationNoseSneerRight, ARBlendShapeLocationTongueOut ];
        P(@"const blendShapes count=%lu values=%@", (unsigned long)bs.count, [bs componentsJoinedByString:@","]);
        P(@"const joints root=%@ head=%@ leftHand=%@ rightHand=%@ leftFoot=%@ rightFoot=%@ leftShoulder=%@ rightShoulder=%@",
          ARSkeletonJointNameRoot, ARSkeletonJointNameHead, ARSkeletonJointNameLeftHand, ARSkeletonJointNameRightHand,
          ARSkeletonJointNameLeftFoot, ARSkeletonJointNameRightFoot, ARSkeletonJointNameLeftShoulder, ARSkeletonJointNameRightShoulder);
        P(@"const ARSkeletonJointNameForRecognizedPointKey(head)=%@", ARSkeletonJointNameForRecognizedPointKey(@"head_joint"));
        // Byte layout of the archived transform: rotation about z by 90 degrees plus a translation.
        simd_float4x4 m = matrix_identity_float4x4;
        m.columns[0] = (simd_float4){ 0, 1, 0, 0 };
        m.columns[1] = (simd_float4){ -1, 0, 0, 0 };
        m.columns[3] = (simd_float4){ 0.1f, 0.2f, -0.5f, 1 };
        ARAnchor *a = [[ARAnchor alloc] initWithTransform:m];
        NSData *d = [NSKeyedArchiver archivedDataWithRootObject:a requiringSecureCoding:YES error:NULL];
        NSDictionary *pl = [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL];
        for (id o in pl[@"$objects"]) {
            if (![o isKindOfClass:[NSDictionary class]]) continue;
            for (NSString *k in @[ @"transform", @"referenceTransform" ]) {
                NSData *t = o[k];
                if (![t isKindOfClass:[NSData class]] || t.length != 64) continue;
                const float *f = t.bytes;
                NSMutableArray *fs = [NSMutableArray array];
                for (int i = 0; i < 16; i++) [fs addObject:[NSString stringWithFormat:@"%g", f[i]]];
                P(@"const archived %@ floats=[%@]", k, [fs componentsJoinedByString:@" "]);
            }
            if (o[@"name"]) P(@"const archived name entry for unnamed anchor=%@", o[@"name"]);
        }
        P(@"END-OF-SCRIPT");
    }
    if ([probe isEqualToString:@"all"]) {
        for (Class C in ConfigClasses()) ProbeConfigClass(C);
        ProbeSetUnsupportedSemantics();
        ProbeSetters();
        ProbeData();
        // Sessions: default world tracking on main queue, every configuration, a custom queue, reruns.
        RunSession(@"world-main", [ARWorldTrackingConfiguration new], nil, 0);
        int i = 0;
        for (Class C in ConfigClasses()) {
            ARConfiguration *cfg = nil;
            @try { cfg = [[C alloc] init]; } @catch (NSException *ex) { continue; }
            RunSession([NSString stringWithFormat:@"run-%d-%@", i++, NSStringFromClass(C)], cfg, nil, 0);
        }
        dispatch_queue_t q = dispatch_queue_create("dev.ycode.arprobe.delegate", DISPATCH_QUEUE_SERIAL);
        RunSession(@"world-customqueue", [ARWorldTrackingConfiguration new], q, 0);
        RunSession(@"world-reset", [ARWorldTrackingConfiguration new], nil, ARSessionRunOptionResetTracking | ARSessionRunOptionRemoveExistingAnchors);
        ARWorldTrackingConfiguration *sem = [ARWorldTrackingConfiguration new];
        @try { sem.frameSemantics = ARFrameSemanticSceneDepth; RunSession(@"world-scenedepth", sem, nil, 0); }
        @catch (NSException *ex) { P(@"world-scenedepth EXCEPTION %@", ex.reason); }
        SessionCallsWhileFailed();
        // Re-run the first session after failure, then pause.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            ARSession *s = gKeep.firstObject;
            P(@"[world-main] after 2s currentFrame=%@ configuration=%@", s.currentFrame ? @"set" : @"nil",
              s.configuration ? NSStringFromClass([s.configuration class]) : @"nil");
            [s runWithConfiguration:[AROrientationTrackingConfiguration new]];
            P(@"[world-main] re-run with orientation returned");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [s pause];
                P(@"[world-main] paused; END-OF-SCRIPT");
            });
        });
    }
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = [SceneDelegate class];
    return c;
}
@end

int main(int argc, char *argv[]) {
    gStart = CACurrentMediaTime();
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
