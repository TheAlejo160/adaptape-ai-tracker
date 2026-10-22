import SwiftUI

/// One provider. Collapsed: worst window (or local stats). Expanded: every window + active sessions.
struct ProviderRow: View {
    let provider: ProviderUsage
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canExpand: Bool { provider.windows.count > 1 || !provider.sessions.isEmpty }
    private var isRateLimited: Bool { if case .rateLimited = provider.activity { true } else { false } }
    private var isOffline: Bool { provider.activity == .offline }

    /// Worst first, so the collapsed bar stays put when the rest slide in below it.
    private var shownWindows: [UsageWindow] {
        let sorted = provider.windows.sorted { $0.used > $1.used }
        return expanded ? sorted : Array(sorted.prefix(1))
    }

    var body: some View {
        Button {
            if canExpand { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let local = provider.local {
                    LocalStatsView(stats: local)
                } else if let summary = provider.summary {
                    Text(summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if provider.windows.isEmpty {
                    Text("Sin datos").font(.caption).foregroundStyle(.tertiary)
                }
                if let error = provider.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                ForEach(shownWindows) { window in
                    UsageBar(window: window)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if expanded && !provider.sessions.isEmpty {
                    sessions.transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: expanded)
        }
        .buttonStyle(.plain)
        .opacity(isOffline ? 0.5 : 1)
        .onHover { hovering = canExpand && $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(canExpand ? (expanded ? "Contraer detalles" : "Mostrar detalles") : "")
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProviderIcon(url: provider.iconURL, name: provider.name, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(provider.name).font(.body.weight(.medium))
                    if let plan = provider.plan {
                        // APIs send "plus", "free"…; upper-case only the first letter so model ids stay intact.
                        Text(plan.prefix(1).uppercased() + plan.dropFirst())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: .capsule)
                    }
                }
                HStack(spacing: 4) {
                    ActivityIndicator(activity: provider.activity)
                    Text(provider.activity.label)
                        .font(.caption)
                        .foregroundStyle(isRateLimited ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sesiones activas")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(provider.sessions) { SessionRow(session: $0) }
        }
    }

    private var background: AnyShapeStyle {
        if isRateLimited { AnyShapeStyle(.red.opacity(hovering || expanded ? 0.14 : 0.08)) }
        else if hovering || expanded { AnyShapeStyle(.fill.quaternary) }
        else { AnyShapeStyle(.clear) }
    }

    private var accessibilityText: String {
        var parts = [provider.name]
        if let plan = provider.plan { parts.append("plan \(plan)") }
        parts.append(provider.activity.label)
        if let peak = provider.peakUsage { parts.append("uso máximo \(Int((peak * 100).rounded())) por ciento") }
        if let summary = provider.summary { parts.append(summary) }
        if let error = provider.error { parts.append("error: \(error)") }
        // The custom label replaces children's labels, so details must be spelled out here.
        if let local = provider.local {
            parts.append("VRAM \(local.vramUsedGB.formatted(.number.precision(.fractionLength(1)))) de \(local.vramTotalGB.formatted()) gigabytes")
            parts.append(local.loadedModel ?? "ningún modelo cargado")
            if let tps = local.tokensPerSecond { parts.append("\(Int(tps.rounded())) tokens por segundo") }
        }
        if expanded && !provider.sessions.isEmpty {
            parts.append("sesiones activas: " + provider.sessions.map(\.title).joined(separator: "; "))
        }
        return parts.joined(separator: ", ")
    }
}
