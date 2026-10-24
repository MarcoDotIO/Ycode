// RKProbe: black-box probe of RealityKit behaviour in the iOS simulator.
// Original Ycode research code (KIT-REALITYKIT). It uses only the public SDK.
// Each run executes one mode (launch argument `-mode <name>`) and prints
// `RKP <key>=<value>` lines to stdout. Screenshots are taken from outside
// with `simctl io screenshot`.
import SwiftUI
import RealityKit
import ARKit
import Metal
import AVFoundation
import Combine
import CoreGraphics

// MARK: - logging

let t0 = Date()
func now() -> Double { Date().timeIntervalSince(t0) }
func log(_ key: String, _ value: Any) {
    print("RKP \(key)=\(value)")
    fflush(stdout)
}
func f3(_ v: SIMD3<Float>) -> String { String(format: "(%.4f,%.4f,%.4f)", v.x, v.y, v.z) }
func q4(_ q: simd_quatf) -> String { String(format: "(%.4f,%.4f,%.4f,%.4f)", q.vector.x, q.vector.y, q.vector.z, q.vector.w) }
func bb(_ b: BoundingBox) -> String { "min\(f3(b.min)) max\(f3(b.max))" }
func compNames(_ e: Entity) -> String {
    e.components.map { String(describing: type(of: $0)) }.sorted().joined(separator: ",")
}
func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
}

let mode: String = {
    let a = ProcessInfo.processInfo.arguments
    if let i = a.firstIndex(of: "-mode"), i + 1 < a.count { return a[i + 1] }
    return "rv-basic"
}()

var keep: [Any] = []  // subscriptions and other objects kept alive

// MARK: - Metal facts

func logMetal() {
    guard let d = MTLCreateSystemDefaultDevice() else { log("metal.device", "nil"); return }
    log("metal.name", d.name)
    var fams: [String] = []
    let all: [(String, MTLGPUFamily)] = [("apple1", .apple1), ("apple2", .apple2), ("apple3", .apple3),
        ("apple4", .apple4), ("apple5", .apple5), ("apple6", .apple6), ("apple7", .apple7),
        ("apple8", .apple8), ("apple9", .apple9), ("mac2", .mac2), ("common1", .common1),
        ("common2", .common2), ("common3", .common3), ("metal3", .metal3)]
    for (n, f) in all where d.supportsFamily(f) { fams.append(n) }
    log("metal.families", fams.joined(separator: ","))
    log("metal.argumentBuffersTier", d.argumentBuffersSupport.rawValue)
    log("metal.raytracing", d.supportsRaytracing)
    log("metal.maxThreadsPerThreadgroup", "\(d.maxThreadsPerThreadgroup.width)")
    log("metal.readWriteTextureTier", d.readWriteTextureSupport.rawValue)
    log("metal.sampleCount4", d.supportsTextureSampleCount(4))
    log("metal.maxBufferLength", d.maxBufferLength)
}

// MARK: - shared scene

@MainActor func makeStage() -> Entity {
    let root = Entity()
    root.name = "root"
    let floor = ModelEntity(mesh: .generatePlane(width: 2, depth: 2),
                            materials: [SimpleMaterial(color: .gray, roughness: 0.8, isMetallic: false)])
    floor.name = "floor"
    root.addChild(floor)

    let box = ModelEntity(mesh: .generateBox(size: 0.2), materials: [SimpleMaterial(color: .red, isMetallic: false)])
    box.name = "box"; box.position = [-0.35, 0.1, 0]
    root.addChild(box)

    var pbr = PhysicallyBasedMaterial()
    pbr.baseColor = .init(tint: .green)
    pbr.metallic = 1.0
    pbr.roughness = 0.25
    let sphere = ModelEntity(mesh: .generateSphere(radius: 0.1), materials: [pbr])
    sphere.name = "sphere"; sphere.position = [0, 0.1, 0]
    root.addChild(sphere)

    let cyl = ModelEntity(mesh: .generateCylinder(height: 0.2, radius: 0.08), materials: [UnlitMaterial(color: .blue)])
    cyl.name = "cylinder"; cyl.position = [0.35, 0.1, 0]
    root.addChild(cyl)

    let sun = DirectionalLight()
    sun.name = "sun"
    sun.light.intensity = 3000
    sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 4, depthBias: 1)
    sun.look(at: [0, 0, 0], from: [1, 2, 1.5], relativeTo: nil)
    root.addChild(sun)

    let cam = PerspectiveCamera()
    cam.name = "camera"
    cam.camera.fieldOfViewInDegrees = 60
    cam.look(at: [0, 0.1, 0], from: [0, 0.7, 1.3], relativeTo: nil)
    root.addChild(cam)
    return root
}

@MainActor func frameCounter(_ subscribe: (@escaping (SceneEvents.Update) -> Void) -> Void, label: String) {
    var n = 0
    var dts: [Double] = []
    var start: Double = -1
    subscribe { e in
        if start < 0 { start = now(); log("\(label).firstUpdateAt", String(format: "%.3f", start)) }
        n += 1
        if dts.count < 600 { dts.append(e.deltaTime) }
    }
    after(6) {
        let el = now() - start
        let mean = dts.reduce(0, +) / Double(max(1, dts.count))
        log("\(label).updates", n)
        log("\(label).updatesPerSecond", String(format: "%.1f", Double(n) / max(el, 0.001)))
        log("\(label).deltaTime", String(format: "mean %.5f min %.5f max %.5f first %@", mean, dts.min() ?? 0, dts.max() ?? 0,
                                         dts.prefix(4).map { String(format: "%.4f", $0) }.joined(separator: ",")))
        log("framecounter.done", 1)
    }
}

// MARK: - ECS probe

struct ProbeComponent: Component { var n = 0 }
struct OtherComponent: Component { var s = "x" }
struct TransientProbe: TransientComponent { var v = 1 }
var ecsTrace: [String] = []
var frameNo = 0
func trace(_ s: String) { if ecsTrace.count < 400 { ecsTrace.append("f\(frameNo):\(s)") } }

struct SysA: System {
    static let query = EntityQuery(where: .has(ProbeComponent.self))
    init(scene: RealityKit.Scene) { trace("A.init") }
    func update(context: SceneUpdateContext) {
        var c = 0
        for e in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            c += 1
            if var p = e.components[ProbeComponent.self] { p.n += 1; e.components.set(p) }
        }
        if frameNo < 4 { trace("A.update(n=\(c),dt=\(String(format: "%.4f", context.deltaTime)))") }
    }
}
struct SysB: System {
    static var dependencies: [SystemDependency] { [.after(SysA.self)] }
    init(scene: RealityKit.Scene) { trace("B.init") }
    func update(context: SceneUpdateContext) { if frameNo < 4 { trace("B.update") } }
}
struct SysC: System {
    static var dependencies: [SystemDependency] { [.before(SysA.self)] }
    init(scene: RealityKit.Scene) { trace("C.init") }
    func update(context: SceneUpdateContext) { if frameNo < 4 { trace("C.update") } }
}

