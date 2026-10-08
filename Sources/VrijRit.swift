import SwiftUI
import MapKit
import CoreLocation
import Combine
import UIKit
import CoreMotion
import UniformTypeIdentifiers

struct Fix: Codable {
    var latitude: Double
    var longitude: Double
    var date: Date
    var speed: Double
    var accuracy: Double
    var course: Double? = nil
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var location: CLLocation { .init(latitude: latitude, longitude: longitude) }
}
struct Trip: Codable, Identifiable {
    var id = UUID()
    var start = Date()
    var end: Date?
    var points: [Fix] = []
    var motionPeakG: Double? = nil
    var distance: Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let dt = pair.1.date.timeIntervalSince(pair.0.date)
            return total + (dt > 0 && dt < 30 ? pair.1.location.distance(from: pair.0.location) : 0)
        }
    }
    var duration: Double { max(0, (end ?? points.last?.date ?? start).timeIntervalSince(start)) }
    var topSpeed: Double { (points.map(\.speed).max() ?? 0) * 3.6 }
    var average: Double { duration > 0 ? distance / duration * 3.6 : 0 }
}
final class Recorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var trips: [Trip] = []
    @Published var active: Trip?
    @Published var armed = false
    @Published var message = "Start een rit of schakel detectie in."
    @Published var speed = 0.0
    private let manager = CLLocationManager()
    private let motion = CMMotionManager()
    private var filteredG = 0.0
    private var pendingStart = false
    private var drivingSince: Date?
    private var stoppedSince: Date?
    private var buffer: [Fix] = []
    private let url = URL.documentsDirectory.appending(path: "vrijrit.json")
    private let recovery = URL.documentsDirectory.appending(path: "active.json")
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        do {
            if FileManager.default.fileExists(atPath: url.path) { trips = try JSONDecoder().decode([Trip].self, from: Data(contentsOf: url)) }
            if FileManager.default.fileExists(atPath: recovery.path) {
                var recovered = try JSONDecoder().decode(Trip.self, from: Data(contentsOf: recovery))
                recovered.end = recovered.points.last?.date ?? recovered.start
                if !trips.contains(where: { $0.id == recovered.id }) { trips.insert(recovered, at: 0) }
                try save(); try FileManager.default.removeItem(at: recovery)
                message = "Onderbroken rit hersteld."
            }
        } catch { message = "Opslag kon niet worden gelezen: \(error.localizedDescription)" }
    }
    func start() { pendingStart = true; authorize() }
    func setArmed(_ value: Bool) {
        armed = value
        if value { authorize() } else if active == nil { manager.stopUpdatingLocation(); buffer = []; drivingSince = nil }
    }
    private func authorize() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            if pendingStart { active = Trip(); pendingStart = false; startMotion(); checkpoint() }
            message = active != nil ? "Rit wordt opgenomen." : "Detectie actief zolang iOS de app laat draaien."
        default: pendingStart = false; armed = false; message = "Geef VrijRit locatie-toegang in Instellingen."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if pendingStart || armed { authorize() }
    }
    func finish() {
        guard var trip = active else { return }
        trip.end = trip.points.last?.date ?? Date()
        trips.insert(trip, at: 0)
        do { try save(); try? FileManager.default.removeItem(at: recovery); active = nil }
        catch { trips.removeFirst(); message = "Opslaan mislukt. Probeer opnieuw: \(error.localizedDescription)"; return }
        motion.stopDeviceMotionUpdates(); filteredG = 0
        speed = 0; stoppedSince = nil; drivingSince = nil; buffer = []
        if !armed { manager.stopUpdatingLocation() }
        message = "Rit opgeslagen."
    }
    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        filteredG = 0
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let self, let sample, self.active != nil else { return }
            let a = sample.userAcceleration
            let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            self.filteredG = 0.8 * self.filteredG + 0.2 * magnitude
            self.active?.motionPeakG = max(self.active?.motionPeakG ?? 0, self.filteredG)
        }
    }
    private func save() throws { try JSONEncoder().encode(trips).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    private func checkpoint() {
        do { if let active { try JSONEncoder().encode(active).write(to: recovery, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } }
        catch { message = "Tussentijds opslaan mislukt: \(error.localizedDescription)" }
    }
    func delete(_ offsets: IndexSet) {
        let old = trips; trips.remove(atOffsets: offsets)
        do { try save() } catch { trips = old; message = "Verwijderen mislukt." }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { message = "GPS: \(error.localizedDescription)" }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 35,
                  abs(location.timestamp.timeIntervalSinceNow) < 15, location.speed >= 0 else { continue }
            if let last = active?.points.last ?? buffer.last, location.timestamp <= last.date { continue }
            let fix = Fix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, date: location.timestamp, speed: location.speed, accuracy: location.horizontalAccuracy, course: location.course >= 0 ? location.course : nil)
            speed = fix.speed * 3.6
            if active == nil && armed {
                buffer.append(fix); buffer.removeAll { fix.date.timeIntervalSince($0.date) > 30 }
                if speed >= 15 {
                    if drivingSince == nil { drivingSince = fix.date }
                    if fix.date.timeIntervalSince(drivingSince!) >= 10 { active = Trip(start: buffer.first?.date ?? fix.date, points: Array(buffer.dropLast())); startMotion() }
                } else { drivingSince = nil }
            }
            if active != nil {
                active?.points.append(fix); checkpoint()
                if armed {
                    if speed < 3 {
                        if stoppedSince == nil { stoppedSince = fix.date }
                        if fix.date.timeIntervalSince(stoppedSince!) >= 180 { finish() }
                    } else { stoppedSince = nil }
                }
            }
        }
    }
}
struct RouteView: View {
    let points: [Fix]
    var body: some View {
        Map {
            if points.count > 1 { MapPolyline(coordinates: points.map(\.coordinate)).stroke(.mint, lineWidth: 5) }
            if let first = points.first { Marker("Start", coordinate: first.coordinate).tint(.mint) }
            if let last = points.last, points.count > 1 { Marker("Einde", coordinate: last.coordinate).tint(.orange) }
        }.mapStyle(.standard(elevation: .flat)).frame(height: 270).clipShape(RoundedRectangle(cornerRadius: 22))
    }
}
struct Stats: View {
    let trip: Trip
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            tile("Afstand", String(format: "%.2f km", trip.distance / 1000))
            tile("Duur", String(format: "%d:%02d min", Int(trip.duration) / 60, Int(trip.duration) % 60))
            tile("Gemiddeld", String(format: "%.0f km/u", trip.average))
            tile("Hoogste snelheid", String(format: "%.0f km/u", trip.topSpeed))
        }
    }
    func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.bold()).monospacedDigit() }
            .frame(maxWidth: .infinity, alignment: .leading).padding().background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}
