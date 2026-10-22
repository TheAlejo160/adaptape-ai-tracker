import Foundation

struct CopilotConnector: UsageConnector {
    let info = ProviderInfo(id: "copilot", name: "GitHub Copilot", kind: .codeAssistant,
                            iconURL: ProviderInfo.lobeIcon("githubcopilot"))

    nonisolated func fetch() async throws -> ProviderUsage? {
        var token = await LocalFiles.ghToken()
        if token == nil {
            let hosts = LocalFiles.home(".config/gh/hosts.yml")
            if FileManager.default.fileExists(atPath: hosts.path) {
                token = Self.hostToken(try String(contentsOf: hosts, encoding: .utf8))
            }
        }
        if token == nil {
            let auth = LocalFiles.home(".local/share/opencode/auth.json")
            if FileManager.default.fileExists(atPath: auth.path) {
                let object = try LocalFiles.json(Data(contentsOf: auth))
                let copilot = object["github-copilot"] as? [String: Any]
                token = [copilot?["refresh"], copilot?["access"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            }
        }
        guard let token, !token.isEmpty else { return nil }
        let data = try await HTTP.get(URL(string: "https://api.github.com/copilot_internal/user")!, headers: [
            "Authorization": "token \(token)", "Accept": "application/json", "Editor-Version": "vscode/1.99.0"
        ])
        return try parse(data)
    }

    static func hostToken(_ text: String) -> String? {
        var github = false
        for line in text.split(whereSeparator: \.isNewline) {
            if line.first?.isWhitespace == false && !line.hasPrefix("#") {
                github = line.trimmingCharacters(in: .whitespaces) == "github.com:"
                continue
            }
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard github, entry.hasPrefix("oauth_token:") else { continue }
            let token = entry.dropFirst("oauth_token:".count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !token.isEmpty, !token.contains(where: { $0.isWhitespace }) { return token }
        }
        return nil
    }

    func parse(_ data: Data) throws -> ProviderUsage {
        let object = try LocalFiles.json(data)
        guard let snapshots = object["quota_snapshots"] as? [String: Any],
              let premium = snapshots["premium_interactions"] as? [String: Any] else {
            throw ConnectorError.unexpectedResponse("cuotas de Copilot")
        }
        var usage = ProviderUsage(info: info)
        usage.plan = object["copilot_plan"] as? String
        if premium["unlimited"] as? Bool == true { return usage }
        let entitlement = LocalFiles.number(premium["entitlement"])
        let remaining = LocalFiles.number(premium["remaining"])
        let percentRemaining = LocalFiles.number(premium["percent_remaining"])
            ?? remaining.flatMap { remaining in entitlement.flatMap { $0 > 0 ? remaining / $0 * 100 : nil } }
        guard let percentRemaining else { throw ConnectorError.unexpectedResponse("requests premium de Copilot") }
        var reset = LocalFiles.date(object["quota_reset_date_utc"])
        if reset == nil, let text = object["quota_reset_date"] as? String {
            reset = FlexibleDate.parse(text) ?? FlexibleDate.parse("\(text)T00:00:00Z")
        }
        let detail = entitlement.flatMap { entitlement in remaining.map {
            "\(max(0, entitlement - $0).formatted()) / \(entitlement.formatted())"
        } }
        usage.windows = [UsageWindow(label: "Requests premium", used: LocalFiles.fraction(100 - percentRemaining),
                                     resetsAt: reset, detail: detail)]
        usage.activity = LocalFiles.activity(windows: usage.windows, newest: nil, now: Date())
        return usage
    }
}