@MainActor func ecsProbe(root: Entity, scene: RealityKit.Scene) {
    // Default component sets of the built-in entity classes.
    log("ecs.Entity.components", compNames(Entity()))
    log("ecs.ModelEntity.components", compNames(ModelEntity()))
    log("ecs.ModelEntityMesh.components", compNames(ModelEntity(mesh: .generateBox(size: 0.1))))
    log("ecs.AnchorEntity.components", compNames(AnchorEntity()))
    log("ecs.AnchorEntityPlane.components", compNames(AnchorEntity(plane: .horizontal)))
    log("ecs.PerspectiveCamera.components", compNames(PerspectiveCamera()))
    log("ecs.DirectionalLight.components", compNames(DirectionalLight()))
    log("ecs.PointLight.components", compNames(PointLight()))
    log("ecs.SpotLight.components", compNames(SpotLight()))
    log("ecs.TriggerVolume.components", compNames(TriggerVolume(shape: .generateSphere(radius: 0.1))))
    let defLight = PointLightComponent(color: .white)
    log("ecs.PointLightComponent.default", "intensity \(defLight.intensity) radius \(defLight.attenuationRadius) falloff \(defLight.attenuationFalloffExponent)")
    let dl = DirectionalLightComponent()
    log("ecs.DirectionalLightComponent.default", "intensity \(dl.intensity)")
    let sl = SpotLightComponent()
    log("ecs.SpotLightComponent.default", "intensity \(sl.intensity) inner \(sl.innerAngleInDegrees) outer \(sl.outerAngleInDegrees) radius \(sl.attenuationRadius)")
    let pc = PerspectiveCameraComponent()
    log("ecs.PerspectiveCameraComponent.default", "near \(pc.near) far \(pc.far) fov \(pc.fieldOfViewInDegrees) orient \(pc.fieldOfViewOrientation)")
    let oc = OrthographicCameraComponent()
    log("ecs.OrthographicCameraComponent.default", "near \(oc.near) far \(oc.far) scale \(oc.scale)")
    let pb = PhysicsBodyComponent()
    log("ecs.PhysicsBodyComponent.default", "mode \(pb.mode) mass \(pb.massProperties.mass) gravity \(pb.isAffectedByGravity) linDamp \(pb.linearDamping) angDamp \(pb.angularDamping) ccd \(pb.isContinuousCollisionDetectionEnabled)")
    let psc = PhysicsSimulationComponent()
    log("ecs.PhysicsSimulationComponent.default", "gravity \(f3(psc.gravity)) solver \(psc.solverIterations.positionIterations)/\(psc.solverIterations.velocityIterations)")
    let ccc = CharacterControllerComponent()
    log("ecs.CharacterControllerComponent.default", "radius \(ccc.radius) height \(ccc.height) skin \(ccc.skinWidth) slope \(ccc.slopeLimit) step \(ccc.stepLimit) up \(f3(ccc.upVector))")
    log("ecs.CollisionFilter.default", "group \(CollisionFilter.default.group.rawValue) mask \(CollisionFilter.default.mask.rawValue) sensor \(CollisionFilter.sensor.group.rawValue)/\(CollisionFilter.sensor.mask.rawValue)")
    log("ecs.PhysicsMaterial.default", "\(PhysicsMaterialResource.default)")

    // Transform math.
    let parent = Entity(); parent.position = [1, 0, 0]; parent.scale = [2, 2, 2]
    parent.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
    let child = Entity(); parent.addChild(child); child.position = [0, 0, -1]
    log("tf.childWorldPos", f3(child.position(relativeTo: nil)))
    child.setPosition([0, 0, 0], relativeTo: nil)
    log("tf.childLocalAfterSetWorldOrigin", f3(child.position))
    let looker = Entity(); looker.look(at: [0, 0, -1], from: [0, 0, 0], relativeTo: nil)
    log("tf.lookAtNegZ", q4(looker.orientation))
    looker.look(at: [1, 0, 0], from: [0, 0, 0], relativeTo: nil)
    log("tf.lookAtPosX", q4(looker.orientation))
    looker.look(at: [1, 0, 0], from: [0, 0, 0], upVector: [0, 1, 0], relativeTo: nil, forward: .positiveZ)
    log("tf.lookAtPosX.forwardPosZ", q4(looker.orientation))
    let tr = Transform(pitch: .pi / 2, yaw: 0, roll: 0)
    log("tf.pitch90", q4(tr.rotation))
    log("tf.yaw90", q4(Transform(pitch: 0, yaw: .pi / 2, roll: 0).rotation))
    log("tf.convertDir", f3(parent.convert(direction: [0, 0, -1], to: nil)))
    let sbox = ModelEntity(mesh: .generateBox(size: 0.2)); sbox.scale = [2, 1, 1]; sbox.position = [0, 1, 0]
    log("tf.visualBoundsScaled", bb(sbox.visualBounds(relativeTo: nil)))
    let clone = sbox.clone(recursive: true)
    log("ecs.clone", "sameID \(clone.id == sbox.id) comps \(compNames(clone))")
    let tc = Entity(); tc.components.set(TransientProbe()); tc.components.set(ProbeComponent())
    log("ecs.cloneTransient", compNames(tc.clone(recursive: false)))
    log("ecs.entityIDsMonotonic", "\(Entity().id) \(Entity().id)")

    // Events and systems.
    keep.append(scene.subscribe(to: SceneEvents.DidAddEntity.self) { e in if e.entity.name.hasPrefix("ev") { trace("DidAddEntity(\(e.entity.name))") } })
    keep.append(scene.subscribe(to: SceneEvents.DidActivateEntity.self) { e in if e.entity.name.hasPrefix("ev") { trace("DidActivateEntity(\(e.entity.name))") } })
    keep.append(scene.subscribe(to: SceneEvents.WillDeactivateEntity.self) { e in if e.entity.name.hasPrefix("ev") { trace("WillDeactivateEntity(\(e.entity.name))") } })
    keep.append(scene.subscribe(to: SceneEvents.WillRemoveEntity.self) { e in if e.entity.name.hasPrefix("ev") { trace("WillRemoveEntity(\(e.entity.name))") } })
    keep.append(scene.subscribe(to: SceneEvents.DidReparentEntity.self) { e in if e.child.name.hasPrefix("ev") { trace("DidReparent(\(e.child.name))") } })
    keep.append(scene.subscribe(to: ComponentEvents.DidAdd.self) { e in if e.entity.name.hasPrefix("ev") { trace("C.DidAdd(\(e.entity.name),\(e.componentType))") } })
    keep.append(scene.subscribe(to: ComponentEvents.DidActivate.self) { e in if e.entity.name.hasPrefix("ev") { trace("C.DidActivate(\(e.entity.name),\(e.componentType))") } })
    keep.append(scene.subscribe(to: ComponentEvents.DidChange.self) { e in if e.entity.name.hasPrefix("ev") { trace("C.DidChange(\(e.entity.name),\(e.componentType))") } })
    keep.append(scene.subscribe(to: ComponentEvents.WillDeactivate.self) { e in if e.entity.name.hasPrefix("ev") { trace("C.WillDeactivate(\(e.entity.name),\(e.componentType))") } })
    keep.append(scene.subscribe(to: ComponentEvents.WillRemove.self) { e in if e.entity.name.hasPrefix("ev") { trace("C.WillRemove(\(e.entity.name),\(e.componentType))") } })
    keep.append(scene.subscribe(to: SceneEvents.Update.self) { e in
        frameNo += 1
        if frameNo < 4 { trace("SceneEvents.Update(dt=\(String(format: "%.4f", e.deltaTime)))") }
    })

    let ev = Entity(); ev.name = "ev1"
    trace("op:addComponentDetached")
    ev.components.set(ProbeComponent())
    trace("op:addChild")
    root.addChild(ev)
    trace("op:setComponent")
    ev.components.set(ProbeComponent(n: 100))
    trace("op:addOther")
    ev.components.set(OtherComponent())
    trace("op:done-sync")
    after(0.5) {
        trace("op:disable")
        ev.isEnabled = false
        trace("op:enable")
        ev.isEnabled = true
        trace("op:removeOther")
        ev.components.remove(OtherComponent.self)
        trace("op:reparent")
        let ev2 = Entity(); ev2.name = "ev2"; root.addChild(ev2)
        ev2.addChild(ev)
        trace("op:removeFromParent")
        ev2.removeFromParent()
        trace("op:done2")
    }
    after(1.5) {
        log("ecs.probeCounter", ev.components[ProbeComponent.self]?.n ?? -1)
        for (i, l) in ecsTrace.enumerated() { log("ecs.trace.\(String(format: "%03d", i))", l) }
        let q = scene.performQuery(EntityQuery(where: .has(ModelComponent.self)))
        var names: [String] = []
        for e in q { names.append(e.name) }
        log("ecs.queryModel", names.sorted().joined(separator: ","))
    }
}

