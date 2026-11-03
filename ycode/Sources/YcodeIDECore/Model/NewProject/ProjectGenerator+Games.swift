import Foundation
import YcodePlist
import YcodeProject

// Games and augmented reality (`templates.md` § Catalog: Game, Augmented
// Reality App). Source texts are Ycode's own; the APIs are the public SDK
// documentation (SpriteKit, SceneKit, MetalKit, RealityKit, ARKit,
// GameplayKit).

extension ProjectGenerator {
    static let platformController = """
    #if os(macOS)
    import Cocoa
    typealias PlatformViewController = NSViewController
    #else
    import UIKit
    typealias PlatformViewController = UIViewController
    #endif
    """

    /// The game view controller and the technology's files, in `folder`.
    static func gameCore(_ c: GenContext, folder: String, technology: String) -> (files: [(String, String)], viewClass: String) {
        let gk = c.on(TemplateOptionID.integrateGameplayKit)
        switch technology {
        case "SceneKit":
            return ([
                ("\(folder)/GameScene.swift", """
                import SceneKit

                /// A lit scene with a camera and a slowly turning box.
                enum GameScene {
                    static func make() -> SCNScene {
                        let scene = SCNScene()
                        let box = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.1))
                        box.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 6)))
                        scene.rootNode.addChildNode(box)
                        let camera = SCNNode()
                        camera.camera = SCNCamera()
                        camera.position = SCNVector3(0, 1, 4)
                        camera.look(at: SCNVector3(0, 0, 0))
                        scene.rootNode.addChildNode(camera)
                        return scene
                    }
                }

                """),
                ("\(folder)/GameViewController.swift", """
                import SceneKit
                \(platformController)

                class GameViewController: PlatformViewController {
                    override func viewDidLoad() {
                        super.viewDidLoad()
                        guard let view = view as? SCNView else { return }
                        view.scene = GameScene.make()
                        view.allowsCameraControl = true
                        view.autoenablesDefaultLighting = true
                        view.showsStatistics = true
                    }
                }

                """),
                ("\(folder)/art.scnassets/", ""),
            ], "SCNView")
        case "Metal":
            return ([
                ("\(folder)/ShaderTypes.h", "#ifndef ShaderTypes_h\n#define ShaderTypes_h\n\n/// The triangle's size, shared by the shaders and the app.\n#define kTriangleScale 0.6\n\n#endif\n"),
                ("\(folder)/Shaders.metal", """
                #include <metal_stdlib>
                #include "ShaderTypes.h"
                using namespace metal;

                struct Fragment {
                    float4 position [[position]];
                    float4 color;
                };

                vertex Fragment triangleVertex(uint id [[vertex_id]]) {
                    const float2 corners[3] = { float2(0, 1), float2(-1, -0.8), float2(1, -0.8) };
                    const float3 colors[3] = { float3(0.95, 0.4, 0.3), float3(0.3, 0.8, 0.5), float3(0.3, 0.5, 0.95) };
                    Fragment out;
                    out.position = float4(corners[id] * kTriangleScale, 0, 1);
                    out.color = float4(colors[id], 1);
                    return out;
                }

                fragment float4 triangleFragment(Fragment in [[stage_in]]) {
                    return in.color;
                }

                """),
                ("\(folder)/Renderer.swift", #"""
                import MetalKit

                /// Draws one colored triangle and slowly cycles the background.
                final class Renderer: NSObject {
                    private let queue: MTLCommandQueue
                    private let pipeline: MTLRenderPipelineState?
                    private var time = 0.0

                    init?(view: MTKView) {
                        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
                        self.queue = queue
                        view.device = device
                        view.colorPixelFormat = .bgra8Unorm
                        let library = device.makeDefaultLibrary()
                        let descriptor = MTLRenderPipelineDescriptor()
                        descriptor.vertexFunction = library?.makeFunction(name: "triangleVertex")
                        descriptor.fragmentFunction = library?.makeFunction(name: "triangleFragment")
                        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
                        super.init()
                    }

                    func render(in view: MTKView) {
                        time += 1 / Double(max(view.preferredFramesPerSecond, 1))
                        let shade = 0.1 + 0.05 * sin(time)
                        view.clearColor = MTLClearColor(red: shade, green: shade * 1.2, blue: shade * 2, alpha: 1)
                        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                              let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
                        if let pipeline {
                            encoder.setRenderPipelineState(pipeline)
                            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        }
                        encoder.endEncoding()
                        buffer.present(drawable)
                        buffer.commit()
                    }
                }

                extension Renderer: MTKViewDelegate {
                    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

                    nonisolated func draw(in view: MTKView) {
                        MainActor.assumeIsolated { render(in: view) }
                    }
                }

                """#),
                ("\(folder)/GameViewController.swift", """
                import MetalKit
                \(platformController)

                class GameViewController: PlatformViewController {
                    private var renderer: Renderer?

                    override func viewDidLoad() {
                        super.viewDidLoad()
                        guard let view = view as? MTKView else { return }
                        renderer = Renderer(view: view)
                        view.delegate = renderer
                    }
                }

                """),
            ], "MTKView")
        default:
            return ([
                ("\(folder)/GameScene.swift", """
                \(gk ? "import GameplayKit\n" : "")import SpriteKit

                /// A spinning tile; each tap or click leaves a ring that fades out.
                class GameScene: SKScene {
                \(gk ? "    /// The scene's entities; each frame updates their components.\n    var entities: [GKEntity] = []\n    private var lastUpdate: TimeInterval = 0\n\n" : "")    override func didMove(to view: SKView) {
                        backgroundColor = SKColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 1)
                        let tile = SKShapeNode(rectOf: CGSize(width: 90, height: 90), cornerRadius: 18)
                        tile.name = "tile"
                        tile.fillColor = SKColor(red: 0.2, green: 0.7, blue: 0.9, alpha: 1)
                        tile.strokeColor = .clear
                        tile.position = CGPoint(x: frame.midX, y: frame.midY)
                        tile.run(.repeatForever(.rotate(byAngle: .pi, duration: 1.5)))
                        addChild(tile)
                    }

                    override func didChangeSize(_ oldSize: CGSize) {
                        childNode(withName: "tile")?.position = CGPoint(x: frame.midX, y: frame.midY)
                    }
                \(gk ? "\n    override func update(_ currentTime: TimeInterval) {\n        let dt = lastUpdate == 0 ? 0 : currentTime - lastUpdate\n        lastUpdate = currentTime\n        for entity in entities { entity.update(deltaTime: dt) }\n    }\n" : "")
                    func ring(at point: CGPoint) {
                        let ring = SKShapeNode(circleOfRadius: 24)
                        ring.strokeColor = .white
                        ring.lineWidth = 3
                        ring.position = point
                        addChild(ring)
                        ring.run(.sequence([.group([.scale(to: 3, duration: 0.6), .fadeOut(withDuration: 0.6)]), .removeFromParent()]))
                    }

                    #if os(macOS)
                    override func mouseDown(with event: NSEvent) {
                        ring(at: event.location(in: self))
                    }
                    #else
                    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
                        for touch in touches { ring(at: touch.location(in: self)) }
                    }
                    #endif
                }

                """),
                ("\(folder)/GameViewController.swift", """
                import SpriteKit
                \(platformController)

                class GameViewController: PlatformViewController {
                    override func viewDidLoad() {
                        super.viewDidLoad()
                        guard let view = view as? SKView else { return }
                        let scene = GameScene(size: view.bounds.size)
                        scene.scaleMode = .resizeFill
                        view.presentScene(scene)
                        view.ignoresSiblingOrder = true
                        view.showsFPS = true
                        view.showsNodeCount = true
                    }
                }

                """),
            ], "SKView")
        }
    }

    /// The RealityKit game: a SwiftUI app with a spinning box.
    static func realityKitGameFiles(_ c: GenContext, folder: String) -> [(String, String)] {
        [
            ("\(folder)/\(c.t)App.swift", """
            import RealityKit
            import SwiftUI

            @main
            struct \(c.t)App: App {
                init() {
                    SpinComponent.registerComponent()
                    SpinSystem.registerSystem()
                }

                var body: some SwiftUI.Scene {
                    WindowGroup {
                        ContentView()
                    }
                }
            }

            """),
            ("\(folder)/ContentView.swift", """
            import RealityKit
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    RealityView { content in
                        let box = ModelEntity(mesh: .generateBox(size: 0.2, cornerRadius: 0.02),
                                              materials: [SimpleMaterial(color: .cyan, isMetallic: false)])
                        box.position = [0, 0, -0.6]
                        box.components.set(SpinComponent())
                        content.add(box)
                    }
                    .ignoresSafeArea()
                }
            }

            """),
            ("\(folder)/SpinComponent.swift", """
            import RealityKit

            /// Turns an entity about its vertical axis.
            struct SpinComponent: Component {
                var radiansPerSecond: Float = 1
            }

            /// Applies every `SpinComponent` each frame.
            struct SpinSystem: System {
                static let query = EntityQuery(where: .has(SpinComponent.self))

                init(scene: RealityKit.Scene) {}

                func update(context: SceneUpdateContext) {
                    for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
                        guard let spin = entity.components[SpinComponent.self] else { continue }
                        let turn = simd_quatf(angle: spin.radiansPerSecond * Float(context.deltaTime), axis: [0, 1, 0])
                        entity.transform.rotation = turn * entity.transform.rotation
                    }
                }
            }

