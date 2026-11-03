import Foundation
import YcodePlist
import YcodeProject

// Apps, document apps, watchOS and visionOS (`templates.md` § "Catalog by
// template"). Source texts are Ycode's own; the APIs are Apple's public
// SDK documentation (SwiftUI, SwiftData, Core Data, UIKit, AppKit).

extension ProjectGenerator {
    // MARK: Source sets

    /// `TApp.swift` and `ContentView.swift` for the SwiftUI lifecycle, with
    /// the storage the options chose.
    static func swiftUISources(_ c: GenContext, folder: String, storage: String, cloud: Bool) -> [(String, String)] {
        let t = c.t
        var imports = "import SwiftUI"
        var scene = "        WindowGroup {\n            ContentView()\n        }\n"
        var extra = ""
        let content: String
        switch storage {
        case "SwiftData":
            imports = "import SwiftData\nimport SwiftUI"
            scene = "        WindowGroup {\n            ContentView()\n        }\n        .modelContainer(Self.container)\n"
            extra = """
                /// The app's SwiftData store\(cloud ? ", mirrored to CloudKit" : "").
                static let container: ModelContainer = {
                    let configuration = ModelConfiguration(\(cloud ? "cloudKitDatabase: .automatic" : ""))
                    do {
                        return try ModelContainer(for: Item.self, configurations: configuration)
                    } catch {
                        fatalError("The model container could not be made: \\(error)")
                    }
                }()


            """
            content = """
            import SwiftData
            import SwiftUI

            struct ContentView: View {
                @Environment(\\.modelContext) private var context
                @Query(sort: \\Item.timestamp) private var items: [Item]

                var body: some View {
                    NavigationStack {
                        List {
                            ForEach(items) { item in
                                Text(item.timestamp, format: .dateTime)
                            }
                            .onDelete { offsets in
                                for i in offsets { context.delete(items[i]) }
                            }
                        }
                        .navigationTitle("\(c.lit)")
                        .toolbar {
                            Button("Add Item", systemImage: "plus") { context.insert(Item(timestamp: .now)) }
                        }
                    }
                }
            }

            #Preview {
                ContentView()
                    .modelContainer(for: Item.self, inMemory: true)
            }

            """
        case "Core Data":
            imports = "import CoreData\nimport SwiftUI"
            scene = "        WindowGroup {\n            ContentView()\n                .environment(\\.managedObjectContext, PersistenceController.shared.container.viewContext)\n        }\n"
            content = """
            import CoreData
            import SwiftUI

            struct ContentView: View {
                @Environment(\\.managedObjectContext) private var context
                @FetchRequest(sortDescriptors: [SortDescriptor(\\.timestamp)]) private var items: FetchedResults<Item>

                var body: some View {
                    NavigationStack {
                        List(items) { item in
                            Text(item.timestamp ?? .now, format: .dateTime)
                        }
                        .navigationTitle("\(c.lit)")
                        .toolbar {
                            Button("Add Item", systemImage: "plus") {
                                let item = Item(context: context)
                                item.timestamp = .now
                                try? context.save()
                            }
                        }
                    }
                }
            }

            """
        default:
            content = """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                        Text("\(c.lit)")
                    }
                    .padding()
                }
            }

            #Preview {
                ContentView()
            }

            """
        }
        return [("\(folder)/\(t)App.swift", "\(imports)\n\n@main\nstruct \(t)App: App {\n\(extra)    var body: some Scene {\n\(scene)    }\n}\n"),
                ("\(folder)/ContentView.swift", content)]
    }

    /// The UIKit scene-based app in Swift: delegates, a view controller and
    /// the storyboards (`viewControllerBody` is the class body).
    static func uikitSwiftSources(_ c: GenContext, folder: String, rt: InterfaceBuilderFiles.Runtime, viewControllerImports: String = "import UIKit",
                                  viewControllerBody: String = "", viewClass: String? = nil, viewControllerName: String = "ViewController",
                                  launchScreen: Bool = true) -> [(String, String)] {
        var out: [(String, String)] = [
            ("\(folder)/AppDelegate.swift", """
            import UIKit

            @main
            class AppDelegate: UIResponder, UIApplicationDelegate {
                func application(_ application: UIApplication,
                                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
                    true
                }

                func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                                 options: UIScene.ConnectionOptions) -> UISceneConfiguration {
                    UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
                }
            }

            """),
            ("\(folder)/SceneDelegate.swift", """
            import UIKit

            class SceneDelegate: UIResponder, UIWindowSceneDelegate {
                var window: UIWindow?
            }

            """),
            ("\(folder)/\(viewControllerName).swift", """
            \(viewControllerImports)

            class \(viewControllerName): UIViewController {
            \(viewControllerBody.isEmpty ? "    override func viewDidLoad() {\n        super.viewDidLoad()\n    }\n" : viewControllerBody)}

            """),
            ("\(folder)/Base.lproj/Main.storyboard", InterfaceBuilderFiles.uikitStoryboard(rt, viewController: viewControllerName, module: c.module,
                                                                                           viewClass: viewClass)),
            ("\(folder)/Info.plist", infoPlist([("UIApplicationSceneManifest", InterfaceBuilderFiles.sceneManifest(storyboard: "Main"))])),
        ]
        if launchScreen {
            out.append(("\(folder)/Base.lproj/LaunchScreen.storyboard", InterfaceBuilderFiles.uikitStoryboard(rt, viewController: nil, module: nil,
                                                                                                              launch: rt == .iOS, id: "101")))
        }
        return out
    }