// MARK: - physics probe

@MainActor func physicsProbe(root: Entity, scene: RealityKit.Scene) {
    let floor = ModelEntity(mesh: .generateBox(width: 4, height: 0.1, depth: 4), materials: [SimpleMaterial(color: .gray, isMetallic: false)])
    floor.name = "pfloor"; floor.position = [0, -0.05, 0]
    floor.collision = CollisionComponent(shapes: [.generateBox(width: 4, height: 0.1, depth: 4)])
    floor.physicsBody = PhysicsBodyComponent(massProperties: .default, material: .generate(friction: 0.5, restitution: 0.0), mode: .static)
    root.addChild(floor)

    let cube = ModelEntity(mesh: .generateBox(size: 0.1), materials: [SimpleMaterial(color: .red, isMetallic: false)])
    cube.name = "pcube"; cube.position = [-0.3, 1.0, 0]
    cube.collision = CollisionComponent(shapes: [.generateBox(size: [0.1, 0.1, 0.1])])
    cube.physicsBody = PhysicsBodyComponent(shapes: [.generateBox(size: [0.1, 0.1, 0.1])], density: 1000, material: .generate(friction: 0.5, restitution: 0), mode: .dynamic)
    root.addChild(cube)
    log("phys.cube.mass(density1000,0.1m)", cube.physicsBody!.massProperties.mass)
    log("phys.cube.inertia", f3(cube.physicsBody!.massProperties.inertia))

    let ball = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [SimpleMaterial(color: .yellow, isMetallic: false)])
    ball.name = "pball"; ball.position = [0.3, 1.0, 0]
    ball.collision = CollisionComponent(shapes: [.generateSphere(radius: 0.05)])
    ball.physicsBody = PhysicsBodyComponent(shapes: [.generateSphere(radius: 0.05)], mass: 1, material: .generate(friction: 0.3, restitution: 0.8), mode: .dynamic)
    root.addChild(ball)

    let kick = ModelEntity(mesh: .generateBox(size: 0.1), materials: [SimpleMaterial(color: .blue, isMetallic: false)])
    kick.name = "pkick"; kick.position = [0, 0.05, 0.5]
    kick.collision = CollisionComponent(shapes: [.generateBox(size: [0.1, 0.1, 0.1])])
    kick.physicsBody = PhysicsBodyComponent(shapes: [.generateBox(size: [0.1, 0.1, 0.1])], mass: 2, material: .generate(friction: 0, restitution: 0), mode: .dynamic)
    kick.physicsBody!.isAffectedByGravity = false
    root.addChild(kick)

    let defMass = ModelEntity(mesh: .generateBox(size: 0.1))
    defMass.collision = CollisionComponent(shapes: [.generateBox(size: [0.1, 0.1, 0.1])])
    defMass.physicsBody = PhysicsBodyComponent()
    log("phys.defaultBody.mass", defMass.physicsBody!.massProperties.mass)

    // Everything below is sampled on simulated time (sum of DidSimulate deltaTime), not wall time,
    // because the host may be heavily loaded.
    var collisions: [String] = []
    var physT: Double = 0
    var marks: [Double] = [0, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0]
    var maxBallAfterBounce: Float = 0
    var bounced = false
    var lastY: Float = 10
    var steps = 0
    var kickAt: Double = -1
    var kickLogged = false
    var finished = false
    keep.append(scene.subscribe(to: CollisionEvents.Began.self) { e in
        if collisions.count < 20 { collisions.append("\(String(format: "%.3f", physT)) \(e.entityA.name)-\(e.entityB.name) pos\(f3(e.position)) imp \(String(format: "%.4f", e.impulse)) contacts \(e.contacts.count)") }
    })
    var ballOnly = 0
    keep.append(scene.subscribe(to: CollisionEvents.Began.self, on: ball) { _ in ballOnly += 1 })
    kick.components.set(PhysicsMotionComponent())
    keep.append(scene.subscribe(to: PhysicsSimulationEvents.WillSimulate.self) { e in
        steps += 1
        if steps <= 3 { log("phys.willSimulate.dt.\(steps)", e.deltaTime) }
    })
    keep.append(scene.subscribe(to: PhysicsSimulationEvents.DidSimulate.self) { e in
        physT += Double(e.deltaTime)
        let y = ball.position(relativeTo: nil).y
        if !bounced && y > lastY + 0.0001 && lastY < 0.2 { bounced = true }
        if bounced { maxBallAfterBounce = max(maxBallAfterBounce, y) }
        lastY = y
        while let m = marks.first, physT >= m - 1e-6 {
            marks.removeFirst()
            log("phys.t\(m).cube.y", String(format: "%.4f (at %.4f)", cube.position(relativeTo: nil).y, physT))
            log("phys.t\(m).ball.y", String(format: "%.4f", y))
        }
        if kickAt < 0 && physT >= 1.0 { kickAt = physT; kick.applyLinearImpulse([1, 0, 0], relativeTo: nil) }
        if kickAt >= 0 && !kickLogged && physT >= kickAt + 0.2 {
            kickLogged = true
            log("phys.kick.velocityAfterImpulse(mass2,imp1)", f3(kick.physicsMotion?.linearVelocity ?? .zero))
            log("phys.kick.dx.after0.2s", String(format: "%.4f", kick.position(relativeTo: nil).x))
        }
        if !finished && physT >= 3.2 {
            finished = true
            log("phys.steps.in3.2s", steps)
            log("phys.collisionBegan.filteredOnBall", ballOnly)
            log("phys.ball.maxAfterFirstBounce", String(format: "%.4f", maxBallAfterBounce))
            for (i, c) in collisions.enumerated() { log("phys.collision.\(i)", c) }
            let hits = scene.raycast(origin: [-0.3, 2, 0], direction: [0, -1, 0], length: 5, query: .all, mask: .all, relativeTo: nil)
            log("phys.raycast.all", hits.map { "\($0.entity.name)@\(String(format: "%.4f", $0.distance)) n\(f3($0.normal))" }.joined(separator: " | "))
            let near = scene.raycast(origin: [-0.3, 2, 0], direction: [0, -1, 0], length: 5, query: .nearest, mask: .all, relativeTo: nil)
            log("phys.raycast.nearest", near.map { "\($0.entity.name)@\(String(format: "%.4f", $0.distance))" }.joined(separator: " | "))
            log("phys.cube.final", f3(cube.position(relativeTo: nil)))
            log("phys.cube.finalOrientation", q4(cube.orientation(relativeTo: nil)))
            log("phys.sim.nearestSimEntity", PhysicsSimulationComponent.nearestSimulationEntity(for: cube)?.name ?? "nil")
            log("done", 1)
        }
    })
}

