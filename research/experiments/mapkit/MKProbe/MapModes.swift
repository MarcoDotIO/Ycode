// MKProbe: MKMapView modes (rendering, configurations, gestures, annotations,
// overlays, user location, Look Around, offline-ish failure cases).
import UIKit
import MapKit
import CoreLocation

/// Asks the driver for a screenshot and waits for it to be taken.
@MainActor func shot(_ name: String) async { P("SHOT \(name)"); await sleep(2.5) }
/// Tells the driver to perform a scripted action, then waits.
@MainActor func ready(_ action: String, wait: Double) async { P("READY \(action)"); await sleep(wait) }

@MainActor func waitRender(_ d: MapDel, _ label: String, timeout: Double = 40) async {
    let t0 = Date()
    d.renderFinished = false
    while !d.renderFinished && Date().timeIntervalSince(t0) < timeout { await sleep(0.1) }
    // Rendering may finish more than once (tiles arriving); give it a moment.
    await sleep(1.0)
    P("render \(label) finished=\(d.renderFinished) fullyRendered=\(String(describing: d.fullyRendered)) after=\(f(Date().timeIntervalSince(t0), 2))s")
}

@MainActor func runMap(_ vc: ProbeVC) async {
    let t0 = Date()
    let m = vc.makeMap()
    P("map created; region=\(rg(m.region))")
    m.setRegion(MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)), animated: false)
    await waitRender(vc.del, "first", timeout: 60)
    P("map firstRender t=\(f(Date().timeIntervalSince(t0), 2)) counts=\(vc.del.counts)")
    await shot("map-standard")
    // Second load of the same area (cached)
    m.setRegion(MKCoordinateRegion(center: stanford, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)), animated: false)
    await waitRender(vc.del, "stanford")
    m.setRegion(MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)), animated: false)
    await waitRender(vc.del, "applepark-again")
    // Animated region change: count callbacks
    vc.del.counts = [:]
    m.setRegion(MKCoordinateRegion(center: stanford, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)), animated: true)
    await sleep(3)
    P("map animated setRegion counts=\(vc.del.counts) region=\(rg(m.region))")
    vc.del.counts = [:]
    m.setCenter(applePark, animated: true)
    await sleep(3)
    P("map animated setCenter counts=\(vc.del.counts)")
    vc.del.counts = [:]
    m.setCamera(MKMapCamera(lookingAtCenter: applePark, fromDistance: 1500, pitch: 45, heading: 90), animated: true)
    await sleep(4)
    P("map animated setCamera counts=\(vc.del.counts) cam=\(cam(m.camera))")
    // Ornaments and subviews
    func tree(_ v: UIView, _ depth: Int) {
        if depth > 3 { return }
        P("subview depth=\(depth) \(type(of: v)) frame=\(rc(v.frame)) hidden=\(v.isHidden)")
        for s in v.subviews { tree(s, depth + 1) }
    }
    m.showsScale = true; m.showsCompass = true
    await sleep(1)
    tree(m, 0)
    await shot("map-pitched")
    P("map attributions: compass/scale visible; layer class=\(type(of: m.layer))")
}

