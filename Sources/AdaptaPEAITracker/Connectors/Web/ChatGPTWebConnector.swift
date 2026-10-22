import Foundation

/// ChatGPT Plus/Pro via the signed-in chatgpt.com web session. The session cookie is exchanged for a
/// short-lived access token on every poll; that token only lives in memory for the request.
struct ChatGPTWebConnector: WebLoginConnector {
    let info = ProviderInfo(
        id: "chatgpt-web", name: "ChatGPT", kind: .cloud,
        iconURL: ProviderInfo.lobeIcon("openai"),
        auth: .webLogin(URL(string: "https://chatgpt.com/auth/login")!)
    )
    /// Large sessions are split into `.0`, `.1`…; `WebSession.matches` accepts those.
    let requiredCookies = ["__Secure-next-auth.session-token"]

    private struct Session: Decodable {
        struct Account: Decodable {
            let id: String?
            let planType: String?
        }
        let accessToken: String?
        let account: Account?
    }

    private struct Window: Decodable {
        let usedPercent: Double
        let resetAt: FlexibleDate?
        let resetAfterSeconds: Double?
        let limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case resetAfterSeconds = "reset_after_seconds"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    private struct Usage: Decodable {
        struct RateLimit: Decodable {
            let primaryWindow, secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }
        let planType: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }
    }

    private static let sessionURL = URL(string: "https://chatgpt.com/api/auth/session")!

    /// A partial (chunked) session cookie still answers 200, but with `{}` and no access token.
    func validate(_ headers: [String: String]) async -> Bool {
        (try? await HTTP.getJSON(Session.self, from: Self.sessionURL, headers: headers))?.accessToken != nil
    }

    func fetch() async throws -> ProviderUsage? {
        guard var headers = WebSession.headers(id: info.id) else { return nil }

        let session = try await HTTP.getJSON(Session.self, from: Self.sessionURL, headers: headers)
        // Signed out → the endpoint answers 200 with `{}`.
        guard let token = session.accessToken else { throw ConnectorError.unauthorized }
        headers["Authorization"] = "Bearer \(token)"
        if let accountID = session.account?.id { headers["ChatGPT-Account-Id"] = accountID }

        let usage = try await HTTP.getJSON(Usage.self,
                                           from: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                                           headers: headers)

        var result = ProviderUsage(info: info)
        result.plan = (usage.planType ?? session.account?.planType).map(\.capitalized)
        let windows = [
            usage.rateLimit?.primaryWindow.map { usageWindow($0, fallback: "Principal") },
            usage.rateLimit?.secondaryWindow.map { usageWindow($0, fallback: "Secundario") },
        ]
        result.windows = windows.compactMap { $0 }
        return result
    }

    private func usageWindow(_ window: Window, fallback: String) -> UsageWindow {
        UsageWindow(
            label: Self.label(seconds: window.limitWindowSeconds) ?? fallback,
            used: min(max(window.usedPercent / 100, 0), 1),
            resetsAt: window.resetAt?.date ?? window.resetAfterSeconds.map { Date(timeIntervalSinceNow: $0) }
        )
    }

    /// 18000 → "Sesión (5 h)", 604800 → "Semanal".
    static func label(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds < 86_400 { return "Sesión (\(max(1, Int((Double(seconds) / 3600).rounded()))) h)" }
        switch Int((Double(seconds) / 86_400).rounded()) {
        case 1: return "Diario"
        case 7: return "Semanal"
        case let days: return "\(days) días"
        }
    }
}
