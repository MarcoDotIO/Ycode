// MKProbe: our own black-box probe for MapKit (and the Core Location /
// GeoServices pieces maps need) in the iOS Simulator. Original Ycode code; it
// calls only public API and prints what it observes, one line per
// observation, to stderr:   MKP [  t.ttt] <key> <values>
//
// Launch arguments:
//   -mode <m>    math | map | config | gesture | annot | user | search | dir |
//                geo | look | snap | open | sui | suicam | offline
//   -wait N      seconds before the mode prints "done" (default per mode)
//   -variant V   mode-specific variant (see each mode)
//
// Every mode ends with a line "MKP [...] done" so a driver can wait for it.

import UIKit
import SwiftUI
import MapKit
import CoreLocation

let gStart = Date()
func P(_ s: String) {
    let t = String(format: "%7.3f", Date().timeIntervalSince(gStart))
    FileHandle.standardError.write("MKP [\(t)] \(s)\n".data(using: .utf8)!)
}
func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}
let gMode = arg("-mode") ?? "math"
let gVariant = arg("-variant") ?? ""

func f(_ d: Double, _ p: Int = 6) -> String { String(format: "%.\(p)f", d) }
func c(_ k: CLLocationCoordinate2D, _ p: Int = 6) -> String { "(\(f(k.latitude, p)),\(f(k.longitude, p)))" }
func mp(_ p: MKMapPoint) -> String { "(\(f(p.x, 3)),\(f(p.y, 3)))" }
func mr(_ r: MKMapRect) -> String { "[x=\(f(r.origin.x, 3)) y=\(f(r.origin.y, 3)) w=\(f(r.size.width, 3)) h=\(f(r.size.height, 3))]" }
func rg(_ r: MKCoordinateRegion) -> String { "{center=\(c(r.center)) span=(\(f(r.span.latitudeDelta, 7)),\(f(r.span.longitudeDelta, 7)))}" }
func pt(_ p: CGPoint) -> String { "(\(f(p.x, 3)),\(f(p.y, 3)))" }
func rc(_ r: CGRect) -> String { "[\(f(r.origin.x, 2)),\(f(r.origin.y, 2)) \(f(r.size.width, 2))x\(f(r.size.height, 2))]" }
func cam(_ m: MKMapCamera) -> String {
    "{center=\(c(m.centerCoordinate)) dist=\(f(m.centerCoordinateDistance, 3)) alt=\(f(m.altitude, 3)) pitch=\(f(Double(m.pitch), 3)) heading=\(f(m.heading, 3))}"
}
func describe(_ error: Error?) -> String {
    guard let error else { return "nil" }
    let ns = error as NSError
    var s = "domain=\(ns.domain) code=\(ns.code) desc=\"\(ns.localizedDescription)\" keys=\(ns.userInfo.keys.map { "\($0)" }.sorted())"
    if let r = ns.localizedFailureReason { s += " reason=\"\(r)\"" }
    if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { s += " underlying=(\(u.domain) \(u.code))" }
    return s
}

let applePark = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
let stanford = CLLocationCoordinate2D(latitude: 37.4275, longitude: -122.1697)
let sfDowntown = CLLocationCoordinate2D(latitude: 37.7946, longitude: -122.3999)
let unionSquare = CLLocationCoordinate2D(latitude: 37.7880, longitude: -122.4075)

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo s: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        P("launch mode=\(gMode) variant=\(gVariant) screen=\(rc(ws.screen.bounds)) scale=\(ws.screen.scale) os=\(UIDevice.current.systemVersion)")
        switch gMode {
        case "sui", "suicam": w.rootViewController = UIHostingController(rootView: SUIRoot())
        default: w.rootViewController = ProbeVC()
        }
        w.makeKeyAndVisible()
        window = w
    }
    func scene(_ scene: UIScene, openURLContexts ctx: Set<UIOpenURLContext>) {
        P("openURLContexts \(ctx.map { $0.url.absoluteString })")
    }
    func sceneDidBecomeActive(_ scene: UIScene) { P("scene didBecomeActive") }
    func sceneWillResignActive(_ scene: UIScene) { P("scene willResignActive") }
    func sceneDidEnterBackground(_ scene: UIScene) { P("scene didEnterBackground") }
    func sceneWillEnterForeground(_ scene: UIScene) { P("scene willEnterForeground") }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
    func application(_ app: UIApplication, configurationForConnecting s: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: s.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class ProbeVC: UIViewController {
    var mapView: MKMapView?
    let del = MapDel()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }
    var started = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if started { return }
        started = true
        P("vc.viewDidAppear bounds=\(rc(view.bounds)) safe=\(view.safeAreaInsets)")
        Task { @MainActor in
            switch gMode {
            case "math": runMath(self)
            case "map": await runMap(self)
            case "config": await runConfig(self)
            case "gesture": await runGesture(self)
            case "annot": await runAnnot(self)
            case "user": await runUser(self)
            case "search": await runSearch()
            case "dir": await runDirections()
            case "geo": await runGeo()
            case "look": await runLook(self)
            case "snap": await runSnap()
            case "open": await runOpen()
            case "offline": await runOffline(self)
            default: P("unknown mode")
            }
            P("done")
        }
    }
    @discardableResult
    func makeMap() -> MKMapView {
        let m = MKMapView(frame: view.bounds)
        m.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        m.delegate = del
        view.addSubview(m)
        mapView = m
        return m
    }
}

