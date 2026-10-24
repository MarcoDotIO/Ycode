// MKProbe: SwiftUI Map modes.
//   -mode sui     content (markers, annotation, shapes) with .automatic position;
//                 records the camera the framework picks, then camera changes.
//   -mode suicam  sequence of programmatic positions; MapProxy conversions.
//   -variant      map style: standard | standard-realistic | imagery | hybrid
import SwiftUI
import MapKit

func mcam(_ m: MapCamera) -> String {
    "{center=\(c(m.centerCoordinate)) dist=\(f(m.distance, 3)) heading=\(f(m.heading, 3)) pitch=\(f(m.pitch, 3))}"
}
func posDesc(_ p: MapCameraPosition) -> String {
    "{auto=\(p.positionedByUser ? "user" : "app") followsUser=\(p.followsUserLocation) region=\(p.region.map(rg) ?? "nil") rect=\(p.rect.map(mr) ?? "nil") camera=\(p.camera.map(mcam) ?? "nil") item=\(p.item?.name ?? "nil") fallback=\(p.fallbackPosition != nil)}"
}

struct SUIRoot: View {
    @State var pos: MapCameraPosition = .automatic
    @State var sel: Int?
    @State var cont = 0
    var style: MapStyle {
        switch gVariant {
        case "imagery": return .imagery(elevation: .realistic)
        case "hybrid": return .hybrid(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false)
        case "standard-realistic": return .standard(elevation: .realistic)
        default: return .standard
        }
    }
    var body: some View {
        MapReader { proxy in
            Map(position: $pos, selection: $sel) {
                Marker("Probe A", coordinate: applePark).tag(1)
                Marker("Probe B", systemImage: "star.fill", coordinate: CLLocationCoordinate2D(latitude: applePark.latitude + 0.004, longitude: applePark.longitude)).tint(.orange).tag(2)
                Marker("Probe M", monogram: Text("MK"), coordinate: CLLocationCoordinate2D(latitude: applePark.latitude - 0.004, longitude: applePark.longitude + 0.004)).tag(3)
                Annotation("Probe C", coordinate: CLLocationCoordinate2D(latitude: applePark.latitude, longitude: applePark.longitude - 0.006)) {
                    Circle().fill(.red).frame(width: 20, height: 20)
                }.tag(4)
                MapCircle(center: CLLocationCoordinate2D(latitude: applePark.latitude - 0.003, longitude: applePark.longitude - 0.002), radius: 200).foregroundStyle(.blue.opacity(0.3))
                MapPolyline(coordinates: [CLLocationCoordinate2D(latitude: applePark.latitude - 0.006, longitude: applePark.longitude - 0.006), applePark, CLLocationCoordinate2D(latitude: applePark.latitude + 0.006, longitude: applePark.longitude + 0.002)]).stroke(.blue, lineWidth: 4)
                MapPolygon(coordinates: [CLLocationCoordinate2D(latitude: applePark.latitude + 0.006, longitude: applePark.longitude - 0.007), CLLocationCoordinate2D(latitude: applePark.latitude + 0.002, longitude: applePark.longitude - 0.007), CLLocationCoordinate2D(latitude: applePark.latitude + 0.004, longitude: applePark.longitude - 0.003)]).foregroundStyle(.green.opacity(0.3))
            }
            .mapStyle(style)
            .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView(); MapPitchToggle() }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                P("sui onEnd camera=\(mcam(ctx.camera)) region=\(rg(ctx.region)) rect=\(mr(ctx.rect)) pos=\(posDesc(pos))")
            }
            .onMapCameraChange(frequency: .continuous) { _ in cont += 1 }
            .onChange(of: sel) { _, n in P("sui selection -> \(String(describing: n))") }
            .task { await drive(proxy) }
        }
        .ignoresSafeArea()
    }

    @MainActor func drive(_ proxy: MapProxy) async {
        await sleep(6)
        P("sui after6s pos=\(posDesc(pos)) continuousCount=\(cont)")
        let p = proxy.convert(applePark, to: .local)
        P("sui proxy applepark->local=\(p.map(pt) ?? "nil") local(0,0)->coord=\(proxy.convert(CGPoint.zero, from: .local).map { c($0, 7) } ?? "nil") global applepark=\(proxy.convert(applePark, to: .global).map(pt) ?? "nil")")
        if let b = proxy.convert(CLLocationCoordinate2D(latitude: applePark.latitude + 0.004, longitude: applePark.longitude), to: .global) {
            let s = UIScreen.main.bounds
            P("target markerB=\(f(Double(b.x / s.width), 4)),\(f(Double((b.y - 20) / s.height), 4))")
        }
        await shot("sui-\(gMode)-\(gVariant.isEmpty ? "standard" : gVariant)")
        if gMode == "sui" {
            await ready("tap=markerB", wait: 4)
            P("sui after tap sel=\(String(describing: sel))")
            await shot("sui-selected")
            return
        }
        let steps: [(String, MapCameraPosition)] = [
            ("camera1000p0", .camera(MapCamera(centerCoordinate: applePark, distance: 1000, heading: 0, pitch: 0))),
            ("camera1000p60h45", .camera(MapCamera(centerCoordinate: sfDowntown, distance: 1000, heading: 45, pitch: 60))),
            ("region0.05", .region(MKCoordinateRegion(center: applePark, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))),
            ("rect10km", .rect(MKMapRect(origin: MKMapPoint(applePark), size: MKMapSize(width: 10000, height: 10000)))),
            ("userLocation-fallback", .userLocation(fallback: .region(MKCoordinateRegion(center: stanford, latitudinalMeters: 2000, longitudinalMeters: 2000)))),
            ("automatic", .automatic),
        ]
        for (n, s) in steps {
            cont = 0
            pos = s
            P("sui set \(n) pos=\(posDesc(pos))")
            await sleep(4)
            P("sui after \(n) pos=\(posDesc(pos)) continuous=\(cont)")
        }
        withAnimation(.linear(duration: 2)) {
            pos = .camera(MapCamera(centerCoordinate: stanford, distance: 3000, heading: 0, pitch: 0))
        }
        cont = 0
        await sleep(4)
        P("sui animated camera continuous=\(cont)")
        await ready("drag-map", wait: 4)
        P("sui after drag pos=\(posDesc(pos))")
    }
}
