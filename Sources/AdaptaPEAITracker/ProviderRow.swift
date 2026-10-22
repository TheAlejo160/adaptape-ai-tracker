import SwiftUI

/// Quotas stay visible; disclosure is reserved for sessions and the model catalog.
struct ProviderRow: View {
    let provider: ProviderUsage
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canExpand: Bool { provider.kind == .cloud || !provider.sessions.isEmpty || !provider.models.isEmpty }
    private var isRateLimited: Bool { if case .rateLimited = provider.activity { true } else { false } }

    var body: some View {
        Group {
            if canExpand {
                Button { expanded.toggle() } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .onHover { hovering = canExpand && $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(canExpand ? (expanded ? "Contraer detalles" : "Mostrar detalles") : "")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let model = provider.recentModel {
                Text("Último modelo: \(modelName(model))").font(.caption).foregroundStyle(.secondary)
            }
            if let local = provider.local {
                LocalStatsView(stats: local)
            } else if let summary = provider.summary {
                Text(summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else if provider.windows.isEmpty && provider.error == nil {
                Text("Sin datos").font(.caption).foregroundStyle(.tertiary)
            }
            if let error = provider.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let source = provider.quotaSource {
                Text(source).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(provider.orderedWindows) { window in
                UsageBar(window: window)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if expanded && !provider.sessions.isEmpty {
                sessions.transition(.opacity.combined(with: .move(edge: .top)))
            }
            if expanded && provider.kind == .cloud {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Modelos informados").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(provider.models.isEmpty ? "La fuente no informa un catálogo de modelos de tu plan." : provider.models.map(modelName).joined(separator: " · ")).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if let source = provider.modelsSource {
                        Text(source).font(.caption).foregroundStyle(.secondary)
                    }
                    if !provider.modelGroups.isEmpty {
                        Text("Grupos con cuota: " + provider.modelGroups.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: .rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: expanded)
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
        if let model = provider.recentModel { parts.append("modelo \(modelName(model))") }
        if expanded && !provider.models.isEmpty { parts.append("modelos: " + provider.models.map(modelName).joined(separator: ", ")) }
        if expanded && provider.kind == .cloud && provider.models.isEmpty { parts.append("La fuente no informa un catálogo de modelos de tu plan") }
        if expanded, let source = provider.modelsSource { parts.append(source) }
        if expanded && !provider.modelGroups.isEmpty { parts.append("grupos con cuota: " + provider.modelGroups.joined(separator: ", ")) }
        parts.append(provider.activity.label)
        for window in provider.orderedWindows {
            parts.append("\(window.label), \(Int((window.used * 100).rounded())) por ciento usado")
        }
        if let summary = provider.summary { parts.append(summary) }
        if let error = provider.error { parts.append("error: \(error)") }
        if let source = provider.quotaSource { parts.append(source) }
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
