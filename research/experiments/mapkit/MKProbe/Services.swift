// MKProbe: network-backed services (search, completer, directions, geocoding,
// snapshots, opening map items). Business details are reported as shapes
// (presence, counts, categories), not copied.
import UIKit
import MapKit
import CoreLocation

func item(_ i: MKMapItem) -> String {
    var s = "name=\"\(i.name ?? "nil")\" coord=\(c(i.location.coordinate, 4)) cat=\(i.pointOfInterestCategory?.rawValue ?? "nil") phone=\(i.phoneNumber != nil) url=\(i.url?.host ?? "nil") tz=\(i.timeZone?.identifier ?? "nil") id=\(i.identifier != nil) altIds=\(i.alternateIdentifiers.count) isCurrent=\(i.isCurrentLocation)"
    if let a = i.address { s += " address.full=\"\(a.fullAddress.replacingOccurrences(of: "\n", with: "|"))\" address.short=\"\(a.shortAddress ?? "nil")\"" } else { s += " address=nil" }
    if let r = i.addressRepresentations {
        s += " rep.city=\(r.cityName ?? "nil") rep.cityCtx=\(r.cityWithContext ?? "nil") rep.region=\(r.regionName ?? "nil") rep.code=\(r.region?.identifier ?? "nil") rep.full1line=\"\(r.fullAddress(includingRegion: true, singleLine: true) ?? "nil")\""
    }
    let pm = i.placemark
    s += " pm.locality=\(pm.locality ?? "nil") pm.admin=\(pm.administrativeArea ?? "nil") pm.iso=\(pm.isoCountryCode ?? "nil") pm.postal=\(pm.postalCode != nil) pm.thoroughfare=\(pm.thoroughfare != nil) pm.region=\(type(of: pm.region as Any))"
    return s
}