// MARK: - animation probe

@MainActor func animationProbe(root: Entity, scene: RealityKit.Scene) {
    let e = ModelEntity(mesh: .generateBox(size: 0.1), materials: [SimpleMaterial(color: .orange, isMetallic: false)])
    e.name = "anim"
    root.addChild(e)
    var events: [String] = []
    var animT: Double = 0   // scene time: sum of SceneEvents.Update deltaTime since start
    keep.append(scene.subscribe(to: AnimationEvents.PlaybackStarted.self) { _ in events.append("started@\(String(format: "%.3f", animT))") })
    keep.append(scene.subscribe(to: AnimationEvents.PlaybackCompleted.self) { _ in events.append("completed@\(String(format: "%.3f", animT))") })
    keep.append(scene.subscribe(to: AnimationEvents.PlaybackLooped.self) { _ in events.append("looped@\(String(format: "%.3f", animT))") })
    keep.append(scene.subscribe(to: AnimationEvents.PlaybackTerminated.self) { _ in events.append("terminated@\(String(format: "%.3f", animT))") })
    let ctl = e.move(to: Transform(translation: [1, 0, 0]), relativeTo: e.parent, duration: 1.0, timingFunction: .linear)
    log("anim.move.duration", ctl.duration)
    log("anim.move.isPlaying", ctl.isPlaying)

    let e2 = ModelEntity(mesh: .generateSphere(radius: 0.05)); e2.name = "anim2"; root.addChild(e2)
    let def = FromToByAnimation<Transform>(name: "up", from: Transform(translation: [0, 0, 0]), to: Transform(translation: [0, 1, 0]),
                                          duration: 1, timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)
    var c2: AnimationPlaybackController? = nil
    do {
        let res = try AnimationResource.generate(with: def)
        c2 = e2.playAnimation(res)
        log("anim.fromTo.duration", c2!.duration)
    } catch { log("anim.fromTo.error", error) }

    let e3 = Entity(); e3.name = "anim3"; root.addChild(e3)
    e3.components.set(OpacityComponent(opacity: 0))
    let sampled = SampledAnimation<Float>(frames: [0, 1, 0], name: "op", frameInterval: 0.5, bindTarget: .opacity)
    do { _ = e3.playAnimation(try AnimationResource.generate(with: sampled)) } catch { log("anim.sampled.error", error) }

    var marks: [Double] = [0.25, 0.5, 0.75, 1.2, 1.5, 2.5, 3.0]
    var stopped = false
    keep.append(scene.subscribe(to: SceneEvents.Update.self) { u in
        animT += u.deltaTime
        while let m = marks.first, animT >= m {
            marks.removeFirst()
            log("anim.t\(m)", String(format: "at %.4f move.x %.4f fromTo.y %.4f opacity %.4f ctl.time %.4f", animT, e.position.x, e2.position.y,
                                     e3.components[OpacityComponent.self]?.opacity ?? -1, ctl.time))
        }
        if !stopped && animT >= 2.6 { stopped = true; c2?.stop() }
        if animT >= 3.0 && marks.isEmpty && !events.contains("logged") {
            events.append("logged")
            log("anim.events", events.dropLast().joined(separator: " "))
            log("done", 1)
        }
    })
}

// MARK: - mesh probe

@MainActor func meshFacts(_ name: String, _ m: MeshResource) {
    var parts = 0, verts = 0, tris = 0
    for model in m.contents.models { for p in model.parts { parts += 1; verts += p.positions.count; tris += (p.triangleIndices?.count ?? 0) / 3 } }
    var hasN = true, hasUV = true
    for model in m.contents.models { for p in model.parts { if p.normals == nil { hasN = false }; if p.textureCoordinates == nil { hasUV = false } } }
    log("mesh.\(name)", "bounds \(bb(m.bounds)) models \(m.contents.models.count) instances \(m.contents.instances.count) parts \(parts) verts \(verts) tris \(tris) normals \(hasN) uvs \(hasUV) materials \(m.expectedMaterialCount)")
}