struct TripDetail: View {
    let trip: Trip
    var body: some View {
        ScrollView { VStack(spacing: 20) {
            Text(trip.start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
            RouteView(points: trip.points); Stats(trip: trip)
            MetricsView(metrics: Metrics.calculate(trip))
            if let last = trip.points.last, let url = googleURL(last) {
                Link(destination: url) { Label("Navigeer naar eindpunt met Google Maps", systemImage: "arrow.triangle.turn.up.right.diamond") }
                Text("Opent Google Maps en deelt dit eindpunt met Google. De gereden GPS-route wordt niet overgezet.").font(.caption).foregroundStyle(.secondary)
            }
            ShareLink(item: report) { Label("Deel ritoverzicht", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
            ShareLink(item: gpx) { Label("Deel GPX als tekst", systemImage: "map") }
            Text("GPS-metingen zijn schattingen. Gaten van 30 seconden of langer tellen niet mee voor de afstand.").font(.caption).foregroundStyle(.secondary)
        }.padding() }.navigationTitle("Jouw rit")
    }
    func googleURL(_ point: Fix) -> URL? {
        var components = URLComponents(string: "https://www.google.com/maps/dir/")
        components?.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "destination", value: "\(point.latitude),\(point.longitude)"), URLQueryItem(name: "travelmode", value: "driving"), URLQueryItem(name: "dir_action", value: "navigate")]
        return components?.url
    }
    var report: String { "VrijRit • \(trip.start.formatted())\n\(String(format: "%.2f", trip.distance / 1000)) km • \(Int(trip.duration / 60)) minuten\nGemiddeld \(Int(trip.average)) km/u • hoogste \(Int(trip.topSpeed)) km/u\n" + Metrics.calculate(trip).report }
    var gpx: String {
        let formatter = ISO8601DateFormatter()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"VrijRit\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>VrijRit</name><trkseg>" + trip.points.map { "<trkpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"><time>\(formatter.string(from: $0.date))</time></trkpt>" }.joined() + "</trkseg></trk></gpx>"
    }
}
@main struct VrijRitApp: App {
    @StateObject private var recorder = Recorder()
    var body: some Scene { WindowGroup { RootView().environmentObject(recorder).preferredColorScheme(.dark).tint(.mint) } }
}
struct RootView: View {
    @EnvironmentObject var recorder: Recorder
    var body: some View {
        TabView {
            NavigationStack {
                ScrollView { VStack(alignment: .leading, spacing: 22) {
                    Text("Elke rit. Jouw data.").font(.largeTitle.bold())
                    Text("GRATIS • GEEN ACCOUNT • GEEN ABONNEMENT").font(.caption.bold()).foregroundStyle(.mint)
                    RouteView(points: recorder.active?.points ?? [])
                    if let trip = recorder.active {
                        Text(String(format: "%.0f km/u", recorder.speed)).font(.system(size: 54, weight: .bold, design: .rounded)).monospacedDigit()
                        Stats(trip: trip)
                        Button("Stop en bewaar rit", action: recorder.finish).buttonStyle(.borderedProminent)
                    } else { Button(action: recorder.start) { Label("Start rit", systemImage: "record.circle") }.buttonStyle(.borderedProminent).controlSize(.large) }
                    Text(recorder.message).font(.callout).foregroundStyle(.secondary)
                    Toggle("Automatische detectie", isOn: Binding(get: { recorder.armed }, set: { recorder.setArmed($0) }))
                    Text("Detectie start na 10 seconden boven 15 km/u en stopt na 3 minuten stilstand. Dit kan ook fiets- of treinritten herkennen. Open de app vóór vertrek; herstart na afsluiten is nog niet ondersteund.").font(.caption).foregroundStyle(.secondary)
                    Text("Stel de app in vóór je vertrekt.").font(.caption)
                }.padding() }.navigationTitle("VrijRit")
            }.tabItem { Label("Opnemen", systemImage: "location.circle") }
            NavigationStack {
                List {
                    Section {
                        Text("\(recorder.trips.count) ritten • \(String(format: "%.1f", recorder.trips.reduce(0) { $0 + $1.distance } / 1000)) km totaal")
                    }
                    if recorder.trips.isEmpty { Text("Je eerste rit verschijnt hier zodra je hem opslaat.").foregroundStyle(.secondary) }
                    ForEach(recorder.trips) { trip in
                        NavigationLink { TripDetail(trip: trip) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(trip.start.formatted(date: .abbreviated, time: .shortened))
                                Text("\(String(format: "%.1f", trip.distance / 1000)) km • \(Int(trip.duration / 60)) min").foregroundStyle(.secondary)
                            }
                        }
                    }.onDelete(perform: recorder.delete)
                }.navigationTitle("Ritten").toolbar { EditButton() }
            }.tabItem { Label("Geschiedenis", systemImage: "clock") }
            TotalsView().tabItem { Label("Totaal", systemImage: "chart.bar") }
            ExplorationView().tabItem { Label("Ontdekken", systemImage: "map") }
            NavigationStack {
                List {
                    Section("Jouw gegevens") {
                        Text("Ritten blijven in de lokale app-opslag. Geen eigen server, advertenties of betaalde functies. Apple Maps haalt kaartgegevens op via Apple. iOS-apparaatback-ups kunnen app-data bevatten.")
                        ShareLink(item: backup) { Label("Exporteer alle ritten (JSON-tekst)", systemImage: "square.and.arrow.up") }
                    }
                    Section("Nauwkeurigheid") { Text("Afstand, snelheid en detectie zijn gebaseerd op GPS. Remacties, acceleraties en afslagen zijn GPS-schattingen. De bewegingssensor meet een gefilterde piek; hobbels en telefoonbewegingen kunnen meetellen.") }
                    Section("Locatie") { Button("Open app-instellingen") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } }
                }.navigationTitle("Instellingen")
            }.tabItem { Label("Instellingen", systemImage: "gearshape") }
        }
    }
    var backup: String { String(data: (try? JSONEncoder().encode(recorder.trips)) ?? Data(), encoding: .utf8) ?? "[]" }
}