func runSearch() async {
    let region = MKCoordinateRegion(center: applePark, latitudinalMeters: 5000, longitudinalMeters: 5000)
    func go(_ label: String, _ r: MKLocalSearch.Request) async -> MKLocalSearch.Response? {
        let t0 = Date()
        do {
            let resp = try await MKLocalSearch(request: r).start()
            P("search \(label) OK in \(f(Date().timeIntervalSince(t0), 3))s n=\(resp.mapItems.count) boundingRegion=\(rg(resp.boundingRegion))")
            for (k, i) in resp.mapItems.prefix(4).enumerated() { P("search \(label) item\(k) \(item(i))") }
            let cats = Set(resp.mapItems.compactMap { $0.pointOfInterestCategory?.rawValue })
            P("search \(label) categories=\(cats.sorted()) withAddress=\(resp.mapItems.filter { $0.address != nil }.count) withId=\(resp.mapItems.filter { $0.identifier != nil }.count)")
            if let first = resp.mapItems.first {
                let d = MKMapPoint(first.location.coordinate).distance(to: MKMapPoint(applePark))
                P("search \(label) firstDistanceFromCenter=\(f(d, 0))m")
            }
            return resp
        } catch {
            P("search \(label) THROW in \(f(Date().timeIntervalSince(t0), 3))s \(describe(error))")
            return nil
        }
    }
    let r0 = MKLocalSearch.Request()
    P("search request defaults resultTypes=\(r0.resultTypes.rawValue) poiFilter=\(String(describing: r0.pointOfInterestFilter)) region=\(rg(r0.region)) regionPriority=\(r0.regionPriority.rawValue) addressFilter=\(String(describing: r0.addressFilter))")
    let r1 = MKLocalSearch.Request(); r1.naturalLanguageQuery = "coffee"; r1.region = region
    let coffee = await go("coffee", r1)
    let r1b = MKLocalSearch.Request(); r1b.naturalLanguageQuery = "coffee"; r1b.region = region; r1b.regionPriority = .required
    _ = await go("coffee-required", r1b)
    let r2 = MKLocalSearch.Request(); r2.naturalLanguageQuery = "1 Apple Park Way, Cupertino"; r2.resultTypes = .address
    _ = await go("address", r2)
    let r3 = MKLocalSearch.Request(); r3.naturalLanguageQuery = "restaurant"; r3.region = region; r3.pointOfInterestFilter = MKPointOfInterestFilter(including: [.cafe])
    _ = await go("restaurant-filter-cafe", r3)
    let r4 = MKLocalSearch.Request(); r4.naturalLanguageQuery = "qzxqzxqzxvbnq"; r4.region = region
    _ = await go("gibberish", r4)
    let r5 = MKLocalSearch.Request(); r5.region = region
    _ = await go("empty", r5)
    let r6 = MKLocalSearch.Request(); r6.naturalLanguageQuery = "museum"; r6.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522), latitudinalMeters: 5000, longitudinalMeters: 5000)
    _ = await go("museum-paris", r6)
    let r7 = MKLocalSearch.Request(); r7.naturalLanguageQuery = "coffee"; r7.region = region; r7.resultTypes = .physicalFeature
    _ = await go("coffee-physicalFeature", r7)
    // Points of interest around a point
    let poi = MKLocalPointsOfInterestRequest(center: applePark, radius: 1000)
    P("search poi request radius=\(poi.radius) filter=\(String(describing: poi.pointOfInterestFilter))")
    let t0 = Date()
    do {
        let resp = try await MKLocalSearch(request: poi).start()
        P("search poi OK in \(f(Date().timeIntervalSince(t0), 3))s n=\(resp.mapItems.count) bounding=\(rg(resp.boundingRegion)) cats=\(Set(resp.mapItems.compactMap { $0.pointOfInterestCategory?.rawValue }).sorted())")
        let maxD = resp.mapItems.map { MKMapPoint($0.location.coordinate).distance(to: MKMapPoint(applePark)) }.max() ?? 0
        P("search poi maxDistance=\(f(maxD, 0))m")
    } catch { P("search poi THROW \(describe(error))") }
    let poiBig = MKLocalPointsOfInterestRequest(center: applePark, radius: 100_000)
    do { let resp = try await MKLocalSearch(request: poiBig).start(); P("search poi100km n=\(resp.mapItems.count)") } catch { P("search poi100km THROW \(describe(error))") }
    // Map item request by identifier
    if let id = coffee?.mapItems.first?.identifier {
        let t1 = Date()
        do {
            let it = try await MKMapItemRequest(mapItemIdentifier: id).mapItem
            P("search mapItemRequest OK in \(f(Date().timeIntervalSince(t1), 3))s \(item(it)) sameName=\(it.name == coffee?.mapItems.first?.name)")
        } catch { P("search mapItemRequest THROW \(describe(error))") }
        P("search identifier rawValue length=\(id.rawValue.count) prefix=\(id.rawValue.prefix(2))")
    }
    if let bogus = MKMapItem.Identifier(rawValue: "I0000000000000000") {
        do { _ = try await MKMapItemRequest(mapItemIdentifier: bogus).mapItem; P("search mapItemRequest bogus OK") } catch { P("search mapItemRequest bogus THROW \(describe(error))") }
    } else { P("search identifier bogus init -> nil") }
    // Two searches on the same object
    let s = MKLocalSearch(request: r1)
    P("search isSearching before=\(s.isSearching)")
    s.start { _, _ in P("search firstStart callback") }
    P("search isSearching after start=\(s.isSearching)")
    s.cancel()
    await sleep(1)
    P("search isSearching after cancel=\(s.isSearching)")
    // Completer
    await Completer().run()
}