@MainActor func meshProbe(root: Entity) {
    meshFacts("box0.2", .generateBox(size: 0.2))
    meshFacts("box0.2.r0.02", .generateBox(size: 0.2, cornerRadius: 0.02))
    meshFacts("boxSplit", .generateBox(width: 0.2, height: 0.2, depth: 0.2, cornerRadius: 0, splitFaces: true))
    meshFacts("sphere0.1", .generateSphere(radius: 0.1))
    meshFacts("planeXY", .generatePlane(width: 0.4, height: 0.2))
    meshFacts("planeXZ", .generatePlane(width: 0.4, depth: 0.2))
    meshFacts("cone", .generateCone(height: 0.2, radius: 0.1))
    meshFacts("cylinder", .generateCylinder(height: 0.2, radius: 0.1))
    meshFacts("text", .generateText("RK", extrusionDepth: 0.02, font: .systemFont(ofSize: 0.1)))
    var d = MeshDescriptor(name: "tri")
    d.positions = MeshBuffers.Positions([[0, 0, 0], [0.2, 0, 0], [0, 0.2, 0]])
    d.primitives = .triangles([0, 1, 2])
    do { meshFacts("descriptorTri", try MeshResource.generate(from: [d])) } catch { log("mesh.descriptorTri.error", error) }
    var q = MeshDescriptor(name: "quad")
    q.positions = MeshBuffers.Positions([[0, 0, 0], [0.2, 0, 0], [0.2, 0.2, 0], [0, 0.2, 0]])
    q.primitives = .polygons([4], [0, 1, 2, 3])
    do { meshFacts("descriptorQuadPolygon", try MeshResource.generate(from: [q])) } catch { log("mesh.quad.error", error) }
    // LowLevelMesh triangle
    struct V { var p: SIMD3<Float>; var n: SIMD3<Float> }
    let attrs: [LowLevelMesh.Attribute] = [
        .init(semantic: .position, format: .float3, offset: 0),
        .init(semantic: .normal, format: .float3, offset: MemoryLayout<SIMD3<Float>>.stride)]
    let desc = LowLevelMesh.Descriptor(vertexCapacity: 3, vertexAttributes: attrs,
                                       vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<V>.stride)],
                                       indexCapacity: 3, indexType: .uint32)
    do {
        let llm = try LowLevelMesh(descriptor: desc)
        llm.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let v = raw.bindMemory(to: V.self)
            v[0] = V(p: [0, 0, 0], n: [0, 0, 1]); v[1] = V(p: [0.2, 0, 0], n: [0, 0, 1]); v[2] = V(p: [0, 0.2, 0], n: [0, 0, 1])
        }
        llm.withUnsafeMutableIndices { raw in let i = raw.bindMemory(to: UInt32.self); i[0] = 0; i[1] = 1; i[2] = 2 }
        llm.parts.replaceAll([LowLevelMesh.Part(indexCount: 3, topology: .triangle, bounds: BoundingBox(min: [0, 0, 0], max: [0.2, 0.2, 0]))])
        let m = try MeshResource(from: llm)
        meshFacts("lowLevelTri", m)
        log("mesh.lowLevel.vertexStride", MemoryLayout<V>.stride)
        let me = ModelEntity(mesh: m, materials: [SimpleMaterial(color: .magenta, isMetallic: false)])
        me.position = [0.4, 0.3, 0]; root.addChild(me)
    } catch { log("mesh.lowLevel.error", error) }
    do {
        var path = AttributedString("Y")
        path.font = .systemFont(ofSize: 0.1)
        let ext = try MeshResource(extruding: path)
        meshFacts("extrudedText", ext)
    } catch { log("mesh.extruded.error", error) }
    // Visible sample of each generator.
    let ms: [(String, MeshResource)] = [("b", .generateBox(size: 0.15, cornerRadius: 0.02)), ("s", .generateSphere(radius: 0.08)),
        ("c", .generateCone(height: 0.15, radius: 0.08)), ("y", .generateCylinder(height: 0.15, radius: 0.08)),
        ("t", .generateText("RK", extrusionDepth: 0.02, font: .systemFont(ofSize: 0.1)))]
    for (i, (n, m)) in ms.enumerated() {
        let me = ModelEntity(mesh: m, materials: [SimpleMaterial(color: .cyan, roughness: 0.4, isMetallic: false)])
        me.name = n; me.position = [Float(i) * 0.2 - 0.4, 0.1, 0.2]; root.addChild(me)
    }
}

// MARK: - material probe

@MainActor func materialProbe(root: Entity) {
    var mats: [(String, any RealityKit.Material)] = []
    mats.append(("simple", SimpleMaterial(color: .red, roughness: 0.5, isMetallic: false)))
    mats.append(("simpleMetal", SimpleMaterial(color: .white, roughness: 0.1, isMetallic: true)))
    mats.append(("unlit", UnlitMaterial(color: .green)))
    var pbr = PhysicallyBasedMaterial(); pbr.baseColor = .init(tint: .blue); pbr.roughness = 0.3; pbr.clearcoat = .init(floatLiteral: 1)
    mats.append(("pbrClearcoat", pbr))
    var em = PhysicallyBasedMaterial(); em.baseColor = .init(tint: .black); em.emissiveColor = .init(color: .yellow); em.emissiveIntensity = 2
    mats.append(("pbrEmissive", em))
    var tr = PhysicallyBasedMaterial(); tr.baseColor = .init(tint: .purple); tr.blending = .transparent(opacity: 0.4)
    mats.append(("pbrTransparent", tr))
    mats.append(("occlusion", OcclusionMaterial()))
    var wire = SimpleMaterial(color: .white, isMetallic: false); wire.triangleFillMode = .lines
    mats.append(("wireframe", wire))
    // CustomMaterial with our own surface shader.
    if let dev = MTLCreateSystemDefaultDevice(), let lib = dev.makeDefaultLibrary() {
        log("mat.custom.libraryFunctions", lib.functionNames.sorted().joined(separator: ","))
        do {
            let ss = CustomMaterial.SurfaceShader(named: "rkpStripes", in: lib)
            let cm = try CustomMaterial(surfaceShader: ss, lightingModel: .lit)
            mats.append(("custom", cm))
            log("mat.custom", "created")
        } catch { log("mat.custom.error", error) }
        do {
            let gm = CustomMaterial.GeometryModifier(named: "rkpWobble", in: lib)
            let cm = try CustomMaterial(from: SimpleMaterial(color: .orange, isMetallic: false), geometryModifier: gm)
            mats.append(("customGeom", cm))
            log("mat.customGeom", "created")
        } catch { log("mat.customGeom.error", error) }
        log("mat.custom.supportsMutableUniformsResources", CustomMaterial.supportsMutableUniformsResources)
    } else { log("mat.custom.library", "nil") }
    // ShaderGraphMaterial from our own hand-written USD (UsdPreviewSurface through MaterialX).
    Task { @MainActor in
        do {
            let url = Bundle.main.url(forResource: "sgmat", withExtension: "usda")!
            let sg = try await ShaderGraphMaterial(named: "/Root/RKPMat", from: url)
            log("mat.shaderGraph", "created params \(sg.parameterNames.sorted())")
            let s = ModelEntity(mesh: .generateSphere(radius: 0.08), materials: [sg]); s.position = [0.6, 0.45, 0]; root.addChild(s)
        } catch { log("mat.shaderGraph.error", error) }
    }
    mats.append(("portal", PortalMaterial()))
    for (i, (n, m)) in mats.enumerated() {
        let s = ModelEntity(mesh: .generateSphere(radius: 0.08), materials: [m])
        s.name = n
        s.position = [Float(i % 4) * 0.22 - 0.33, 0.1 + Float(i / 4) * 0.22, 0]
        root.addChild(s)
        log("mat.\(n).type", String(describing: type(of: m)))
    }
    let dp = PhysicallyBasedMaterial()
    let r: Float = dp.roughness.scale, me: Float = dp.metallic.scale, sp: Float = dp.specular.scale
    log("mat.pbr.defaults", "rough \(r) metal \(me) spec \(sp)")
    log("mat.pbr.defaults2", "blending \(dp.blending) cull \(dp.faceCulling) opThresh \(String(describing: dp.opacityThreshold)) emissiveIntensity \(dp.emissiveIntensity) clearcoat \(dp.clearcoat.scale)")
    log("mat.simple.defaults", "rough \(SimpleMaterial().roughness) metal \(SimpleMaterial().metallic)")
}

