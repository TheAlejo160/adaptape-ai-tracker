import SwiftUI
import Charts

struct HistoryView: View {
    let samples: [QuotaSample]
    let error: String?
    @State private var selectedID = ""
    @State private var days = 1
    @State private var window = "5h"

    private var providers: [String: String] {
        Dictionary(samples.map { ($0.providerID, $0.providerName) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Historial de cuota").font(.headline)
            Picker("Vista", selection: $selectedID) {
                Text("General · todas las IAs").tag("")
                ForEach(providers.keys.sorted(), id: \.self) { id in
                    Text(providers[id] ?? id).tag(id)
                }
            }
            Picker("Periodo", selection: $days) {
                Text("Día").tag(1)
                Text("Semana").tag(7)
                Text("Mes").tag(30)
            }
            .pickerStyle(.segmented)
            Picker("Cuota", selection: $window) {
                Text("5 h").tag("5h")
                Text("Semanal").tag("weekly")
                Text("Otras cuotas").tag("other")
            }
            .pickerStyle(.segmented)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                chart(now: context.date)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            Text("Porcentajes de cuota, no tokens consumidos. Cada curva tiene su propio límite; no se suman. Los reinicios pueden bajar la curva.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Muestras horarias durante 35 días, solo en este Mac. No se inventa historial anterior; un cierre forzado puede perder los últimos 10 minutos.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .onChange(of: selectedID, initial: true) { _, id in
            let kinds = Set(samples.filter { id.isEmpty || $0.providerID == id }.map(\.windowKind))
            if !kinds.contains(window), let available = ["5h", "weekly", "other"].first(where: kinds.contains) {
                window = available
            }
        }
    }

    @ViewBuilder private func chart(now: Date) -> some View {
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        let points = QuotaHistory.visible(samples, providerID: selectedID, days: days, window: window, now: now)
        if points.isEmpty {
            ContentUnavailableView("Aún no hay muestras para esta vista", systemImage: "chart.xyaxis.line",
                                   description: Text("Se añadirán al recibir cuotas de esta ventana. Prueba otra IA o tipo de cuota."))
                .frame(height: 220)
        } else {
            Text(days == 1 ? "Últimas 24 horas" : "Últimos \(days) días")
                .font(.caption).foregroundStyle(.secondary)
            Chart(points) { point in
                LineMark(x: .value("Fecha", point.date), y: .value("Cuota usada", point.used * 100))
                    .foregroundStyle(by: .value("IA y límite", point.series))
                PointMark(x: .value("Fecha", point.date), y: .value("Cuota usada", point.used * 100))
                    .foregroundStyle(by: .value("IA y límite", point.series))
                    .symbol(by: .value("IA y límite", point.series))
                    .symbolSize(14)
            }
            .chartXScale(domain: start...now)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) {
                    AxisGridLine()
                    AxisValueLabel(format: days == 1 ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated), anchor: .top)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) {
                    AxisGridLine()
                    AxisValueLabel(anchor: .trailing)
                }
            }
            .chartYAxisLabel("Usado (%)")
            .frame(height: 230)
            .accessibilityLabel("Historial de cuota usada por IA y límite, últimos \(days) días")
            if points.contains(where: \.unverified) {
                Label("Incluye registros locales con cuenta sin verificar.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
