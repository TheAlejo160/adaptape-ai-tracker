import Foundation
import Testing
@testable import AdaptaPEAITracker

@Test func failedQuotaRequestsRespectMinimumInterval() async throws {
    let cache = QuotaCache()
    let now = Date()
    for failure in [ConnectorError.forbidden, .invalidToken(tool: "claude"), .http(503)] {
        let id = failure.localizedDescription
        do {
            _ = try await cache.usage(id: id, minInterval: 300, now: now) { throw failure }
            Issue.record("failure accepted")
        } catch {
            #expect(error.localizedDescription == failure.localizedDescription)
        }
        do {
            _ = try await cache.usage(id: id, minInterval: 300, now: now.addingTimeInterval(60)) {
                Issue.record("retried a failed request inside minInterval")
                throw ConnectorError.http(500)
            }
            Issue.record("failure lost")
        } catch {
            #expect(error.localizedDescription == failure.localizedDescription)
        }
        let recovered = try await cache.usage(id: id, minInterval: 300, now: now.addingTimeInterval(300)) {
            ProviderUsage(info: ClaudeCodeConnector().info)
        }
        #expect(recovered.error == nil)
    }
}

@Test func cachePreservesLatestFailureAfterRateLimitEnds() async throws {
    let cache = QuotaCache()
    let now = Date()
    var fixture = ProviderUsage(info: ClaudeCodeConnector().info)
    fixture.windows = [UsageWindow(label: "Semanal", used: 0.3)]
    let known = fixture
    _ = try await cache.usage(id: "claude", minInterval: 300, now: now) { known }
    _ = try await cache.usage(id: "claude", minInterval: 300, now: now.addingTimeInterval(300)) {
        throw ConnectorError.rateLimited(retryAfter: 3600)
    }
    let rejected = try await cache.usage(id: "claude", minInterval: 300, now: now.addingTimeInterval(3900)) {
        throw ConnectorError.forbidden
    }
    #expect(rejected.windows == known.windows)
    #expect(rejected.error?.contains("403") == true)
    let cached = try await cache.usage(id: "claude", minInterval: 300, now: now.addingTimeInterval(3960)) {
        Issue.record("retried inside minInterval after 403")
        throw ConnectorError.http(500)
    }
    #expect(cached.windows == known.windows)
    #expect(cached.error?.contains("403") == true)
    #expect(cached.error?.contains("429") == false)
    #expect(cached.error?.contains("datos de hace") == true)
}