@MainActor func runConfig(_ vc: ProbeVC) async {
    let m = vc.makeMap()
    m.showsCompass = true; m.showsScale = true
    let steps: [(String, () -> Void)] = [
        ("standard-flat", {
            m.preferredConfiguration = MKStandardMapConfiguration()
            m.setRegion(MKCoordinateRegion(center: sfDowntown, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)), animated: false) }),
        ("standard-realistic-3d", {
            m.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
            m.setCamera(MKMapCamera(lookingAtCenter: sfDowntown, fromDistance: 900, pitch: 60, heading: 30), animated: false) }),
        ("standard-flat-pitched", {
            m.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
            m.setCamera(MKMapCamera(lookingAtCenter: sfDowntown, fromDistance: 900, pitch: 60, heading: 30), animated: false) }),
        ("hybrid-realistic", {
            m.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
            m.setCamera(MKMapCamera(lookingAtCenter: sfDowntown, fromDistance: 900, pitch: 60, heading: 30), animated: false) }),
        ("imagery-flat", {
            m.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            m.setRegion(MKCoordinateRegion(center: sfDowntown, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)), animated: false) }),
        ("imagery-realistic-3d", {
            m.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
            m.setCamera(MKMapCamera(lookingAtCenter: sfDowntown, fromDistance: 900, pitch: 60, heading: 30), animated: false) }),
        ("mapType-satelliteFlyover", {
            m.mapType = .satelliteFlyover
            m.setCamera(MKMapCamera(lookingAtCenter: sfDowntown, fromDistance: 900, pitch: 60, heading: 30), animated: false) }),
        ("mapType-mutedStandard", {
            m.mapType = .mutedStandard
            m.setRegion(MKCoordinateRegion(center: sfDowntown, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)), animated: false) }),
        ("standard-muted-dark", {
            m.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
            m.overrideUserInterfaceStyle = .dark }),
        ("standard-dark-traffic-nopoi", {
            let s = MKStandardMapConfiguration(); s.showsTraffic = true; s.pointOfInterestFilter = .excludingAll
            m.preferredConfiguration = s }),
        ("standard-globe", {
            m.overrideUserInterfaceStyle = .light
            m.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
            m.setCamera(MKMapCamera(lookingAtCenter: applePark, fromDistance: 20_000_000, pitch: 0, heading: 0), animated: false) }),
        ("standard-flat-world", {
            m.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
            m.setCamera(MKMapCamera(lookingAtCenter: applePark, fromDistance: 20_000_000, pitch: 0, heading: 0), animated: false) }),
        ("imagery-globe", {
            m.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
            m.setCamera(MKMapCamera(lookingAtCenter: applePark, fromDistance: 20_000_000, pitch: 0, heading: 0), animated: false) }),
    ]
    for (n, step) in steps {
        step()
        await waitRender(vc.del, n, timeout: 30)
        P("config \(n) mapType=\(m.mapType.rawValue) config=\(type(of: m.preferredConfiguration)) elevation=\(m.preferredConfiguration.elevationStyle.rawValue) cam=\(cam(m.camera)) region=\(rg(m.region)) pitchEnabled=\(m.isPitchEnabled)")
        await shot("config-\(n)")
    }
}

@MainActor func runGesture(_ vc: ProbeVC) async {
    let m = vc.makeMap()
    vc.del.log = true
    let start = MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
    m.setRegion(start, animated: false)
    await waitRender(vc.del, "gesture-start", timeout: 40)
    let b = m.bounds
    P("gesture bounds=\(rc(b)) metersPerPoint=\(f(m.visibleMapRect.size.width / Double(b.width) * MKMetersPerMapPointAtLatitude(applePark.latitude), 6))")
    let actions = ["drag-h", "drag-v", "fling", "doubletap-center", "doubletap-offcenter", "long-press", "edge-drag"]
    for a in actions {
        m.setRegion(start, animated: false)
        await sleep(1.0)
        let before = m.region, vb = m.visibleMapRect, cb = m.camera
        vc.del.counts = [:]
        await ready("gesture=\(a)", wait: 5)
        let after = m.region, va = m.visibleMapRect
        P("gesture \(a) before=\(rg(before)) after=\(rg(after)) dMapPoint=(\(f(va.midX - vb.midX, 2)),\(f(va.midY - vb.midY, 2))) dPoints=(\(f((va.midX - vb.midX) / vb.size.width * Double(b.width), 3)),\(f((va.midY - vb.midY) / vb.size.height * Double(b.height), 3))) widthRatio=\(f(va.size.width / vb.size.width, 6)) camBefore=\(cam(cb)) camAfter=\(cam(m.camera)) counts=\(vc.del.counts) selected=\(m.selectedAnnotations.count)")
    }
}

final class Pin: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?
    init(_ c: CLLocationCoordinate2D, _ t: String?, _ s: String? = nil) { coordinate = c; title = t; subtitle = s }
}

