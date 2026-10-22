import SwiftUI

@main
struct AdaptaPEAITrackerApp: App {
    @State private var loginItem = LoginItem()
    @State private var store = UsageStore()

    var body: some Scene {
        // .window style = borderless panel anchored to the status item; AppKit hides it on focus loss.
        MenuBarExtra {
            PanelView()
                .environment(loginItem)
                .environment(store)
        } label: {
            MenuBarLabel(peak: store.peakUsage)
                .task { await store.run() }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Status-item readout: gauge + worst quota percentage, warning glyph from 85 %.
private struct MenuBarLabel: View {
    let peak: Double?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(peak.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(peak.map { "AdaptaPE AI Tracker, uso máximo \(Int(($0 * 100).rounded())) por ciento" } ?? "AdaptaPE AI Tracker")
    }

    private var symbol: String {
        switch peak ?? 0 {
        case 0.85...: "gauge.open.with.lines.needle.84percent.exclamation"
        case 0.5...: "gauge.with.dots.needle.67percent"
        default: "gauge.with.dots.needle.33percent"
        }
    }
}
