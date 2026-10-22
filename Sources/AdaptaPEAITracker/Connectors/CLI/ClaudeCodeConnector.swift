import Foundation

struct ClaudeCodeConnector: UsageConnector {
    let info = ProviderInfo(id: "claude-code", name: "Claude Code", kind: .codeAssistant,
                            iconURL: ProviderInfo.lobeIcon("claudecode"), auth: .keychainConsent)

    nonisolated func fetch() async throws -> ProviderUsage? {
        guard let data = KeychainStore.readForeign(service: "Claude Code-credentials") else { return nil }
        let credentials = try LocalFiles.json(data)["claudeAiOauth"] as? [String: Any]
        guard let credentials, let token = credentials["accessToken"] as? String, !token.isEmpty else {
            throw ConnectorError.unauthorized
        }
        if let expiry = LocalFiles.number(credentials["expiresAt"]), expiry / 1000 < Date().timeIntervalSince1970 {
            throw ConnectorError.unauthorized
        }
        let plan = (credentials["subscriptionType"] as? String)?.capitalized
        let response = try await HTTP.get(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: [
            "Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"
        ])
        var usage = try parse(response)
        usage.plan = plan
        let now = Date()
        let projects = LocalFiles.home(".claude/projects")
        let files = LocalFiles.sessionFiles(in: projects).filter {
            $0.url.deletingLastPathComponent().deletingLastPathComponent().path == projects.path
        }
        usage.sessions = files.filter { now.timeIntervalSince($0.modified) < 600 }.map { file in
            // shortcut: Claude's path encoding loses literal hyphens; use the final encoded component until it exposes cwd metadata.
            let project = file.url.deletingLastPathComponent().lastPathComponent
            let title = project.split(separator: "-").last.map(String.init) ?? project
            return ActiveSessionInfo(id: file.url.path, title: title, startedAt: file.created)
        }
        usage.activity = LocalFiles.activity(windows: usage.windows, newest: files.first?.modified, now: now)
        return usage
    }

    func parse(_ data: Data) throws -> ProviderUsage {
        let object = try LocalFiles.json(data)
        var usage = ProviderUsage(info: info)
        for (key, label) in [("five_hour", "Sesión (5 h)"), ("seven_day", "Semanal"), ("seven_day_opus", "Semanal Opus")] {
            guard let window = object[key] as? [String: Any] else { continue }
            guard let percent = LocalFiles.number(window["utilization"]) else {
                throw ConnectorError.unexpectedResponse("cuota de Claude Code")
            }
            usage.windows.append(UsageWindow(label: label, used: LocalFiles.fraction(percent),
                                             resetsAt: LocalFiles.date(window["resets_at"])))
        }
        guard !usage.windows.isEmpty else { throw ConnectorError.unexpectedResponse("cuotas de Claude Code") }
        return usage
    }
}