@MainActor func runAnnot(_ vc: ProbeVC) async {
    let m = vc.makeMap()
    let clustered = gVariant == "cluster"
    if clustered {
        vc.del.viewProvider = { mv, a in
            if a is MKUserLocation { return nil }
            if a is MKClusterAnnotation { return nil }
            let v = mv.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier, for: a)
            v.clusteringIdentifier = "c"
            return v
        }
    }
    m.setRegion(MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)), animated: false)
    await waitRender(vc.del, "annot-start")
    let pa = MKPointAnnotation(); pa.coordinate = applePark; pa.title = "Probe A"; pa.subtitle = "subtitle A"
    let pb = Pin(CLLocationCoordinate2D(latitude: applePark.latitude + 0.004, longitude: applePark.longitude), "Probe B")
    let pc = Pin(CLLocationCoordinate2D(latitude: applePark.latitude, longitude: applePark.longitude - 0.005), nil)
    m.addAnnotations([pa, pb, pc])
    if clustered {
        var many: [MKAnnotation] = []
        for i in 0..<20 {
            many.append(Pin(CLLocationCoordinate2D(latitude: applePark.latitude - 0.004 + Double(i % 5) * 0.0002, longitude: applePark.longitude + 0.004 + Double(i / 5) * 0.0002), "C\(i)"))
        }
        m.addAnnotations(many)
    }
    await sleep(2)
    P("annot count=\(m.annotations.count) inRect=\(m.annotations(in: m.visibleMapRect).count)")
    for a in m.annotations {
        guard let v = m.view(for: a) else { P("annot view nil for \(type(of: a))"); continue }
        var s = "annot view \(type(of: v)) for=\(type(of: a)) title=\((a.title ?? nil) ?? "nil") frame=\(rc(v.frame)) bounds=\(rc(v.bounds)) centerOffset=\(pt(v.centerOffset)) calloutOffset=\(pt(v.calloutOffset)) canShowCallout=\(v.canShowCallout) displayPriority=\(v.displayPriority.rawValue) collision=\(v.collisionMode.rawValue) zPriority=\(v.zPriority.rawValue) reuse=\(v.reuseIdentifier ?? "nil") clusterId=\(v.clusteringIdentifier ?? "nil")"
        if let mk = v as? MKMarkerAnnotationView {
            s += " markerTint=\(String(describing: mk.markerTintColor)) glyphTint=\(String(describing: mk.glyphTintColor)) glyphText=\(mk.glyphText ?? "nil") titleVis=\(mk.titleVisibility.rawValue) subtitleVis=\(mk.subtitleVisibility.rawValue) animatesWhenAdded=\(mk.animatesWhenAdded)"
        }
        if let cl = a as? MKClusterAnnotation { s += " members=\(cl.memberAnnotations.count) clTitle=\(cl.title ?? "nil") clSubtitle=\(cl.subtitle ?? "nil")" }
        s += " screen=\(pt(m.convert(a.coordinate, toPointTo: m)))"
        P(s)
        if let t = a.title, t == "Probe B" {
            let p = m.convert(a.coordinate, toPointTo: vc.view)
            P("target markerB=\(f(Double(p.x / vc.view.bounds.width), 4)),\(f(Double((v.frame.midY) / vc.view.bounds.height), 4))")
        }
    }
    // Overlays
    var line = [CLLocationCoordinate2D(latitude: applePark.latitude - 0.006, longitude: applePark.longitude - 0.006), applePark, CLLocationCoordinate2D(latitude: applePark.latitude + 0.006, longitude: applePark.longitude + 0.002)]
    let pl = MKPolyline(coordinates: &line, count: 3)
    let ci = MKCircle(center: CLLocationCoordinate2D(latitude: applePark.latitude - 0.003, longitude: applePark.longitude - 0.002), radius: 200)
    var tri = [CLLocationCoordinate2D(latitude: applePark.latitude + 0.006, longitude: applePark.longitude - 0.007), CLLocationCoordinate2D(latitude: applePark.latitude + 0.002, longitude: applePark.longitude - 0.007), CLLocationCoordinate2D(latitude: applePark.latitude + 0.004, longitude: applePark.longitude - 0.003)]
    let pg = MKPolygon(coordinates: &tri, count: 3)
    m.addOverlay(pl, level: .aboveRoads)
    m.addOverlays([ci, pg], level: .aboveLabels)
    await sleep(2)
    P("overlays count=\(m.overlays.count) aboveRoads=\(m.overlays(in: .aboveRoads).count) aboveLabels=\(m.overlays(in: .aboveLabels).count)")
    if let r = m.renderer(for: pl) as? MKPolylineRenderer {
        let mpc = MKMapPoint(applePark)
        P("renderer polyline point(for: applepark)=\(pt(r.point(for: mpc))) mapPoint(for: 0,0)=\(mp(r.mapPoint(for: .zero))) rect(for: bounding)=\(rc(r.rect(for: pl.boundingMapRect))) contentScale=\(r.contentScaleFactor) pathBounds=\(r.path.map { rc($0.boundingBox) } ?? "nil")")
        P("renderer zoomScale-ish: visible width mappts=\(f(m.visibleMapRect.size.width, 2)) / points=\(f(Double(m.bounds.width), 1))")
    }
    if let r = m.renderer(for: ci) as? MKCircleRenderer {
        P("renderer circle rect(for:bounding)=\(rc(r.rect(for: ci.boundingMapRect))) pathBounds=\(r.path.map { rc($0.boundingBox) } ?? "nil")")
    }
    await shot("annot-\(clustered ? "cluster" : "plain")")
    // Programmatic selection
    m.selectAnnotation(pa, animated: false)
    await sleep(1.5)
    P("annot select A selected=\(m.selectedAnnotations.count)")
    await shot("annot-selected")
    m.deselectAnnotation(pa, animated: false)
    await sleep(1)
    await ready("tap=markerB", wait: 4)
    P("annot after tap selected=\(m.selectedAnnotations.map { ($0.title ?? nil) ?? "nil" })")
    await shot("annot-tapped")
    // Show annotations fitting
    m.showAnnotations([pa, pb, pc], animated: false)
    P("annot showAnnotations -> region=\(rg(m.region))")
    m.removeAnnotations(m.annotations)
    m.removeOverlays(m.overlays)
    await sleep(0.5)
    P("annot removed count=\(m.annotations.count) overlays=\(m.overlays.count)")
}