final class Completer: NSObject, MKLocalSearchCompleterDelegate {
    let comp = MKLocalSearchCompleter()
    var updates = 0
    var t0 = Date()
    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        updates += 1
        P("completer update#\(updates) fragment=\"\(c.queryFragment)\" n=\(c.results.count) in \(f(Date().timeIntervalSince(t0), 3))s isSearching=\(c.isSearching)")
        for r in c.results.prefix(5) {
            P("completer result title=\"\(r.title)\" subtitle=\"\(r.subtitle)\" titleHL=\(r.titleHighlightRanges.map { "\($0.rangeValue.location)+\($0.rangeValue.length)" }) subHL=\(r.subtitleHighlightRanges.count)")
        }
    }
    func completer(_ c: MKLocalSearchCompleter, didFailWithError e: Error) {
        P("completer FAIL fragment=\"\(c.queryFragment)\" \(describe(e))")
    }
    @MainActor func run() async {
        comp.delegate = self
        P("completer defaults resultTypes=\(comp.resultTypes.rawValue) region=\(rg(comp.region)) regionPriority=\(comp.regionPriority.rawValue) poi=\(String(describing: comp.pointOfInterestFilter)) addressFilter=\(String(describing: comp.addressFilter)) isSearching=\(comp.isSearching)")
        comp.region = MKCoordinateRegion(center: applePark, latitudinalMeters: 5000, longitudinalMeters: 5000)
        for frag in ["App", "Apple Park", "coffee", "", "qzxqzxqzxvbnq", "1 Infinite"] {
            t0 = Date()
            comp.queryFragment = frag
            P("completer set \"\(frag)\" isSearching=\(comp.isSearching)")
            await sleep(4)
        }
        comp.resultTypes = .address
        t0 = Date(); comp.queryFragment = "1 Infinite"; await sleep(4)
        comp.resultTypes = .query
        t0 = Date(); comp.queryFragment = "pizza near"; await sleep(4)
        // Search from a completion
        comp.resultTypes = [.address, .pointOfInterest]
        t0 = Date(); comp.queryFragment = "Apple Park"; await sleep(4)
        if let first = comp.results.first {
            let t1 = Date()
            do {
                let resp = try await MKLocalSearch(request: MKLocalSearch.Request(completion: first)).start()
                P("completer->search OK in \(f(Date().timeIntervalSince(t1), 3))s n=\(resp.mapItems.count) first=\(resp.mapItems.first.map(item) ?? "nil")")
            } catch { P("completer->search THROW \(describe(error))") }
        }
        // Rapid typing: how many updates for 5 fragments typed 0.1s apart
        updates = 0; t0 = Date()
        for frag in ["s", "st", "sta", "stan", "stanf"] { comp.queryFragment = frag; await sleep(0.1) }
        await sleep(4)
        P("completer rapid typing updates=\(updates) final=\"\(comp.queryFragment)\" n=\(comp.results.count)")
        comp.cancel()
        P("completer cancelled isSearching=\(comp.isSearching)")
    }
}