// MARK: - texture and IBL probe

func gradientImage(_ w: Int, _ h: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<h { for x in 0..<w {
        ctx.setFillColor(red: CGFloat(x) / CGFloat(w), green: CGFloat(y) / CGFloat(h), blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
    } }
    return ctx.makeImage()!
}

@MainActor func textureProbe(root: Entity) {
    let img = gradientImage(64, 32)
    do {
        let t = try TextureResource(image: img, withName: "grad", options: .init(semantic: .color))
        log("tex.fromCGImage", "w \(t.width) h \(t.height) mips \(t.mipmapLevelCount) fmt \(t.pixelFormat.rawValue) type \(t.textureType.rawValue)")
        let t2 = try TextureResource(image: img, withName: "grad2", options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        log("tex.fromCGImage.mips", "mips \(t2.mipmapLevelCount)")
        let traw = try TextureResource(image: img, withName: "grad3", options: .init(semantic: .raw))
        log("tex.raw", "fmt \(traw.pixelFormat.rawValue)")
        var m = UnlitMaterial(); m.color = .init(tint: .white, texture: .init(t))
        let p = ModelEntity(mesh: .generatePlane(width: 0.4, height: 0.2), materials: [m]); p.position = [-0.3, 0.3, 0]; root.addChild(p)
    } catch { log("tex.error", error) }
    do {
        let env = try EnvironmentResource(equirectangular: gradientImage(128, 64), withName: "env")
        log("ibl.fromEquirect", "ok skybox \(String(describing: env.skybox))")
        root.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: 1))
        root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root))
        for c in root.children { c.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root)) }
    } catch { log("ibl.error", error) }
    // DrawableQueue
    do {
        let q = try TextureResource.DrawableQueue(.init(pixelFormat: .bgra8Unorm, width: 64, height: 64, usage: [.renderTarget, .shaderRead], mipmapsMode: .none))
        log("tex.drawableQueue", "ok \(q.width)x\(q.height)")
    } catch { log("tex.drawableQueue.error", error) }
}

// MARK: - USD probe

@MainActor func dumpTree(_ e: Entity, _ depth: Int, _ out: inout [String]) {
    if out.count > 60 { return }
    var extra = ""
    if let m = e.components[ModelComponent.self] {
        extra += " mesh\(bb(m.mesh.bounds)) mats[\(m.materials.map { String(describing: type(of: $0)) }.joined(separator: ","))]"
        if let p = m.materials.first as? PhysicallyBasedMaterial { extra += " tint\(p.baseColor.tint)" }
    }
    out.append(String(repeating: ".", count: depth) + "\(e.name)<\(type(of: e))> pos\(f3(e.position)) scale\(f3(e.scale)) rot\(q4(e.orientation)) [\(compNames(e))]\(extra)")
    for c in e.children { dumpTree(c, depth + 1, &out) }
}

@MainActor func usdProbe(root: Entity) {
    Task { @MainActor in
        for name in ["cube.usda", "cube.usdz", "cube_cm.usda", "cube_zup.usda", "skinned.usda", "Probe.reality"] {
            let parts = name.split(separator: ".")
            guard let url = Bundle.main.url(forResource: String(parts[0]), withExtension: String(parts[1])) else { log("usd.\(name)", "missing"); continue }
            do {
                let t = now()
                let e = try await Entity(contentsOf: url)
                log("usd.\(name).loadSeconds", String(format: "%.3f", now() - t))
                var lines: [String] = []
                dumpTree(e, 0, &lines)
                for (i, l) in lines.enumerated() { log("usd.\(name).tree.\(String(format: "%02d", i))", l) }
                log("usd.\(name).animations", e.availableAnimations.map { "\($0.name ?? "-") \($0.definition.duration)" }.joined(separator: ";"))
                log("usd.\(name).visualBounds", bb(e.visualBounds(relativeTo: nil)))
                if name == "cube.usda" {
                    e.position = [0, 0.15, 0]; root.addChild(e)
                    if let a = e.availableAnimations.first { _ = e.playAnimation(a.repeat()) }
                    let out = FileManager.default.temporaryDirectory.appendingPathComponent("export.usdz")
                    do {
                        try await e.write(to: out)
                        let data = try Data(contentsOf: out)
                        log("usd.export", "bytes \(data.count) magic \(data.prefix(4).map { String(format: "%02x", $0) }.joined()) path \(out.path)")
                    } catch { log("usd.export.error", error) }
                    let out2 = FileManager.default.temporaryDirectory.appendingPathComponent("export.usda")
                    do { try await e.write(to: out2); log("usd.exportUsda", "ok \(out2.path)") } catch { log("usd.exportUsda.error", error) }
                }
                if name == "cube_zup.usda" { e.position = [0.4, 0.15, 0]; root.addChild(e) }
                if name == "skinned.usda" { e.position = [-0.4, 0.0, 0]; root.addChild(e); if let a = e.availableAnimations.first { _ = e.playAnimation(a.repeat()) } }
            } catch { log("usd.\(name).error", error) }
        }
        do {
            let m = try await ModelEntity(contentsOf: Bundle.main.url(forResource: "cube", withExtension: "usda")!)
            log("usd.asModelEntity", "\(type(of: m)) children \(m.children.count) model \(m.model != nil) bounds \(bb(m.visualBounds(relativeTo: nil)))")
        } catch { log("usd.asModelEntity.error", error) }
        log("usd.done", 1)
    }
}