@MainActor func runUser(_ vc: ProbeVC) async {
    let lm = CLLocationManager()
    P("user auth=\(lm.authorizationStatus.rawValue) acc=\(lm.accuracyAuthorization.rawValue)")
    let m = vc.makeMap()
    m.setRegion(MKCoordinateRegion(center: stanford, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)), animated: false)
    await waitRender(vc.del, "user-start")
    m.showsUserLocation = true
    P("user showsUserLocation=true userLocation=\(c(m.userLocation.coordinate)) visible=\(m.isUserLocationVisible) updating=\(m.userLocation.isUpdating)")
    await sleep(6)
    P("user after6s coord=\(c(m.userLocation.coordinate)) visible=\(m.isUserLocationVisible) loc=\(String(describing: m.userLocation.location)) title=\(m.userLocation.title ?? "nil")")
    if let v = m.view(for: m.userLocation) { P("user view \(type(of: v)) frame=\(rc(v.frame)) zPriority=\(v.zPriority.rawValue)") }
    m.setUserTrackingMode(.follow, animated: false)
    await sleep(4)
    P("user follow region=\(rg(m.region)) mode=\(m.userTrackingMode.rawValue) cam=\(cam(m.camera))")
    await shot("user-follow")
    await ready("location=stanford", wait: 6)
    P("user after move region=\(rg(m.region)) coord=\(c(m.userLocation.coordinate)) mode=\(m.userTrackingMode.rawValue)")
    m.setUserTrackingMode(.followWithHeading, animated: false)
    await sleep(3)
    P("user followWithHeading mode=\(m.userTrackingMode.rawValue) heading=\(String(describing: m.userLocation.heading))")
    await ready("drag-map", wait: 4)
    P("user after drag mode=\(m.userTrackingMode.rawValue)")
    await ready("location=clear", wait: 6)
    P("user after clear coord=\(c(m.userLocation.coordinate)) updating=\(m.userLocation.isUpdating) loc=\(String(describing: m.userLocation.location))")
    let item = MKMapItem.forCurrentLocation()
    P("user mapItemForCurrentLocation isCurrent=\(item.isCurrentLocation) name=\(item.name ?? "nil") coord=\(c(item.location.coordinate))")
}