func runDirections() async {
    func mi(_ k: CLLocationCoordinate2D) -> MKMapItem { MKMapItem(location: CLLocation(latitude: k.latitude, longitude: k.longitude), address: nil) }
    let r0 = MKDirections.Request()
    P("dir request defaults transport=\(r0.transportType.rawValue) alternates=\(r0.requestsAlternateRoutes) departure=\(String(describing: r0.departureDate)) arrival=\(String(describing: r0.arrivalDate)) tolls=\(r0.tollPreference.rawValue) highways=\(r0.highwayPreference.rawValue) source=\(String(describing: r0.source)) destination=\(String(describing: r0.destination))")
    func calc(_ label: String, _ from: MKMapItem, _ to: MKMapItem, _ tt: MKDirectionsTransportType, alt: Bool = false, tweak: ((MKDirections.Request) -> Void)? = nil) async {
        let r = MKDirections.Request(); r.source = from; r.destination = to; r.transportType = tt; r.requestsAlternateRoutes = alt
        tweak?(r)
        let t0 = Date()
        do {
            let resp = try await MKDirections(request: r).calculate()
            P("dir \(label) OK in \(f(Date().timeIntervalSince(t0), 3))s routes=\(resp.routes.count) source=\(c(resp.source.location.coordinate, 4)) dest=\(c(resp.destination.location.coordinate, 4))")
            for (k, rt) in resp.routes.enumerated() {
                let pl = rt.polyline
                let first = pl.points()[0].coordinate, last = pl.points()[pl.pointCount - 1].coordinate
                P("dir \(label) route\(k) name=\"\(rt.name)\" distance=\(f(rt.distance, 1)) eta=\(f(rt.expectedTravelTime, 1)) transport=\(rt.transportType.rawValue) steps=\(rt.steps.count) advisories=\(rt.advisoryNotices.count) tolls=\(rt.hasTolls) highways=\(rt.hasHighways) points=\(pl.pointCount) first=\(c(first, 5)) last=\(c(last, 5)) bounding=\(mr(pl.boundingMapRect))")
                if k == 0 {
                    for (j, st) in rt.steps.prefix(4).enumerated() {
                        P("dir \(label) step\(j) distance=\(f(st.distance, 1)) transport=\(st.transportType.rawValue) instrLen=\(st.instructions.count) notice=\(st.notice != nil) points=\(st.polyline.pointCount)")
                    }
                    let sum = rt.steps.reduce(0) { $0 + $1.distance }
                    P("dir \(label) stepDistanceSum=\(f(sum, 1)) step0instrEmpty=\(rt.steps.first?.instructions.isEmpty ?? true)")
                }
            }
        } catch { P("dir \(label) THROW in \(f(Date().timeIntervalSince(t0), 3))s \(describe(error))") }
        let t1 = Date()
        do {
            let e = try await MKDirections(request: r).calculateETA()
            P("dir \(label) ETA OK in \(f(Date().timeIntervalSince(t1), 3))s eta=\(f(e.expectedTravelTime, 1)) distance=\(f(e.distance, 1)) transport=\(e.transportType.rawValue) arr-dep=\(f(e.expectedArrivalDate.timeIntervalSince(e.expectedDepartureDate), 1)) depVsNow=\(f(e.expectedDepartureDate.timeIntervalSinceNow, 1))")
        } catch { P("dir \(label) ETA THROW in \(f(Date().timeIntervalSince(t1), 3))s \(describe(error))") }
    }
    await calc("car", mi(applePark), mi(stanford), .automobile)
    await calc("car-alt", mi(applePark), mi(stanford), .automobile, alt: true)
    await calc("walk", mi(applePark), mi(stanford), .walking)
    await calc("cycle", mi(applePark), mi(stanford), .cycling)
    await calc("transit", mi(applePark), mi(sfDowntown), .transit)
    await calc("any", mi(applePark), mi(stanford), .any)
    await calc("car-avoidTolls-highways", mi(applePark), mi(sfDowntown), .automobile) { r in r.tollPreference = .avoid; r.highwayPreference = .avoid }
    await calc("car-depart+1d", mi(applePark), mi(stanford), .automobile) { r in r.departureDate = Date().addingTimeInterval(86400) }
    await calc("car-ocean", mi(CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)), mi(CLLocationCoordinate2D(latitude: 21.3069, longitude: -157.8583)), .automobile)
    await calc("car-same", mi(applePark), mi(applePark), .automobile)
    await calc("car-currentLocation", MKMapItem.forCurrentLocation(), mi(stanford), .automobile)
    let bad = MKDirections.Request()
    do { _ = try await MKDirections(request: bad).calculate(); P("dir empty OK") } catch { P("dir empty THROW \(describe(error))") }
    let d = MKDirections(request: { let r = MKDirections.Request(); r.source = mi(applePark); r.destination = mi(stanford); return r }())
    d.calculate { _, e in P("dir cancelled callback error=\(describe(e))") }
    P("dir isCalculating=\(d.isCalculating)")
    d.cancel()
    await sleep(2)
}

