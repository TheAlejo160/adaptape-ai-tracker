import Foundation
import Testing
import SQLite3
@testable import AdaptaPEAITracker

@Test func paceProjection() {
    let now = Date()
    // 5 h window, 2.5 h in, 60 % used → runs out ~1 h 40 min from now, before the reset.
    var window = UsageWindow(label: "s", used: 0.6, resetsAt: now.addingTimeInterval(9_000), duration: 18_000)
    #expect(window.elapsed(at: now) == 0.5)
    let empty = try! #require(window.exhaustion(at: now))
    #expect(abs(empty.timeIntervalSince(now) - 6_000) < 1)
    // Same point, 30 % used → lasts until reset.
    window.used = 0.3
    #expect(window.exhaustion(at: now) == nil)
    // No duration → no pace.
    #expect(UsageWindow(label: "s", used: 0.6, resetsAt: now).exhaustion(at: now) == nil)
}

@Test func quotaCacheBacksOffAndServesStale() async throws {
    let cache = QuotaCache()
    let info = ProviderInfo(id: "t", name: "T", kind: .cloud, iconURL: nil)
    let start = Date()
    var seed = ProviderUsage(info: info)
    seed.windows = [UsageWindow(label: "s", used: 0.4)]
    let good = seed
    let first = try await cache.usage(id: "t", minInterval: 300, now: start) { good }
    #expect(first.error == nil)

    // Inside minInterval: cached, endpoint not called.
    let cached = try await cache.usage(id: "t", minInterval: 300, now: start.addingTimeInterval(60)) {
        Issue.record("fetched inside minInterval"); return good
    }
    #expect(cached.windows == good.windows)

    // 429 → stale data with an error, then blocked for the backoff (5 min) without calling out.
    let limited = try await cache.usage(id: "t", minInterval: 300, now: start.addingTimeInterval(400)) {
        throw ConnectorError.rateLimited(retryAfter: nil)
    }
    #expect(limited.windows == good.windows && limited.error != nil)
    let blocked = try await cache.usage(id: "t", minInterval: 300, now: start.addingTimeInterval(500)) {
        Issue.record("fetched while blocked"); return good
    }
    #expect(blocked.error != nil)

    // Never succeeded → throws, so the connector can fall back to local data.
    await #expect(throws: ConnectorError.self) {
        try await cache.usage(id: "other", minInterval: 300) { throw ConnectorError.rateLimited(retryAfter: 60) }
    }
}

@Test func codexLogMatchesOfficialUsage() throws {
    // Real log line shape: primary 22 % used (ChatGPT shows 78 % left), secondary 67 % (33 % left).
    let line = #"{"timestamp":"2026-10-22T04:50:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":22.0,"window_minutes":300,"resets_at":1792658021},"secondary":{"used_percent":67.0,"window_minutes":10080,"resets_at":1793113819}}}}"#
    let usage = try CodexConnector().parseLog(Data(line.utf8))
    #expect(usage.windows.map(\.label) == ["Sesión (5 h)", "Semanal"])
    #expect(usage.windows.map { Int(($0.remaining * 100).rounded()) } == [78, 33])
    #expect(usage.windows.map(\.duration) == [18_000, 604_800])
}

@Test func sessionCwd() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"""
    {"type":"permission-mode"}
    {"type":"user","cwd":"/Users/me/Desktop/AdaptaPE AI TRACKER"}
    """#.utf8).write(to: url)
    #expect(LocalFiles.projectName(cwd: LocalFiles.cwd(in: url)) == "AdaptaPE AI TRACKER")
    #expect(LocalFiles.projectName(cwd: "/Users/me/Library/Application Support/Claude/scratch-1") == nil)
}

@Test func modelNames() {
    #expect(modelName("claude-opus-5-5") == "Opus 5.5")
    #expect(modelName("claude-sonnet-4-6") == "Sonnet 4.6")
    #expect(modelName("gemini-3.8-flash") == "Gemini 3.8 Flash")
    #expect(modelName("gpt-6.1-sol") == "gpt-6.1-sol")
}

