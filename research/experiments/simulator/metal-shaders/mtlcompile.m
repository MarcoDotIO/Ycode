// mtlcompile.m: Ycode R8 tool (ours). Compiles a Metal source file with
// the system Metal framework's run-time compiler (public API only) and
// writes the result as a .metallib through MTLDynamicLibrary
// -serializeToURL:error:. Used before the offline Metal toolchain was
// installed; the output is a metallib of our own shaders (section 2.8).
//
// Build: clang -fobjc-arc -framework Metal -framework Foundation \
//          mtlcompile.m -o <out>/mtlcompile
// Usage: mtlcompile IN.metal OUT.metallib [installName]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: %s in.metal out.metallib [installName]\n", argv[0]); return 2; }
        NSError *err = nil;
        NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&err];
        if (!src) { fprintf(stderr, "read: %s\n", err.description.UTF8String); return 1; }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        MTLCompileOptions *opt = [MTLCompileOptions new];
        opt.libraryType = MTLLibraryTypeDynamic;
        opt.installName = argc > 3 ? @(argv[3]) : [@"@executable_path/" stringByAppendingString:@(argv[2]).lastPathComponent];
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:opt error:&err];
        if (!lib) { fprintf(stderr, "compile: %s\n", err.description.UTF8String); return 1; }
        for (NSString *n in lib.functionNames) printf("function %s\n", n.UTF8String);
        id<MTLDynamicLibrary> dl = [dev newDynamicLibrary:lib error:&err];
        if (!dl) { fprintf(stderr, "dynamic: %s\n", err.description.UTF8String); return 1; }
        if (![dl serializeToURL:[NSURL fileURLWithPath:@(argv[2])] error:&err]) {
            fprintf(stderr, "serialize: %s\n", err.description.UTF8String); return 1;
        }
        printf("wrote %s\n", argv[2]);
    }
    return 0;
}
