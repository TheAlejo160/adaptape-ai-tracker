import Foundation
import Observation

/// Single source of truth: which connectors are on, their latest data, and the polling loop.
@Observable
@MainActor
final class UsageStore {
    private(set) var providers: [ProviderUsage] = []
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    /// Connectors that need opt-in (keychain, web login, API key) and the user turned on.
    private(set) var enabledIDs: Set<String>

    /// Bumped on every config change so an in-flight refresh can tell its results are obsolete.
    private var generation = 0
    private var refreshQueued = false

    var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: Keys.demo)
            providers = []
            configChanged()
        }
    }

    /// Everything the Accounts screen can offer, demo or not.
    let available: [any UsageConnector] = ConnectorRegistry.all

    private enum Keys {
        static let enabled = "enabledConnectors"
        static let demo = "demoMode"
    }

    init() {
        enabledIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.enabled) ?? [])
        demoMode = UserDefaults.standard.bool(forKey: Keys.demo)
    }

    func providers(of kind: ProviderKind) -> [ProviderUsage] {
        providers.filter { $0.kind == kind }
    }

    /// Highest used fraction across all quota windows, for the menu bar label.
    var peakUsage: Double? { providers.compactMap(\.peakUsage).max() }

    /// Only Keychain-consent providers need opting in (macOS prompts). Everything else self-detects:
    /// fetch() returns nil when the local source or env var is absent, so the row simply stays hidden.
    func isEnabled(_ info: ProviderInfo) -> Bool {
        info.auth == .keychainConsent ? enabledIDs.contains(info.id) : true
    }

    func setEnabled(_ enabled: Bool, id: String) {
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        UserDefaults.standard.set(Array(enabledIDs), forKey: Keys.enabled)
        if !enabled { providers.removeAll { $0.id == id } }
        if enabled {
            Task {
                await Task.detached(priority: .userInitiated) { KeychainStore.requestAccess(providerID: id) }.value
                configChanged()
            }
        } else {
            configChanged()
        }
    }

    private func configChanged() {
        generation += 1
        Task { await refresh() }
    }

    /// Polls forever. ContinuousClock counts system sleep, so after wake the pending sleep
    /// ends at once and data refreshes without a wake observer.
    // Rate-limited endpoints pace themselves through QuotaCache, so this loop can stay one fixed interval.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(120))
        }
    }

    /// Called when the panel opens so the user never stares at minutes-old numbers.
    func refreshIfStale() {
        guard let lastUpdated, Date().timeIntervalSince(lastUpdated) > 60 else { return }
        Task { await refresh() }
    }

    /// Coalesces: a call during a refresh queues exactly one more pass instead of being dropped.
    func refresh() async {
        guard !isRefreshing else { refreshQueued = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            let started = generation
            let next = await fetchAll()
            // Config changed mid-flight (demo toggled, account removed): these results are stale.
            if started == generation {
                providers = next
                lastUpdated = Date()
            } else {
                refreshQueued = true
            }
        } while refreshQueued
    }

    private func fetchAll() async -> [ProviderUsage] {
        let active = (demoMode ? MockConnector.all : available).filter { isEnabled($0.info) }
        let results = await withTaskGroup(of: (Int, Result<ProviderUsage?, any Error>).self) { group in
            for (index, connector) in active.enumerated() {
                group.addTask {
                    do { return (index, .success(try await connector.fetch())) }
                    catch { return (index, .failure(error)) }
                }
            }
            var out = [Int: Result<ProviderUsage?, any Error>]()
            for await (index, result) in group { out[index] = result }
            return out
        }

        var next: [ProviderUsage] = []
        for (index, connector) in active.enumerated() {
            switch results[index] {
            case .success(var usage?)?:
                // One guard for every connector: NaN/∞ would trap in Int conversions in the UI.
                usage.windows.removeAll { !$0.used.isFinite }
                for i in usage.windows.indices { usage.windows[i].used = min(max(usage.windows[i].used, 0), 1) }
                next.append(usage)
            case .failure(let error)?:
                // Keep the last good numbers; flag them as stale.
                var stale = providers.first { $0.id == connector.info.id } ?? ProviderUsage(info: connector.info)
                stale.activity = .offline
                stale.error = error.localizedDescription
                next.append(stale)
            default:
                break // not installed on this Mac
            }
        }
        return next
    }
}