    /// The UIKit scene-based app in Objective-C.
    static func uikitObjCSources(_ c: GenContext, folder: String, rt: InterfaceBuilderFiles.Runtime) -> [(String, String)] {
        [
            ("\(folder)/main.m", """
            #import <UIKit/UIKit.h>
            #import "AppDelegate.h"

            int main(int argc, char *argv[]) {
                NSString *delegateClass;
                @autoreleasepool {
                    delegateClass = NSStringFromClass([AppDelegate class]);
                }
                return UIApplicationMain(argc, argv, nil, delegateClass);
            }

            """),
            ("\(folder)/AppDelegate.h", "#import <UIKit/UIKit.h>\n\n@interface AppDelegate : UIResponder <UIApplicationDelegate>\n@end\n"),
            ("\(folder)/AppDelegate.m", """
            #import "AppDelegate.h"

            @implementation AppDelegate

            - (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
                return YES;
            }

            - (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session
                                          options:(UISceneConnectionOptions *)options {
                return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:session.role];
            }

            @end

            """),
            ("\(folder)/SceneDelegate.h", "#import <UIKit/UIKit.h>\n\n@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>\n@property (strong, nonatomic) UIWindow *window;\n@end\n"),
            ("\(folder)/SceneDelegate.m", "#import \"SceneDelegate.h\"\n\n@implementation SceneDelegate\n@end\n"),
            ("\(folder)/ViewController.h", "#import <UIKit/UIKit.h>\n\n@interface ViewController : UIViewController\n@end\n"),
            ("\(folder)/ViewController.m", "#import \"ViewController.h\"\n\n@implementation ViewController\n\n- (void)viewDidLoad {\n    [super viewDidLoad];\n}\n\n@end\n"),
            ("\(folder)/Base.lproj/Main.storyboard", InterfaceBuilderFiles.uikitStoryboard(rt, viewController: "ViewController", module: nil)),
            ("\(folder)/Base.lproj/LaunchScreen.storyboard", InterfaceBuilderFiles.uikitStoryboard(rt, viewController: nil, module: nil, launch: rt == .iOS, id: "101")),
            ("\(folder)/Info.plist", infoPlist([("UIApplicationSceneManifest", InterfaceBuilderFiles.sceneManifest(storyboard: "Main", delegate: "SceneDelegate"))])),
        ]
    }

    /// The Cocoa lifecycle in Swift or Objective-C, with a storyboard or a
    /// XIB (`viewClass`/`viewControllerBody` for games).
    static func cocoaSources(_ c: GenContext, folder: String, xib: Bool, objc: Bool, viewControllerImports: String = "import Cocoa",
                             viewControllerBody: String = "", viewClass: String? = nil) -> [(String, String)] {
        let module: String? = objc ? nil : c.module
        var out: [(String, String)] = []
        if objc {
            out += [
                ("\(folder)/main.m", "#import <Cocoa/Cocoa.h>\n\nint main(int argc, const char *argv[]) {\n    return NSApplicationMain(argc, argv);\n}\n"),
                ("\(folder)/AppDelegate.h", "#import <Cocoa/Cocoa.h>\n\n@interface AppDelegate : NSObject <NSApplicationDelegate>\n\(xib ? "@property (strong) IBOutlet NSWindow *window;\n" : "")@end\n"),
                ("\(folder)/AppDelegate.m", """
                #import "AppDelegate.h"

                @implementation AppDelegate

                - (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
                    return YES;
                }

                @end

                """),
            ]
            if !xib {
                out += [("\(folder)/ViewController.h", "#import <Cocoa/Cocoa.h>\n\n@interface ViewController : NSViewController\n@end\n"),
                        ("\(folder)/ViewController.m", "#import \"ViewController.h\"\n\n@implementation ViewController\n\n- (void)viewDidLoad {\n    [super viewDidLoad];\n}\n\n@end\n")]
            }
        } else {
            out.append(("\(folder)/AppDelegate.swift", """
            import Cocoa

            @main
            class AppDelegate: NSObject, NSApplicationDelegate {
            \(xib ? "    @IBOutlet var window: NSWindow!\n\n" : "")    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
                    true
                }
            }

            """))
            if !xib {
                out.append(("\(folder)/ViewController.swift", """
                \(viewControllerImports)

                class ViewController: NSViewController {
                \(viewControllerBody.isEmpty ? "    override func viewDidLoad() {\n        super.viewDidLoad()\n    }\n" : viewControllerBody)}

                """))
            }
        }
        if xib {
            out.append(("\(folder)/Base.lproj/MainMenu.xib", InterfaceBuilderFiles.cocoaXIB(owner: "NSApplication", module: module, appName: c.n,
                                                                                         menu: true, window: true)))
        } else {
            out.append(("\(folder)/Base.lproj/Main.storyboard", InterfaceBuilderFiles.cocoaStoryboard(appName: c.n, module: module,
                                                                                                     viewController: "ViewController", viewClass: viewClass)))
        }
        return out
    }

