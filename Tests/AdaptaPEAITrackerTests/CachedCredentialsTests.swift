import Foundation
import Testing
@testable import AdaptaPEAITracker

@Test func expiredClaudeTokenRetainsSameTokenQuota() async throws {
    let now = Date()
    let token = UUID().uuidString
    let connector = ClaudeCodeConnector()
    var fixture = ProviderUsage(info: connector.info)
    fixture.windows = [UsageWindow(label: "Semanal", used: 0.45)]
    let known = fixture
    _ = try await QuotaCache.shared.usage(id: "claude:\(token.hashValue)", minInterval: 300,
                                          now: now.addingTimeInterval(-600)) { known }
    let credentials = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
        "accessToken": token, "expiresAt": now.addingTimeInterval(-1).timeIntervalSince1970 * 1000
    ]])
    let usage = try await connector.fetch(credentials: credentials, files: [], now: now)
    #expect(usage.windows == known.windows)
    #expect(usage.error?.contains("«claude»") == true)
    #expect(usage.error?.contains("datos de hace") == true)
}

@Test func expiredGeminiCredentialsRetainQuotaWithoutMixingAccounts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let connector = GeminiConnector()
    var fixture = ProviderUsage(info: connector.info)
    fixture.plan = "AI Pro"
    fixture.windows = [UsageWindow(label: "Gemini", used: 0.25)]
    let known = fixture
    let auth = directory.appendingPathComponent("oauth_creds.json")
    let data = try JSONSerialization.data(withJSONObject: ["access_token": UUID().uuidString, "expiry_date": 1])
    try data.write(to: auth)
    _ = try await QuotaCache.shared.usage(id: "gemini:\(data.hashValue)", minInterval: 300,
                                          now: now.addingTimeInterval(-600)) { known }
    let cli = try #require(await connector.fetch(credentials: auth, chats: directory, antigravity: [], installed: true))
    #expect(cli.windows == known.windows)
    #expect(cli.error?.contains("«gemini»") == true)

    let keyring = try JSONSerialization.data(withJSONObject: ["token": [
        "access_token": UUID().uuidString, "expiry": "2020-01-01T00:00:00Z"
    ]])
    _ = try await QuotaCache.shared.usage(id: "antigravity:\(keyring.hashValue)", minInterval: 300,
                                          now: now.addingTimeInterval(-600)) { known }
    let agy = try #require(await connector.fetch(credentials: auth, keyring: keyring,
                                                chats: directory, antigravity: [], installed: true))
    #expect(agy.windows == known.windows && agy.plan == known.plan)
    #expect(agy.error?.contains("«agy»") == true)

    let otherKeyring = try JSONSerialization.data(withJSONObject: ["token": [
        "access_token": UUID().uuidString, "expiry": "2020-01-01T00:00:00Z"
    ]])
    let other = try #require(await connector.fetch(credentials: auth, keyring: otherKeyring,
                                                  chats: directory, antigravity: [], installed: true))
    #expect(other.windows.isEmpty && other.plan == nil)
    #expect(other.error?.contains("«agy»") == true)
}
