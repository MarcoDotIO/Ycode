/*
 * objcdump: list ObjC metadata (classes, superclasses, protocols, ivar names
 * and types, properties, method selectors and type encodings) of one loaded
 * image, read at run time through the public ObjC runtime API. Original Ycode
 * code. It never reads method implementations.
 * Usage: objcdump <image path> [<image path> ...]
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>

static void dump_methods(Class c, const char *kind)
{
    unsigned n = 0;
    Method *m = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++)
        printf("    %s%s  %s\n", kind, sel_getName(method_getName(m[i])), method_getTypeEncoding(m[i]));
    free(m);
}

static void dump_protocol(Protocol *p, int depth)
{
    printf("%*sprotocol %s\n", depth * 2, "", protocol_getName(p));
    unsigned n = 0;
    Protocol *__unsafe_unretained *sub = protocol_copyProtocolList(p, &n);
    for (unsigned i = 0; i < n; i++) printf("%*s  adopts %s\n", depth * 2, "", protocol_getName(sub[i]));
    free(sub);
    for (int req = 1; req >= 0; req--)
        for (int inst = 1; inst >= 0; inst--) {
            unsigned k = 0;
            struct objc_method_description *d = protocol_copyMethodDescriptionList(p, req, inst, &k);
            for (unsigned i = 0; i < k; i++)
                printf("%*s  %s%s %s  %s\n", depth * 2, "", req ? "required" : "optional", inst ? " -" : " +",
                       sel_getName(d[i].name), d[i].types);
            free(d);
        }
    unsigned pc = 0;
    objc_property_t *props = protocol_copyPropertyList(p, &pc);
    for (unsigned i = 0; i < pc; i++)
        printf("%*s  property %s  %s\n", depth * 2, "", property_getName(props[i]), property_getAttributes(props[i]));
    free(props);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        for (int a = 1; a < argc; a++) {
            void *h = dlopen(argv[a], RTLD_NOW);
            printf("== image %s handle=%p %s\n", argv[a], h, h ? "" : dlerror());
            if (!h) continue;
            /* The runtime knows the image under its resolved path: match by file name. */
            const char *base = strrchr(argv[a], '/') ? strrchr(argv[a], '/') + 1 : argv[a];
            unsigned ni = 0;
            const char **images = objc_copyImageNames(&ni);
            const char *image = argv[a];
            for (unsigned k = 0; k < ni; k++) {
                const char *b = strrchr(images[k], '/');
                if (b && !strcmp(b + 1, base)) image = images[k];
            }
            printf("   runtime image name %s\n", image);
            unsigned n = 0;
            const char **names = objc_copyClassNamesForImage(image, &n);
            for (unsigned i = 0; i < n; i++) {
                Class c = objc_getClass(names[i]);
                Class s = class_getSuperclass(c);
                printf("class %s : %s  (instance size %zu)\n", names[i], s ? class_getName(s) : "(root)",
                       class_getInstanceSize(c));
                unsigned pc = 0;
                Protocol *__unsafe_unretained *protos = class_copyProtocolList(c, &pc);
                for (unsigned j = 0; j < pc; j++) {
                    printf("  conforms ");
                    dump_protocol(protos[j], 1);
                }
                free(protos);
                unsigned ic = 0;
                Ivar *iv = class_copyIvarList(c, &ic);
                for (unsigned j = 0; j < ic; j++)
                    printf("  ivar %s  %s  @%td\n", ivar_getName(iv[j]), ivar_getTypeEncoding(iv[j]),
                           ivar_getOffset(iv[j]));
                free(iv);
                objc_property_t *props = class_copyPropertyList(c, &pc);
                for (unsigned j = 0; j < pc; j++)
                    printf("  property %s  %s\n", property_getName(props[j]), property_getAttributes(props[j]));
                free(props);
                dump_methods(object_getClass(c), "+");
                dump_methods(c, "-");
            }
            free(names);
        }
    }
    return 0;
}