    // MARK: App

    /// Multiplatform, iOS, macOS and tvOS ▸ App.
    static func app(_ c: GenContext) throws -> GeneratedProject {
        let sdk = c.sdk
        let n = c.n
        let interface = c.option(TemplateOptionID.interface).isEmpty ? "SwiftUI" : c.option(TemplateOptionID.interface)
        let swiftUI = interface == "SwiftUI"
        let st = storage(c, folder: n, sdk: sdk)
        var files: [(String, String)] = []
        var settings = appBlock(c, bundleID: c.bundleID, swiftUI: swiftUI) + platformApp(c, sdk: sdk, swiftUILifecycle: swiftUI)
        var exceptions = st.exceptions
        var entry = "\(n)/ContentView.swift"
        if swiftUI {
            files += swiftUISources(c, folder: n, storage: c.option(TemplateOptionID.storage), cloud: c.on(TemplateOptionID.hostInCloudKit))
        } else if sdk.sdkroot == "macosx" {
            let xib = interface == "XIB"
            files += cocoaSources(c, folder: n, xib: xib, objc: c.objc)
            settings.append(xib ? ("INFOPLIST_KEY_NSMainNibFile", "MainMenu") : ("INFOPLIST_KEY_NSMainStoryboardFile", "Main"))
            entry = c.objc ? "\(n)/AppDelegate.m" : "\(n)/AppDelegate.swift"
        } else {
            let rt: InterfaceBuilderFiles.Runtime = sdk.sdkroot == "appletvos" ? .tvOS : .iOS
            files += c.objc ? uikitObjCSources(c, folder: n, rt: rt) : uikitSwiftSources(c, folder: n, rt: rt)
            settings += [("INFOPLIST_FILE", .string("\(n)/Info.plist")), ("INFOPLIST_KEY_UIMainStoryboardFile", "Main"),
                         ("INFOPLIST_KEY_UILaunchStoryboardName", "LaunchScreen")]
            settings.removeAll { $0.0 == "INFOPLIST_KEY_UILaunchScreen_Generation" }
            exceptions.append("Info.plist")
            entry = c.objc ? "\(n)/ViewController.m" : "\(n)/ViewController.swift"
        }
        // CloudKit's Info.plist merges with the storyboard app's.
        files += st.files.filter { f in !(f.0 == "\(n)/Info.plist" && files.contains { $0.0 == f.0 }) }
        settings += st.settings.filter { s in !settings.contains { $0.0 == s.0 } }
        if c.on(TemplateOptionID.hostInCloudKit), sdk.sdkroot == "appletvos" {
            settings += [("ENABLE_APP_SANDBOX", "YES"), ("ENABLE_USER_SELECTED_FILES", "readonly")]
        }
        files += assets(n, platforms: iconPlatforms(sdk))
        let target = appTarget(n, settings: settings, exceptions: Array(Set(exceptions)).sorted(), swift: !c.objc)
        let t = tests(c, host: n, hostSettings: settings, hostIsApp: true, ui: true)
        return try recipe(c, [target] + t.targets, files + t.files, entry: entry)
    }

    // MARK: Document App

