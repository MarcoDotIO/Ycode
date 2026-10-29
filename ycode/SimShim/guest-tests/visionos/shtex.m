// shtex: a shared Metal texture in Ycode's guest (visionos.md §10.9, round
// R2b). Creates a shared texture the way wakeboardd's compositor does
// (newSharedTextureWithDescriptor:), prints what the guest device says the
// texture's IOSurface should carry (copyIOSurfaceSharedTextureProperties:,
// an SPI the guest driver answers itself), the surface's creation
// properties, and whether a shared texture handle can be made and opened.
// Ycode's own probe, public and runtime APIs only.
//   shtex <output file>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <stdio.h>

static FILE *out;
static void say(NSString *s) {
    fprintf(out, "%s\n", s.UTF8String);
    fflush(out);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        out = argc > 1 ? fopen(argv[1], "w") : stdout;
        if (!out) return 73;
        CFStringRef *key = dlsym(RTLD_DEFAULT, "kIOSurfaceMetalSharedTexture");
        say([NSString stringWithFormat:@"kIOSurfaceMetalSharedTexture = %@", key ? (__bridge NSString *)*key : @"(missing)"]);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        say([NSString stringWithFormat:@"device %@ registryID 0x%llx", device.name, device.registryID]);
        // Which value of the creation property makes a handle: surfaces made
        // here with candidate values, then -[MTLSharedTextureHandle
        // initWithIOSurface:label:] (by selector).
        say(@"candidates");
        NSArray *candidates = @[
            @(device.registryID), @{@"registryID": @(device.registryID)}, @YES,
        ];
        Class handleClass = NSClassFromString(@"MTLSharedTextureHandle");
        SEL initSel = NSSelectorFromString(@"initWithIOSurface:label:");
        say([NSString stringWithFormat:@"handle class %@", handleClass]);
        for (id c in candidates) {
            say([NSString stringWithFormat:@"candidate %@", c]);
            NSMutableDictionary *p = [@{(id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @64, (id)kIOSurfaceBytesPerElement: @4,
                                        (id)kIOSurfacePixelFormat: @(0x42475241)} mutableCopy];
            if (c != [NSNull null] && key) p[(__bridge NSString *)*key] = c;
            IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)p);
            say([NSString stringWithFormat:@"  surface %u", s ? IOSurfaceGetID(s) : 0]);
            id h = s && handleClass ? ((id (*)(id, SEL, IOSurfaceRef, id))objc_msgSend)([handleClass alloc], initSel, s, @"probe") : nil;
            say([NSString stringWithFormat:@"candidate %@ -> surface %u handle %@", c, s ? IOSurfaceGetID(s) : 0,
                                           h ? [h description] : @"nil"]);
            if (h) {
                id<MTLTexture> t2 = ((id (*)(id, SEL, id))objc_msgSend)(device, NSSelectorFromString(@"newSharedTextureWithHandle:"), h);
                say([NSString stringWithFormat:@"  newSharedTextureWithHandle: %@", t2 ? @"texture" : @"nil"]);
            }
            if (s) CFRelease(s);
        }
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                     width:3840 height:2160 mipmapped:NO];
        d.textureType = MTLTextureType2DArray;
        d.arrayLength = 1;
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        d.storageMode = MTLStorageModePrivate;
        SEL props = NSSelectorFromString(@"copyIOSurfaceSharedTextureProperties:");
        if ([(id)device respondsToSelector:props]) {
            id p = ((id (*)(id, SEL, id))objc_msgSend)(device, props, d);
            say([NSString stringWithFormat:@"copyIOSurfaceSharedTextureProperties: %@", p]);
        } else {
            say(@"copyIOSurfaceSharedTextureProperties: not implemented");
        }
        // (The shared-texture API is marked unavailable in the visionOS SDK
        // headers; the system processes use it, so it is called by selector.)
        id<MTLTexture> t = ((id (*)(id, SEL, id))objc_msgSend)(device, NSSelectorFromString(@"newSharedTextureWithDescriptor:"), d);
        say([NSString stringWithFormat:@"newSharedTextureWithDescriptor: %@", t ? @"texture" : @"nil"]);
        if (!t) return 0;
        IOSurfaceRef s = t.iosurface;
        say([NSString stringWithFormat:@"iosurface %p id %u", s, s ? IOSurfaceGetID(s) : 0]);
        if (s) {
            CFTypeRef cp = IOSurfaceCopyValue(s, CFSTR("CreationProperties"));
            say([NSString stringWithFormat:@"CreationProperties %@", (__bridge id)cp]);
            if (cp) CFRelease(cp);
        }
        id h = ((id (*)(id, SEL))objc_msgSend)(t, NSSelectorFromString(@"newSharedTextureHandle"));
        say([NSString stringWithFormat:@"newSharedTextureHandle: %@", h ? h : @"nil"]);
        if (h) {
            id<MTLTexture> t2 = ((id (*)(id, SEL, id))objc_msgSend)(device, NSSelectorFromString(@"newSharedTextureWithHandle:"), h);
            say([NSString stringWithFormat:@"newSharedTextureWithHandle: %@", t2 ? @"texture" : @"nil"]);
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:h requiringSecureCoding:YES error:nil];
            say([NSString stringWithFormat:@"archived handle: %lu bytes", (unsigned long)data.length]);
        }
    }
    return 0;
}