// MARK: - audio probe

@MainActor func audioProbe(root: Entity, scene: RealityKit.Scene) {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 24000)!
    buf.frameLength = 24000
    for i in 0..<24000 { buf.floatChannelData![0][i] = 0.2 * sinf(Float(i) * 2 * .pi * 440 / 48000) }
    do {
        let res = try AudioBufferResource(buffer: buf, configuration: .init(shouldLoop: false))
        log("audio.resource.duration", res.duration)
        let src = Entity(); src.name = "audioSrc"; src.position = [0.5, 0, 0]; root.addChild(src)
        src.components.set(SpatialAudioComponent(gain: -6))
        var done = false
        keep.append(scene.subscribe(to: AudioEvents.PlaybackCompleted.self) { _ in
            if !done { done = true; log("audio.completedAfter", String(format: "%.3f", now() - audioStart)) }
        })
        audioStart = now()
        let c = src.playAudio(res)
        log("audio.controller", "playing \(c.isPlaying) gain \(c.gain)")
        after(1.5) { log("audio.after1.5", "playing \(c.isPlaying) completed \(done)") }
    } catch { log("audio.error", error) }
}
var audioStart: Double = 0

// MARK: - perf probe

@MainActor func perfProbe(root: Entity, count: Int) {
    let mesh = MeshResource.generateBox(size: 0.02)
    let mat = SimpleMaterial(color: .white, isMetallic: false)
    let side = Int(Double(count).squareRoot().rounded(.up))
    for i in 0..<count {
        let e = ModelEntity(mesh: mesh, materials: [mat])
        e.position = [Float(i % side) * 0.03 - Float(side) * 0.015, 0.02, Float(i / side) * 0.03 - Float(side) * 0.015]
        root.addChild(e)
    }
    log("perf.entities", count)
}

// MARK: - particles

@MainActor func particleProbe(root: Entity) {
    let presets: [(String, ParticleEmitterComponent)] = [("fireworks", .Presets.fireworks), ("magic", .Presets.magic),
        ("sparks", .Presets.sparks), ("snow", .Presets.snow)]
    for (i, (n, p)) in presets.enumerated() {
        let e = Entity(); e.name = n; e.position = [Float(i) * 0.3 - 0.45, 0.2, 0]
        e.components.set(p); root.addChild(e)
    }
    let d = ParticleEmitterComponent()
    log("particles.default", "shape \(d.emitterShape) birthRate \(d.mainEmitter.birthRate) lifeSpan \(d.mainEmitter.lifeSpan) size \(d.mainEmitter.size) speed \(d.speed) timing \(d.timing)")
}

// MARK: - RealityRenderer offscreen probe

@MainActor func rendererProbe() {
    do {
        let r = try RealityRenderer()
        keep.append(r)
        let stage = makeStage()
        r.entities.append(stage)
        if let cam = stage.findEntity(named: "camera") as? PerspectiveCamera { r.activeCamera = cam }
        r.cameraSettings.colorBackground = .color(.init(srgbRed: 0.1, green: 0.1, blue: 0.3, alpha: 1))
        let dev = MTLCreateSystemDefaultDevice()!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 256, height: 256, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let tex = dev.makeTexture(descriptor: d)!
        let out = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: tex))
        let tStart = now()
        try r.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: out, onComplete: { _ in
            DispatchQueue.main.async {
                log("renderer.completeAfter", String(format: "%.3f", now() - tStart))
                var px = [UInt8](repeating: 0, count: 4)
                for (n, x, y) in [("corner", 5, 5), ("center", 128, 128), ("left", 70, 150), ("right", 186, 150), ("floor", 128, 220)] {
                    tex.getBytes(&px, bytesPerRow: 256 * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                    log("renderer.px.\(n)", "bgra \(px)")
                }
            }
        })
        log("renderer.submitted", "ok")
    } catch { log("renderer.error", error) }
}

// MARK: - views

struct RVScene: View {
    var body: some View {
        RealityView { content in
            log("rv.make", String(format: "%.3f", now()))
            let root = makeStage()
            if mode == "rv-nocamera" || mode == "rv-square" { root.findEntity(named: "camera")?.removeFromParent() }
            if ["rv-ecs", "rv-physics", "rv-anim", "rv-mesh", "rv-mat", "rv-tex", "rv-usd", "rv-audio", "rv-particles"].contains(mode) || mode.hasPrefix("rv-perf") {
                for n in ["box", "sphere", "cylinder"] { root.findEntity(named: n)?.removeFromParent() }
            }
            if mode == "rv-physics" { root.findEntity(named: "floor")?.removeFromParent() }
            content.add(root)
            if mode == "rv-orbit" { content.camera = .virtual }
            keep.append(content.subscribe(to: SceneEvents.Update.self) { _ in })
            frameCounter({ h in keep.append(content.subscribe(to: SceneEvents.Update.self, h)) }, label: "rv")
            // A plane anchor in a non-AR RealityView.
            let pa = AnchorEntity(plane: .horizontal); pa.name = "planeAnchor"; content.add(pa)
            let wa = AnchorEntity(world: [0, 0, 0]); wa.name = "worldAnchor"; content.add(wa)
            let cc = content
            after(2.5) {
                let content = cc
                let b = UIScreen.main.bounds
                log("rv.screenPoints", "\(b.width)x\(b.height)")
                if let r = content.ray(through: CGPoint(x: b.midX, y: b.midY), in: .local, to: .scene) {
                    log("rv.centerRay", "origin \(f3(r.origin)) dir \(f3(r.direction))")
                } else { log("rv.centerRay", "nil") }
                for p: SIMD3<Float> in [[0, 0, 0], [0.1, 0, 0], [0, 0.1, 0]] {
                    log("rv.project\(f3(p))", String(describing: content.project(point: p, to: .local)))
                }
            }
            after(3) { log("rv.anchors", "plane anchored \(pa.isAnchored) world anchored \(wa.isAnchored) root anchored \(root.isAnchored) rootScene \(root.scene != nil)") }
            guard let scene = root.scene else { log("rv.scene", "nil"); return }
            switch mode {
            case "rv-ecs": ecsProbe(root: root, scene: scene)
            case "rv-physics": physicsProbe(root: root, scene: scene)
            case "rv-anim": animationProbe(root: root, scene: scene)
            case "rv-mesh": meshProbe(root: root)
            case "rv-mat": materialProbe(root: root)
            case "rv-tex": textureProbe(root: root)
            case "rv-usd": usdProbe(root: root)
            case "rv-audio": audioProbe(root: root, scene: scene)
            case "rv-particles": particleProbe(root: root)
            case "rv-perf1000": perfProbe(root: root, count: 1000)
            case "rv-perf5000": perfProbe(root: root, count: 5000)
            default: break
            }
        }
        .realityViewCameraControls(mode == "rv-orbit" ? .orbit : .none)
        .ignoresSafeArea()
    }
}