    static func documentApp(_ c: GenContext) throws -> GeneratedProject {
        let sdk = c.sdk, n = c.n, t = c.t
        let interface = c.option(TemplateOptionID.interface).isEmpty ? "SwiftUI" : c.option(TemplateOptionID.interface)
        let swiftUI = interface == "SwiftUI"
        let storageKind = c.option(TemplateOptionID.documentStorage)
        let swiftData = storageKind == "SwiftData"
        let ext = String(n.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12))
        let fileExt = ext.isEmpty ? "document" : ext
        // Ycode's placeholder UTI: the bundle identifier plus ".document".
        let typeID = "\(c.bundleID).document"
        var files: [(String, String)] = []
        var settings = appBlock(c, bundleID: c.bundleID, swiftUI: swiftUI)
        let lower = t.prefix(1).lowercased() + t.dropFirst()
        switch sdk.sdkroot {
        case "macosx": settings += macAdditions(c, cocoa: !swiftUI, document: true)
        case "auto":
            settings += multiplatformApp(c).map { $0.0 == "ENABLE_USER_SELECTED_FILES" ? ($0.0, "readwrite") : $0 }
            settings += [("INFOPLIST_KEY_UISupportsDocumentBrowser[sdk=iphoneos*]", "YES"), ("INFOPLIST_KEY_UISupportsDocumentBrowser[sdk=iphonesimulator*]", "YES")]
        default:
            settings += iosAdditions(swiftUILifecycle: swiftUI) + [("INFOPLIST_KEY_UISupportsDocumentBrowser", "YES")]
        }
        var docType: [(String, PropertyListItem)] = [("CFBundleTypeRole", .string("Editor")), ("LSItemContentTypes", .array([.string(typeID)])),
                                                     ("NSUbiquitousDocumentUserActivityType", .string("$(PRODUCT_BUNDLE_IDENTIFIER).editing"))]
        var plist: [(String, PropertyListItem)] = []
        if swiftUI {
            if swiftData {
                docType.append(("LSHandlerRank", .string("Default")))
                files += [
                    ("\(n)/\(t)App.swift", """
                    import SwiftData
                    import SwiftUI
                    import UniformTypeIdentifiers

                    extension UTType {
                        nonisolated static var \(lower)Document: UTType { UTType(importedAs: "\(typeID)") }
                    }

                    @main
                    struct \(t)App: App {
                        var body: some Scene {
                            DocumentGroup(editing: Item.self, contentType: .\(lower)Document) {
                                ContentView()
                            }
                        }
                    }

                    """),
                    ("\(n)/Item.swift", "import Foundation\nimport SwiftData\n\n@Model\nfinal class Item {\n    var timestamp: Date\n\n    init(timestamp: Date) {\n        self.timestamp = timestamp\n    }\n}\n"),
                    ("\(n)/ContentView.swift", """
                    import SwiftData
                    import SwiftUI

                    struct ContentView: View {
                        @Environment(\\.modelContext) private var context
                        @Query private var items: [Item]

                        var body: some View {
                            List(items) { item in
                                Text(item.timestamp, format: .dateTime)
                            }
                            .toolbar {
                                Button("Add Item", systemImage: "plus") { context.insert(Item(timestamp: .now)) }
                            }
                        }
                    }

                    """),
                ]
            } else {
                files += [
                    ("\(n)/\(t)App.swift", """
                    import SwiftUI

                    @main
                    struct \(t)App: App {
                        var body: some Scene {
                            DocumentGroup(newDocument: \(t)Document()) { file in
                                ContentView(document: file.$document)
                            }
                        }
                    }

                    """),
                    ("\(n)/\(t)Document.swift", """
                    import SwiftUI
                    import UniformTypeIdentifiers

                    extension UTType {
                        /// The app's document type (declared in Info.plist).
                        nonisolated static var \(lower)Document: UTType { UTType(importedAs: "\(typeID)") }
                    }

                    /// A plain-text document.
                    nonisolated struct \(t)Document: FileDocument {
                        var text: String

                        init(text: String = "") {
                            self.text = text
                        }

                        static let readableContentTypes = [UTType.\(lower)Document]

                        init(configuration: ReadConfiguration) throws {
                            guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            self.text = text
                        }

                        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
                            FileWrapper(regularFileWithContents: Data(text.utf8))
                        }
                    }

                    """),
                    ("\(n)/ContentView.swift", """
                    import SwiftUI

                    struct ContentView: View {
                        @Binding var document: \(t)Document

                        var body: some View {
                            TextEditor(text: $document.text)
                                .font(.body.monospaced())
                        }
                    }

                    #Preview {
                        ContentView(document: .constant(\(t)Document(text: "\(c.lit)")))
                    }

                    """),
                ]
            }
        } else if sdk.sdkroot == "macosx" {
            files += cocoaDocumentSources(c, folder: n, xib: interface == "XIB", coreData: storageKind == "Core Data", typeID: typeID)
            if interface == "XIB" { settings.append(("INFOPLIST_KEY_NSMainNibFile", "MainMenu")) } else { settings.append(("INFOPLIST_KEY_NSMainStoryboardFile", "Main")) }
            docType += [("NSDocumentClass", .string("$(PRODUCT_MODULE_NAME).Document"))]
            if storageKind == "Core Data" { docType.append(("LSTypeIsPackage", .bool(false))) }
        } else {
            files += uikitDocumentSources(c, folder: n, typeID: typeID)
            settings += [("INFOPLIST_KEY_UILaunchStoryboardName", "LaunchScreen")]
            docType.append(("UIDocumentClass", .string("$(PRODUCT_MODULE_NAME).Document")))
            plist.append(("UIApplicationSceneManifest", InterfaceBuilderFiles.sceneManifest(storyboard: nil)))
        }
        plist = [("CFBundleDocumentTypes", .array([pd(docType)])),
                 ("UTImportedTypeDeclarations", .array([pd([
                     ("UTTypeConformsTo", .array([.string(swiftData ? "com.apple.package" : "public.plain-text")])),
                     ("UTTypeDescription", .string("\(n) Document")), ("UTTypeIdentifier", .string(typeID)),
                     ("UTTypeTagSpecification", pd([("public.filename-extension", .array([.string(fileExt)]))])),
                 ])]))] + plist
        files.append(("\(n)/Info.plist", infoPlist(plist)))
        files += assets(n, platforms: iconPlatforms(sdk))
        settings.append(("INFOPLIST_FILE", .string("\(n)/Info.plist")))
        var target = appTarget(n, settings: settings, exceptions: ["Info.plist"])
        target.swiftVersion = swiftUI && !swiftData ? "6.0" : "5.0"
        let tt = tests(c, host: n, hostSettings: settings, hostIsApp: true, ui: true)
        let entry = swiftUI ? "\(n)/ContentView.swift" : "\(n)/Document.swift"
        return try recipe(c, [target] + tt.targets, files + tt.files, entry: entry)
    }

    /// An `NSDocument` (or `NSPersistentDocument`) app with a storyboard
    /// or XIBs.
    static func cocoaDocumentSources(_ c: GenContext, folder: String, xib: Bool, coreData: Bool, typeID: String) -> [(String, String)] {
        let base = coreData ? "NSPersistentDocument" : "NSDocument"
        let body: String
        if coreData {
            body = "    override class var autosavesInPlace: Bool { true }\n"
        } else {
            body = """
                var text = ""

                override class var autosavesInPlace: Bool { true }

                override func data(ofType typeName: String) throws -> Data { Data(text.utf8) }

                override func read(from data: Data, ofType typeName: String) throws {
                    text = String(decoding: data, as: UTF8.self)
                }

            """
        }
        let windows = xib ? "    override var windowNibName: NSNib.Name? { \"Document\" }\n"
            : """
                override func makeWindowControllers() {
                    MainActor.assumeIsolated {
                        let storyboard = NSStoryboard(name: "Main", bundle: nil)
                        if let controller = storyboard.instantiateController(withIdentifier: "Document Window Controller") as? NSWindowController {
                            addWindowController(controller)
                        }
                    }
                }

            """
        var out: [(String, String)] = [
            ("\(folder)/AppDelegate.swift", "import Cocoa\n\n@main\nclass AppDelegate: NSObject, NSApplicationDelegate {\n    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {\n        true\n    }\n}\n"),
            ("\(folder)/Document.swift", "import Cocoa\n\n/// One open document (its overrides are nonisolated, as the base class's are).\nnonisolated class Document: \(base) {\n\(body)\n\(windows)}\n"),
        ]
        if xib {
            out += [("\(folder)/Base.lproj/MainMenu.xib", InterfaceBuilderFiles.cocoaXIB(owner: "NSApplication", module: c.module, appName: c.n, menu: true, window: false)),
                    ("\(folder)/Base.lproj/Document.xib", InterfaceBuilderFiles.cocoaXIB(owner: "Document", module: c.module, appName: c.n, menu: false,
                                                                                         window: true, ownerHasWindowOutlet: true))]
        } else {
            out += [("\(folder)/ViewController.swift", "import Cocoa\n\nclass ViewController: NSViewController {\n    override func viewDidLoad() {\n        super.viewDidLoad()\n    }\n}\n"),
                    ("\(folder)/Base.lproj/Main.storyboard", InterfaceBuilderFiles.cocoaStoryboard(appName: c.n, module: c.module, viewController: "ViewController",
                                                                                                  windowControllerID: "Document Window Controller"))]
        }
        if coreData {
            out.append(("\(folder)/Document.xcdatamodeld/Document.xcdatamodel/contents", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" lastSavedToolsVersion="1" systemVersion="1" minimumToolsVersion="Automatic" sourceLanguage="Swift" userDefinedModelVersionIdentifier="">
                <entity name="Note" representedClassName="Note" syncable="YES" codeGenerationType="class">
                    <attribute name="text" optional="YES" attributeType="String"/>
                </entity>
            </model>

            """))
        }
        return out
    }

    /// A UIKit document-browser app (`UIDocument`).
    static func uikitDocumentSources(_ c: GenContext, folder: String, typeID: String) -> [(String, String)] {
        [
            ("\(folder)/AppDelegate.swift", "import UIKit\n\n@main\nclass AppDelegate: UIResponder, UIApplicationDelegate {\n    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,\n                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {\n        UISceneConfiguration(name: \"Default Configuration\", sessionRole: connectingSceneSession.role)\n    }\n}\n"),
            ("\(folder)/SceneDelegate.swift", """
            import UIKit
            import UniformTypeIdentifiers

            class SceneDelegate: UIResponder, UIWindowSceneDelegate {
                var window: UIWindow?

                func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
                    guard let scene = scene as? UIWindowScene else { return }
                    let window = UIWindow(windowScene: scene)
                    window.rootViewController = DocumentBrowserViewController(forOpening: [UTType(importedAs: "\(typeID)")])
                    window.makeKeyAndVisible()
                    self.window = window
                }
            }

            """),
            ("\(folder)/DocumentBrowserViewController.swift", """
            import UIKit
            import UniformTypeIdentifiers

            /// Browses for documents, creates new ones and opens them.
            class DocumentBrowserViewController: UIDocumentBrowserViewController, UIDocumentBrowserViewControllerDelegate {
                override func viewDidLoad() {
                    super.viewDidLoad()
                    delegate = self
                    allowsDocumentCreation = true
                }

                func documentBrowser(_ controller: UIDocumentBrowserViewController, didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Untitled").appendingPathExtension(for: UTType(importedAs: "\(typeID)"))
                    let document = Document(fileURL: url)
                    document.save(to: url, for: .forCreating) { ok in importHandler(ok ? url : nil, .move) }
                }

                func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt urls: [URL]) {
                    if let url = urls.first { present(url) }
                }

                func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt source: URL, toDestinationURL destination: URL) {
                    present(destination)
                }

                func present(_ url: URL) {
                    let view = DocumentViewController(document: Document(fileURL: url))
                    view.modalPresentationStyle = .fullScreen
                    present(view, animated: true)
                }
            }

            """),
            ("\(folder)/DocumentViewController.swift", """
            import UIKit

            /// Shows one document's text.
            class DocumentViewController: UIViewController {
                let document: Document
                private let textView = UITextView()

                init(document: Document) {
                    self.document = document
                    super.init(nibName: nil, bundle: nil)
                }

                required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

                override func viewDidLoad() {
                    super.viewDidLoad()
                    textView.frame = view.bounds
                    textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    view.addSubview(textView)
                    document.open { [weak self] _ in self?.textView.text = self?.document.text }
                }
            }

            """),
            ("\(folder)/Document.swift", """
            import UIKit

            /// A plain-text document.
            nonisolated class Document: UIDocument {
                var text = ""

                override func contents(forType typeName: String) throws -> Any { Data(text.utf8) }

                override func load(fromContents contents: Any, ofType typeName: String?) throws {
                    text = String(decoding: contents as? Data ?? Data(), as: UTF8.self)
                }
            }

            """),
            ("\(folder)/Base.lproj/LaunchScreen.storyboard", InterfaceBuilderFiles.uikitStoryboard(.iOS, viewController: nil, module: nil, launch: true, id: "101")),
        ]
    }

    // MARK: watchOS

    static func watchApp(_ c: GenContext) throws -> GeneratedProject {
        let n = c.n
        let companion = c.option(TemplateOptionID.watchAppType) == "Watch App with New Companion iOS App"
        let watch = "\(n) Watch App"
        var files: [(String, String)] = [
            ("\(watch)/\(c.t)App.swift", "import SwiftUI\n\n@main\nstruct \(c.t)App: App {\n    var body: some Scene {\n        WindowGroup {\n            ContentView()\n        }\n    }\n}\n"),
            ("\(watch)/ContentView.swift", """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .imageScale(.large)
                            .foregroundStyle(.tint)
                        Text("\(c.lit)")
                    }
                    .padding()
                }
            }

            #Preview {
                ContentView()
            }

            """),
        ]
        files += assets(watch, platforms: ["watchOS"])
        var ws = appBlock(c, bundleID: "\(c.bundleID).watchkitapp", swiftUI: true) + platformApp(c, sdk: .watchOS, swiftUILifecycle: true)
        ws.append(("INFOPLIST_KEY_CFBundleDisplayName", .string(n)))
        ws.append(companion ? ("INFOPLIST_KEY_WKCompanionAppBundleIdentifier", .string(c.bundleID)) : ("INFOPLIST_KEY_WKWatchOnly", "YES"))
        var targets = [appTarget(watch, settings: ws, sdk: .watchOS)]
        if companion {
            files += swiftUISources(c, folder: n, storage: "None", cloud: false)
            files += assets(n, platforms: ["iOS"])
            var phone = appTarget(n, settings: appBlock(c, bundleID: c.bundleID, swiftUI: true) + iosAdditions(swiftUILifecycle: true)
                                    + [("INFOPLIST_KEY_CFBundleDisplayName", .string(n))], sdk: .iOS)
            phone.dependencies = [watch]
            phone.embeds = [.watch([watch])]
            targets.insert(phone, at: 0)
        } else {
            // The watch-only container: an iOS-SDK wrapper with no folder.
            let s: [(String, PlistValue)] = [("PRODUCT_NAME", "$(TARGET_NAME)"), ("PRODUCT_BUNDLE_IDENTIFIER", .string(c.bundleID)),
                                             ("INFOPLIST_KEY_CFBundleDisplayName", .string(n)), ("MARKETING_VERSION", "1.0"), ("CURRENT_PROJECT_VERSION", "1")]
            var container = ProjectRecipe.Target(name: n, productType: "com.apple.product-type.application.watchapp2-container", productPath: "\(n).app",
                                                 productFileType: "wrapper.application", folders: [], settings: s, phases: ["PBXResourcesBuildPhase"],
                                                 dependencies: [watch], embeds: [.watch([watch])], sdk: .iOS)
            container.swiftVersion = nil
            targets.insert(container, at: 0)
        }
        let tt = tests(c, host: watch, hostSettings: ws, hostIsApp: true, ui: true, sdk: .watchOS)
        return try recipe(c, targets + tt.targets, files + tt.files, entry: "\(watch)/ContentView.swift", projectSDK: .some(nil))
    }

    // MARK: visionOS

    /// visionOS ▸ App and Immersive Environment App.
    static func visionApp(_ c: GenContext, environment: Bool) throws -> GeneratedProject {
        let n = c.n
        let renderer = environment ? "RealityKit" : c.option(TemplateOptionID.immersiveSpaceRenderer)
        let immersive = renderer != "None"
        let volume = !environment && c.option(TemplateOptionID.initialScene) == "Volume"
        let styleName = c.option(TemplateOptionID.immersiveSpace)
        let style = ".\(styleName.lowercased())"
        var scene = "        WindowGroup {\n            ContentView()\(immersive ? "\n                .environment(appModel)" : "")\n        }\n"
        if volume { scene += "        .windowStyle(.volumetric)\n" }
        if immersive {
            if renderer == "Metal" {
                scene += """

                        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
                            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                                Renderer.start(layerRenderer)
                            }
                        }
                        .immersionStyle(selection: .constant(\(style)), in: \(style))

                """
            } else {
                scene += """

                        ImmersiveSpace(id: AppModel.immersiveSpaceID) {
                            ImmersiveView()
                                .environment(appModel)
                                .onAppear { appModel.immersiveSpaceState = .open }
                                .onDisappear { appModel.immersiveSpaceState = .closed }
                        }
                        .immersionStyle(selection: .constant(\(style)), in: \(style))

                """
            }
        }
        let imports = renderer == "Metal" ? "import CompositorServices\nimport SwiftUI" : "import SwiftUI"
        let state = immersive ? "    @State private var appModel = AppModel()\n\n" : ""
        var files: [(String, String)] = [("\(n)/\(c.t)App.swift", "\(imports)\n\n@main\nstruct \(c.t)App: App {\n\(state)    var body: some Scene {\n\(scene)    }\n}\n")]
        let button = immersive ? "                ToggleImmersiveSpaceButton()\n" : ""
        files.append(("\(n)/ContentView.swift", volume ? """
        import RealityKit
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                RealityView { content in
                    if let scene = try? await Entity(named: "Scene", in: .main) {
                        content.add(scene)
                    } else {
                        content.add(ModelEntity(mesh: .generateSphere(radius: 0.1), materials: [SimpleMaterial(color: .cyan, isMetallic: false)]))
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomOrnament) {
                        VStack(spacing: 12) {
                            Text("\(c.lit)")
        \(button.replacingOccurrences(of: "                ", with: "                    "))                }
                    }
                }
            }
        }

        """ : """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack(spacing: 16) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 48))
                    Text("\(c.lit)")
                        .font(.title)
        \(button)        }
                .padding()
            }
        }

        #Preview(windowStyle: .automatic) {
            ContentView()\(immersive ? "\n        .environment(AppModel())" : "")
        }

        """))
        files.append(("\(n)/Resources/Scene.usda", usdScene(name: "Scene", radius: 0.1)))
        if immersive {
            files.append(("\(n)/AppModel.swift", """
            import SwiftUI

            /// What the app's scenes share: whether the immersive space is open.
            @MainActor
            @Observable
            final class AppModel {
                static let immersiveSpaceID = "ImmersiveSpace"

                enum ImmersiveSpaceState {
                    case closed, inTransition, open
                }

                var immersiveSpaceState = ImmersiveSpaceState.closed
            }

            """))
            files.append(("\(n)/ToggleImmersiveSpaceButton.swift", """
            import SwiftUI

            /// Opens the immersive space, or closes it when it is open.
            struct ToggleImmersiveSpaceButton: View {
                @Environment(AppModel.self) private var appModel
                @Environment(\\.openImmersiveSpace) private var openImmersiveSpace
                @Environment(\\.dismissImmersiveSpace) private var dismissImmersiveSpace

                var body: some View {
                    Button(appModel.immersiveSpaceState == .open ? "Leave Immersive Space" : "Enter Immersive Space") {
                        Task { @MainActor in
                            switch appModel.immersiveSpaceState {
                            case .open:
                                appModel.immersiveSpaceState = .inTransition
                                await dismissImmersiveSpace()
                                appModel.immersiveSpaceState = .closed
                            case .closed:
                                appModel.immersiveSpaceState = .inTransition
                                switch await openImmersiveSpace(id: AppModel.immersiveSpaceID) {
                                case .opened: appModel.immersiveSpaceState = .open
                                default: appModel.immersiveSpaceState = .closed
                                }
                            case .inTransition:
                                break
                            }
                        }
                    }
                    .disabled(appModel.immersiveSpaceState == .inTransition)
                }
            }

            """))
            files.append(("\(n)/Resources/Immersive.usda", usdScene(name: "Immersive", radius: environment ? 30 : 0.2)))
            if renderer == "Metal" {
                files.append(("\(n)/Renderer.swift", metalImmersiveRenderer))
                files.append(("\(n)/Shaders.metal", "#include <metal_stdlib>\n#include \"ShaderTypes.h\"\nusing namespace metal;\n\nfragment float4 clearFragment() {\n    return float4(kClearRed, kClearGreen, kClearBlue, 1);\n}\n"))
                files.append(("\(n)/ShaderTypes.h", "#ifndef ShaderTypes_h\n#define ShaderTypes_h\n\n#define kClearRed 0.05\n#define kClearGreen 0.08\n#define kClearBlue 0.16\n\n#endif\n"))
            } else if environment {
                files.append(("\(n)/ImmersiveView.swift", """
                import RealityKit
                import SwiftUI

                /// The environment: a sky dome around you and a ground disc.
                struct ImmersiveView: View {
                    var body: some View {
                        RealityView { content in
                            var sky = UnlitMaterial(color: .init(red: 0.45, green: 0.65, blue: 0.9, alpha: 1))
                            sky.faceCulling = .front
                            content.add(ModelEntity(mesh: .generateSphere(radius: 30), materials: [sky]))
                            let ground = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 12),
                                                     materials: [SimpleMaterial(color: .init(white: 0.35, alpha: 1), isMetallic: false)])
                            content.add(ground)
                        }
                    }
                }

                """))
            } else {
                files.append(("\(n)/ImmersiveView.swift", """
                import RealityKit
                import SwiftUI

                /// A ring of spheres around you.
                struct ImmersiveView: View {
                    var body: some View {
                        RealityView { content in
                            for i in 0..<8 {
                                let angle = Float(i) / 8 * 2 * .pi
                                let sphere = ModelEntity(mesh: .generateSphere(radius: 0.1),
                                                         materials: [SimpleMaterial(color: .cyan, isMetallic: true)])
                                sphere.position = [sin(angle) * 1.5, 1.5, cos(angle) * 1.5]
                                content.add(sphere)
                            }
                        }
                    }
                }

                """))
            }
        }
        var configurations: [(String, PropertyListItem)] = []
        if immersive {
            let key = "UIImmersionStyle" + styleName
            configurations.append(("UISceneSessionRoleImmersiveSpaceApplication", .array([pd([("UISceneInitialImmersionStyle", .string(key))])])))
        }
        files.append(("\(n)/Info.plist", infoPlist([("UIApplicationSceneManifest", pd([
            ("UIApplicationPreferredDefaultSceneSessionRole",
             .string(volume ? "UIWindowSceneSessionRoleVolumetricApplication" : "UIWindowSceneSessionRoleApplication")),
            ("UIApplicationSupportsMultipleScenes", .bool(true)), ("UISceneConfigurations", pd(configurations)),
        ]))])))
        files += assets(n, platforms: ["visionOS"])
        var settings = appBlock(c, bundleID: c.bundleID, swiftUI: true) + platformApp(c, sdk: .visionOS, swiftUILifecycle: true)
        settings.append(("INFOPLIST_FILE", "$(TARGET_NAME)/Info.plist"))
        if renderer == "Metal" { settings.append(("SWIFT_OBJC_BRIDGING_HEADER", "$(TARGET_NAME)/ShaderTypes.h")) }
        let target = appTarget(n, settings: settings, exceptions: ["Info.plist"])
        let tt = tests(c, host: n, hostSettings: settings, hostIsApp: true, ui: false)
        return try recipe(c, [target] + tt.targets, files + tt.files, entry: "\(n)/ContentView.swift")
    }

    /// A small USD scene (Ycode's own): one sphere of `radius` meters.
    static func usdScene(name: String, radius: Double) -> String {
        """
        #usda 1.0
        (
            defaultPrim = "\(name)"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "\(name)"
        {
            def Sphere "Ball"
            {
                double radius = \(radius)
            }
        }

        """
    }

    /// A CompositorServices render loop that clears every frame.
    static let metalImmersiveRenderer = #"""
    import CompositorServices
    import Metal
    import SwiftUI

    /// The layer's formats: color, depth and the view layout.
    struct ContentStageConfiguration: CompositorLayerConfiguration {
        func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
            configuration.depthFormat = .depth32Float
            configuration.colorFormat = .bgra8Unorm_srgb
            configuration.isFoveationEnabled = capabilities.supportsFoveation
            configuration.layout = .dedicated
        }
    }

    /// Renders on its own thread until the layer is invalidated.
    nonisolated final class Renderer: @unchecked Sendable {
        let layerRenderer: LayerRenderer
        let queue: MTLCommandQueue

        init?(_ layerRenderer: LayerRenderer) {
            guard let queue = layerRenderer.device.makeCommandQueue() else { return nil }
            self.layerRenderer = layerRenderer
            self.queue = queue
        }

        static func start(_ layerRenderer: LayerRenderer) {
            guard let renderer = Renderer(layerRenderer) else { return }
            let thread = Thread { renderer.run() }
            thread.name = "Render Thread"
            thread.start()
        }

        func run() {
            while true {
                switch layerRenderer.state {
                case .paused: layerRenderer.waitUntilRunning()
                case .running: autoreleasepool { renderFrame() }
                case .invalidated: return
                @unknown default: return
                }
            }
        }

        func renderFrame() {
            guard let frame = layerRenderer.queryNextFrame() else { return }
            frame.startUpdate()
            frame.endUpdate()
            guard let timing = frame.predictTiming() else { return }
            LayerRenderer.Clock().wait(until: timing.optimalInputTime)
            frame.startSubmission()
            defer { frame.endSubmission() }
            guard let drawable = frame.queryDrawable(), let buffer = queue.makeCommandBuffer() else { return }
            for view in drawable.views.indices {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.colorTextures[min(view, drawable.colorTextures.count - 1)]
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: kClearRed, green: kClearGreen, blue: kClearBlue, alpha: 1)
                pass.depthAttachment.texture = drawable.depthTextures[min(view, drawable.depthTextures.count - 1)]
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = 0
                buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            drawable.encodePresent(commandBuffer: buffer)
            buffer.commit()
        }
    }

    """#
}