func runGeo() async {
    let g = CLGeocoder()
    func pm(_ p: CLPlacemark) -> String {
        "name=\"\(p.name ?? "nil")\" coord=\(p.location.map { c($0.coordinate, 4) } ?? "nil") locality=\(p.locality ?? "nil") subLocality=\(p.subLocality ?? "nil") admin=\(p.administrativeArea ?? "nil") subAdmin=\(p.subAdministrativeArea ?? "nil") country=\(p.country ?? "nil") iso=\(p.isoCountryCode ?? "nil") postal=\(p.postalCode ?? "nil") tz=\(p.timeZone?.identifier ?? "nil") thoroughfare=\(p.thoroughfare ?? "nil") subThoroughfare=\(p.subThoroughfare ?? "nil") region=\(String(describing: p.region)) ocean=\(p.ocean ?? "nil") inlandWater=\(p.inlandWater ?? "nil") aoi=\(p.areasOfInterest ?? [])"
    }
    func t<T>(_ label: String, _ body: () async throws -> T, _ show: (T) -> String) async {
        let t0 = Date()
        do { let v = try await body(); P("geo \(label) OK in \(f(Date().timeIntervalSince(t0), 3))s \(show(v))") }
        catch { P("geo \(label) THROW in \(f(Date().timeIntervalSince(t0), 3))s \(describe(error))") }
    }
    await t("clgeocoder.forward", { try await g.geocodeAddressString("1 Infinite Loop, Cupertino, CA") }, { "n=\($0.count) " + ($0.first.map(pm) ?? "") })
    await t("clgeocoder.reverse", { try await g.reverseGeocodeLocation(CLLocation(latitude: applePark.latitude, longitude: applePark.longitude)) }, { "n=\($0.count) " + ($0.first.map(pm) ?? "") })
    await t("clgeocoder.reverse.ocean", { try await g.reverseGeocodeLocation(CLLocation(latitude: 0, longitude: -140)) }, { "n=\($0.count) " + ($0.first.map(pm) ?? "") })
    await t("clgeocoder.forward.gibberish", { try await g.geocodeAddressString("qzxqzxqzxvbnq") }, { "n=\($0.count)" })
    await t("clgeocoder.reverse.de", { try await g.reverseGeocodeLocation(CLLocation(latitude: 52.5163, longitude: 13.3777), preferredLocale: Locale(identifier: "de_DE")) }, { "n=\($0.count) " + ($0.first.map(pm) ?? "") })
    // Two concurrent requests on one geocoder
    let g2 = CLGeocoder()
    g2.reverseGeocodeLocation(CLLocation(latitude: applePark.latitude, longitude: applePark.longitude)) { p, e in P("geo concurrent first p=\(p?.count ?? -1) e=\(describe(e))") }
    P("geo isGeocoding=\(g2.isGeocoding)")
    g2.reverseGeocodeLocation(CLLocation(latitude: stanford.latitude, longitude: stanford.longitude)) { p, e in P("geo concurrent second p=\(p?.count ?? -1) e=\(describe(e))") }
    await sleep(3)
    // MapKit geocoding (iOS 26)
    await t("mk.forward", { try await MKGeocodingRequest(addressString: "1 Infinite Loop, Cupertino, CA")!.mapItems }, { "n=\($0.count) " + ($0.first.map(item) ?? "") })
    await t("mk.forward.apple-park", { try await MKGeocodingRequest(addressString: "Apple Park")!.mapItems }, { "n=\($0.count) " + ($0.first.map(item) ?? "") })
    await t("mk.reverse", { try await MKReverseGeocodingRequest(location: CLLocation(latitude: applePark.latitude, longitude: applePark.longitude))!.mapItems }, { "n=\($0.count) " + ($0.first.map(item) ?? "") })
    await t("mk.reverse.ocean", { try await MKReverseGeocodingRequest(location: CLLocation(latitude: 0, longitude: -140))!.mapItems }, { "n=\($0.count) " + ($0.first.map(item) ?? "") })
    await t("mk.forward.gibberish", { try await MKGeocodingRequest(addressString: "qzxqzxqzxvbnq")!.mapItems }, { "n=\($0.count)" })
    P("geo mk.forward empty-string init -> \(MKGeocodingRequest(addressString: "") == nil ? "nil" : "nonnil")")
    P("geo mk.reverse invalid-coordinate init -> \(MKReverseGeocodingRequest(location: CLLocation(latitude: 200, longitude: 0)) == nil ? "nil" : "nonnil")")
    // Burst: 12 reverse lookups back to back (throttling behavior)
    var ok = 0, fail: [String] = []
    let t0 = Date()
    for i in 0..<12 {
        do { let r = try await MKReverseGeocodingRequest(location: CLLocation(latitude: 37.30 + Double(i) * 0.01, longitude: -122.0))!.mapItems; ok += r.isEmpty ? 0 : 1 }
        catch { fail.append("\((error as NSError).domain):\((error as NSError).code)") }
    }
    P("geo burst12 ok=\(ok) fail=\(fail) in \(f(Date().timeIntervalSince(t0), 2))s")
    var clok = 0, clfail: [String] = []
    let t1 = Date()
    for i in 0..<12 {
        do { let r = try await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: 37.30 + Double(i) * 0.01, longitude: -122.1)); clok += r.isEmpty ? 0 : 1 }
        catch { clfail.append("\((error as NSError).domain):\((error as NSError).code)") }
    }
    P("geo clburst12 ok=\(clok) fail=\(clfail) in \(f(Date().timeIntervalSince(t1), 2))s")
}

