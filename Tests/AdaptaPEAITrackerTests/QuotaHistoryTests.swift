import Foundation
import Testing
@testable import AdaptaPEAITracker

@Test func historyFiltersGeneralAndProviderByDayWeekMonth() {
    let now = Date()
    let samples = [0.5, 3, 20, 32].map { days in
        QuotaSample(date: now.addingTimeInterval(-days * 86_400), providerID: "claude", providerName: "Claude", window: "5h", duration: 18_000, used: 0.3, unverified: false)
    } + [QuotaSample(date: now, providerID: "chatgpt", providerName: "ChatGPT", window: "5h", duration: 18_000, used: 0.8, unverified: false),
         QuotaSample(date: now, providerID: "chatgpt", providerName: "ChatGPT", window: "Semanal", duration: 604_800, used: 0.2, unverified: false)]
    #expect(QuotaHistory.visible(samples, providerID: "", days: 1, window: "5h", now: now).count == 2)
    #expect(QuotaHistory.visible(samples, providerID: "claude", days: 1, window: "5h", now: now).count == 1)
    #expect(QuotaHistory.visible(samples, providerID: "claude", days: 7, window: "5h", now: now).count == 2)
    #expect(QuotaHistory.visible(samples, providerID: "claude", days: 30, window: "5h", now: now).count == 3)
    #expect(QuotaHistory.visible(samples, providerID: "chatgpt", days: 30, window: "weekly", now: now).count == 1)
    let monthly = QuotaSample(date: now, providerID: "cursor", providerName: "Cursor", window: "Mensual", duration: nil, used: 0.2, unverified: false)
    #expect(QuotaHistory.visible([monthly], providerID: "cursor", days: 30, window: "other", now: now).count == 1)
}

@Test func historyPreservesObservationTimeAndIndependentLimits() {
    let now = Date(timeIntervalSince1970: 1_800_001_800)
    var usage = ProviderUsage(info: GeminiConnector().info)
    usage.observedAt = now.addingTimeInterval(-3600)
    usage.quotaSource = "Registro local · cuenta sin verificar"
    usage.windows = [UsageWindow(label: "Gemini 5h", used: 0.02, duration: 18_000),
                     UsageWindow(label: "Claude semanal", used: 1, duration: 604_800)]
    let first = QuotaHistory.recording([usage], into: [], now: now)
    #expect(first.count == 2)
    #expect(first.allSatisfy { $0.date == usage.observedAt && $0.unverified })
    let repeated = QuotaHistory.recording([usage], into: first, now: now.addingTimeInterval(120))
    #expect(repeated == first)
    usage.observedAt = now
    usage.windows[0].used = 0.12
    let nextHour = QuotaHistory.recording([usage], into: first, now: now)
    #expect(nextHour.count == 4)
    usage.observedAt = now.addingTimeInterval(120)
    usage.windows[0].used = 0.18
    let updated = QuotaHistory.recording([usage], into: nextHour, now: now.addingTimeInterval(120))
    #expect(updated.count == 4)
    #expect(updated.contains { $0.used == 0.18 })
    #expect(!updated.contains { $0.used == 0.12 })
}

@Test func historyRejectsDemoMalformedAndOldData() {
    let now = Date()
    var usage = ProviderUsage(info: .init(id: "demo-claude", name: "Claude", kind: .cloud, iconURL: nil))
    usage.windows = [UsageWindow(label: "5h", used: 0.3, duration: 18_000)]
    #expect(QuotaHistory.recording([usage], into: [], now: now).isEmpty)
    usage = ProviderUsage(info: ClaudeCodeConnector().info)
    usage.error = "fixture-error"
    usage.windows = [UsageWindow(label: "5h", used: 0.3, duration: 18_000)]
    #expect(QuotaHistory.recording([usage], into: [], now: now).isEmpty)
    usage.observedAt = now.addingTimeInterval(-QuotaHistory.retention - 1)
    #expect(QuotaHistory.recording([usage], into: [], now: now).isEmpty)
    usage.observedAt = now.addingTimeInterval(1)
    #expect(QuotaHistory.recording([usage], into: [], now: now).isEmpty)
    usage.observedAt = now
    usage.windows[0].used = .nan
    #expect(QuotaHistory.recording([usage], into: [], now: now).isEmpty)
    usage.windows[0].used = 0.4
    usage.windows[0].duration = .infinity
    #expect(QuotaHistory.recording([usage], into: [], now: now).isEmpty)
}

@Test func historyWritesOnlyExplicitQuotaFieldsAndLoadsSafely() throws {
    let now = Date()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = directory.appendingPathComponent("history.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    var usage = ProviderUsage(info: CodexConnector().info)
    usage.summary = "fixture-private-data"
    usage.recentModel = "fixture-private-model"
    usage.windows = [UsageWindow(label: "5h", used: 0.3, duration: 18_000)]
    let samples = QuotaHistory.recording([usage], into: [], now: now)
    try QuotaHistory.save(samples, to: file)
    #expect(QuotaHistory.load(from: file, now: now) == samples)
    let json = try String(contentsOf: file, encoding: .utf8)
    #expect(!json.contains("fixture-private"))
    #expect(!json.contains("token") && !json.contains("account"))
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    try Data("broken".utf8).write(to: file)
    #expect(QuotaHistory.load(from: file, now: now).isEmpty)
    try Data(repeating: 32, count: 8_388_609).write(to: file)
    #expect(QuotaHistory.load(from: file, now: now).isEmpty)
}

@Test func quotaCacheDoesNotMoveObservationTimeOnCacheHit() async throws {
    let now = Date()
    let cache = QuotaCache()
    let first = try await cache.usage(id: "history-fixture", minInterval: 300, now: now) {
        ProviderUsage(info: CodexConnector().info)
    }
    let cached = try await cache.usage(id: "history-fixture", minInterval: 300, now: now.addingTimeInterval(120)) {
        Issue.record("unexpected quota fetch")
        return ProviderUsage(info: CodexConnector().info)
    }
    #expect(first.observedAt == now && cached.observedAt == now)
}

@Test func historyFileRemainsWithinReadLimit() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = directory.appendingPathComponent("history.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let samples = (0..<QuotaHistory.maxSamples).map { index in
        QuotaSample(date: now, providerID: String(repeating: "p", count: 145) + String(index),
            providerName: String(repeating: "n", count: 160), window: String(repeating: "w", count: 240), duration: 18_000, used: 0.5, unverified: false)
    }
    try QuotaHistory.save(samples, to: file)
    #expect(try Data(contentsOf: file).count <= 8_388_608)
    let loaded = QuotaHistory.load(from: file, now: now)
    #expect(!loaded.isEmpty && loaded.count < samples.count)
}
