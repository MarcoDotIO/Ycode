import Foundation
import YcodePlist
import YcodeProject

// Frameworks, libraries, tools, bundles, app extensions, drivers,
// packages and the Other tab (`templates.md` § "Catalog by template").
// Texts are Ycode's own; product types, settings and plist keys are the
// spec's interop facts.

extension ProjectGenerator {
    // MARK: Frameworks and libraries

    static func docc(_ c: GenContext, folder: String) -> [(String, String)] {
        [("\(folder)/\(c.t).docc/\(c.t).md", "# ``\(c.t)``\n\nAn overview of \(c.n).\n\n## Topics\n\n### Getting Started\n\n- <doc:\(c.t)>\n")]
    }

    static func librarySwift(_ c: GenContext) -> String {
        "/// \(c.n)'s public interface.\npublic struct \(c.t) {\n    public init() {}\n\n    /// A greeting from the library.\n    public func greeting() -> String {\n        \"Hello from \(c.lit)\"\n    }\n}\n"
    }

    /// The Framework block.
    static func framework(_ c: GenContext) throws -> GeneratedProject {
        let sdk = c.sdk, n = c.n
        var s: [(String, PlistValue)] = [
            ("PRODUCT_NAME", "$(TARGET_NAME:c99extidentifier)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string(c.bundleID)), ("GENERATE_INFOPLIST_FILE", "YES"),
            ("INSTALL_PATH", "$(LOCAL_LIBRARY_DIR)/Frameworks"), ("SKIP_INSTALL", "YES"), ("DYLIB_COMPATIBILITY_VERSION", "1"),
            ("DYLIB_CURRENT_VERSION", "1"), ("DYLIB_INSTALL_NAME_BASE", "@rpath"), ("ENABLE_MODULE_VERIFIER", "YES"),
            ("MODULE_VERIFIER_SUPPORTED_LANGUAGES", "objective-c objective-c++"), ("MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS", "gnu17 gnu++20"),
            ("INFOPLIST_KEY_NSHumanReadableCopyright", .string(c.copyright)), ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        ]
        s.append(("LD_RUNPATH_SEARCH_PATHS", sdk.sdkroot == "macosx" ? ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/Frameworks"]
                  : ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]))
        if c.objc { s.append(("DEFINES_MODULE", "YES")) } else {
            s += [("BUILD_LIBRARY_FOR_DISTRIBUTION", "YES"), ("SWIFT_INSTALL_MODULE", "YES"), ("SWIFT_INSTALL_OBJC_HEADER", "NO")]
        }
        switch sdk.sdkroot {
        case "auto":
            s += [("SDKROOT", "auto"), ("SUPPORTED_PLATFORMS", .string(TemplateSDK.multiplatform.supportedPlatforms)), ("TARGETED_DEVICE_FAMILY", "1,2,7"),
                  ("ALLOW_TARGET_PLATFORM_SPECIALIZATION", "YES"), ("LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]", ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/Frameworks"])]
            s += TemplateSDK.multiplatform.platformRow
        case "xros": s += [("TARGETED_DEVICE_FAMILY", "7"), ("SUPPORTED_PLATFORMS", "xros xrsimulator")]
        default: if let f = sdk.deviceFamily { s.append(("TARGETED_DEVICE_FAMILY", .string(f))) }
        }
        var files: [(String, String)] = c.objc
            ? [("\(n)/\(c.t).h", "#import <Foundation/Foundation.h>\n\n//! The project version number of \(c.t.replacingOccurrences(of: "*/", with: "")).\nFOUNDATION_EXPORT double \(c.t)VersionNumber;\n\n//! The project version string.\nFOUNDATION_EXPORT const unsigned char \(c.t)VersionString[];\n")]
            : [("\(n)/\(c.t).swift", librarySwift(c))]
        if sdk.sdkroot == "driverkit" {
            files = [("\(n)/\(c.t).h", "#ifndef \(c.t)_h\n#define \(c.t)_h\n\n#include <DriverKit/DriverKit.h>\n\n#endif\n")]
        }
        if c.on(TemplateOptionID.hasDocumentation) { files += docc(c, folder: n) }
        var target = ProjectRecipe.Target(name: n, productType: "com.apple.product-type.framework", productPath: "\(n).framework",
                                          productFileType: "wrapper.framework", folders: [n], settings: s,
                                          phases: ["PBXHeadersBuildPhase", "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"])
        if c.objc || sdk.sdkroot == "driverkit" { target.swiftVersion = nil }
        let tt = tests(c, host: n, hostSettings: s, hostIsApp: false, ui: false)
        var r = try recipe(c, [target] + tt.targets, files + tt.files, entry: files.first?.0, swift: !c.objc)
        try addProjectSettings(&r, [("VERSIONING_SYSTEM", "apple-generic"), ("CURRENT_PROJECT_VERSION", "1"), ("VERSION_INFO_PREFIX", "")])
        return r
    }

    /// Adds settings to both project configurations of a generated project.
    static func addProjectSettings(_ g: inout GeneratedProject, _ extra: [(String, PlistValue)]) throws {
        guard var p = g.project else { return }
        for cfg in p.buildConfigurations(listID: p.project?.string("buildConfigurationList")) {
            var o = cfg
            var bs = o["buildSettings"]?.dictionary ?? PlistDictionary()
            for (k, v) in extra { bs[k] = v }
            o["buildSettings"] = .dictionary(PlistDictionary(bs.keys.sorted().map { ($0, bs[$0]!) }))
            p[cfg.id] = o
        }
        g.project = p
    }

    /// The Static library block.
    static func staticLibrary(_ c: GenContext) throws -> GeneratedProject {
        let n = c.n
        var s: [(String, PlistValue)] = [("PRODUCT_NAME", "$(TARGET_NAME)"), ("OTHER_LDFLAGS", "-ObjC"), ("SKIP_INSTALL", "YES")]
        if c.sdk.sdkroot == "xros" { s += [("TARGETED_DEVICE_FAMILY", "7"), ("SUPPORTED_PLATFORMS", "xros xrsimulator")] }
        else if let f = c.sdk.deviceFamily { s.append(("TARGETED_DEVICE_FAMILY", .string(f))) }
        let files: [(String, String)] = c.objc
            ? [("\(n)/\(c.t).h", "#import <Foundation/Foundation.h>\n\n@interface \(c.t) : NSObject\n- (NSString *)greeting;\n@end\n"),
               ("\(n)/\(c.t).m", "#import \"\(c.t).h\"\n\n@implementation \(c.t)\n\n- (NSString *)greeting {\n    return @\"Hello from \(c.lit)\";\n}\n\n@end\n")]
            : [("\(n)/\(c.t).swift", librarySwift(c))]
        var target = ProjectRecipe.Target(name: n, productType: "com.apple.product-type.library.static", productPath: "lib\(n).a",
                                          productFileType: "archive.ar", folders: [n], settings: s, phases: ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase"],
                                          copyPhases: [.init(subfolderSpec: "16", path: "include/$(PRODUCT_NAME)")])
        if c.objc { target.swiftVersion = nil }
        let tt = tests(c, host: n, hostSettings: s, hostIsApp: false, ui: false)
        return try recipe(c, [target] + tt.targets, files + tt.files, entry: files.last?.0, swift: !c.objc)
    }

    /// macOS ▸ Library.
    static func macLibrary(_ c: GenContext) throws -> GeneratedProject {
        let n = c.n, t = c.t
        let dynamic = c.option(TemplateOptionID.libraryType) == "Dynamic"
        var s: [(String, PlistValue)] = [("PRODUCT_NAME", "$(TARGET_NAME)"), ("EXECUTABLE_PREFIX", "lib"), ("SKIP_INSTALL", "YES")]
        if dynamic { s += [("DYLIB_COMPATIBILITY_VERSION", "1"), ("DYLIB_CURRENT_VERSION", "1")] }
        var files: [(String, String)] = []
        switch c.option(TemplateOptionID.libraryFramework) {
        case "Cocoa":
            files = [("\(n)/\(t).h", "#import <Cocoa/Cocoa.h>\n\n@interface \(t) : NSObject\n- (NSString *)greeting;\n@end\n"),
                     ("\(n)/\(t).m", "#import \"\(t).h\"\n\n@implementation \(t)\n\n- (NSString *)greeting {\n    return @\"Hello from \(c.lit)\";\n}\n\n@end\n")]
        case "STL":
            files = [("\(n)/\(t).hpp", "#ifndef \(t)_\n#define \(t)_\n\n#pragma GCC visibility push(default)\n\nclass \(t) {\npublic:\n    void greet(const char *name);\n};\n\n#pragma GCC visibility pop\n#endif\n"),
                     ("\(n)/\(t)Priv.hpp", "#ifndef \(t)Priv_\n#define \(t)Priv_\n\n#pragma GCC visibility push(hidden)\n\nclass \(t)Priv {\npublic:\n    void greet(const char *name);\n};\n\n#pragma GCC visibility pop\n#endif\n"),
                     ("\(n)/\(t).cpp", "#include <iostream>\n#include \"\(t).hpp\"\n#include \"\(t)Priv.hpp\"\n\nvoid \(t)::greet(const char *name) {\n    \(t)Priv().greet(name);\n}\n\nvoid \(t)Priv::greet(const char *name) {\n    std::cout << \"Hello, \" << name << std::endl;\n}\n")]
            s += [("GCC_ENABLE_CPP_EXCEPTIONS", "YES"), ("GCC_ENABLE_CPP_RTTI", "YES"), ("GCC_SYMBOLS_PRIVATE_EXTERN", "YES")]
        default: break
        }
        var target = ProjectRecipe.Target(name: n, productType: dynamic ? "com.apple.product-type.library.dynamic" : "com.apple.product-type.library.static",
                                          productPath: dynamic ? "lib\(n).dylib" : "lib\(n).a", productFileType: dynamic ? "compiled.mach-o.dylib" : "archive.ar",
                                          folders: files.isEmpty ? [] : [n], settings: s,
                                          phases: ["PBXHeadersBuildPhase", "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase"])
        target.swiftVersion = nil
        return try recipe(c, [target], files, entry: files.last?.0, swift: false)
    }

    /// DriverKit ▸ Library.
    static func driverKitLibrary(_ c: GenContext) throws -> GeneratedProject {
        let dynamic = c.option(TemplateOptionID.libraryType) == "Dynamic"
        var target = ProjectRecipe.Target(name: c.n, productType: dynamic ? "com.apple.product-type.library.dynamic" : "com.apple.product-type.library.static",
                                          productPath: dynamic ? "lib\(c.n).dylib" : "lib\(c.n).a", productFileType: dynamic ? "compiled.mach-o.dylib" : "archive.ar",
                                          folders: [], settings: [("PRODUCT_NAME", "$(TARGET_NAME)"), ("EXECUTABLE_PREFIX", "lib"), ("SKIP_INSTALL", "YES")],
                                          phases: ["PBXHeadersBuildPhase", "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase"])
        target.swiftVersion = nil
        return try recipe(c, [target], [], swift: false)
    }

    /// The Metal Library block.
    static func metalLibrary(_ c: GenContext) throws -> GeneratedProject {
        var target = ProjectRecipe.Target(name: c.n, productType: "com.apple.product-type.metal-library", productPath: "\(c.n).metallib",
                                          productFileType: "archive.metal-library", folders: [c.n], settings: [("PRODUCT_NAME", "$(TARGET_NAME)")],
                                          phases: ["PBXSourcesBuildPhase"])
        target.swiftVersion = nil
        let shader = """
        #include <metal_stdlib>
        using namespace metal;

        /// Scales every element of a buffer by a factor.
        kernel void scale(device float *values [[buffer(0)]],
                          constant float &factor [[buffer(1)]],
                          uint index [[thread_position_in_grid]]) {
            values[index] *= factor;
        }

        """
        return try recipe(c, [target], [("\(c.n)/\(c.t).metal", shader)], entry: "\(c.n)/\(c.t).metal")
    }

    // MARK: macOS bundles and tools

    static func bundle(_ c: GenContext) throws -> GeneratedProject {
        let ext = c.option(TemplateOptionID.bundleExtension).isEmpty ? "bundle" : c.option(TemplateOptionID.bundleExtension)
        var target = ProjectRecipe.Target(name: c.n, productType: "com.apple.product-type.bundle", productPath: "\(c.n).\(ext)", productFileType: "wrapper.cfbundle",
                                          folders: [], settings: [("PRODUCT_NAME", "$(TARGET_NAME)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string(c.bundleID)),
                                                                  ("GENERATE_INFOPLIST_FILE", "YES"), ("WRAPPER_EXTENSION", .string(ext)),
                                                                  ("INSTALL_PATH", "$(LOCAL_LIBRARY_DIR)/Bundles"), ("INFOPLIST_KEY_NSPrincipalClass", ""),
                                                                  ("SKIP_INSTALL", "YES"), ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1")])
        target.swiftVersion = nil
        return try recipe(c, [target], [], swift: false)
    }

    static func commandLineTool(_ c: GenContext) throws -> GeneratedProject {
        let language = c.option(TemplateOptionID.language)
        let file: (String, String)
        switch language {
        case "Objective-C":
            file = ("main.m", "#import <Foundation/Foundation.h>\n\nint main(int argc, const char *argv[]) {\n    @autoreleasepool {\n        NSLog(@\"Hello from %@\", @\"\(c.lit)\");\n    }\n    return 0;\n}\n")
        case "C++":
            file = ("main.cpp", "#include <iostream>\n\nint main(int argc, const char *argv[]) {\n    std::cout << \"Hello from \(c.lit)\" << std::endl;\n    return 0;\n}\n")
        case "C":
            file = ("main.c", "#include <stdio.h>\n\nint main(int argc, const char *argv[]) {\n    printf(\"Hello from \(c.lit)\\n\");\n    return 0;\n}\n")
        default:
            file = ("main.swift", "print(\"Hello from \(c.lit)\")\n")
        }
        var target = ProjectRecipe.Target(name: c.n, productType: "com.apple.product-type.tool", productPath: c.n, productFileType: "compiled.mach-o.executable",
                                          folders: [c.n], settings: [("PRODUCT_NAME", "$(TARGET_NAME)"), ("ENABLE_HARDENED_RUNTIME", "YES")],
                                          phases: ["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase"],
                                          copyPhases: [.init(subfolderSpec: "0", path: "/usr/share/man/man1/", deploymentOnly: true)])
        if language != "Swift" { target.swiftVersion = nil }
        return try recipe(c, [target], [("\(c.n)/\(file.0)", file.1)], entry: "\(c.n)/\(file.0)", swift: language == "Swift")
    }

    static func xpcService(_ c: GenContext) throws -> GeneratedProject {
        let n = c.n, t = c.t
        let high = c.option(TemplateOptionID.apiLevel) != "Low Level"
        var files: [(String, String)] = [("\(n)/Info.plist", infoPlist([("XPCService", pd([("ServiceType", .string("Application"))]))]))]
        if high {
            files += [
                ("\(n)/\(t)Protocol.swift", "import Foundation\n\n/// What the service offers its clients.\n@objc protocol \(t)Protocol {\n    func uppercase(_ text: String, reply: @escaping (String) -> Void)\n}\n"),
                ("\(n)/\(t).swift", "import Foundation\n\n/// The service's implementation of its protocol.\nfinal class \(t): NSObject, \(t)Protocol {\n    @objc func uppercase(_ text: String, reply: @escaping (String) -> Void) {\n        reply(text.uppercased())\n    }\n}\n"),
                ("\(n)/main.swift", """
                import Foundation

                /// Accepts every connection and exports the service object.
                final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
                    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
                        connection.exportedInterface = NSXPCInterface(with: \(t)Protocol.self)
                        connection.exportedObject = \(t)()
                        connection.resume()
                        return true
                    }
                }

                let delegate = ServiceDelegate()
                let listener = NSXPCListener.service()
                listener.delegate = delegate
                listener.resume()

                """),
            ]
        } else {
            files += [
                ("\(n)/\(t)Types.swift", "import Foundation\n\n/// The message keys the service understands.\nenum \(t)Key {\n    static let text = \"text\"\n    static let reply = \"reply\"\n}\n"),
                ("\(n)/main.swift", """
                import Foundation
                import XPC

                /// Answers each message with its "text" in upper case.
                xpc_main { connection in
                    xpc_connection_set_event_handler(connection) { event in
                        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY, let remote = xpc_dictionary_get_remote_connection(event),
                              let reply = xpc_dictionary_create_reply(event) else { return }
                        let text = xpc_dictionary_get_string(event, \(t)Key.text).map { String(cString: $0) } ?? ""
                        xpc_dictionary_set_string(reply, \(t)Key.reply, text.uppercased())
                        xpc_connection_send_message(remote, reply)
                    }
                    xpc_connection_activate(connection)
                }

                """),
            ]
        }
        let target = ProjectRecipe.Target(name: n, productType: "com.apple.product-type.xpc-service", productPath: "\(n).xpc", productFileType: "wrapper.xpc-service",
                                          folders: [n], exceptions: ["Info.plist"],
                                          settings: [("PRODUCT_NAME", "$(TARGET_NAME)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string(c.bundleID)),
                                                     ("GENERATE_INFOPLIST_FILE", "YES"), ("INFOPLIST_FILE", .string("\(n)/Info.plist")), ("ENABLE_APP_SANDBOX", "YES"),
                                                     ("SKIP_INSTALL", "YES"), ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1")])
        return try recipe(c, [target], files, entry: "\(n)/main.swift")
    }

    static func kernelExtension(_ c: GenContext, iokit: Bool) throws -> GeneratedProject {
        let n = c.n, t = c.t
        var files: [(String, String)]
        var plist: [(String, PropertyListItem)] = [("OSBundleLibraries", pd([("com.apple.kpi.libkern", .string("8.0"))] +
                                                                           (iokit ? [("com.apple.kpi.iokit", .string("8.0"))] : [("com.apple.kpi.mach", .string("8.0"))])))]
        var settings: [(String, PlistValue)] = [("PRODUCT_NAME", "$(TARGET_NAME)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string(c.bundleID)),
                                                ("GENERATE_INFOPLIST_FILE", "YES"), ("INFOPLIST_FILE", .string("\(n)/Info.plist")), ("WRAPPER_EXTENSION", "kext"),
                                                ("MACOSX_DEPLOYMENT_TARGET", .string(TemplateSDK.version("MACOSX_DEPLOYMENT_TARGET"))),
                                                ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1"), ("MODULE_VERSION", "1.0.0d1")]
        if iokit {
            files = [("\(n)/\(t).hpp", "#include <IOKit/IOService.h>\n\nclass \(t) : public IOService {\n    OSDeclareDefaultStructors(\(t))\npublic:\n    bool start(IOService *provider) override;\n    void stop(IOService *provider) override;\n};\n"),
                     ("\(n)/\(t).cpp", "#include <IOKit/IOLib.h>\n#include \"\(t).hpp\"\n\nOSDefineMetaClassAndStructors(\(t), IOService)\n\nbool \(t)::start(IOService *provider) {\n    IOLog(\"\(t) started\\n\");\n    return IOService::start(provider);\n}\n\nvoid \(t)::stop(IOService *provider) {\n    IOLog(\"\(t) stopped\\n\");\n    IOService::stop(provider);\n}\n")]
            plist.insert(("IOKitPersonalities", pd([(t, pd([("CFBundleIdentifier", .string("$(PRODUCT_BUNDLE_IDENTIFIER)")), ("IOClass", .string(t)),
                                                          ("IOMatchCategory", .string(t)), ("IOProviderClass", .string("IOResources")),
                                                          ("IOResourceMatch", .string("IOKit"))]))])), at: 0)
        } else {
            files = [("\(n)/\(t).c", "#include <mach/mach_types.h>\n#include <libkern/libkern.h>\n\nkern_return_t \(t)_start(kmod_info_t *ki, void *d);\nkern_return_t \(t)_stop(kmod_info_t *ki, void *d);\n\nkern_return_t \(t)_start(kmod_info_t *ki, void *d) {\n    printf(\"\(t) started\\n\");\n    return KERN_SUCCESS;\n}\n\nkern_return_t \(t)_stop(kmod_info_t *ki, void *d) {\n    printf(\"\(t) stopped\\n\");\n    return KERN_SUCCESS;\n}\n")]
            settings += [("MODULE_NAME", .string(c.bundleID)), ("MODULE_START", .string("\(t)_start")), ("MODULE_STOP", .string("\(t)_stop"))]
        }
        files.append(("\(n)/Info.plist", infoPlist(plist)))
        var target = ProjectRecipe.Target(name: n, productType: "com.apple.product-type.kernel-extension", productPath: "\(n).kext", productFileType: "wrapper.kernel-extension",
                                          folders: [n], exceptions: ["Info.plist"], settings: settings,
                                          phases: ["PBXHeadersBuildPhase", "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"])
        target.swiftVersion = nil
        return try recipe(c, [target], files, entry: files[files.count - 2].0, swift: false)
    }

    /// A bundle with an Objective-C principal class (and XIB).
    static func objcBundle(_ c: GenContext, name: String, wrapper: String, install: String, principal: String, base: String, imports: String,
                           settings extra: [(String, PlistValue)], files more: [(String, String)], body: String = "") throws -> GeneratedProject {
        let n = c.n
        let files: [(String, String)] = [
            ("\(n)/\(principal).h", "\(imports)\n\n@interface \(principal) : \(base)\n@end\n"),
            ("\(n)/\(principal).m", "#import \"\(principal).h\"\n\n@implementation \(principal)\n\(body)@end\n"),
        ] + more
        var s: [(String, PlistValue)] = [("PRODUCT_NAME", "$(TARGET_NAME)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string(c.bundleID)), ("GENERATE_INFOPLIST_FILE", "YES"),
                                         ("INSTALL_PATH", .string(install)), ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1"),
                                         ("INFOPLIST_KEY_NSPrincipalClass", .string(principal))]
        if !wrapper.isEmpty { s.append(("WRAPPER_EXTENSION", .string(wrapper))) }
        s += extra
        var target = ProjectRecipe.Target(name: n, productType: "com.apple.product-type.bundle", productPath: "\(n).\(wrapper.isEmpty ? "bundle" : wrapper)",
                                          productFileType: "wrapper.cfbundle", folders: [n], exceptions: more.contains { $0.0.hasSuffix("/Info.plist") } ? ["Info.plist"] : [],
                                          settings: s)
        target.swiftVersion = nil
        _ = name
        return try recipe(c, [target], files, entry: "\(n)/\(principal).m", swift: false)
    }

    static func screenSaver(_ c: GenContext) throws -> GeneratedProject {
        try objcBundle(c, name: "Screen Saver", wrapper: "saver", install: "$(HOME)/Library/Screen Savers", principal: "\(c.t)View", base: "ScreenSaverView",
                       imports: "#import <ScreenSaver/ScreenSaver.h>", settings: [], files: [], body: """

                       - (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
                           self = [super initWithFrame:frame isPreview:isPreview];
                           if (self) {
                               [self setAnimationTimeInterval:1 / 30.0];
                           }
                           return self;
                       }

                       - (void)drawRect:(NSRect)rect {
                           [[NSColor colorWithHue:fmod([NSDate timeIntervalSinceReferenceDate] / 20, 1) saturation:0.6 brightness:0.4 alpha:1] setFill];
                           NSRectFill(rect);
                       }

                       - (void)animateOneFrame {
                           [self setNeedsDisplay:YES];
                       }

                       """)
    }

    static func preferencePane(_ c: GenContext) throws -> GeneratedProject {
        try objcBundle(c, name: "Preference Pane", wrapper: "prefPane", install: "$(HOME)/Library/PreferencePanes", principal: c.t, base: "NSPreferencePane",
                       imports: "#import <PreferencePanes/PreferencePanes.h>", settings: [("INFOPLIST_KEY_NSMainNibFile", .string(c.t))],
                       files: [("\(c.n)/\(c.t).xib", InterfaceBuilderFiles.cocoaXIB(owner: c.t, module: nil, appName: c.n, menu: false, window: true,
                                                                                     ownerHasWindowOutlet: false))],
                       body: "\n- (void)mainViewDidLoad {\n}\n\n")
    }

    static func installerPlugin(_ c: GenContext) throws -> GeneratedProject {
        let pane = "MyInstallerPane"
        let sections = infoPlist([("SectionOrder", .array([.string("InstallerSection")]))])
        return try objcBundle(c, name: "Installer Plug-in", wrapper: "", install: "$(HOME)/Library/Bundles", principal: pane, base: "InstallerPane",
                              imports: "#import <InstallerPlugins/InstallerPlugins.h>",
                              settings: [("INFOPLIST_KEY_NSMainNibFile", .string(pane)), ("INFOPLIST_KEY_NSPrincipalClass", "InstallerSection")],
                              files: [("\(c.n)/\(pane).xib", InterfaceBuilderFiles.cocoaXIB(owner: pane, module: nil, appName: c.n, menu: false, window: true)),
                                      ("\(c.n)/en.lproj/Localizable.strings", "\"PaneTitle\" = \"\(c.lit)\";\n"),
                                      ("\(c.n)/InstallerSections.plist", sections)],
                              body: "\n- (NSString *)title {\n    return [[NSBundle bundleForClass:[self class]] localizedStringForKey:@\"PaneTitle\" value:nil table:nil];\n}\n\n")
    }

    static func instrumentsPackage(_ c: GenContext) throws -> GeneratedProject {
        let pkg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package>
            <id>\(c.bundleID.xmlEscaped)</id>
            <title>\(c.n.xmlEscaped)</title>
            <owner>
                <name>\((c.organizationName.isEmpty ? c.n : c.organizationName).xmlEscaped)</name>
            </owner>
        </package>

        """
        var target = ProjectRecipe.Target(name: c.n, productType: "com.apple.product-type.instruments-package", productPath: "\(c.n).instrdst",
                                          productFileType: "com.apple.instruments.instrdst", folders: [c.n],
                                          settings: [("PRODUCT_NAME", "$(TARGET_NAME)"), ("INSTALL_PATH", "$(LOCAL_LIBRARY_DIR)/Instruments/Packages")],
                                          phases: ["PBXSourcesBuildPhase"])
        target.swiftVersion = nil
        return try recipe(c, [target], [("\(c.n)/\(c.n).instrpkg", pkg)], entry: "\(c.n)/\(c.n).instrpkg", swift: false)
    }

    // MARK: App extensions

    static func extensionTarget(_ name: String, productName: String? = nil, bundleID: String, sdk: TemplateSDK?, productType: String = "com.apple.product-type.app-extension",
                                settings extra: [(String, PlistValue)] = [], folders: [String]? = nil) -> ProjectRecipe.Target {
        var s: [(String, PlistValue)] = [("PRODUCT_NAME", .string(productName ?? "$(TARGET_NAME)")), ("PRODUCT_BUNDLE_IDENTIFIER", .string(bundleID)),
                                         ("SKIP_INSTALL", "YES"), ("GENERATE_INFOPLIST_FILE", "YES"), ("INFOPLIST_FILE", .string("\((folders ?? [name])[0])/Info.plist")),
                                         ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1"), ("SWIFT_EMIT_LOC_STRINGS", "YES"),
                                         ("INFOPLIST_KEY_CFBundleDisplayName", .string(productName ?? name))]
        s += extra
        return .init(name: name, productType: productType, productPath: "\(productName ?? name).appex", productFileType: "wrapper.app-extension",
                     folders: folders ?? [name], exceptions: ["Info.plist"], settings: s, sdk: sdk)
    }

    static func safariHandler() -> String {
        """
        import SafariServices

        /// Answers messages the extension's scripts send to the app.
        nonisolated final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
            func beginRequest(with context: NSExtensionContext) {
                let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey]
                let reply = NSExtensionItem()
                reply.userInfo = [SFExtensionMessageKey: ["received": String(describing: message ?? "nothing")]]
                context.completeRequest(returningItems: [reply], completionHandler: nil)
            }
        }

        """
    }

    static func webExtensionResources(_ c: GenContext, folder: String) -> [(String, String)] {
        [
            ("\(folder)/Resources/manifest.json", """
            {
              "manifest_version": 3,
              "default_locale": "en",
              "name": "__MSG_extension_name__",
              "description": "__MSG_extension_description__",
              "version": "1.0",
              "background": { "scripts": ["background.js"], "type": "module" },
              "content_scripts": [{ "js": ["content.js"], "matches": ["<all_urls>"] }],
              "action": { "default_popup": "popup.html" },
              "permissions": ["nativeMessaging"]
            }

            """),
            ("\(folder)/Resources/_locales/en/messages.json", """
            {
              "extension_name": { "message": "\(c.n.replacingOccurrences(of: "\"", with: "'")) Extension" },
              "extension_description": { "message": "A Safari web extension." }
            }

            """),
            ("\(folder)/Resources/background.js", "browser.runtime.onMessage.addListener((message) => {\n    console.log(\"A page says:\", message);\n});\n"),
            ("\(folder)/Resources/content.js", "browser.runtime.sendMessage({ page: location.href });\n"),
            ("\(folder)/Resources/popup.html", "<!DOCTYPE html>\n<html>\n<head>\n    <meta charset=\"utf-8\">\n    <link rel=\"stylesheet\" href=\"popup.css\">\n    <script type=\"module\" src=\"popup.js\"></script>\n</head>\n<body>\n    <p id=\"status\">Ready.</p>\n</body>\n</html>\n"),
            ("\(folder)/Resources/popup.js", "document.getElementById(\"status\").textContent = \"Running on \" + navigator.platform + \".\";\n"),
            ("\(folder)/Resources/popup.css", "body {\n    font: 13px -apple-system, sans-serif;\n    width: 200px;\n    padding: 8px;\n}\n"),
            ("\(folder)/Resources/images/", ""),
            ("\(folder)/Info.plist", infoPlist([("NSExtension", pd([
                ("NSExtensionPointIdentifier", .string("com.apple.Safari.web-extension")),
                ("NSExtensionPrincipalClass", .string("$(PRODUCT_MODULE_NAME).SafariWebExtensionHandler")),
            ]))])),
            ("\(folder)/SafariWebExtensionHandler.swift", safariHandler()),
        ]
    }

    /// The app half: a web page in a web view.
    static func safariAppFiles(_ c: GenContext, folder: String, mac: Bool, ios: Bool) -> [(String, String)] {
        [
            ("\(folder)/Resources/Main.html", "<!DOCTYPE html>\n<html>\n<head>\n    <meta charset=\"utf-8\">\n    <meta name=\"viewport\" content=\"width=device-width\">\n    <link rel=\"stylesheet\" href=\"Style.css\">\n    <script src=\"Script.js\" defer></script>\n</head>\n<body>\n    <p>Turn on \(c.n.xmlEscaped)'s extension in Safari's settings.</p>\n</body>\n</html>\n"),
            ("\(folder)/Resources/Style.css", "body {\n    font: -apple-system-body;\n    text-align: center;\n    margin: 2em;\n}\n"),
            ("\(folder)/Resources/Script.js", "document.body.dataset.ready = \"true\";\n"),
            ("\(folder)/ViewController.swift", """
            import WebKit
            #if os(macOS)
            import Cocoa
            typealias PlatformViewController = NSViewController
            #else
            import UIKit
            typealias PlatformViewController = UIViewController
            #endif

            /// Shows Main.html.
            class ViewController: PlatformViewController {
                private let webView = WKWebView()

                override func viewDidLoad() {
                    super.viewDidLoad()
                    webView.frame = view.bounds
                    #if os(macOS)
                    webView.autoresizingMask = [.width, .height]
                    #else
                    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    #endif
                    view.addSubview(webView)
                    if let page = Bundle.main.url(forResource: "Main", withExtension: "html") {
                        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
                    }
                }
            }

            """),
        ] + assets(folder, platforms: (ios ? ["iOS"] : []) + (mac ? ["macOS"] : []))
    }

    static func safariExtensionApp(_ c: GenContext) throws -> GeneratedProject {
        let n = c.n
        let mp = c.sdk.sdkroot == "auto"
        let wantIOS = mp || c.sdk.sdkroot == "iphoneos", wantMac = mp || c.sdk.sdkroot == "macosx"
        var files: [(String, String)] = []
        var targets: [ProjectRecipe.Target] = []
        let appFolder = mp ? "Shared (App)" : n
        let extFolder = mp ? "Shared (Extension)" : "\(n) Extension"
        files += safariAppFiles(c, folder: appFolder, mac: wantMac, ios: wantIOS)
        files += webExtensionResources(c, folder: extFolder)
        func addApp(_ sdk: TemplateSDK) {
            let ios = sdk.sdkroot == "iphoneos"
            let suffix = mp ? (ios ? " (iOS)" : " (macOS)") : ""
            let appName = n + suffix
            let extName = "\(n) Extension" + suffix
            let own = mp ? (ios ? "iOS (App)" : "macOS (App)") : appFolder
            let ownExt = mp ? (ios ? "iOS (Extension)" : "macOS (Extension)") : extFolder
            let module = appName.templateModuleName
            var s = appBlock(c, bundleID: c.bundleID, swiftUI: false) + [("INFOPLIST_KEY_CFBundleDisplayName", .string(n)),
                                                                        ("OTHER_LDFLAGS", ["-framework", "SafariServices", "-framework", "WebKit"])]
            if ios {
                s += iosAdditions(swiftUILifecycle: false) + [("IPHONEOS_DEPLOYMENT_TARGET", "17.0"), ("INFOPLIST_FILE", .string("\(own)/Info.plist")),
                                                              ("INFOPLIST_KEY_UIMainStoryboardFile", "Main"), ("INFOPLIST_KEY_UILaunchStoryboardName", "LaunchScreen")]
                files += [("\(own)/AppDelegate.swift", "import UIKit\n\n@main\nclass AppDelegate: UIResponder, UIApplicationDelegate {\n    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,\n                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {\n        UISceneConfiguration(name: \"Default Configuration\", sessionRole: connectingSceneSession.role)\n    }\n}\n"),
                          ("\(own)/SceneDelegate.swift", "import UIKit\n\nclass SceneDelegate: UIResponder, UIWindowSceneDelegate {\n    var window: UIWindow?\n}\n"),
                          ("\(own)/Base.lproj/Main.storyboard", InterfaceBuilderFiles.uikitStoryboard(.iOS, viewController: "ViewController", module: module)),
                          ("\(own)/Base.lproj/LaunchScreen.storyboard", InterfaceBuilderFiles.uikitStoryboard(.iOS, viewController: nil, module: nil, launch: true, id: "101")),
                          ("\(own)/Info.plist", infoPlist([("UIApplicationSceneManifest", InterfaceBuilderFiles.sceneManifest(storyboard: "Main"))]))]
            } else {
                s += macAdditions(c, cocoa: true) + [("ENABLE_HARDENED_RUNTIME", "YES"), ("ENABLE_OUTGOING_NETWORK_CONNECTIONS", "YES"),
                                                     ("MACOSX_DEPLOYMENT_TARGET", "12.0"), ("INFOPLIST_KEY_NSMainStoryboardFile", "Main")]
                files += [("\(own)/AppDelegate.swift", "import Cocoa\n\n@main\nclass AppDelegate: NSObject, NSApplicationDelegate {\n    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {\n        true\n    }\n}\n"),
                          ("\(own)/Base.lproj/Main.storyboard", InterfaceBuilderFiles.cocoaStoryboard(appName: n, module: module, viewController: "ViewController"))]
            }
            var app = appTarget(appName, settings: s, sdk: sdk, exceptions: ios ? ["Info.plist"] : [], folders: mp ? [own, appFolder] : [own])
            app.dependencies = [extName]
            app.embeds = [.extensions([extName])]
            var es: [(String, PlistValue)] = [("OTHER_LDFLAGS", ["-framework", "SafariServices"])]
            es += ios ? [("IPHONEOS_DEPLOYMENT_TARGET", "15.0"), ("TARGETED_DEVICE_FAMILY", "1,2"),
                         ("LD_RUNPATH_SEARCH_PATHS", ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"])]
                : [("MACOSX_DEPLOYMENT_TARGET", "12.0"), ("ENABLE_APP_SANDBOX", "YES"), ("ENABLE_HARDENED_RUNTIME", "YES"),
                   ("LD_RUNPATH_SEARCH_PATHS", ["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"])]
            var ext = extensionTarget(extName, productName: mp ? "\(n) Extension" : nil, bundleID: "\(c.bundleID).Extension", sdk: sdk, settings: es,
                                      folders: mp ? [ownExt, extFolder] : [extFolder])
            if mp {
                // The shared folder holds the extension's Info.plist.
                ext.settings = ext.settings.map { $0.0 == "INFOPLIST_FILE" ? ($0.0, .string("\(extFolder)/Info.plist")) : $0 }
                ext.exceptions = []
                files.append(("\(ownExt)/.keep", ""))
            }
            targets += [app, ext]
        }
        if wantIOS { addApp(.iOS) }
        if wantMac { addApp(.macOS) }
        let tt = mp ? (targets: [ProjectRecipe.Target](), files: [(String, String)]()) : tests(c, host: n, hostSettings: targets[0].settings, hostIsApp: true, ui: true)
        var g = try recipe(c, targets + tt.targets, files + tt.files, entry: "\(extFolder)/Resources/manifest.json", projectSDK: .some(nil))
        // The shared extension folder's Info.plist belongs to no target.
        if mp, var p = g.project, let folder = p.objects.values.first(where: { $0.isa == "PBXFileSystemSynchronizedRootGroup" && $0.string("path") == extFolder }) {
            var sets: [String] = []
            for t in p.targets where t.references("fileSystemSynchronizedGroups").contains(folder.id) {
                let id = p.makeObjectID()
                p[id] = PBXObject(id: id, attributes: PlistDictionary([("isa", "PBXFileSystemSynchronizedBuildFileExceptionSet"),
                                                                       ("membershipExceptions", .array(["Info.plist"])), ("target", .string(t.id))]))
                sets.append(id)
            }
            var f = folder
            f["exceptions"] = .array(sets.map(PlistValue.string))
            p[folder.id] = f
            g.project = p
        }
        return g
    }

    static func audioUnitApp(_ c: GenContext) throws -> GeneratedProject {
        let n = c.n
        let ext = "\(n)Extension"
        let ui = c.option(TemplateOptionID.hasUserInterface) == "Presents User Interface"
        let (type, tag): (String, String) = switch c.option(TemplateOptionID.audioUnitType) {
        case "Instrument": ("aumu", "Synthesizer")
        case "Generator": ("augn", "Generator")
        case "Effect": ("aufx", "Effects")
        case "Music Effect": ("aumf", "Effects")
        default: ("aumi", "MIDI")
        }
        let takesInput = type == "aufx" || type == "aumf"
        let makesAudio = type != "aumi"
        let render = takesInput ? """
                    guard let pull = pullInput else { return kAudioUnitErr_NoConnection }
                    return pull(flags, timestamp, frames, 0, output)
        """ : """
                    for buffer in UnsafeMutableAudioBufferListPointer(output) {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                    return noErr
        """
        let unit = """
        import AudioToolbox
        import AVFoundation

        /// The audio unit: \(takesInput ? "passes its input through unchanged" : makesAudio ? "renders silence for a start" : "passes MIDI through"), in stereo.
        nonisolated final class \(c.t)AudioUnit: AUAudioUnit, @unchecked Sendable {
            private var inputs: AUAudioUnitBusArray!
            private var outputs: AUAudioUnitBusArray!

            override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
                try super.init(componentDescription: componentDescription, options: options)
                let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
                inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: \(takesInput ? "[try AUAudioUnitBus(format: format)]" : "[]"))
                outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: \(makesAudio ? "[try AUAudioUnitBus(format: format)]" : "[]"))
            }

            override var inputBusses: AUAudioUnitBusArray { inputs }
            override var outputBusses: AUAudioUnitBusArray { outputs }

            override var internalRenderBlock: AUInternalRenderBlock {
                { flags, timestamp, frames, _, output, _, pullInput in
        \(render)
                }
            }
        }

        """
        let principal = ui ? "AudioUnitViewController" : "AudioUnitFactory"
        let factory = ui ? """
        import CoreAudioKit
        #if os(macOS)
        import AppKit
        #else
        import UIKit
        #endif

        /// The extension's view, and the factory hosts ask for audio units.
        nonisolated public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
            public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
                try \(c.t)AudioUnit(componentDescription: componentDescription, options: [])
            }
        }

        """ : """
        import AudioToolbox

        /// Makes the extension's audio units for hosts.
        nonisolated public final class AudioUnitFactory: NSObject, AUAudioUnitFactory {
            public func beginRequest(with context: NSExtensionContext) {}

            public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
                try \(c.t)AudioUnit(componentDescription: componentDescription, options: [])
            }
        }

        """
        let org = c.organizationName.isEmpty ? n : c.organizationName
        let component = pd([
            ("description", .string(n)), ("factoryFunction", .string("$(PRODUCT_MODULE_NAME).\(principal)")),
            ("manufacturer", .string(c.option(TemplateOptionID.manufacturerCode))), ("name", .string("\(org): \(n)")),
            ("sandboxSafe", .bool(true)), ("subtype", .string(c.option(TemplateOptionID.subtypeCode))),
            ("tags", .array([.string(tag)])), ("type", .string(type)), ("version", .integer(65536)),
        ])
        var files = swiftUISources(c, folder: n, storage: c.option(TemplateOptionID.storage), cloud: c.on(TemplateOptionID.hostInCloudKit))
        files = files.map { f in
            f.0 == "\(n)/ContentView.swift" && c.option(TemplateOptionID.storage) == "None"
                ? (f.0, "import SwiftUI\n\nstruct ContentView: View {\n    var body: some View {\n        VStack(spacing: 12) {\n            Text(\"\(c.lit)\")\n                .font(.title)\n            Text(\"Open a host app that loads Audio Unit extensions to use \(c.lit).\")\n                .multilineTextAlignment(.center)\n                .foregroundStyle(.secondary)\n        }\n        .padding()\n    }\n}\n")
                : f
        }
        let st = storage(c, folder: n, sdk: .multiplatform)
        files += st.files + assets(n, platforms: ["iOS", "macOS"])
        files.append(("\(n)/\(c.t)Host.entitlements", infoPlist([("inter-app-audio", .bool(true))])))
        files += [("\(ext)/\(c.t)AudioUnit.swift", unit), ("\(ext)/\(principal).swift", factory),
                  ("\(ext)/Info.plist", infoPlist([("NSExtension", pd([
                      ("NSExtensionAttributes", pd([("AudioComponents", .array([component]))])),
                      ("NSExtensionPointIdentifier", .string(ui ? "com.apple.AudioUnit-UI" : "com.apple.AudioUnit")),
                      ("NSExtensionPrincipalClass", .string("$(PRODUCT_MODULE_NAME).\(principal)")),
                  ]))]))]
        var hs = appBlock(c, bundleID: c.bundleID, swiftUI: true) + multiplatformApp(c) + st.settings
        if !hs.contains(where: { $0.0 == "CODE_SIGN_ENTITLEMENTS" }) { hs.append(("CODE_SIGN_ENTITLEMENTS", .string("\(n)/\(c.t)Host.entitlements"))) }
        hs += [("ENABLE_HARDENED_RUNTIME", "YES"), ("INFOPLIST_KEY_CFBundleDisplayName", .string(c.t)),
               ("OTHER_LDFLAGS", ["-framework", "AudioToolbox", "-framework", "AVFoundation"])]
        var host = appTarget(n, settings: hs, exceptions: st.exceptions)
        host.dependencies = [ext]
        host.embeds = [.extensions([ext])]
        var es: [(String, PlistValue)] = [("SDKROOT", "auto"), ("SUPPORTED_PLATFORMS", .string(TemplateSDK.multiplatform.supportedPlatforms)),
                                          ("TARGETED_DEVICE_FAMILY", "1,2,7"), ("ENABLE_APP_SANDBOX[sdk=macosx*]", "YES"),
                                          ("LD_RUNPATH_SEARCH_PATHS", ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]),
                                          ("LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]", ["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"])]
        es += TemplateSDK.multiplatform.platformRow
        let tt = tests(c, host: n, hostSettings: hs, hostIsApp: true, ui: true)
        return try recipe(c, [host, extensionTarget(ext, bundleID: "\(c.bundleID).\(ext)", sdk: nil, settings: es)] + tt.targets, files + tt.files,
                          entry: "\(ext)/\(c.t)AudioUnit.swift")
    }

    /// A Messages app container (`application.messages`).
    static func messagesContainer(_ c: GenContext, extensionName: String, extra: [(String, PlistValue)], folder: Bool) -> ProjectRecipe.Target {
        var s = appBlock(c, bundleID: c.bundleID, swiftUI: false).filter { folder || !$0.0.hasPrefix("ASSETCATALOG") } + extra
        s.append(("TARGETED_DEVICE_FAMILY", "1,2"))
        var t = ProjectRecipe.Target(name: c.n, productType: "com.apple.product-type.application.messages", productPath: "\(c.n).app",
                                     productFileType: "wrapper.application", folders: folder ? [c.n] : [], settings: s, phases: ["PBXResourcesBuildPhase"],
                                     dependencies: [extensionName], embeds: [.extensions([extensionName])])
        t.swiftVersion = nil
        return t
    }

    static func iMessageApp(_ c: GenContext) throws -> GeneratedProject {
        let ext = "\(c.n) MessagesExtension"
        var files = assets(c.n, platforms: ["iOS"])
        files += assets(ext, platforms: [])
        files += [
            ("\(ext)/MessagesViewController.swift", """
            import Messages
            import UIKit

            /// The extension's view in Messages.
            class MessagesViewController: MSMessagesAppViewController {
                override func viewDidLoad() {
                    super.viewDidLoad()
                    let label = UILabel()
                    label.text = "\(c.lit)"
                    label.font = .preferredFont(forTextStyle: .title2)
                    label.translatesAutoresizingMaskIntoConstraints = false
                    view.addSubview(label)
                    NSLayoutConstraint.activate([
                        label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                        label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    ])
                }
            }

            """),
            ("\(ext)/Base.lproj/MainInterface.storyboard", InterfaceBuilderFiles.uikitStoryboard(.iOS, viewController: "MessagesViewController",
                                                                                                 module: ext.templateModuleName)),
            ("\(ext)/Info.plist", infoPlist([("NSExtension", pd([
                ("NSExtensionMainStoryboard", .string("MainInterface")),
                ("NSExtensionPointIdentifier", .string("com.apple.message-payload-provider")),
            ]))])),
        ]
        var e = extensionTarget(ext, bundleID: "\(c.bundleID).MessagesExtension", sdk: nil, productType: "com.apple.product-type.app-extension.messages",
                                settings: [("TARGETED_DEVICE_FAMILY", "1,2"), ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
                                           ("LD_RUNPATH_SEARCH_PATHS", ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"])])
        e.sdkFrameworks = ["Messages"]
        return try recipe(c, [messagesContainer(c, extensionName: ext, extra: [("INFOPLIST_KEY_UILaunchStoryboardName", "LaunchScreen")], folder: true), e],
                          files, entry: "\(ext)/MessagesViewController.swift")
    }

    static func stickerPackApp(_ c: GenContext) throws -> GeneratedProject {
        let ext = "\(c.n) StickerPackExtension"
        let files: [(String, String)] = [
            ("\(ext)/Stickers.xcstickers/Contents.json", json(info)),
            ("\(ext)/Stickers.xcstickers/Sticker Pack.stickerpack/Contents.json",
             json(#""info" : { "author" : "ycode", "version" : 1 },\#n  "properties" : { "grid-size" : "regular" },\#n  "stickers" : [ ]"#)),
            ("\(ext)/Stickers.xcstickers/iMessage App Icon.stickersiconset/Contents.json", json(#""images" : [ ],\#n  "# + info)),
        ]
        var e = ProjectRecipe.Target(name: ext, productType: "com.apple.product-type.app-extension.messages-sticker-pack", productPath: "\(ext).appex",
                                     productFileType: "wrapper.app-extension", folders: [ext],
                                     settings: [("PRODUCT_NAME", "$(TARGET_NAME)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string("\(c.bundleID).StickerPackExtension")),
                                                ("GENERATE_INFOPLIST_FILE", "YES"), ("INFOPLIST_KEY_CFBundleDisplayName", .string(c.n)), ("SKIP_INSTALL", "YES"),
                                                ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1"), ("TARGETED_DEVICE_FAMILY", "1,2"),
                                                ("ASSETCATALOG_COMPILER_APPICON_NAME", "iMessage App Icon")],
                                     phases: ["PBXResourcesBuildPhase"])
        e.swiftVersion = nil
        return try recipe(c, [messagesContainer(c, extensionName: ext, extra: [("INFOPLIST_KEY_NSStickerSharingLevel", "OS")], folder: false), e], files,
                          entry: nil, swift: false)
    }

    // MARK: DriverKit

    static func driver(_ c: GenContext) throws -> GeneratedProject {
        let cls = c.t, n = c.n
        let files: [(String, String)] = [
            ("\(n)/\(cls).iig", "#ifndef \(cls)_h\n#define \(cls)_h\n\n#include <Availability.h>\n#include <DriverKit/IOService.iig>\n\nclass \(cls): public IOService\n{\npublic:\n    virtual kern_return_t Start(IOService * provider) override;\n};\n\n#endif\n"),
            ("\(n)/\(cls).cpp", "#include <os/log.h>\n\n#include <DriverKit/IOLib.h>\n#include <DriverKit/IOUserServer.h>\n\n#include \"\(cls).h\"\n\nkern_return_t\nIMPL(\(cls), Start)\n{\n    kern_return_t ret = Start(provider, SUPERDISPATCH);\n    os_log(OS_LOG_DEFAULT, \"\(cls) started: %d\", ret);\n    return ret;\n}\n"),
            ("\(n)/Info.plist", infoPlist([
                ("IOKitPersonalities", pd([(cls, pd([
                    ("CFBundleIdentifier", .string("$(PRODUCT_BUNDLE_IDENTIFIER)")), ("IOClass", .string("IOUserService")),
                    ("IOMatchCategory", .string(cls)), ("IOProviderClass", .string("IOUserResources")),
                    ("IOResourceMatch", .string("IOKit")), ("IOUserClass", .string(cls)),
                    ("IOUserServerName", .string("$(PRODUCT_BUNDLE_IDENTIFIER)")),
                ]))])),
                ("OSBundleUsageDescription", .string("\(n) is a DriverKit driver.")),
            ])),
        ]
        var target = ProjectRecipe.Target(name: n, productType: "com.apple.product-type.driver-extension", productPath: "\(c.bundleID).dext",
                                          productFileType: "wrapper.driver-extension", folders: [n], exceptions: ["Info.plist"],
                                          settings: [("PRODUCT_NAME", "$(inherited)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string(c.bundleID)),
                                                     ("GENERATE_INFOPLIST_FILE", "YES"), ("INFOPLIST_FILE", .string("\(n)/Info.plist")), ("SKIP_INSTALL", "YES"),
                                                     ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1")],
                                          phases: ["PBXHeadersBuildPhase", "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"])
        target.swiftVersion = nil
        target.sdkFrameworks = ["DriverKit"]
        return try recipe(c, [target], files, entry: "\(n)/\(cls).cpp", swift: false)
    }

    // MARK: Packages and playgrounds

    /// A Package… template: SwiftPM writes the package (`swift package
    /// init --type`), with the testing flags of the Testing System.
    static func package(_ c: GenContext, type: String) -> GeneratedProject {
        var args: [String] = []
        if c.d.fields.contains(where: { $0.id == TemplateOptionID.testingSystem }) {
            switch c.f.value(TemplateOptionID.testingSystem) {
            case "XCTest": args = ["--enable-xctest", "--disable-swift-testing"]
            case "Swift Testing": args = ["--disable-xctest", "--enable-swift-testing"]
            default: args = ["--disable-xctest", "--disable-swift-testing"]
            }
        }
        var g = GeneratedProject(folderName: c.n, files: [], project: nil, projectName: c.n, entryFile: "Package.swift")
        g.packageInit = (type, args)
        return g
    }

    /// iOS ▸ App Playground: `N.swiftpm`, an app package. The manifest
    /// declares the app product where the app-package product types exist
    /// and an executable elsewhere, so the package builds with any SwiftPM.
    static func appPlayground(_ c: GenContext) -> GeneratedProject {
        let n = c.n
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        #if canImport(AppleProductTypes)
        import AppleProductTypes

        let products: [Product] = [
            .iOSApplication(
                name: "\(n.swiftLiteral)",
                targets: ["AppModule"],
                bundleIdentifier: "\(c.bundleID)",
                displayVersion: "1.0",
                bundleVersion: "1",
                supportedDeviceFamilies: [.pad, .phone],
                supportedInterfaceOrientations: [.portrait, .landscapeRight, .landscapeLeft]
            ),
        ]
        #else
        let products: [Product] = []
        #endif

        let package = Package(
            name: "\(n.swiftLiteral)",
            platforms: [.iOS("18.0"), .macOS("15.0")],
            products: products,
            targets: [
                .executableTarget(name: "AppModule", path: "."),
            ]
        )

        """
        let files: [(String, String)] = [
            ("Package.swift", manifest),
            ("MyApp.swift", "import SwiftUI\n\n@main\nstruct MyApp: App {\n    var body: some Scene {\n        WindowGroup {\n            ContentView()\n        }\n    }\n}\n"),
            ("ContentView.swift", "import SwiftUI\n\nstruct ContentView: View {\n    @State private var taps = 0\n\n    var body: some View {\n        VStack(spacing: 16) {\n            Text(\"\(c.lit)\")\n                .font(.largeTitle)\n            Button(\"Tapped \\(taps) times\") { taps += 1 }\n        }\n        .padding()\n    }\n}\n"),
            (".swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata", GeneratedProject.selfWorkspace),
        ]
        return GeneratedProject(folderName: "\(n).swiftpm", files: files, project: nil, projectName: n, entryFile: "ContentView.swift")
    }

    // MARK: Other

    static func externalBuildSystem(_ c: GenContext) throws -> GeneratedProject {
        let tool = c.option(TemplateOptionID.buildTool)
        var t = ProjectRecipe.Target(kind: .legacy(tool: tool, arguments: "$(ACTION)"), name: c.n, productType: "", productPath: "", productFileType: "",
                                     folders: [], settings: [("PRODUCT_NAME", "$(TARGET_NAME)"), ("OTHER_CFLAGS", ""), ("OTHER_LDFLAGS", "")],
                                     debugSettings: [("DEBUGGING_SYMBOLS", "YES"), ("GCC_GENERATE_DEBUGGING_SYMBOLS", "YES"), ("GCC_OPTIMIZATION_LEVEL", "0"),
                                                     ("DEBUG_INFORMATION_FORMAT", "dwarf")],
                                     releaseSettings: [("DEBUG_INFORMATION_FORMAT", "dwarf-with-dsym")], phases: [])
        t.swiftVersion = nil
        return try recipe(c, [t], [], swift: false)
    }
}