func runSnap() async {
    func snap(_ label: String, _ o: MKMapSnapshotter.Options, probe: [CLLocationCoordinate2D] = []) async {
        let t0 = Date()
        do {
            let s = try await MKMapSnapshotter(options: o).start()
            var line = "snap \(label) OK in \(f(Date().timeIntervalSince(t0), 3))s image=\(s.image.size) scale=\(s.image.scale) traits=\(s.traitCollection.userInterfaceStyle.rawValue)"
            for k in probe { line += " pt\(c(k, 4))=\(pt(s.point(for: k)))" }
            P(line)
            if let data = s.image.pngData() {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("snap-\(label).png")
                try? data.write(to: url)
            }
        } catch { P("snap \(label) THROW in \(f(Date().timeIntervalSince(t0), 3))s \(describe(error))") }
    }
    let o0 = MKMapSnapshotter.Options()
    P("snap options defaults size=\(o0.size) region=\(rg(o0.region)) mapRect=\(mr(o0.mapRect)) cam=\(cam(o0.camera)) mapType=\(o0.mapType.rawValue) showsBuildings=\(o0.showsBuildings) poi=\(String(describing: o0.pointOfInterestFilter)) config=\(type(of: o0.preferredConfiguration)) traitsScale=\(o0.traitCollection.displayScale) style=\(o0.traitCollection.userInterfaceStyle.rawValue)")
    let reg = MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
    let o1 = MKMapSnapshotter.Options(); o1.region = reg; o1.size = CGSize(width: 300, height: 200)
    P("snap options after region mapRect=\(mr(o1.mapRect)) cam=\(cam(o1.camera))")
    let corners = [applePark, CLLocationCoordinate2D(latitude: applePark.latitude + 0.01, longitude: applePark.longitude - 0.01), CLLocationCoordinate2D(latitude: applePark.latitude - 0.01, longitude: applePark.longitude + 0.01)]
    await snap("region300x200", o1, probe: corners)
    let o2 = MKMapSnapshotter.Options(); o2.region = reg; o2.size = CGSize(width: 300, height: 200)
    o2.traitCollection = UITraitCollection(traitsFrom: [UITraitCollection(displayScale: 1), UITraitCollection(userInterfaceStyle: .dark)])
    await snap("region300x200-scale1-dark", o2, probe: corners)
    let o3 = MKMapSnapshotter.Options(); o3.size = CGSize(width: 300, height: 300)
    o3.mapRect = MKMapRect(origin: MKMapPoint(applePark), size: MKMapSize(width: 10000, height: 10000))
    await snap("mapRect300x300", o3, probe: [MKMapPoint(x: MKMapPoint(applePark).x + 5000, y: MKMapPoint(applePark).y + 5000).coordinate, applePark])
    let o4 = MKMapSnapshotter.Options(); o4.size = CGSize(width: 400, height: 300)
    o4.camera = MKMapCamera(lookingAtCenter: sfDowntown, fromDistance: 900, pitch: 60, heading: 30)
    o4.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
    await snap("camera-pitched", o4, probe: [sfDowntown])
    let o5 = MKMapSnapshotter.Options(); o5.region = reg; o5.size = CGSize(width: 300, height: 200); o5.preferredConfiguration = MKImageryMapConfiguration()
    await snap("imagery", o5)
    let o5b = MKMapSnapshotter.Options(); o5b.region = reg; o5b.size = CGSize(width: 300, height: 200); o5b.preferredConfiguration = MKHybridMapConfiguration()
    await snap("hybrid", o5b)
    if gVariant == "size0" {
        // Raises NSInvalidArgumentException ("Cannot set a zero area size.") on the reference: run last.
        let o6 = MKMapSnapshotter.Options(); o6.region = reg; P("snap setting size zero"); o6.size = .zero
        await snap("size0", o6)
        return
    }
    let o7 = MKMapSnapshotter.Options(); o7.region = reg; o7.size = CGSize(width: 6000, height: 6000)
    await snap("size6000", o7)
    let o8 = MKMapSnapshotter.Options(); o8.region = MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.1)); o8.size = CGSize(width: 300, height: 300)
    await snap("aspectMismatch", o8, probe: [CLLocationCoordinate2D(latitude: applePark.latitude, longitude: applePark.longitude + 0.05), CLLocationCoordinate2D(latitude: applePark.latitude + 0.01, longitude: applePark.longitude)])
    let s = MKMapSnapshotter(options: o1)
    s.start { snap, e in P("snap cancelled callback snap=\(snap != nil) error=\(describe(e))") }
    P("snap isLoading=\(s.isLoading)")
    s.cancel()
    await sleep(2)
    P("snap isLoading after cancel=\(s.isLoading)")
    // Several snapshots in parallel
    let t0 = Date()
    await withTaskGroup(of: Void.self) { grp in
        for i in 0..<4 {
            grp.addTask {
                let o = MKMapSnapshotter.Options(); o.size = CGSize(width: 200, height: 200)
                o.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.3 + Double(i) * 0.1, longitude: -122.0), span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
                do { _ = try await MKMapSnapshotter(options: o).start() } catch { P("snap parallel\(i) THROW \(describe(error))") }
            }
        }
    }
    P("snap parallel4 total=\(f(Date().timeIntervalSince(t0), 3))s")
}

