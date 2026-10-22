import SwiftUI
import Charts

struct PlanningView: View {
    let providers: [ProviderUsage]
    @AppStorage("menu.provider") private var selectedID = ""
    @AppStorage("menu.window") private var menuWindow = "rotate"
    @State private var agents = 1
    @State private var weekly = false

    init(providers: [ProviderUsage], agents: Int = 1) {
        self.providers = providers
        _agents = State(initialValue: min(max(agents, 1), 16))
    }

    private var candidates: [ProviderUsage] { providers.filter { !$0.planningWindows.isEmpty } }
    private var provider: ProviderUsage? { ProviderUsage.menuProvider(in: providers, selectedID: selectedID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let provider {
                Picker("IA en la barra", selection: Binding(get: { provider.id }, set: { selectedID = $0 })) {
                    ForEach(candidates) { Text($0.name).tag($0.id) }
                }
                Picker("Cuota en la barra", selection: $menuWindow) {
                    Text("Alternar").tag("rotate")
                    Text("5 h").tag("5h")
                    Text("Semanal").tag("weekly")
                }
                .pickerStyle(.segmented)
                Text("La barra muestra cuota libre de esta IA. Una ventana de 5 h no equivale a cinco horas de trabajo.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Picker("Ventana a proyectar", selection: $weekly) {
                    Text("Sesión de 5 h").tag(false)
                    Text("Semanal").tag(true)
                }
                .pickerStyle(.segmented)
                if let window = provider.planningWindows.first(where: { $0.duration == (weekly ? 604_800 : 18_000) }) {
                    UsageBar(window: window, showsPace: false)
                    Stepper("Agentes en el escenario: \(agents)", value: $agents, in: 1...16)
                        .font(.callout).monospacedDigit()
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        forecast(provider: provider, window: window, now: context.date)
                    }
                } else {
                    Text("Esta fuente no informa esa ventana.").font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                Text("Sesiones recientes: \(provider.sessions.count). No equivalen al número de agentes activos.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Sin cuotas para proyectar", systemImage: "chart.xyaxis.line",
                                       description: Text("Se necesita una ventana de 5 h o semanal informada por la herramienta."))
            }
        }
        .padding(16)
    }

    @ViewBuilder private func forecast(provider: ProviderUsage, window: UsageWindow, now: Date) -> some View {
        if provider.error == nil, provider.quotaSource?.hasPrefix("Registro") != true,
           let runtime = window.estimatedRunTime(agents: agents, at: now), let reset = window.resetsAt {
            let title = if window.remaining <= 0 {
                "Cuota agotada en esta ventana"
            } else if runtime >= reset.timeIntervalSince(now) {
                "Alcanza hasta el reinicio"
            } else {
                "≈ \(compactDuration(runtime)) de trabajo antes de agotar cuota"
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Proyección de cuota").font(.headline)
                Text(title)
                    .font(.callout.weight(.medium))
                    .contentTransition(.numericText())
                QuotaProjectionChart(window: window, agents: agents, now: now)
                Text("Cada agente consume como el ritmo medio de la ventana, incluidas pausas. Puede variar según modelo y tarea; no mide agentes reales.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Label("Sin ritmo suficiente para estimar. Se necesita consumo mayor que cero, un reinicio vigente y datos sin errores.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct QuotaProjectionChart: View {
    let window: UsageWindow
    let agents: Int
    let now: Date

    private var hours: Double { max((window.resetsAt?.timeIntervalSince(now) ?? 0) / 3600, 0.01) }

    var body: some View {
        Chart {
            ForEach(agents == 1 ? [1] : [1, agents], id: \.self) { count in
                ForEach(0...24, id: \.self) { step in
                    let hour = hours * Double(step) / 24
                    let fraction = window.projectedRemaining(after: min(hour * 3600, window.resetsAt?.timeIntervalSince(now) ?? 0), agents: count, at: now)
                    if let fraction {
                        LineMark(x: .value("Horas desde ahora", hour), y: .value("Cuota libre", fraction * 100))
                            .foregroundStyle(by: .value("Escenario", count == 1 ? "Ritmo observado" : "\(count) agentes"))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: count == 1 ? [] : [5, 3]))
                    }
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: 0...hours)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(anchor: .top)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) {
                AxisGridLine()
                AxisValueLabel(anchor: .trailing)
            }
        }
        .chartXAxisLabel("Horas desde ahora · hasta el reinicio")
        .chartYAxisLabel("Libre (%)")
        .frame(height: 150)
        .accessibilityLabel("Proyección lineal de cuota libre hasta el próximo reinicio")
    }
}