            """),
        ]
    }

    /// The UIKit app files of a game (iOS or tvOS): delegates, storyboards
    /// and the scene manifest.
    static func uikitGameShell(_ c: GenContext, folder: String, rt: InterfaceBuilderFiles.Runtime, viewClass: String, module: String) -> [(String, String)] {
        [
            ("\(folder)/AppDelegate.swift", "import UIKit\n\n@main\nclass AppDelegate: UIResponder, UIApplicationDelegate {\n    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,\n                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {\n        UISceneConfiguration(name: \"Default Configuration\", sessionRole: connectingSceneSession.role)\n    }\n}\n"),
            ("\(folder)/SceneDelegate.swift", "import UIKit\n\nclass SceneDelegate: UIResponder, UIWindowSceneDelegate {\n    var window: UIWindow?\n}\n"),
            ("\(folder)/Base.lproj/Main.storyboard", InterfaceBuilderFiles.uikitStoryboard(rt, viewController: "GameViewController", module: module, viewClass: viewClass)),
            ("\(folder)/Base.lproj/LaunchScreen.storyboard", InterfaceBuilderFiles.uikitStoryboard(rt, viewController: nil, module: nil, launch: rt == .iOS, id: "101")),
            ("\(folder)/Info.plist", infoPlist([("UIApplicationSceneManifest", InterfaceBuilderFiles.sceneManifest(storyboard: "Main"))])),
        ]
    }

    static func uikitGameSettings(metal: Bool) -> [(String, PlistValue)] {
        var s: [(String, PlistValue)] = [("INFOPLIST_KEY_UIMainStoryboardFile", "Main"), ("INFOPLIST_KEY_UILaunchStoryboardName", "LaunchScreen"),
                                         ("INFOPLIST_KEY_UIStatusBarHidden", "YES"), ("INFOPLIST_FILE", "$(TARGET_NAME)/Info.plist")]
        if metal { s.append(("INFOPLIST_KEY_UIRequiredDeviceCapabilities", "metal")) }
        return s
    }

    static func game(_ c: GenContext) throws -> GeneratedProject {
        let tech = c.option(TemplateOptionID.gameTechnology)
        let n = c.n
        let metal = tech == "Metal"
        let bridging: [(String, PlistValue)] = metal ? [("SWIFT_OBJC_BRIDGING_HEADER", "$(TARGET_NAME)/ShaderTypes.h")] : []
        switch c.sdk.sdkroot {
        case "auto": return try multiplatformGame(c, tech: tech)
        case "macosx":
            var files: [(String, String)]
            var settings = appBlock(c, bundleID: c.bundleID, swiftUI: tech == "RealityKit")
            if tech == "RealityKit" {
                files = realityKitGameFiles(c, folder: n)
                settings += macAdditions(c, cocoa: false)
            } else {
                let core = gameCore(c, folder: n, technology: tech)
                files = core.files + cocoaSources(c, folder: n, xib: false, objc: false).filter { !$0.0.hasSuffix("ViewController.swift") }
                files = files.map { f in
                    f.0.hasSuffix("Main.storyboard")
                        ? (f.0, InterfaceBuilderFiles.cocoaStoryboard(appName: n, module: c.module, viewController: "GameViewController", viewClass: core.viewClass))
                        : f
                }
                settings += macAdditions(c, cocoa: true) + [("INFOPLIST_KEY_NSMainStoryboardFile", "Main")] + bridging
            }
            settings.append(("MACOSX_DEPLOYMENT_TARGET", .string(TemplateSDK.version("MACOSX_DEPLOYMENT_TARGET"))))
            files += assets(n, platforms: ["macOS"])
            let tt = tests(c, host: n, hostSettings: settings, hostIsApp: true, ui: true)
            return try recipe(c, [appTarget(n, settings: settings)] + tt.targets, files + tt.files,
                              entry: tech == "RealityKit" ? "\(n)/ContentView.swift" : "\(n)/GameViewController.swift")
        default:
            let tv = c.sdk.sdkroot == "appletvos"
            var files: [(String, String)]
            var settings = appBlock(c, bundleID: c.bundleID, swiftUI: tech == "RealityKit") + platformApp(c, sdk: c.sdk, swiftUILifecycle: tech == "RealityKit")
            var exceptions: [String] = []
            if tech == "RealityKit" {
                files = realityKitGameFiles(c, folder: n)
                settings.append(("INFOPLIST_KEY_NSCameraUsageDescription", "The camera shows the world the game is placed in."))
            } else {
                let core = gameCore(c, folder: n, technology: tech)
                files = core.files + uikitGameShell(c, folder: n, rt: tv ? .tvOS : .iOS, viewClass: core.viewClass, module: c.module)
                settings.removeAll { $0.0 == "INFOPLIST_KEY_UILaunchScreen_Generation" }
                settings += uikitGameSettings(metal: metal) + bridging
                exceptions = ["Info.plist"]
            }
            files += assets(n, platforms: iconPlatforms(c.sdk))
            let tt = tests(c, host: n, hostSettings: settings, hostIsApp: true, ui: true)
            return try recipe(c, [appTarget(n, settings: settings, exceptions: exceptions)] + tt.targets, files + tt.files,
                              entry: tech == "RealityKit" ? "\(n)/ContentView.swift" : "\(n)/GameViewController.swift")
        }
    }

    /// Multiplatform ▸ Game: RealityKit is one SDK-`auto` target; the other
    /// technologies share "N Shared" across one target per platform.
    static func multiplatformGame(_ c: GenContext, tech: String) throws -> GeneratedProject {
        let n = c.n
        let ios = c.on(TemplateOptionID.iOSPlatform), mac = c.on(TemplateOptionID.macOSPlatform)
        let tv = c.on(TemplateOptionID.tvOSPlatform), vision = c.on(TemplateOptionID.visionOSPlatform)
        if tech == "RealityKit" {
            // How the checkboxes narrow the one target is OPEN; Ycode lists
            // the checked platforms.
            var platforms: [String] = [], families: [String] = [], keys: [String] = [], icons: [String] = []
            if ios { platforms += ["iphoneos", "iphonesimulator"]; families += ["1", "2"]; keys.append("IPHONEOS_DEPLOYMENT_TARGET"); icons.append("iOS") }
            if mac { platforms.append("macosx"); keys.append("MACOSX_DEPLOYMENT_TARGET"); icons.append("macOS") }
            if tv { platforms += ["appletvos", "appletvsimulator"]; families.append("3"); keys.append("TVOS_DEPLOYMENT_TARGET"); icons.append("tvOS") }
            if vision { platforms += ["xros", "xrsimulator"]; families.append("7"); keys.append("XROS_DEPLOYMENT_TARGET"); icons.append("visionOS") }
            var s = appBlock(c, bundleID: c.bundleID, swiftUI: true) + [("SDKROOT", "auto"), ("SUPPORTED_PLATFORMS", .string(platforms.joined(separator: " "))),
                                                                       ("INFOPLIST_KEY_NSCameraUsageDescription", "The camera shows the world the game is placed in.")]
            if !families.isEmpty { s.append(("TARGETED_DEVICE_FAMILY", .string(families.joined(separator: ",")))) }
            s += keys.map { ($0, .string(TemplateSDK.version($0))) }
            s += [("LD_RUNPATH_SEARCH_PATHS", ["$(inherited)", "@executable_path/Frameworks"]),
                  ("LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]", ["$(inherited)", "@executable_path/../Frameworks"])]
            if mac { s += [("ENABLE_APP_SANDBOX[sdk=macosx*]", "YES"), ("ENABLE_USER_SELECTED_FILES[sdk=macosx*]", "readonly")] }
            if ios {
                s += [("INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphoneos*]", "YES"),
                      ("INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphonesimulator*]", "YES"),
                      ("INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphoneos*]", "YES"), ("INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphonesimulator*]", "YES")]
            }
            let files = realityKitGameFiles(c, folder: n) + assets(n, platforms: icons)
            return try recipe(c, [appTarget(n, settings: s)], files, entry: "\(n)/ContentView.swift")
        }
        let shared = "\(n) Shared"
        let core = gameCore(c, folder: shared, technology: tech)
        var files = core.files + assets(shared, platforms: (ios ? ["iOS"] : []) + (mac ? ["macOS"] : []) + (tv ? ["tvOS"] : []))
        var targets: [ProjectRecipe.Target] = []
        let bridging: [(String, PlistValue)] = tech == "Metal" ? [("SWIFT_OBJC_BRIDGING_HEADER", .string("\(shared)/ShaderTypes.h"))] : []
        func add(_ suffix: String, _ sdk: TemplateSDK) {
            let name = "\(n) \(suffix)"
            let module = name.templateModuleName
            var s = appBlock(c, bundleID: c.bundleID, swiftUI: false) + bridging
            if sdk.sdkroot == "macosx" {
                files += [("\(name)/AppDelegate.swift", "import Cocoa\n\n@main\nclass AppDelegate: NSObject, NSApplicationDelegate {\n    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {\n        true\n    }\n}\n"),
                          ("\(name)/Base.lproj/Main.storyboard", InterfaceBuilderFiles.cocoaStoryboard(appName: n, module: module, viewController: "GameViewController",
                                                                                                       viewClass: core.viewClass))]
                s += macAdditions(c, cocoa: true) + [("INFOPLIST_KEY_NSMainStoryboardFile", "Main")]
                targets.append(appTarget(name, settings: s, sdk: sdk, folders: [name, shared]))
            } else {
                files += uikitGameShell(c, folder: name, rt: sdk.sdkroot == "appletvos" ? .tvOS : .iOS, viewClass: core.viewClass, module: module)
                s += platformApp(c, sdk: sdk, swiftUILifecycle: false).filter { $0.0 != "INFOPLIST_KEY_UILaunchScreen_Generation" }
                s += uikitGameSettings(metal: tech == "Metal")
                targets.append(appTarget(name, settings: s, sdk: sdk, exceptions: ["Info.plist"], folders: [name, shared]))
            }
        }
        if ios { add("iOS", .iOS) }
        if tv { add("tvOS", .tvOS) }
        if mac { add("macOS", .macOS) }
        return try recipe(c, targets, files, entry: "\(shared)/GameViewController.swift", projectSDK: .some(nil))
    }

    static func arApp(_ c: GenContext) throws -> GeneratedProject {
        let n = c.n
        let tech = c.option(TemplateOptionID.contentTechnology)
        var files: [(String, String)] = [
            ("\(n)/AppDelegate.swift", "import UIKit\n\n@main\nclass AppDelegate: UIResponder, UIApplicationDelegate {\n    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,\n                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {\n        UISceneConfiguration(name: \"Default Configuration\", sessionRole: connectingSceneSession.role)\n    }\n}\n"),
            ("\(n)/Base.lproj/LaunchScreen.storyboard", InterfaceBuilderFiles.uikitStoryboard(.iOS, viewController: nil, module: nil, launch: true, id: "101")),
        ]
        var settings = appBlock(c, bundleID: c.bundleID, swiftUI: tech == "RealityKit") + iosAdditions(swiftUILifecycle: false) + [
            ("INFOPLIST_KEY_NSCameraUsageDescription", "The camera shows the world your content is placed in."),
            ("INFOPLIST_KEY_UIRequiredDeviceCapabilities", "arkit"), ("INFOPLIST_KEY_UIStatusBarHidden", "YES"),
            ("INFOPLIST_KEY_UILaunchStoryboardName", "LaunchScreen"), ("INFOPLIST_FILE", .string("\(n)/Info.plist")),
        ]
        if tech == "RealityKit" {
            files += [
                ("\(n)/SceneDelegate.swift", """
                import SwiftUI
                import UIKit

