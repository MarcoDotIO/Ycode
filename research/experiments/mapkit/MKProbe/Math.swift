// MKProbe: geometry, projection, camera math and defaults (no network needed).
import UIKit
import MapKit
import CoreLocation

@MainActor func runMath(_ vc: ProbeVC) {
    // --- MKMapPoint projection
    P("world rect=\(mr(MKMapRect.world)) size=(\(f(MKMapSize.world.width, 3)),\(f(MKMapSize.world.height, 3))) null=\(mr(MKMapRect.null)) nullIsNull=\(MKMapRect.null.isNull) worldIsEmpty=\(MKMapRect.world.isEmpty)")
    let pts: [(String, Double, Double)] = [
        ("origin", 0, 0), ("applepark", 37.3349, -122.0090), ("london", 51.5074, -0.1278),
        ("sydney", -33.8568, 151.2153), ("lat85", 85, 180), ("latm85", -85, -180), ("lat85.0511", 85.05112878, 0),
        ("lat89", 89, 0), ("lat90", 90, 0), ("latm90", -90, 0), ("lon180", 0, 180), ("lonm180", 0, -180),
        ("lon190", 0, 190), ("lat100", 100, 0),
    ]
    for (n, la, lo) in pts {
        let k = CLLocationCoordinate2D(latitude: la, longitude: lo)
        let p = MKMapPoint(k)
        P("mappoint \(n) in=\(c(k)) valid=\(CLLocationCoordinate2DIsValid(k)) p=\(mp(p)) back=\(c(p.coordinate, 9))")
    }
    for (x, y) in [(0.0, 0.0), (MKMapSize.world.width / 2, MKMapSize.world.height / 2), (MKMapSize.world.width, MKMapSize.world.height), (-1000.0, -1000.0), (MKMapSize.world.width + 1e7, 0.0)] {
        P("mappoint->coord p=(\(f(x, 1)),\(f(y, 1))) coord=\(c(MKMapPoint(x: x, y: y).coordinate, 9))")
    }
    for la in [0.0, 30.0, 37.3349, 45.0, 60.0, 80.0, 85.0, 89.0, 90.0] {
        P("scale lat=\(la) pointsPerMeter=\(f(MKMapPointsPerMeterAtLatitude(la), 9)) metersPerPoint=\(f(MKMetersPerMapPointAtLatitude(la), 9))")
    }
    let a = MKMapPoint(applePark), b = MKMapPoint(stanford)
    let la = CLLocation(latitude: applePark.latitude, longitude: applePark.longitude)
    let lb = CLLocation(latitude: stanford.latitude, longitude: stanford.longitude)
    P("distance applepark-stanford metersBetweenMapPoints=\(f(a.distance(to: b), 4)) pointDistance=\(f(a.distance(to: b), 4)) clDistance=\(f(la.distance(from: lb), 4))")
    let tokyo = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503), sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    P("distance sf-tokyo metersBetweenMapPoints=\(f(MKMapPoint(sf).distance(to: MKMapPoint(tokyo)), 3)) clDistance=\(f(CLLocation(latitude: sf.latitude, longitude: sf.longitude).distance(from: CLLocation(latitude: tokyo.latitude, longitude: tokyo.longitude)), 3))")
    P("distance equator 1deg lon metersBetween=\(f(MKMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: 0)).distance(to: MKMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: 1))), 4)) 1deg lat=\(f(MKMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: 0)).distance(to: MKMapPoint(CLLocationCoordinate2D(latitude: 1, longitude: 0))), 4))")

    // --- tables for fitting the scale and distance functions
    var tbl: [String] = []
    for la in stride(from: 0.0, through: 86.0, by: 2.0) { tbl.append("\(la):\(f(MKMetersPerMapPointAtLatitude(la), 12))") }
    for la in [84.0, 84.5, 84.9, 84.99, 85.01, 85.5, 88.0, 89.9, 89.99, -37.3349, -60.0] { tbl.append("\(la):\(f(MKMetersPerMapPointAtLatitude(la), 12))") }
    P("fit metersPerMapPoint " + tbl.joined(separator: " "))
    func dist(_ a: (Double, Double), _ b: (Double, Double)) -> String {
        let pa = MKMapPoint(CLLocationCoordinate2D(latitude: a.0, longitude: a.1)), pb = MKMapPoint(CLLocationCoordinate2D(latitude: b.0, longitude: b.1))
        return "(\(a.0),\(a.1))->(\(b.0),\(b.1))=\(f(pa.distance(to: pb), 6))"
    }
    P("fit metersBetween " + [
        dist((0, 0), (0, 1)), dist((0, 0), (1, 0)), dist((0, 0), (0, 10)), dist((0, 0), (10, 0)), dist((0, 0), (0, 90)),
        dist((30, 0), (30, 1)), dist((30, 0), (31, 0)), dist((60, 0), (60, 1)), dist((60, 0), (61, 0)), dist((60, 0), (60, 0.01)),
        dist((37.3349, -122.009), (37.3349, -122.0)), dist((37.3349, -122.009), (37.3449, -122.009)), dist((-45, 170), (-45, -170)),
        dist((0, 0), (45, 45)), dist((80, 0), (80, 1)), dist((10, 10), (20, 30)),
    ].joined(separator: " "))

    // --- regions
    for (la, lo, m1, m2) in [(0.0, 0.0, 1000.0, 1000.0), (37.3349, -122.0090, 1000.0, 1000.0), (60.0, 0.0, 1000.0, 1000.0), (37.3349, -122.0090, 100000.0, 50000.0), (0.0, 0.0, 40_000_000.0, 40_000_000.0), (89.0, 0.0, 1000.0, 1000.0)] {
        let r = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: la, longitude: lo), latitudinalMeters: m1, longitudinalMeters: m2)
        P("region fromMeters center=(\(la),\(lo)) m=(\(m1),\(m2)) -> \(rg(r))")
    }
    for r in [MKMapRect(x: 1e8, y: 1e8, width: 1e6, height: 1e6), MKMapRect.world, MKMapRect(x: 0, y: 0, width: MKMapSize.world.width / 2, height: MKMapSize.world.height / 2), MKMapRect(origin: MKMapPoint(applePark), size: MKMapSize(width: 10000, height: 10000))] {
        P("region fromMapRect \(mr(r)) -> \(rg(MKCoordinateRegion(r)))")
    }

    // --- MKMapRect algebra
    let r1 = MKMapRect(x: 0, y: 0, width: 100, height: 100), r2 = MKMapRect(x: 50, y: 50, width: 100, height: 100)
    P("rect union=\(mr(r1.union(r2))) intersection=\(mr(r1.intersection(r2))) inset10=\(mr(r1.insetBy(dx: 10, dy: 10))) offset=\(mr(r1.offsetBy(dx: 5, dy: -5))) intersects=\(r1.intersects(r2)) contains(50,50)=\(r1.contains(MKMapPoint(x: 50, y: 50))) contains(100,100)=\(r1.contains(MKMapPoint(x: 100, y: 100))) containsRect=\(r1.contains(MKMapRect(x: 10, y: 10, width: 10, height: 10)))")
    P("rect disjoint intersection=\(mr(r1.intersection(MKMapRect(x: 500, y: 500, width: 1, height: 1)))) isNull=\(r1.intersection(MKMapRect(x: 500, y: 500, width: 1, height: 1)).isNull) unionNull=\(mr(r1.union(.null))) empty0=\(MKMapRect(x: 1, y: 1, width: 0, height: 5).isEmpty)")
    let span = MKMapRect(x: MKMapSize.world.width - 100, y: 1000, width: 200, height: 10)
    P("rect spans180 a=\(span.spans180thMeridian) world=\(MKMapRect.world.spans180thMeridian) remainder=\(mr(span.remainder)) remainderOfWorld=\(mr(MKMapRect.world.remainder))")
    P("rect minmax r2 minX=\(r2.minX) midX=\(r2.midX) maxX=\(r2.maxX) minY=\(r2.minY) midY=\(r2.midY) maxY=\(r2.maxY)")

    // --- overlays
    var line = [applePark, stanford, sfDowntown]
    let pl = MKPolyline(coordinates: &line, count: line.count)
    P("polyline pointCount=\(pl.pointCount) bounding=\(mr(pl.boundingMapRect)) coordinate=\(c(pl.coordinate)) points0=\(mp(pl.points()[0])) location(at:1)=\(f(pl.location(atPointIndex: 1)))")
    P("polyline locations(atPointIndexes:0,2)=\(pl.locations(at: IndexSet([0, 2])).map { f(Double($0)) })")
    for rad in [1000.0, 0.0, 100_000.0] {
        let ci = MKCircle(center: applePark, radius: rad)
        P("circle r=\(rad) bounding=\(mr(ci.boundingMapRect)) coord=\(c(ci.coordinate)) radius=\(ci.radius)")
    }
    let ci2 = MKCircle(mapRect: MKMapRect(x: 1000, y: 1000, width: 200, height: 100))
    P("circle fromMapRect center=\(c(ci2.coordinate, 9)) radius=\(f(ci2.radius, 6)) bounding=\(mr(ci2.boundingMapRect))")
    var tri = [applePark, stanford, CLLocationCoordinate2D(latitude: 37.3, longitude: -122.2)]
    let pg = MKPolygon(coordinates: &tri, count: 3)
    P("polygon pointCount=\(pg.pointCount) bounding=\(mr(pg.boundingMapRect)) coordinate=\(c(pg.coordinate)) interiors=\(pg.interiorPolygons?.count ?? -1)")
    var gl = [sf, tokyo]
    let geo = MKGeodesicPolyline(coordinates: &gl, count: 2)
    P("geodesic sf-tokyo pointCount=\(geo.pointCount) bounding=\(mr(geo.boundingMapRect)) spans180=\(geo.boundingMapRect.spans180thMeridian) mid=\(c(geo.points()[geo.pointCount / 2].coordinate, 4))")
    var gl2 = [applePark, stanford]
    let geo2 = MKGeodesicPolyline(coordinates: &gl2, count: 2)
    P("geodesic applepark-stanford pointCount=\(geo2.pointCount)")
    var gl3 = [CLLocationCoordinate2D(latitude: 0, longitude: 170), CLLocationCoordinate2D(latitude: 0, longitude: -170)]
    let geo3 = MKGeodesicPolyline(coordinates: &gl3, count: 2)
    P("geodesic across180 pointCount=\(geo3.pointCount) bounding=\(mr(geo3.boundingMapRect)) spans180=\(geo3.boundingMapRect.spans180thMeridian) first=\(mp(geo3.points()[0])) last=\(mp(geo3.points()[geo3.pointCount - 1]))")
    var ln2 = [CLLocationCoordinate2D(latitude: 0, longitude: 170), CLLocationCoordinate2D(latitude: 0, longitude: -170)]
    let pl180 = MKPolyline(coordinates: &ln2, count: 2)
    P("polyline across180 bounding=\(mr(pl180.boundingMapRect)) points=\(mp(pl180.points()[0])),\(mp(pl180.points()[1]))")
    let mpl = MKMultiPolyline([pl, pl180])
    P("multipolyline bounding=\(mr(mpl.boundingMapRect)) count=\(mpl.polylines.count)")
    let to = MKTileOverlay(urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png?s={scale}")
    P("tileoverlay defaults tileSize=\(to.tileSize) minZ=\(to.minimumZ) maxZ=\(to.maximumZ) geometryFlipped=\(to.isGeometryFlipped) canReplaceMapContent=\(to.canReplaceMapContent) bounding=\(mr(to.boundingMapRect)) coordinate=\(c(to.coordinate))")
    to.isGeometryFlipped = false
    P("tileoverlay url(z=3,x=1,y=2,scale=2)=\(to.url(forTilePath: MKTileOverlayPath(x: 1, y: 2, z: 3, contentScaleFactor: 2)).absoluteString)")
    to.isGeometryFlipped = true
    P("tileoverlay flipped url(z=3,x=1,y=2,scale=1)=\(to.url(forTilePath: MKTileOverlayPath(x: 1, y: 2, z: 3, contentScaleFactor: 1)).absoluteString)")

    // --- cameras (not attached to a view)
    let c0 = MKMapCamera()
    P("camera init default \(cam(c0))")
    for (dist, pitch, heading) in [(1000.0, 0.0, 0.0), (1000.0, 45.0, 90.0), (1000.0, 60.0, -30.0), (1000.0, 89.0, 400.0)] {
        let m = MKMapCamera(lookingAtCenter: applePark, fromDistance: dist, pitch: CGFloat(pitch), heading: heading)
        P("camera lookingAt dist=\(dist) pitch=\(pitch) heading=\(heading) -> \(cam(m))")
    }
    let eye = CLLocationCoordinate2D(latitude: applePark.latitude - 0.01, longitude: applePark.longitude)
    let me = MKMapCamera(lookingAtCenter: applePark, fromEyeCoordinate: eye, eyeAltitude: 1000)
    P("camera fromEye south0.01 alt1000 -> \(cam(me))")
    let me2 = MKMapCamera(lookingAtCenter: applePark, fromEyeCoordinate: applePark, eyeAltitude: 500)
    P("camera fromEye same alt500 -> \(cam(me2))")
    let me3 = MKMapCamera(lookingAtCenter: applePark, fromEyeCoordinate: CLLocationCoordinate2D(latitude: applePark.latitude, longitude: applePark.longitude - 0.01), eyeAltitude: 300)
    P("camera fromEye west0.01 alt300 -> \(cam(me3))")
    let mc = MKMapCamera(lookingAtCenter: applePark, fromDistance: 1000, pitch: 0, heading: 0)
    mc.altitude = 2000
    P("camera set altitude 2000 on pitch0 -> \(cam(mc))")
    mc.pitch = 60
    P("camera then pitch 60 -> \(cam(mc))")

    let zr = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 500, maxCenterCoordinateDistance: 5000)
    P("zoomRange 500..5000 -> min=\(String(describing: zr?.minCenterCoordinateDistance)) max=\(String(describing: zr?.maxCenterCoordinateDistance)) defaultConst=\(MKMapCameraZoomDefault)")
    let zrBad = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 5000, maxCenterCoordinateDistance: 500)
    P("zoomRange inverted -> \(zrBad == nil ? "nil" : "nonnil")")
    let zrMin = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 500)
    P("zoomRange minOnly -> min=\(String(describing: zrMin?.minCenterCoordinateDistance)) max=\(String(describing: zrMin?.maxCenterCoordinateDistance))")
    let bnd = MKMapView.CameraBoundary(coordinateRegion: MKCoordinateRegion(center: applePark, latitudinalMeters: 2000, longitudinalMeters: 2000))
    P("cameraBoundary region -> region=\(rg(bnd!.region)) mapRect=\(mr(bnd!.mapRect))")
    let bnd2 = MKMapView.CameraBoundary(mapRect: MKMapRect(origin: MKMapPoint(applePark), size: MKMapSize(width: 5000, height: 5000)))
    P("cameraBoundary mapRect -> region=\(rg(bnd2!.region)) mapRect=\(mr(bnd2!.mapRect))")

    // --- distance formatter
    for loc in ["en_US", "en_GB", "de_DE", "fr_FR", "ja_JP"] {
        let fm = MKDistanceFormatter(); fm.locale = Locale(identifier: loc)
        P("distfmt \(loc) default units=\(fm.units.rawValue) style=\(fm.unitStyle.rawValue) " + [0, 10, 99, 100, 160, 805, 1000, 1609.344, 15000, 123456].map { "\($0)=\"\(fm.string(fromDistance: $0))\"" }.joined(separator: " "))
    }
    let fm = MKDistanceFormatter(); fm.locale = Locale(identifier: "en_US")
    for (u, n) in [(MKDistanceFormatter.Units.metric, "metric"), (.imperial, "imperial"), (.imperialWithYards, "imperialWithYards")] {
        for (s, sn) in [(MKDistanceFormatter.DistanceUnitStyle.default, "default"), (.abbreviated, "abbrev"), (.full, "full")] {
            fm.units = u; fm.unitStyle = s
            P("distfmt en_US \(n) \(sn) " + [10, 100, 1000, 1609.344, 15000].map { "\($0)=\"\(fm.string(fromDistance: $0))\"" }.joined(separator: " "))
        }
    }
    fm.units = .default; fm.unitStyle = .default
    for s in ["5 km", "3 mi", "100 m", "250 ft", "1.5 miles", "10 yards", "abc", "12"] {
        P("distfmt parse \"\(s)\" -> \(f(fm.distance(from: s), 4))")
    }

    // --- MKMapView defaults (not yet on screen, then on screen)
    let off = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    P("mapview offscreen defaults mapType=\(off.mapType.rawValue) zoom=\(off.isZoomEnabled) scroll=\(off.isScrollEnabled) pitch=\(off.isPitchEnabled) rotate=\(off.isRotateEnabled) compass=\(off.showsCompass) scale=\(off.showsScale) traffic=\(off.showsTraffic) buildings=\(off.showsBuildings) userLoc=\(off.showsUserLocation) tracking=\(off.userTrackingMode.rawValue) poiFilter=\(String(describing: off.pointOfInterestFilter)) selectable=\(off.selectableMapFeatures.rawValue) config=\(type(of: off.preferredConfiguration)) elevation=\(off.preferredConfiguration.elevationStyle.rawValue) region=\(rg(off.region)) cam=\(cam(off.camera)) zoomRange=(\(off.cameraZoomRange.minCenterCoordinateDistance),\(off.cameraZoomRange.maxCenterCoordinateDistance)) boundary=\(String(describing: off.cameraBoundary)) pitchButton=\(off.pitchButtonVisibility.rawValue)")
    if let sc = off.preferredConfiguration as? MKStandardMapConfiguration {
        P("mapview standardConfig emphasis=\(sc.emphasisStyle.rawValue) showsTraffic=\(sc.showsTraffic) poiFilter=\(String(describing: sc.pointOfInterestFilter))")
    }

    // --- viewport geometry vs view size (views placed away from the safe-area edges)
    for (w, h) in [(200.0, 200.0), (200.0, 400.0), (300.0, 150.0), (100.0, 300.0), (300.0, 300.0)] {
        let v = MKMapView(frame: CGRect(x: 20, y: 60, width: w, height: h))
        vc.view.addSubview(v)
        v.layoutIfNeeded()
        v.setCamera(MKMapCamera(lookingAtCenter: applePark, fromDistance: 1000, pitch: 0, heading: 0), animated: false)
        let vr = v.visibleMapRect
        let mpp = MKMetersPerMapPointAtLatitude(applePark.latitude)
        P("fov size=\(w)x\(h) safe=\(v.safeAreaInsets) visible=\(mr(vr)) visibleMeters=(\(f(vr.size.width * mpp, 3)),\(f(vr.size.height * mpp, 3))) region=\(rg(v.region)) centerPt=\(pt(v.convert(applePark, toPointTo: v)))")
        v.setRegion(MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)), animated: false)
        P("fov size=\(w)x\(h) setRegion0.01 -> region=\(rg(v.region)) cam=\(cam(v.camera))")
        v.removeFromSuperview()
    }
    let m = vc.makeMap()
    vc.view.layoutIfNeeded()
    P("mapview safeAreaInsets=\(m.safeAreaInsets) layoutMargins=\(m.layoutMargins) directional=\(m.directionalLayoutMargins)")
    P("mapview onscreen bounds=\(rc(m.bounds)) region=\(rg(m.region)) visible=\(mr(m.visibleMapRect)) cam=\(cam(m.camera))")
    let tests: [(String, MKCoordinateRegion)] = [
        ("ap0.05", MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))),
        ("ap1km", MKCoordinateRegion(center: applePark, latitudinalMeters: 1000, longitudinalMeters: 1000)),
        ("eq1x1", MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1))),
        ("tiny", MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.00001, longitudeDelta: 0.00001))),
        ("huge", MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 170, longitudeDelta: 360))),
        ("wide", MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 1))),
    ]
    for (n, r) in tests {
        let fit = m.regionThatFits(r)
        m.setRegion(r, animated: false)
        P("mapview setRegion \(n) in=\(rg(r)) fits=\(rg(fit)) after=\(rg(m.region)) visible=\(mr(m.visibleMapRect)) cam=\(cam(m.camera))")
    }
    m.setRegion(tests[0].1, animated: false)
    let b0 = m.bounds
    P("convert center coord->pt \(pt(m.convert(applePark, toPointTo: m))) topLeft pt->coord \(c(m.convert(.zero, toCoordinateFrom: m), 7)) bottomRight \(c(m.convert(CGPoint(x: b0.maxX, y: b0.maxY), toCoordinateFrom: m), 7)) midTop \(c(m.convert(CGPoint(x: b0.midX, y: 0), toCoordinateFrom: m), 7))")
    P("convert region->rect \(rc(m.convert(MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)), toRectTo: m))) rect->region \(rg(m.convert(CGRect(x: 0, y: 0, width: 100, height: 100), toRegionFrom: m)))")
    let vr = MKMapRect(origin: MKMapPoint(applePark), size: MKMapSize(width: 20000, height: 20000))
    P("mapview mapRectThatFits \(mr(vr)) -> \(mr(m.mapRectThatFits(vr))) withPadding(20 all) -> \(mr(m.mapRectThatFits(vr, edgePadding: UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))))")
    m.setVisibleMapRect(vr, animated: false)
    P("mapview setVisibleMapRect -> visible=\(mr(m.visibleMapRect)) region=\(rg(m.region)) cam=\(cam(m.camera))")
    m.setVisibleMapRect(vr, edgePadding: UIEdgeInsets(top: 100, left: 0, bottom: 0, right: 0), animated: false)
    P("mapview setVisibleMapRect pad top100 -> visible=\(mr(m.visibleMapRect)) center=\(c(m.centerCoordinate))")
    for (dist, pitch, heading) in [(1000.0, 0.0, 0.0), (1000.0, 60.0, 45.0), (300.0, 80.0, 0.0), (30.0, 0.0, 0.0), (1.0e9, 0.0, 0.0), (100_000.0, 60.0, 0.0), (5_000_000.0, 45.0, 0.0)] {
        m.setCamera(MKMapCamera(lookingAtCenter: applePark, fromDistance: dist, pitch: CGFloat(pitch), heading: heading), animated: false)
        P("mapview setCamera dist=\(dist) pitch=\(pitch) heading=\(heading) -> cam=\(cam(m.camera)) region=\(rg(m.region)) visible=\(mr(m.visibleMapRect))")
    }
    m.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 2000, maxCenterCoordinateDistance: 4000)!
    m.setCamera(MKMapCamera(lookingAtCenter: applePark, fromDistance: 1000, pitch: 0, heading: 0), animated: false)
    P("mapview zoomRange 2000..4000 setCamera 1000 -> dist=\(f(m.camera.centerCoordinateDistance, 3))")
    m.setCamera(MKMapCamera(lookingAtCenter: applePark, fromDistance: 9000, pitch: 0, heading: 0), animated: false)
    P("mapview zoomRange 2000..4000 setCamera 9000 -> dist=\(f(m.camera.centerCoordinateDistance, 3))")
    m.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: MKMapCameraZoomDefault, maxCenterCoordinateDistance: MKMapCameraZoomDefault)!
    m.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: MKCoordinateRegion(center: applePark, latitudinalMeters: 2000, longitudinalMeters: 2000))
    m.setCenter(stanford, animated: false)
    P("mapview boundary 2km setCenter stanford -> center=\(c(m.centerCoordinate)) region=\(rg(m.region))")
    m.cameraBoundary = nil
    m.setCenter(stanford, animated: false)
    P("mapview setCenter stanford -> center=\(c(m.centerCoordinate)) region=\(rg(m.region))")
    m.setRegion(tests[0].1, animated: false)
    m.camera.heading = 90
    P("mapview heading90 region=\(rg(m.region)) visible=\(mr(m.visibleMapRect)) convert center=\(pt(m.convert(applePark, toPointTo: m))) north+0.01 -> \(pt(m.convert(CLLocationCoordinate2D(latitude: applePark.latitude + 0.01, longitude: applePark.longitude), toPointTo: m)))")
}
