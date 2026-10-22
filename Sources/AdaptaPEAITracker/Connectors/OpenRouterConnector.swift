import Foundation

/// OpenRouter credit via the official key endpoint. The key is read from the OPENROUTER_API_KEY
/// environment variable; the app never stores it.
struct OpenRouterConnector: UsageConnector {
    static let envVar = "OPENROUTER_API_KEY"
    let info = ProviderInfo(
        id: "openrouter", name: "OpenRouter", kind: .cloud,
        iconURL: ProviderInfo.lobeIcon("openrouter"),
        auth: .apiKeyEnv(envVar)
    )

    private struct KeyInfo: Decodable {
        struct Details: Decodable {
            let usage: Double
            let limit: Double?
            let limitRemaining: Double?
            let limitReset: String?

            enum CodingKeys: String, CodingKey {
                case usage, limit
                case limitRemaining = "limit_remaining"
                case limitReset = "limit_reset"
            }
        }
        let data: Details
    }

    func fetch() async throws -> ProviderUsage? {
        guard let key = ProcessInfo.processInfo.environment[Self.envVar], !key.isEmpty else { return nil }

        let details = try await HTTP.getJSON(KeyInfo.self,
                                             from: URL(string: "https://openrouter.ai/api/v1/key")!,
                                             headers: ["Authorization": "Bearer \(key)"]).data

        var result = ProviderUsage(info: info)
        if let limit = details.limit {
            // With a periodic reset, `usage` is lifetime; the remaining credit is the live figure.
            let spent = details.limitRemaining.map { limit - $0 } ?? details.usage
            // A $0 cap is a real (blocking) limit, not "unlimited": full as soon as anything is spent.
            let used = limit > 0 ? spent / limit : (spent > 0 ? 1 : 0)
            result.windows = [UsageWindow(
                label: "Crédito",
                used: min(max(used, 0), 1),
                resetsAt: Self.nextReset(details.limitReset),
                detail: "\(Self.dollars(spent)) / \(Self.dollars(limit))"
            )]
        } else {
            result.summary = "Gastado: \(Self.dollars(details.usage)) (sin límite)"
        }
        return result
    }

    private static func dollars(_ amount: Double) -> String { String(format: "$%.2f", amount) }

    /// OpenRouter resets key limits at midnight UTC: daily, on Mondays, or on the 1st.
    private static func nextReset(_ period: String?) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let match: DateComponents
        switch period {
        case "daily": match = DateComponents(hour: 0, minute: 0, second: 0)
        case "weekly": match = DateComponents(hour: 0, minute: 0, second: 0, weekday: 2)
        case "monthly": match = DateComponents(day: 1, hour: 0, minute: 0, second: 0)
        default: return nil
        }
        return calendar.nextDate(after: .now, matching: match, matchingPolicy: .nextTime)
    }
}
