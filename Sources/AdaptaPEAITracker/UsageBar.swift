import SwiftUI

struct UsageBar: View {
    let window: UsageWindow

    // Rounded, not truncated: 0.29 * 100 = 28.999… would show 28 % where the provider shows 29 %.
    private var percent: Int { Int((min(max(window.used, 0), 1) * 100).rounded()) }

    private var remainingPercent: Int { 100 - percent }

    private var color: Color {
        switch window.severity {
        case .ok: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    var body: some View {
        // Whole bar inside the timeline so the spoken reset countdown ticks with the visible one.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(window.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let detail = window.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if window.severity == .critical {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                }
                Text("\(percent) %").font(.caption.weight(.semibold)).monospacedDigit()
                    + Text(" usado").font(.caption).foregroundStyle(.secondary)
            }
            MeterBar(fraction: window.used, color: color, marker: window.elapsed(at: now))
            Text(footerParts(now: now).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            if let warning = exhaustionText(now: now) {
                Text(warning).font(.caption2).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue(accessibilityValue(now: now))
    }

    private func footerParts(now: Date) -> [String] {
        var parts = ["Quedan \(remainingPercent) %"]
        if let resetsAt = window.resetsAt { parts.append(resetText(resetsAt, now: now)) }
        return parts
    }

    private func exhaustionText(now: Date) -> String? {
        window.exhaustion(at: now).map { "Al ritmo actual se agota en \(compactDuration($0.timeIntervalSince(now)))" }
    }

    private func accessibilityValue(now: Date) -> String {
        var value = "\(percent) por ciento usado, quedan \(remainingPercent) por ciento"
        if let resetsAt = window.resetsAt {
            value += resetsAt > now ? ", se reinicia en \(compactDuration(resetsAt.timeIntervalSince(now)))" : ", reiniciando"
        }
        if let warning = exhaustionText(now: now) { value += ", \(warning.lowercased())" }
        return value
    }

    private func resetText(_ date: Date, now: Date) -> String {
        date > now ? "Se reinicia en \(compactDuration(date.timeIntervalSince(now)))" : "Reiniciando…"
    }
}

/// Capsule meter shared by UsageBar and LocalStatsView.
struct MeterBar: View {
    let fraction: Double
    let color: Color
    /// Optional 0…1 tick, e.g. fraction of the window elapsed.
    var marker: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    if let marker {
                        Rectangle()
                            .fill(.primary.opacity(0.5))
                            .frame(width: 1.5)
                            .offset(x: proxy.size.width * min(max(marker, 0), 1) - 0.75)
                    }
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.1), value: fraction)
            .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.1), value: color)
            .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.1), value: marker)
    }
}

/// "18 min", "2 h 18 min", "1 h 05 min", "3 d 4 h". Hand-rolled because Foundation's
/// abbreviated Spanish styles insert commas ("2 h, 18 min").
func compactDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite else { return "—" }
    // Cap before the Int conversion: a bogus far-future reset (e.g. 1e300 s) would otherwise trap.
    let minutes = Int(min(max(seconds, 0), 3_153_600_000) / 60) // ≈ 100 años
    let (d, h, m) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
    if d > 0 { return h > 0 ? "\(d) d \(h) h" : "\(d) d" }
    if h > 0 { return "\(h) h " + String(format: "%02d min", m) }
    return m > 0 ? "\(m) min" : "<1 min"
}