struct VisitedCell: Identifiable {
    var row: Int
    var column: Int
    var id: String { "\(row):\(column)" }
    var corners: [CLLocationCoordinate2D] {
        let lat = Double(row) * 0.0025
        let lon = Double(column) * 0.004
        return [.init(latitude: lat, longitude: lon), .init(latitude: lat + 0.0025, longitude: lon), .init(latitude: lat + 0.0025, longitude: lon + 0.004), .init(latitude: lat, longitude: lon + 0.004)]
    }
}
struct ExplorationView: View {
    @EnvironmentObject var recorder: Recorder
    @State private var showAreas = true
    @State private var showRoutes = true
    var allTrips: [Trip] { recorder.trips + (recorder.active.map { [$0] } ?? []) }
    var cells: [VisitedCell] {
        var seen = Set<String>()
        return allTrips.flatMap(\.points).compactMap { point in
            let cell = VisitedCell(row: Int(floor(point.latitude / 0.0025)), column: Int(floor(point.longitude / 0.004)))
            return seen.insert(cell.id).inserted ? cell : nil
        }
    }
    // Split at GPS gaps instead of drawing a falsely visited road across missing data.
    var segments: [[Fix]] {
        allTrips.flatMap { trip -> [[Fix]] in
            var result: [[Fix]] = []; var current: [Fix] = []
            for point in trip.points {
                if let last = current.last, point.date.timeIntervalSince(last.date) >= 30 {
                    if current.count > 1 { result.append(current) }; current = []
                }
                current.append(point)
            }
            if current.count > 1 { result.append(current) }
            return result
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Map {
                    if showAreas {
                        ForEach(cells) { cell in MapPolygon(coordinates: cell.corners).foregroundStyle(.mint.opacity(0.15)) }
                    }
                    if showRoutes {
                        ForEach(Array(segments.enumerated()), id: \.offset) { item in
                            MapPolyline(coordinates: item.element.map(\.coordinate)).stroke(.green, lineWidth: 4)
                        }
                    }
                    UserAnnotation()
                }.mapStyle(.standard(elevation: .flat)).mapControls { MapUserLocationButton(); MapCompass() }
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(cells.count) bezochte kaartvakken").font(.headline)
                    Toggle("Gereden trajecten", isOn: $showRoutes)
                    Toggle("Bezochte gebieden", isOn: $showAreas)
                    Text("Groen = geregistreerd traject. Wegen zonder groen hebben geen registratie. GPS kan afwijken; dit is nog geen herkenning van afzonderlijke wegen. Gebieden zijn kaartvakken van ongeveer 280 × 270 meter in Nederland.").font(.caption).foregroundStyle(.secondary)
                    if recorder.trips.isEmpty && recorder.active == nil { Text("Neem je eerste rit op om de kaart te vullen.").font(.callout) }
                }.padding(.horizontal).padding(.bottom)
            }.navigationTitle("Jouw wegen")
        }
    }
}
