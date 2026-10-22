import Foundation

/// Claude Pro/Max via the signed-in claude.ai web session (same numbers as Settings › Usage).
struct ClaudeWebConnector: WebLoginConnector {
    let info = ProviderInfo(
        id: "claude-web", name: "Claude", kind: .cloud,
        iconURL: ProviderInfo.lobeIcon("claude"),
        auth: .webLogin(URL(string: "https://claude.ai/login")!)
    )
    let requiredCookies = ["sessionKey"]

    private struct Organization: Decodable {
        let uuid: String
        let capabilities: [String]?
        let rateLimitTier: String?

        enum CodingKeys: String, CodingKey {
            case uuid, capabilities
            case rateLimitTier = "rate_limit_tier"
        }

        /// "default_claude_max_20x" → "Max 20x"; Pro/Free otherwise.
        var plan: String? {
            let caps = capabilities ?? []
            if caps.contains("claude_max") {
                let tier = rateLimitTier ?? ""
                return tier.hasSuffix("20x") ? "Max 20x" : tier.hasSuffix("5x") ? "Max 5x" : "Max"
            }
            if caps.contains("claude_pro") { return "Pro" }
            return nil
        }
    }

    private struct Window: Decodable {
        let utilization: Double?
        let resetsAt: FlexibleDate?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    private struct Usage: Decodable {
        let fiveHour, sevenDay, sevenDayOpus: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
        }
    }

    private static let organizationsURL = URL(string: "https://claude.ai/api/organizations")!

    func validate(_ headers: [String: String]) async -> Bool {
        (try? await HTTP.get(Self.organizationsURL, headers: headers)) != nil
    }

    func fetch() async throws -> ProviderUsage? {
        guard let headers = WebSession.headers(id: info.id) else { return nil }

        // ponytail: org list refetched every poll (one extra small GET); cache if it gets rate-limited.
        let orgs = try await HTTP.getJSON([Organization].self,
                                          from: Self.organizationsURL,
                                          headers: headers)
        guard let org = orgs.first(where: { $0.capabilities?.contains("chat") == true }) ?? orgs.first else {
            throw ConnectorError.unexpectedResponse("sin organización")
        }
        let usage = try await HTTP.getJSON(Usage.self,
                                           from: URL(string: "https://claude.ai/api/organizations/\(org.uuid)/usage")!,
                                           headers: headers)

        var result = ProviderUsage(info: info)
        result.plan = org.plan
        let windows: [(String, Window?)] = [
            ("Sesión (5 h)", usage.fiveHour),
            ("Semanal", usage.sevenDay),
            ("Semanal Opus", usage.sevenDayOpus),
        ]
        result.windows = windows.compactMap { label, window in
            guard let utilization = window?.utilization else { return nil }
            return UsageWindow(label: label, used: min(max(utilization / 100, 0), 1), resetsAt: window?.resetsAt?.date)
        }
        return result
    }
}