@Test func claudeModelFromBoundedTail() throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("session.jsonl")
    var data = Data(repeating: 120, count: 300_000)
    data.append(Data(#"""

    {"type":"assistant","message":{"model":"claude-sonnet-4-6"}}
    {"type":"user","model":"ignored"}
    {"type":"assistant","message":{"model":"claude-opus-5-5"}}
    {"type":"assistant","message":{"model":"<synthetic>"}}
    {"partial":
    """#.utf8))
    try data.write(to: file)
    let tail = try LocalFiles.tail(file)
    #expect(tail.count == 262_144)
    #expect(LocalFiles.recentModel(tail) == "claude-opus-5-5")
    #expect(LocalFiles.recentModel(Data(#"{"type":"user","message":{"model":"ignored"}}"#.utf8)) == nil)
}

@Test func codexModelsAndPlan() throws {
    let data = Data(#"""
    {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
    {"type":"event_msg","payload":{"model":"ignored"}}
    """#.utf8)
    #expect(LocalFiles.recentModel(data) == "gpt-6.1-sol")
    #expect(CodexConnector.configModel(Data("model = 'gpt-6.1-sol' # selected\n[profiles.other]\nmodel = 'ignored'".utf8)) == "gpt-6.1-sol")
    #expect(CodexConnector.configModel(Data("[profiles.other]\nmodel = 'ignored'".utf8)) == nil)
    #expect(ClaudeCodeConnector.plan(["subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"]) == "Max 20x")
    #expect(ClaudeCodeConnector.plan(["subscriptionType": "pro"]) == "Pro")
}

@Test func geminiQuotaShape() throws {
    // Synthetic values, fields verified against the installed Gemini CLI 0.46.0 and Google's BucketInfo.
    let quota = Data(#"""
    {"buckets":[
      {"modelId":"gemini-3.8-flash","remainingFraction":0.75,"remainingAmount":"750","resetTime":"2026-10-23T07:00:00Z","tokenType":"REQUESTS"},
      {"modelId":"gemini-3.8-flash","remainingFraction":0.5,"resetTime":"2026-10-23T07:00:00Z","tokenType":"REQUESTS"},
      {"modelId":"gemini-3.6-flash","remainingFraction":0,"resetTime":"2026-10-23T07:00:00Z"},
      {"modelId":"unknown-limit","remainingFraction":null},
      {"modelId":"invalid","remainingFraction":true}
    ]}
    """#.utf8)
    let account = Data(#"{"currentTier":{"id":"free-tier","name":"Free"},"paidTier":{"id":"standard-tier","name":"Pro"},"cloudaicompanionProject":"fixture-project"}"#.utf8)
    let usage = try GeminiConnector().parse(quota, account: account)
    #expect(usage.plan == "Pro")
    #expect(usage.models == ["gemini-3.8-flash", "gemini-3.6-flash", "unknown-limit", "invalid"])
    #expect(usage.windows.map(\.used) == [0.5, 1])
    #expect(usage.windows.map(\.duration) == [86_400, 86_400])
    #expect(usage.windows.first?.resetsAt == FlexibleDate.parse("2026-10-23T07:00:00Z"))
    #expect(Set(usage.windows.map(\.id)).count == usage.windows.count)
    let free = try GeminiConnector().parse(quota, account: Data(#"{"paidTier":{},"currentTier":{"id":"free-tier"}}"#.utf8))
    #expect(free.plan == "Free")
    #expect(throws: ConnectorError.self) { try GeminiConnector().parse(Data("{}".utf8), account: account) }
}

@Test func retryAfterForms() {
    let now = FlexibleDate.parse("2026-10-22T05:00:00Z")!
    #expect(HTTP.retryAfter("600", now: now) == 600)
    #expect(HTTP.retryAfter("Thu, 22 Oct 2026 06:00:00 GMT", now: now) == 3600)
    #expect(HTTP.retryAfter("Thu, 22 Oct 2026 04:00:00 GMT", now: now) == nil)
    for value in ["NaN", "inf", "-1", "nonsense"] { #expect(HTTP.retryAfter(value, now: now) == nil) }
}

@Test func retryAfterHTTPDateControlsCacheDeadline() async throws {
    let cache = QuotaCache()
    let now = FlexibleDate.parse("2026-10-22T05:00:00Z")!
    let delay = HTTP.retryAfter("Thu, 22 Oct 2026 06:00:00 GMT", now: now)
    await #expect(throws: ConnectorError.self) {
        try await cache.usage(id: "date", minInterval: 300, now: now) {
            throw ConnectorError.rateLimited(retryAfter: delay)
        }
    }
    await #expect(throws: ConnectorError.self) {
        try await cache.usage(id: "date", minInterval: 300, now: now.addingTimeInterval(1800)) {
            Issue.record("retried before the server's HTTP-date")
            throw ConnectorError.http(500)
        }
    }
}

@Test func expiredExhaustedWindowDoesNotLimitSession() {
    let now = Date()
    let expired = UsageWindow(label: "daily", used: 1, resetsAt: now.addingTimeInterval(-1))
    #expect(LocalFiles.activity(windows: [expired], newest: now, now: now) == .processing(task: "Trabajando"))
    #expect(LocalFiles.activity(windows: [expired], newest: now.addingTimeInterval(-180), now: now) == .waiting)
    #expect(LocalFiles.activity(windows: [expired], newest: nil, now: now) == .idle)
    #expect(LocalFiles.activity(windows: [UsageWindow(label: "unknown reset", used: 1)], newest: now, now: now) == .rateLimited(until: nil))
}

@Test func malformedCredentialsKeepSessions() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = directory.appendingPathComponent("session.jsonl")
    try Data(#"{"type":"assistant","cwd":"/Users/me/Project","message":{"model":"claude-opus-4-6"}}"#.utf8).write(to: session)
    let now = Date()
    let file = LocalFiles.SessionFile(url: session, modified: now, created: now)
    let claude = try await ClaudeCodeConnector().fetch(credentials: Data("broken".utf8), files: [file], now: now)
    #expect(claude.sessions.count == 1 && claude.error != nil)
    #expect(claude.recentModel == "claude-opus-4-6")
    let auth = directory.appendingPathComponent("auth.json")
    try Data("broken".utf8).write(to: auth)
    let codex = try #require(await CodexConnector().fetch(auth: auth, sessions: directory, config: directory.appendingPathComponent("config.toml")))
    #expect(codex.sessions.count == 1 && codex.error != nil)
}

@Test func geminiExpiredTokenKeepsLocalSessionsAndHidesAbsentInstall() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("project")
    let chats = root.appendingPathComponent("chats")
    try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    try Data("/Users/me/Example Project".utf8).write(to: root.appendingPathComponent(".project_root"))
    try Data(#"{"type":"gemini","model":"gemini-3.8-flash","content":"fixture"}"#.utf8).write(to: chats.appendingPathComponent("session.jsonl"))
    let auth = directory.appendingPathComponent("oauth_creds.json")
    try Data(#"{"access_token":"fixture-only","expiry_date":1}"#.utf8).write(to: auth)
    let connector = GeminiConnector()
    let usage = try #require(await connector.fetch(credentials: auth, chats: directory, antigravity: [], installed: true))
    #expect(usage.error == "Token caducado: ejecuta «gemini» una vez para renovar la sesión")
    #expect(usage.sessions.first?.title == "Gemini CLI · Example Project")
    #expect(usage.recentModel == "gemini-3.8-flash")
    #expect(try String(contentsOf: auth, encoding: .utf8) == #"{"access_token":"fixture-only","expiry_date":1}"#)
    #expect(try await connector.fetch(credentials: directory.appendingPathComponent("absent"), chats: directory, antigravity: [], installed: false) == nil)
}

@Test func codexLogFallbackUsesEventFreshness() throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let url = directory.appendingPathComponent("older-file.jsonl")
    try quotaEvent(at: now.addingTimeInterval(-30), used: 22).write(to: url)
    let newest = directory.appendingPathComponent("new-session.jsonl")
    try Data("{}\n".utf8).write(to: newest)
    let old = directory.appendingPathComponent("recent-write-old-quota.jsonl")
    try quotaEvent(at: now.addingTimeInterval(-700), used: 90).write(to: old)
    let files = [newest, old, url].map { LocalFiles.SessionFile(url: $0, modified: now, created: now) }
    let connector = CodexConnector()
    let usage = try #require(connector.fromLog(files, notBefore: now.addingTimeInterval(-300), now: now))
    #expect(usage.windows.first?.used == 0.22)
    #expect(usage.error?.contains("cuenta sin verificar") == true)
    #expect(connector.fromLog(files, notBefore: now, now: now) == nil)
}

@Test func codexDoesNotReplaceKnownAPIWithLocalQuota() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let token = UUID().uuidString
    let account = UUID().uuidString
    let key = "chatgpt:\(account):\(token.hashValue)"
    let auth = directory.appendingPathComponent("auth.json")
    try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": token, "account_id": account]]).write(to: auth)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: auth.path)
    try quotaEvent(at: now.addingTimeInterval(-10), used: 99).write(to: directory.appendingPathComponent("session.jsonl"))
    let connector = CodexConnector()
    var seed = ProviderUsage(info: connector.info)
    seed.plan = "Plus"
    seed.windows = [UsageWindow(label: "Sesión (5 h)", used: 0.2)]
    let known = seed
    _ = try await QuotaCache.shared.usage(id: key, minInterval: 0, now: now.addingTimeInterval(-400)) { known }
    _ = try await QuotaCache.shared.usage(id: key, minInterval: 0, now: now) { throw ConnectorError.rateLimited(retryAfter: 3600) }
    let usage = try #require(await connector.fetch(auth: auth, sessions: directory, config: directory.appendingPathComponent("config.toml")))
    #expect(usage.windows == known.windows && usage.plan == "Plus" && usage.error != nil)
}

@Test func antigravityReadsSummaryDatabaseWithoutWriting() throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("conversation_summaries.db")
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let now = Date()
    let time = ISO8601DateFormatter().string(from: now)
    let sql = """
        CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT, workspace_uris TEXT, last_modified_time TEXT, killed INTEGER);
        INSERT INTO conversation_summaries VALUES ('\(UUID().uuidString)', 'Example', '["file:///Users/me/Project"]', '\(time)', 0);
        INSERT INTO conversation_summaries VALUES ('\(UUID().uuidString)', 'Old', '[]', '2020-01-01T00:00:00Z', 0);
        """
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)
    let original = try Data(contentsOf: url)
    let result = GeminiConnector().antigravitySessions(in: directory, now: now)
    #expect(result.sessions.count == 1)
    #expect(result.sessions.first?.title == "Antigravity · Project")
    #expect(result.newest != nil)
    #expect(try Data(contentsOf: url) == original)
}

private func fixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func quotaEvent(at date: Date, used: Double) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "timestamp": date.timeIntervalSince1970,
        "payload": ["rate_limits": ["primary": ["used_percent": used, "window_minutes": 300, "resets_in_seconds": 900]]]
    ])
}

@Test func antigravityKeyringAndModels() throws {
    // Shape verified against agy's real go-keyring item and daily-cloudcode-pa responses; values synthetic.
    let json = #"{"token":{"access_token":"fixture","expiry":"2026-10-22T00:36:19.381533-05:00"},"auth_method":"consumer"}"#
    let keyring = Data(("go-keyring-base64:" + Data(json.utf8).base64EncodedString() + "\n").utf8)
    let before = FlexibleDate.parse("2026-10-22T05:00:00Z")!
    #expect(try GeminiConnector.antigravityToken(keyring, now: before) == "fixture")
    #expect(throws: ConnectorError.self) {
        try GeminiConnector.antigravityToken(keyring, now: before.addingTimeInterval(3_600))
    }

    let models = Data(#"""
    {"models":{
      "gemini-3-flash":{"displayName":"Gemini 3 Flash","quotaInfo":{"remainingFraction":0.75,"resetTime":"2026-10-22T09:07:01Z"}},
      "gemini-2.5-pro":{"displayName":"Gemini 2.5 Pro","quotaInfo":{"remainingFraction":0.75,"resetTime":"2026-10-22T09:07:01Z"}},
      "claude-opus-4-6-thinking":{"displayName":"Claude Opus 4.6 (Thinking)","quotaInfo":{"resetTime":"2026-10-28T07:32:19Z"}},
      "gpt-oss-120b-medium":{"displayName":"GPT-OSS 120B (Medium)","quotaInfo":{"resetTime":"2026-10-28T07:32:19Z"}},
      "chat_1":{"quotaInfo":{"remainingFraction":1}}
    },"defaultAgentModelId":"gemini-3-flash"}
    """#.utf8)
    let account = Data(#"{"currentTier":{"id":"free-tier"},"paidTier":{"id":"g1-pro-tier"},"cloudaicompanionProject":"p"}"#.utf8)
    let usage = try GeminiConnector().parseAvailableModels(models, account: account)
    #expect(usage.plan == "AI Pro")
    #expect(usage.models == ["Claude Opus 4.6 (Thinking)", "GPT-OSS 120B (Medium)", "Gemini 2.5 Pro", "Gemini 3 Flash"])
    #expect(usage.windows.map(\.label) == ["Claude · GPT-OSS", "Gemini"])
    #expect(usage.windows.map(\.used) == [1, 0.25])

    let log = Data(#"I1022 model_config_manager.go:340] Propagating selected model override to backend: label="Gemini 3.8 Flash (High)""#.utf8)
    #expect(GeminiConnector.antigravityModel(log) == "Gemini 3.8 Flash (High)")
}