func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

/// Records delegate callbacks with timestamps.
final class MapDel: NSObject, MKMapViewDelegate {
    var log = true
    var counts: [String: Int] = [:]
    var fullyRendered: Bool?
    var renderFinished = false
    var viewProvider: ((MKMapView, MKAnnotation) -> MKAnnotationView?)?
    func bump(_ k: String, _ extra: String = "") {
        counts[k, default: 0] += 1
        if log && (k != "didChangeVisibleRegion" || counts[k]! <= 3) { P("delegate \(k) #\(counts[k]!) \(extra)") }
    }
    func mapViewWillStartLoadingMap(_ m: MKMapView) { bump("willStartLoadingMap") }
    func mapViewDidFinishLoadingMap(_ m: MKMapView) { bump("didFinishLoadingMap") }
    func mapViewDidFailLoadingMap(_ m: MKMapView, withError e: Error) { bump("didFailLoadingMap", describe(e)) }
    func mapViewWillStartRenderingMap(_ m: MKMapView) { bump("willStartRenderingMap") }
    func mapViewDidFinishRenderingMap(_ m: MKMapView, fullyRendered: Bool) {
        self.fullyRendered = fullyRendered; renderFinished = true
        bump("didFinishRenderingMap", "fullyRendered=\(fullyRendered)")
    }
    func mapView(_ m: MKMapView, regionWillChangeAnimated a: Bool) { bump("regionWillChange", "animated=\(a)") }
    func mapView(_ m: MKMapView, regionDidChangeAnimated a: Bool) { bump("regionDidChange", "animated=\(a) region=\(rg(m.region)) cam=\(cam(m.camera))") }
    func mapViewDidChangeVisibleRegion(_ m: MKMapView) { bump("didChangeVisibleRegion") }
    func mapViewWillStartLocatingUser(_ m: MKMapView) { bump("willStartLocatingUser") }
    func mapViewDidStopLocatingUser(_ m: MKMapView) { bump("didStopLocatingUser") }
    func mapView(_ m: MKMapView, didUpdate u: MKUserLocation) {
        bump("didUpdateUserLocation", "coord=\(c(u.coordinate)) updating=\(u.isUpdating) loc=\(u.location.map { "acc=\($0.horizontalAccuracy) sim=\($0.sourceInformation?.isSimulatedBySoftware ?? false)" } ?? "nil") heading=\(u.heading.map { "\($0.trueHeading)" } ?? "nil")")
    }
    func mapView(_ m: MKMapView, didFailToLocateUserWithError e: Error) { bump("didFailToLocateUser", describe(e)) }
    func mapView(_ m: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) { bump("didChangeUserTrackingMode", "mode=\(mode.rawValue) animated=\(animated)") }
    func mapView(_ m: MKMapView, didAdd views: [MKAnnotationView]) {
        bump("didAddAnnotationViews", "n=\(views.count) " + views.prefix(6).map { "\(type(of: $0))@\(rc($0.frame))" }.joined(separator: " "))
    }
    func mapView(_ m: MKMapView, didSelect v: MKAnnotationView) { bump("didSelectView", "\(type(of: v)) title=\((v.annotation?.title ?? nil) ?? "nil")") }
    func mapView(_ m: MKMapView, didDeselect v: MKAnnotationView) { bump("didDeselectView", "\(type(of: v))") }
    func mapView(_ m: MKMapView, didSelect a: MKAnnotation) { bump("didSelectAnnotation", "\(type(of: a))") }
    func mapView(_ m: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? { viewProvider?(m, a) }
    func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
        switch o {
        case let p as MKPolyline:
            let r = MKPolylineRenderer(polyline: p); P("renderer polyline defaults lineWidth=\(r.lineWidth) stroke=\(String(describing: r.strokeColor)) fill=\(String(describing: r.fillColor)) cap=\(r.lineCap.rawValue) join=\(r.lineJoin.rawValue) miter=\(r.miterLimit) alpha=\(r.alpha) strokeStart=\(r.strokeStart) strokeEnd=\(r.strokeEnd) shouldRasterize=\(r.shouldRasterize)")
            r.strokeColor = .systemBlue; r.lineWidth = 6; return r
        case let ci as MKCircle:
            let r = MKCircleRenderer(circle: ci); P("renderer circle defaults lineWidth=\(r.lineWidth) stroke=\(String(describing: r.strokeColor)) fill=\(String(describing: r.fillColor))")
            r.fillColor = UIColor.systemRed.withAlphaComponent(0.3); r.strokeColor = .systemRed; r.lineWidth = 2; return r
        case let pg as MKPolygon:
            let r = MKPolygonRenderer(polygon: pg); r.fillColor = UIColor.systemGreen.withAlphaComponent(0.3); return r
        case let t as MKTileOverlay:
            return MKTileOverlayRenderer(tileOverlay: t)
        default: return MKOverlayRenderer(overlay: o)
        }
    }
    func mapView(_ m: MKMapView, didAdd rs: [MKOverlayRenderer]) { bump("didAddOverlayRenderers", "n=\(rs.count)") }
}
