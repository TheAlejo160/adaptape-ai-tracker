import Foundation
import Testing
@testable import AdaptaPEAITracker

@Test func menuDoesNotCombineIndependentModelPools() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let data = Data(#"{"groups":[{"name":"Claude and GPT","buckets":[{"window":"weekly","remaining_fraction":0}]},{"name":"Gemini","buckets":[{"window":"5h","remaining_fraction":0.98},{"window":"weekly","remaining_fraction":0.63}]}]}"#.utf8)
    let usage = try GeminiConnector().parseQuotaSummary(data, account: Data("{}".utf8))
    #expect(usage.planningWindows.map(\.group) == ["Gemini", "Gemini"])
    #expect(usage.menuReadout(at: now, mode: "5h") == "Gemini · 5h 98% libre")
    #expect(usage.menuReadout(at: now, mode: "weekly") == "Gemini · 7d 63% libre")
    #expect(usage.menuReadout(at: now, mode: "rotate") != usage.menuReadout(at: now.addingTimeInterval(8), mode: "rotate"))
    #expect(usage.windows.contains { $0.used == 1 })
}

@Test func menuSelectionKeepsExplicitChoiceAndPrefersVerifiedQuota() {
    var history = ProviderUsage(info: ClaudeCodeConnector().info)
    history.windows = [UsageWindow(label: "5h", used: 0.8, duration: 18_000)]
    history.quotaSource = "Registro de Claude Desktop"
    var live = ProviderUsage(info: CodexConnector().info)
    live.windows = [UsageWindow(label: "5h", used: 0.1, resetsAt: Date().addingTimeInterval(9000), duration: 18_000)]
    #expect(ProviderUsage.menuProvider(in: [history, live], selectedID: "")?.id == "chatgpt")
    #expect(ProviderUsage.menuProvider(in: [history, live], selectedID: "claude")?.id == "claude")
    #expect(ProviderUsage.menuProvider(in: [], selectedID: "missing") == nil)
    #expect(history.menuReadout(at: Date(), mode: "5h").contains("≈20%"))
    live.windows[0].resetsAt = Date.distantPast
    #expect(live.menuReadout(at: Date(), mode: "5h").hasSuffix("—"))
    live.windows[0].used = .nan
    #expect(live.menuReadout(at: Date(), mode: "5h").hasSuffix("—"))
}

@Test func agentProjectionUsesObservedRateWithoutInventingLowUsage() throws {
    let now = Date()
    var window = UsageWindow(label: "5h", used: 0.5, resetsAt: now.addingTimeInterval(9000), duration: 18_000)
    #expect(window.estimatedRunTime(agents: 1, at: now) == 9000)
    #expect(window.estimatedRunTime(agents: 2, at: now) == 4500)
    #expect(window.projectedRemaining(after: 4500, agents: 2, at: now) == 0)
    #expect(window.projectedRemaining(after: 9001, agents: 1, at: now) == nil)
    #expect(window.estimatedRunTime(agents: 0, at: now) == nil)
    window.used = 0
    #expect(window.estimatedRunTime(agents: 2, at: now) == nil)
    window.used = 1
    #expect(window.estimatedRunTime(agents: 2, at: now) == 0)
    window.used = .infinity
    #expect(window.estimatedRunTime(agents: 2, at: now) == nil)
    window.used = 0.4
    window.resetsAt = now.addingTimeInterval(17_500)
    #expect(window.estimatedRunTime(agents: 2, at: now) == nil)
    window.resetsAt = now.addingTimeInterval(-1)
    #expect(window.estimatedRunTime(agents: 2, at: now) == nil)
}

@Test func localCatalogIsFreshBoundedAndDoesNotClaimPlanAccess() throws {
    let now = Date()
    let data = try JSONSerialization.data(withJSONObject: ["fetched_at": now.addingTimeInterval(-30).timeIntervalSince1970,
        "models": [["slug": "model-visible", "visibility": "list"], ["slug": "model-hidden", "visibility": "hide"],
                   ["slug": "model-visible", "visibility": "list"], ["slug": "", "visibility": "list"]]])
    #expect(try LocalModelCatalog.codex(data, now: now, notBefore: now.addingTimeInterval(-60)) == ["model-visible"])
    #expect(try LocalModelCatalog.codex(data, now: now, notBefore: now) == [])
    #expect(try LocalModelCatalog.codex(data, now: now.addingTimeInterval(86_400), notBefore: .distantPast) == [])
    #expect(try LocalModelCatalog.codex(data, now: now.addingTimeInterval(-60), notBefore: .distantPast) == [])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 32, count: 4_194_305).write(to: url)
    #expect(LocalModelCatalog.codex(at: url, now: now, notBefore: .distantPast).isEmpty)
}
