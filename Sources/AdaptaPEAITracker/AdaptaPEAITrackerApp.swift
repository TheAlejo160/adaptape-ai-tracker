import SwiftUI

@main
struct AdaptaPEAITrackerApp: App {
    @NSApplicationDelegateAdaptor(TrackerDelegate.self) private var delegate
    @State private var loginItem = LoginItem()

    var body: some Scene {
        // .window style = borderless panel anchored to the status item; AppKit hides it on focus loss.
        MenuBarExtra {
            PanelView()
                .environment(loginItem)
                .environment(delegate.store)
        } label: {
            MenuBarLabel().environment(delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor private final class TrackerDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private var polling: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        polling = Task { await store.run() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        polling?.cancel()
        store.flushHistory()
    }
}

private struct MenuBarLabel: View {
    @Environment(UsageStore.self) private var store
    @AppStorage("menu.provider") private var selectedID = ""
    @AppStorage("menu.window") private var mode = "rotate"
    @State private var now = Date()

    var body: some View {
        let provider = ProviderUsage.menuProvider(in: store.providers, selectedID: selectedID)
        let readout = provider?.menuReadout(at: now, mode: mode) ?? "Sin cuota"
        HStack(spacing: 4) {
            if let image = BrandAsset.menuImage { Image(nsImage: image) }
            else { Image(systemName: "gauge.with.dots.needle.33percent") }
            Text(readout).monospacedDigit()
        }
        .onReceive(Timer.publish(every: 8, on: .main, in: .common).autoconnect()) { now = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AdaptaPE AI Tracker, \(readout)\(provider?.error != nil ? ", último dato disponible" : "")")
    }
}