                class SceneDelegate: UIResponder, UIWindowSceneDelegate {
                    var window: UIWindow?

                    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
                        guard let scene = scene as? UIWindowScene else { return }
                        let window = UIWindow(windowScene: scene)
                        window.rootViewController = UIHostingController(rootView: ContentView())
                        window.makeKeyAndVisible()
                        self.window = window
                    }
                }

                """),
                ("\(n)/ContentView.swift", """
                import ARKit
                import RealityKit
                import SwiftUI

                struct ContentView: View {
                    var body: some View {
                        ARViewContainer()
                            .ignoresSafeArea()
                    }
                }

                /// The camera's view with a box anchored to the first horizontal plane.
                struct ARViewContainer: UIViewRepresentable {
                    func makeUIView(context: Context) -> ARView {
                        let view = ARView(frame: .zero)
                        let anchor = AnchorEntity(plane: .horizontal)
                        anchor.addChild(ModelEntity(mesh: .generateBox(size: 0.1, cornerRadius: 0.01),
                                                    materials: [SimpleMaterial(color: .cyan, isMetallic: false)]))
                        view.scene.addAnchor(anchor)
                        return view
                    }

                    func updateUIView(_ view: ARView, context: Context) {}
                }

                """),
                ("\(n)/Info.plist", infoPlist([("UIApplicationSceneManifest", InterfaceBuilderFiles.sceneManifest(storyboard: nil))])),
            ]
        } else {
            let sceneKit = tech == "SceneKit"
            let body = sceneKit ? """
                override func viewDidLoad() {
                    super.viewDidLoad()
                    guard let view = view as? ARSCNView else { return }
                    let box = SCNNode(geometry: SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0.01))
                    box.position = SCNVector3(0, 0, -0.5)
                    view.scene.rootNode.addChildNode(box)
                    view.autoenablesDefaultLighting = true
                }

                override func viewWillAppear(_ animated: Bool) {
                    super.viewWillAppear(animated)
                    (view as? ARSCNView)?.session.run(ARWorldTrackingConfiguration())
                }

            """ : """
                override func viewDidLoad() {
                    super.viewDidLoad()
                    guard let view = view as? ARSKView else { return }
                    view.presentScene(SKScene(size: view.bounds.size))
                }

                override func viewWillAppear(_ animated: Bool) {
                    super.viewWillAppear(animated)
                    (view as? ARSKView)?.session.run(ARWorldTrackingConfiguration())
                }

            """
            files += uikitSwiftSources(c, folder: n, rt: .iOS, viewControllerImports: sceneKit ? "import ARKit\nimport SceneKit\nimport UIKit" : "import ARKit\nimport SpriteKit\nimport UIKit",
                                       viewControllerBody: body, viewClass: sceneKit ? "ARSCNView" : "ARSKView", launchScreen: false)
                .filter { $0.0 != "\(n)/AppDelegate.swift" }
            if sceneKit { files.append(("\(n)/art.scnassets/", "")) }
            settings.append(("INFOPLIST_KEY_UIMainStoryboardFile", "Main"))
        }
        files += assets(n, platforms: ["iOS"])
        let tt = tests(c, host: n, hostSettings: settings, hostIsApp: true, ui: true)
        return try recipe(c, [appTarget(n, settings: settings, exceptions: ["Info.plist"])] + tt.targets, files + tt.files,
                          entry: tech == "RealityKit" ? "\(n)/ContentView.swift" : "\(n)/ViewController.swift")
    }
}