@MainActor func runLook(_ vc: ProbeVC) async {
    func scene(_ k: CLLocationCoordinate2D, _ n: String) async -> MKLookAroundScene? {
        let t0 = Date()
        do {
            let s = try await MKLookAroundSceneRequest(coordinate: k).scene
            P("look scene \(n) -> \(s == nil ? "nil" : "scene") in \(f(Date().timeIntervalSince(t0), 3))s")
            return s
        } catch {
            P("look scene \(n) -> THROW \(describe(error)) in \(f(Date().timeIntervalSince(t0), 3))s")
            return nil
        }
    }
    let us = await scene(unionSquare, "unionSquare")
    _ = await scene(CLLocationCoordinate2D(latitude: 0, longitude: 0), "ocean0,0")
    _ = await scene(CLLocationCoordinate2D(latitude: 64.1466, longitude: -21.9426), "reykjavik")
    _ = await scene(CLLocationCoordinate2D(latitude: 200, longitude: 0), "invalidCoord")
    let req = MKLookAroundSceneRequest(coordinate: unionSquare)
    P("look request isLoading=\(req.isLoading) isCancelled=\(req.isCancelled) coord=\(c(req.coordinate)) mapItem=\(String(describing: req.mapItem))")
    req.cancel()
    do { _ = try await req.scene; P("look cancelled -> ok") } catch { P("look cancelled -> \(describe(error))") }
    guard let us else { return }
    let opt = MKLookAroundSnapshotter.Options()
    P("look snapopt defaults size=\(opt.size) poi=\(String(describing: opt.pointOfInterestFilter)) traits=\(opt.traitCollection.userInterfaceStyle.rawValue)")
    opt.size = CGSize(width: 300, height: 200)
    let t0 = Date()
    do {
        let snap = try await MKLookAroundSnapshotter(scene: us, options: opt).snapshot
        P("look snapshot image=\(snap.image.size) scale=\(snap.image.scale) in \(f(Date().timeIntervalSince(t0), 3))s")
    } catch { P("look snapshot THROW \(describe(error))") }
    let lvc = MKLookAroundViewController(scene: us)
    P("look vc defaults navigationEnabled=\(lvc.isNavigationEnabled) roadLabels=\(lvc.showsRoadLabels) poi=\(String(describing: lvc.pointOfInterestFilter)) badge=\(lvc.badgePosition.rawValue)")
    lvc.modalPresentationStyle = .fullScreen
    vc.present(lvc, animated: false)
    await sleep(8)
    await shot("look-vc")
    await ready("drag-look", wait: 5)
    await shot("look-vc-after-drag")
    P("look vc scene after drag=\(lvc.scene == nil ? "nil" : "scene")")
}

/// Failure-shaped cases that do not need the host network to be cut.
@MainActor func runOffline(_ vc: ProbeVC) async {
    let m = vc.makeMap()
    // A tile overlay that replaces the map with tiles from an unreachable host.
    let to = MKTileOverlay(urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png")
    to.canReplaceMapContent = true
    m.addOverlay(to, level: .aboveLabels)
    m.setRegion(MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)), animated: false)
    await waitRender(vc.del, "unreachable-tiles", timeout: 25)
    P("offline counts=\(vc.del.counts)")
    await shot("offline-unreachable-tiles")
    do { let d = try await to.loadTile(at: MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 2)); P("offline loadTile data=\(d.count)") }
    catch { P("offline loadTile THROW \(describe(error))") }
    m.removeOverlay(to)
    // Requests issued while geod is unavailable are done by the driver (variant geodstopped).
    if gVariant == "geodstopped" {
        await ready("stop-geod", wait: 2)
        let r = MKLocalSearch.Request(); r.naturalLanguageQuery = "coffee"; r.region = MKCoordinateRegion(center: applePark, latitudinalMeters: 5000, longitudinalMeters: 5000)
        let t0 = Date()
        do { let resp = try await MKLocalSearch(request: r).start(); P("offline search ok n=\(resp.mapItems.count) in \(f(Date().timeIntervalSince(t0), 2))s") } catch { P("offline search THROW \(describe(error)) in \(f(Date().timeIntervalSince(t0), 2))s") }
        m.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522), span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)), animated: false)
        await waitRender(vc.del, "paris-geodstopped", timeout: 25)
        await shot("offline-geodstopped-paris")
    }
}
