import SwiftUI

extension EnvironmentValues {
    /// False while the menu bar panel is closed. MenuBarExtra keeps the hidden view alive,
    /// so perpetual animations must stop or they burn CPU all day.
    @Entry var isPanelVisible = true
}

extension Activity {
    var label: String {
        switch self {
        case .idle: "Inactivo"
        case .processing(let task): task ?? "Procesando…"
        case .waiting: "Sesión abierta"
        case .rateLimited: "Límite alcanzado"
        case .offline: "Sin conexión"
        }
    }
}

struct ActivityIndicator: View {
    let activity: Activity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isPanelVisible) private var isPanelVisible

    var body: some View {
        dot
            .frame(width: 8, height: 8)
            .accessibilityLabel(activity.label)
    }

    @ViewBuilder private var dot: some View {
        switch activity {
        case .idle:
            Circle().fill(.secondary).opacity(0.5)
        case .processing where reduceMotion || !isPanelVisible:
            Circle().fill(.blue)
        case .processing:
            // Two phases auto-cycle: dot breathes 0.4↔1, halo expands and fades.
            Circle().fill(.blue).phaseAnimator([false, true]) { dot, on in
                dot
                    .opacity(on ? 1 : 0.4)
                    .background(Circle().stroke(.blue, lineWidth: 1).scaleEffect(on ? 1.8 : 1).opacity(on ? 0 : 0.6))
            } animation: { _ in .easeInOut(duration: 1.2) }
        case .waiting:
            Circle().fill(.green)
        case .rateLimited:
            Circle().fill(.red)
        case .offline:
            Circle().strokeBorder(.secondary, lineWidth: 1.5)
        }
    }
}

struct SessionRow: View {
    let session: ActiveSessionInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.green)
            Text(session.title).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(compactDuration(context.date.timeIntervalSince(session.startedAt)))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

struct LocalStatsView: View {
    let stats: LocalStats
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("VRAM").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(stats.vramUsedGB.formatted(.number.precision(.fractionLength(1)))) / \(stats.vramTotalGB.formatted(.number.precision(.fractionLength(0...1)))) GB")
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            // Neutral color: VRAM is capacity, not a quota.
            MeterBar(fraction: stats.vramTotalGB > 0 ? stats.vramUsedGB / stats.vramTotalGB : 0, color: .blue.opacity(0.8))
            HStack {
                Text(stats.loadedModel ?? "Ningún modelo cargado")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let tps = stats.tokensPerSecond {
                    Label("\(Int(tps.rounded())) t/s", systemImage: "bolt.fill")
                        .font(.caption).monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText(value: tps))
                        .animation(reduceMotion ? nil : .default, value: tps)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
