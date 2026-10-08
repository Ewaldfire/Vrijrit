import SwiftUI

struct MetricsView: View {
    let metrics: Metrics
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rijstatistieken").font(.title2.bold())
            row("Tijd gereden", time(metrics.moving))
            row("Stilstand", time(metrics.stopped))
            row("Niet gemeten tijd", time(metrics.unknown))
            row("Stops (minimaal 5 s)", "\(metrics.stops)")
            row("Links / rechts", "\(metrics.left) / \(metrics.right)")
            row("Remacties normaal / stevig", "\(metrics.braking) / \(metrics.hardBraking)")
            row("Optrekken normaal / stevig", "\(metrics.acceleration) / \(metrics.hardAcceleration)")
            row("Max. versnelling", force(metrics.maxAcceleration))
            if let date = metrics.accelerationDate { Text(date.formatted()).font(.caption).foregroundStyle(.secondary) }
            row("Max. vertraging", force(metrics.maxDeceleration))
            if let date = metrics.decelerationDate { Text(date.formatted()).font(.caption).foregroundStyle(.secondary) }
            row("Zijwaartse piek (GPS)", String(format: "%.2f g", metrics.lateralG))
            row("Bewegingssensor piek", metrics.sensorPeak.map { String(format: "%.2f g", $0) } ?? "Niet gemeten")
            Text("Versnelling, remmen en bochten zijn GPS-schattingen. Bochten vanaf 55° kunnen ook wegkrommingen zijn. De sensorpiek omvat alle richtingen en kan hobbels of telefoonbewegingen bevatten. Sensorregistratie op de achtergrond moet op je toestel worden gecontroleerd.").font(.caption).foregroundStyle(.secondary)
        }.padding().background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
    func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).bold().monospacedDigit().multilineTextAlignment(.trailing) }.font(.callout)
    }
    func time(_ seconds: Double) -> String { "\(Int(seconds) / 3600)u \((Int(seconds) / 60) % 60)m \(Int(seconds) % 60)s" }
    func force(_ value: Double) -> String { String(format: "%.2f m/s² · %.2f g", value, value / 9.80665) }
}
struct TotalsView: View {
    @EnvironmentObject var recorder: Recorder
    var total: Metrics { recorder.trips.reduce(Metrics()) { result, trip in var m = result; m.add(Metrics.calculate(trip)); return m } }
    var distance: Double { recorder.trips.reduce(0) { $0 + $1.distance } }
    var duration: Double { recorder.trips.reduce(0) { $0 + $1.duration } }
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                Text("Alle opgeslagen ritten").font(.title.bold())
                Text("\(recorder.trips.count) ritten").foregroundStyle(.mint)
                Text(String(format: "%.1f km", distance / 1000)).font(.system(size: 44, weight: .bold, design: .rounded))
                Group {
                    Text("Totale ritduur: \(Int(duration / 3600))u \(Int(duration / 60) % 60)m")
                    Text(String(format: "Gemiddelde snelheid: %.1f km/u", duration > 0 ? distance / duration * 3.6 : 0))
                    Text(String(format: "Hoogste snelheid: %.0f km/u", recorder.trips.map(\.topSpeed).max() ?? 0))
                    Text(String(format: "Langste rit: %.1f km", (recorder.trips.map(\.distance).max() ?? 0) / 1000))
                    Text(String(format: "Gemiddelde rit: %.1f km", recorder.trips.isEmpty ? 0 : distance / Double(recorder.trips.count) / 1000))
                }.font(.callout)
                MetricsView(metrics: total)
                ShareLink(item: "VrijRit totaal: \(recorder.trips.count) ritten, \(String(format: "%.1f", distance / 1000)) km\n" + total.report) { Label("Deel totaaloverzicht", systemImage: "square.and.arrow.up") }
                Text("Verwijderde ritten tellen niet mee. Oudere ritten zonder koers- of sensordata hebben geen volledige bocht- of sensorstatistieken.").font(.caption).foregroundStyle(.secondary)
            }.padding() }.navigationTitle("Totaal")
        }
    }
}
