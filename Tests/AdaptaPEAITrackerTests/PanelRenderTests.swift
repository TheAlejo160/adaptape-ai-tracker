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
