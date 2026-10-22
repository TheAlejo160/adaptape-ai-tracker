import Foundation
import Testing
@testable import AdaptaPEAITracker

private actor QuotaRequests {
    var calls: [String] = []
    let responses: [String: Data]
    let failures: [String: ConnectorError]

    init(responses: [String: Data] = [:], failures: [String: ConnectorError] = [:]) {
        self.responses = responses
        self.failures = failures
    }

    func send(_ method: String, body: Data) throws -> Data {
        calls.append(method)
        if let error = failures[method] { throw error }
        return responses[method] ?? Data("{}".utf8)
    }
}

@Test func geminiQuotaSurvivesRejectedPlanLookup() async throws {
    let summary = Data(#"{"groups":[{"displayName":"Gemini","buckets":[{"window":"weekly","remainingFraction":0.3},{"window":"5h","remaining":{"case":"remainingFraction","value":0.8}}]}]}"#.utf8)
    let requests = QuotaRequests(responses: ["retrieveUserQuotaSummary": summary], failures: ["loadCodeAssist": .forbidden])
    let usage = try await GeminiConnector().antigravityUsage(token: "fixture") { method, body in
        try await requests.send(method, body: body)
    }
    #expect(await requests.calls == ["loadCodeAssist", "retrieveUserQuotaSummary"])
    #expect(usage.orderedWindows.map(\.duration) == [18_000, 604_800])
    #expect(usage.orderedWindows.map { Int(($0.used * 100).rounded()) } == [20, 70])
    #expect(usage.plan == nil)
}

@Test func geminiModelsRemainAvailableWhenSummaryIsForbidden() async throws {
    let models = Data(#"{"models":{"g":{"displayName":"Gemini Flash","quotaInfo":{"remainingFraction":0.6}}}}"#.utf8)
    let requests = QuotaRequests(responses: ["fetchAvailableModels": models],
        failures: ["loadCodeAssist": .googleForbidden(reason: "fixture"), "retrieveUserQuotaSummary": .forbidden])
    let usage = try await GeminiConnector().antigravityUsage(token: "fixture") { method, body in
        try await requests.send(method, body: body)
    }
    #expect(await requests.calls == ["loadCodeAssist", "retrieveUserQuotaSummary", "fetchAvailableModels"])
    #expect(usage.windows.first?.used == 0.4)
    #expect(usage.models == ["Gemini Flash"])
    #expect(usage.windows.first?.duration == nil)
}

@Test func geminiStopsAlternativeRequestsWhenRateLimited() async throws {
    let requests = QuotaRequests(failures: ["retrieveUserQuotaSummary": .rateLimited(retryAfter: 3600)])
    do {
        _ = try await GeminiConnector().antigravityUsage(token: "fixture") { method, body in
            try await requests.send(method, body: body)
        }
        Issue.record("429 was ignored")
    } catch ConnectorError.rateLimited(let delay) {
        #expect(delay == 3600)
    }
    #expect(await requests.calls == ["loadCodeAssist", "retrieveUserQuotaSummary"])
    #expect(!GeminiConnector.canTryAlternative(.invalidToken(tool: "agy")))
    #expect(!GeminiConnector.canTryAlternative(.expired(hint: "fixture")))
}

@Test func antigravityParsesBothReferenceQuotaShapes() throws {
    let summary = Data(#"{"command":{"data":{"groups":[{"name":"Gemini","buckets":[{"window":"5h","remaining_fraction":0,"reset_time":"2026-10-23T00:00:00Z"},{"window":"weekly","remaining_fraction":1},{"window":"5h","remaining_fraction":0.5},{"window":"invalid","remaining_fraction":true},{"window":"disabled","remaining_fraction":0.2,"disabled":true}]}]}}}"#.utf8)
    let usage = try GeminiConnector().parseQuotaSummary(summary, account: Data("{}".utf8))
    #expect(usage.windows.count == 2)
    #expect(usage.windows.map(\.used) == [1, 0])
    #expect(usage.windows.map(\.duration) == [18_000, 604_800])
    #expect(usage.windows.first?.resetsAt == FlexibleDate.parse("2026-10-23T00:00:00Z"))
    let named = Data(#"{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"primary","displayName":"Five Hour Limit","remainingFraction":0.8},{"bucketId":"seven_day","remainingFraction":0.5}]}]}"#.utf8)
    #expect(try GeminiConnector().parseQuotaSummary(named, account: Data("{}".utf8)).windows.map(\.duration) == [18_000, 604_800])
    #expect(throws: ConnectorError.self) {
        try GeminiConnector().parseQuotaSummary(Data(#"{"groups":[{"buckets":[{"window":"5h"}]}]}"#.utf8), account: Data("{}".utf8))
    }
}

@Test func googleErrorsNeverExposeRawServerMessages() throws {
    let body = Data(#"{"error":{"message":"fixture-private-message","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#.utf8)
    let hint = HTTP.googlePermissionReason(body)
    #expect(hint == "el token no tiene el alcance requerido")
    #expect(!hint.contains("fixture-private-message"))
    #expect(HTTP.googlePermissionReason(Data(#"{"error":{"message":"fixture-private-message"}}"#.utf8)) == "la cuenta no tiene acceso a este endpoint")
}

@Test func retryDeadlineSurvivesCacheRecreationWithoutCredentials() async throws {
    let suite = "aitracker-quota-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date()
    let first = QuotaCache(persistingIn: suite)
    await #expect(throws: ConnectorError.self) {
        try await first.usage(id: "fixture-one", minInterval: 300, now: now, cooldownID: "claude") {
            throw ConnectorError.rateLimited(retryAfter: 3600)
        }
    }
    #expect(defaults.object(forKey: "quotaRetry.claude.until") as? Date == now.addingTimeInterval(3600))
    let restored = QuotaCache(persistingIn: suite)
    await #expect(throws: ConnectorError.self) {
        try await restored.usage(id: "fixture-two", minInterval: 300, now: now.addingTimeInterval(1800), cooldownID: "claude") {
            Issue.record("queried before persisted deadline")
            return ProviderUsage(info: ClaudeCodeConnector().info)
        }
    }
    #expect(Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []) == ["quotaRetry.claude.until", "quotaRetry.claude.strikes"])
    _ = try await restored.usage(id: "fixture-two", minInterval: 300, now: now.addingTimeInterval(3600), cooldownID: "claude") {
        ProviderUsage(info: ClaudeCodeConnector().info)
    }
    #expect(defaults.object(forKey: "quotaRetry.claude.until") == nil)
}

@Test func claudeLocalQuotaUsesNewestValidSampleAndLabelsItsSource() async throws {
    let now = Date()
    let timestamp = now.addingTimeInterval(-60).timeIntervalSince1970 * 1000
    let data = try JSONSerialization.data(withJSONObject: ["samples": [
        ["t": timestamp, "u": ["fh": 12, "sd": 73]],
        ["t": timestamp - 60_000, "u": ["fh": 99, "sd": 99]],
        ["t": timestamp + 3_600_000, "u": ["fh": 100]],
        ["t": timestamp, "u": ["fh": true]]
    ]])
    let snapshot = try #require(try ClaudeLocalQuota.parse(data, now: now))
    #expect(snapshot.usage.windows.map(\.used) == [0.12, 0.73])
    #expect(snapshot.usage.windows.allSatisfy { $0.resetsAt == nil })
    #expect(snapshot.usage.quotaSource?.contains("Claude Desktop") == true)
    #expect(snapshot.usage.quotaSource?.contains("cuenta sin verificar") == true)
    let usage = try await ClaudeCodeConnector().fetch(credentials: nil, files: [], now: now, localQuota: snapshot)
    #expect(usage.windows == snapshot.usage.windows && usage.error != nil)
    #expect(usage.activity == .idle)
    #expect(try ClaudeLocalQuota.parse(data, now: now.addingTimeInterval(172_800)) == nil)

    let limitbar = try JSONSerialization.data(withJSONObject: ["at": timestamp,
        "limits": ["five_hour": ["percent": 30], "seven_day": ["percent": 100]]])
    let reading = try #require(try ClaudeLocalQuota.parse(limitbar, now: now))
    #expect(reading.usage.windows.map(\.used) == [0.3, 1])
    #expect(reading.usage.quotaSource?.contains("LimitBar") == true)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = directory.appendingPathComponent("history.json")
    try data.write(to: history)
    #expect(ClaudeLocalQuota.latest(urls: [history], now: now)?.usage.windows == snapshot.usage.windows)
    #expect(try Data(contentsOf: history) == data)
    try Data(repeating: 0, count: 4_194_305).write(to: history)
    #expect(ClaudeLocalQuota.latest(urls: [history], now: now) == nil)
}

@Test func consecutiveRateLimitsKeepBackoffAcrossRelaunch() async throws {
    let suite = "aitracker-backoff-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date()
    let first = QuotaCache(persistingIn: suite)
    await #expect(throws: ConnectorError.self) {
        try await first.usage(id: "first", minInterval: 300, now: now, cooldownID: "gemini") {
            throw ConnectorError.rateLimited(retryAfter: nil)
        }
    }
    let next = QuotaCache(persistingIn: suite)
    await #expect(throws: ConnectorError.self) {
        try await next.usage(id: "next", minInterval: 300, now: now.addingTimeInterval(300), cooldownID: "gemini") {
            throw ConnectorError.rateLimited(retryAfter: nil)
        }
    }
    #expect(defaults.object(forKey: "quotaRetry.gemini.until") as? Date == now.addingTimeInterval(900))
}

@Test func accountStatusDoesNotConfusePermissionWithQuota() {
    var usage = ProviderUsage(info: GeminiConnector().info)
    #expect(usage.quotaStatus == "Sin cuota informada")
    usage.error = "fixture"
    #expect(usage.quotaStatus == "Cuota no disponible")
    usage.windows = [UsageWindow(label: "Sesión (5 h)", used: 0.3)]
    #expect(usage.quotaStatus == "Última cuota disponible")
    usage.error = nil
    #expect(usage.quotaStatus == "Cuota recibida")
}
