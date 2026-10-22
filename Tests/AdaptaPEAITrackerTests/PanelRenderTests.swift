import AppKit
import SwiftUI
import Testing
@testable import AdaptaPEAITracker

@Test(.enabled(if: ProcessInfo.processInfo.environment["AITRACKER_RENDER"] == "1"))
@MainActor func renderQuotaRowsWithoutCredentials() throws {
    let now = Date()
    var usage = ProviderUsage(info: .init(id: "fixture", name: "ChatGPT", kind: .cloud, iconURL: nil))
    usage.plan = "Plus"
    usage.windows = [UsageWindow(label: "Semanal", used: 0.73, resetsAt: now.addingTimeInterval(400_000), duration: 604_800),
                     UsageWindow(label: "Sesión (5 h)", used: 0.22, resetsAt: now.addingTimeInterval(10_000), duration: 18_000)]
    for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                        ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
        let root = ProviderRow(provider: usage).padding(8).frame(width: 360)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/aitracker-quota-\(name).png"))
        #expect(host.bounds.height > 100)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AITRACKER_RENDER"] == "1"))
@MainActor func renderPlanningAndAutomaticAccounts() async throws {
    let now = Date()
    var usage = ProviderUsage(info: .init(id: "chatgpt", name: "ChatGPT", kind: .cloud, iconURL: nil))
    usage.windows = [UsageWindow(label: "Sesión (5 h)", used: 0.65, resetsAt: now.addingTimeInterval(9000), duration: 18_000),
                     UsageWindow(label: "Semanal", used: 0.35, resetsAt: now.addingTimeInterval(300_000), duration: 604_800)]
    let accountStore = UsageStore(providers: [usage])
    for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                        ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
        for (surface, content) in [("planning", AnyView(PlanningView(providers: [usage], agents: 3))),
                                   ("history", AnyView(HistoryView(samples: historyFixture(now: now), error: nil))),
                                   ("accounts", AnyView(AccountsView(onClose: {}).environment(accountStore)))] {
            let root = content.frame(width: 360).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: appearance)
            for _ in 0..<4 {
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/aitracker-\(surface)-\(name).png"))
            #expect(host.bounds.height > 100)
        }
    }
}

private func historyFixture(now: Date) -> [QuotaSample] {
    var samples: [QuotaSample] = []
    for index in 0..<12 {
        let date = now.addingTimeInterval(Double(index - 12) * 3600)
        samples.append(QuotaSample(date: date, providerID: "claude", providerName: "Claude", window: "5 h", duration: 18_000, used: Double(index % 5) / 5, unverified: true))
        samples.append(QuotaSample(date: date, providerID: "chatgpt", providerName: "ChatGPT", window: "5 h", duration: 18_000, used: Double(index % 4) / 4, unverified: false))
    }
    return samples
}