struct RVSpatial: View {
    var body: some View {
        RealityView { content in
            content.camera = .spatialTracking
            let root = makeStage()
            root.findEntity(named: "camera")?.removeFromParent()
            let anchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: [0.1, 0.1]))
            anchor.addChild(root)
            content.add(anchor)
            frameCounter({ h in keep.append(content.subscribe(to: SceneEvents.Update.self, h)) }, label: "spatial")
            keep.append(content.subscribe(to: AnchorStateEvents.DidFailToAnchor.self) { e in log("spatial.didFailToAnchor", "\(e.reason)") })
            keep.append(content.subscribe(to: AnchorStateEvents.DidAnchor.self) { e in log("spatial.didAnchor", "\(e.reason)") })
            let s = SpatialTrackingSession()
            keep.append(s)
            let cfg = SpatialTrackingSession.Configuration(tracking: [.plane, .world, .image, .camera], sceneUnderstanding: [.occlusion, .collision], camera: .back)
            if let un = await s.run(cfg) {
                log("spatial.unavailable", "anchor \(un.anchor) su \(un.sceneUnderstanding) camAuth \(un.missingCameraAuthorization)")
            } else { log("spatial.unavailable", "none") }
            after(3) { log("spatial.anchored", anchor.isAnchored) }
        }
        .ignoresSafeArea()
    }
}

final class ARDelegate: NSObject, ARSessionDelegate {
    func session(_ session: ARSession, didFailWithError error: Error) { log("arview.session.didFail", error) }
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) { log("arview.tracking", camera.trackingState) }
    func sessionWasInterrupted(_ session: ARSession) { log("arview.session", "interrupted") }
}

struct ARViewHost: UIViewRepresentable {
    let ar: Bool
    func makeUIView(context: Context) -> ARView {
        log("arkit.worldTracking.isSupported", ARWorldTrackingConfiguration.isSupported)
        log("arkit.face.isSupported", ARFaceTrackingConfiguration.isSupported)
        log("arkit.body.isSupported", ARBodyTrackingConfiguration.isSupported)
        log("arkit.orientation.isSupported", AROrientationTrackingConfiguration.isSupported)
        let v: ARView = ar ? ARView(frame: .zero) : ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        log("arview.cameraMode", v.cameraMode)
        log("arview.automaticallyConfigureSession", v.automaticallyConfigureSession)
        log("arview.session.configuration", String(describing: v.session.configuration))
        let d = ARDelegate(); keep.append(d); v.session.delegate = d
        let root = makeStage()
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(root)
        v.scene.addAnchor(anchor)
        let pa = AnchorEntity(plane: .horizontal); v.scene.addAnchor(pa)
        if ar { root.findEntity(named: "camera")?.removeFromParent(); root.position = [0, -0.5, -1.5] }
        v.environment.background = ar ? v.environment.background : .color(.init(red: 0.15, green: 0.15, blue: 0.2, alpha: 1))
        log("arview.background", String(describing: v.environment.background))
        frameCounter({ h in keep.append(v.scene.subscribe(to: SceneEvents.Update.self, h)) }, label: "arview")
        after(3) {
            log("arview.anchors", "world \(anchor.isAnchored) plane \(pa.isAnchored) cameraTransform \(f3(v.cameraTransform.translation))")
            log("arview.renderOptions", v.renderOptions.rawValue)
            let opts: [(String, ARView.RenderOptions)] = [("cameraGrain", .disableCameraGrain), ("groundingShadows", .disableGroundingShadows), ("motionBlur", .disableMotionBlur), ("depthOfField", .disableDepthOfField), ("HDR", .disableHDR), ("personOcclusion", .disablePersonOcclusion), ("arEnvLighting", .disableAREnvironmentLighting), ("faceMesh", .disableFaceMesh)]
            log("arview.renderOptions.set", opts.filter { v.renderOptions.contains($0.1) }.map { "\($0.0)=\($0.1.rawValue)" }.joined(separator: ","))
            log("arview.renderOptions.all", opts.map { "\($0.0)=\($0.1.rawValue)" }.joined(separator: ","))
            log("arview.debugOptions", v.debugOptions.rawValue)
            log("arview.contentScaleFactor", v.contentScaleFactor)
            root.generateCollisionShapes(recursive: true)
            log("arview.project(origin)", String(describing: v.project([0, 0, 0])))
            let hits = v.hitTest(CGPoint(x: v.bounds.midX, y: v.bounds.midY))
            log("arview.hitTestCenter", hits.map { $0.entity.name }.joined(separator: ","))
            let rc = v.raycast(from: CGPoint(x: v.bounds.midX, y: v.bounds.midY), allowing: .estimatedPlane, alignment: .any)
            log("arview.arRaycastCenter", rc.count)
            v.snapshot(saveToHDR: false) { img in log("arview.snapshot", img.map { "\($0.size.width)x\($0.size.height) scale \($0.scale)" } ?? "nil") }
        }
        return v
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct RootView: View {
    var body: some View {
        Group {
            switch mode {
            case "arview-nonar": ARViewHost(ar: false)
            case "arview-ar": ARViewHost(ar: true)
            case "rv-spatial": RVSpatial()
            case "renderer": Color.black.onAppear { rendererProbe() }
            case "rv-square": RVScene().frame(width: 300, height: 200)
            default: RVScene()
            }
        }
        .ignoresSafeArea()
    }
}

@main
struct RKProbeApp: App {
    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
        log("mode", mode)
        logMetal()
        SysA.registerSystem(); SysB.registerSystem(); SysC.registerSystem()
        ProbeComponent.registerComponent(); OtherComponent.registerComponent()
        log("os", UIDevice.current.systemVersion)
    }
    var body: some SwiftUI.Scene { WindowGroup { RootView() } }
}