@MainActor func runOpen() async {
    let app = UIApplication.shared
    for u in ["maps://?q=coffee", "maps:", "http://maps.apple.com/?q=coffee", "https://maps.apple.com/place?coordinate=37.3349,-122.009", "geo:37.3349,-122.009", "comgooglemaps://"] {
        P("open canOpenURL \(u) -> \(app.canOpenURL(URL(string: u)!))")
    }
    let it = MKMapItem(location: CLLocation(latitude: applePark.latitude, longitude: applePark.longitude), address: nil)
    it.name = "Probe Place"
    P("open mapItem url=\(String(describing: it.url)) name=\(it.name ?? "nil")")
    let variant = gVariant.isEmpty ? "openInMaps" : gVariant
    let t0 = Date()
    switch variant {
    case "openInMaps":
        let ok: Bool = await withCheckedContinuation { k in
            it.openInMaps(launchOptions: [MKLaunchOptionsMapTypeKey: MKMapType.standard.rawValue], from: nil) { k.resume(returning: $0) }
        }
        P("open openInMaps completion=\(ok) in \(f(Date().timeIntervalSince(t0), 3))s")
    case "directions":
        let ok = MKMapItem.openMaps(with: [MKMapItem.forCurrentLocation(), it], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        P("open openMaps(with:) directions returned=\(ok) in \(f(Date().timeIntervalSince(t0), 3))s")
    case "url":
        let ok = await app.open(URL(string: "maps://?q=coffee&ll=37.3349,-122.009")!)
        P("open maps:// URL completion=\(ok) in \(f(Date().timeIntervalSince(t0), 3))s")
    case "https":
        let ok = await app.open(URL(string: "https://maps.apple.com/?q=coffee")!)
        P("open https maps URL completion=\(ok) in \(f(Date().timeIntervalSince(t0), 3))s")
    default: break
    }
    await sleep(3)
    P("open state=\(app.applicationState.rawValue)")
    await shot("open-\(variant)")
    await sleep(3)
    await shot("open-\(variant)-later")
}
