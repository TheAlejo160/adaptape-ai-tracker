import Foundation
import os

/// Claude account usage. Reads the OAuth token Claude Code already stored in the Keychain — the
/// same quota the web account uses — so there is no separate login. Active Claude Code sessions
/// appear under this row.
struct ClaudeCodeConnector: UsageConnector {
    private static let logger = Logger(subsystem: KeychainStore.service, category: "Claude")
    let info = ProviderInfo(id: "claude", name: "Claude", kind: .cloud,
                            iconURL: ProviderInfo.lobeIcon("claude"), auth: .optionalKeychainConsent)

    nonisolated func fetch() async throws -> ProviderUsage? {
        let keychainEnabled = UserDefaults.standard.stringArray(forKey: "enabledConnectors")?.contains(info.id) == true
        let data = keychainEnabled ? KeychainStore.readForeign(service: "Claude Code-credentials") : nil
        let projects = LocalFiles.home(".claude/projects")
        let files = LocalFiles.sessionFiles(in: projects).filter {
            $0.url.deletingLastPathComponent().deletingLastPathComponent().path == projects.path
        }
        let now = Date()
        let local = ClaudeLocalQuota.latest(urls: [
            LocalFiles.home("Library/Application Support/Claude/plan-usage-history.json"),
            LocalFiles.home("Library/Caches/limitbar/claude-status.json")
        ], now: now)
        guard keychainEnabled || local != nil || FileManager.default.fileExists(atPath: projects.deletingLastPathComponent().path) else { return nil }
        var usage = try await fetch(credentials: data, files: files, now: now, localQuota: local)
        if !keychainEnabled, local != nil { usage.error = nil }
        return usage
    }

    func fetch(credentials data: Data?, files: [LocalFiles.SessionFile], now: Date,
               localQuota: ClaudeLocalQuota.Snapshot? = nil) async throws -> ProviderUsage {
        var plan: String?
        var usage: ProviderUsage
        do {
            guard let data else {
                throw ConnectorError.credentialsUnavailable(hint: "Desactiva y activa Claude en Cuentas para autorizar su Llavero.")
            }
            let credentials = try LocalFiles.json(data)["claudeAiOauth"] as? [String: Any]
            plan = Self.plan(credentials)
            // A missing/expired token is reported like any network failure so local sessions still show.
            guard let token = credentials?["accessToken"] as? String, !token.isEmpty else {
                throw ConnectorError.expired(hint: "ejecuta «claude» una vez para renovar la sesión")
            }
            Self.logger.debug("credential source=Claude-Code-keychain tokenBytes=\(token.utf8.count) expiresAtMs=\(LocalFiles.number(credentials?["expiresAt"]) ?? 0)")
            let expiresAt = LocalFiles.number(credentials?["expiresAt"])
            // Keyed by token: limits are per token, and a re-login must not show the old account.
            usage = try await QuotaCache.shared.usage(id: "\(info.id):\(token.hashValue)", minInterval: 300, cooldownID: "claude") {
                guard expiresAt.map({ $0 / 1000 > now.timeIntervalSince1970 }) ?? true else {
                    throw ConnectorError.expired(hint: "ejecuta «claude» una vez para renovar la sesión")
                }
                let response = try await HTTP.get(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: [
                    "Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"
                ])
                return try self.parse(response)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            usage = ProviderUsage(info: info)
            usage.error = error.localizedDescription
        }
        if usage.windows.isEmpty, let localQuota, now.timeIntervalSince(localQuota.observedAt) >= 0,
           now.timeIntervalSince(localQuota.observedAt) < 86_400 {
            Self.logger.info("quota source=local-record windows=\(localQuota.usage.windows.count) observedAt=\(localQuota.observedAt.timeIntervalSince1970)")
            let error = usage.error
            usage = localQuota.usage
            usage.error = error
        }
        usage.plan = usage.quotaSource == nil ? plan : nil
        usage.recentModel = files.first.flatMap { try? LocalFiles.tail($0.url) }.flatMap(LocalFiles.recentModel)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        usage.sessions = files.filter { now.timeIntervalSince($0.modified) < LocalFiles.openSessionAge }.map { file in
            let title = LocalFiles.projectName(cwd: LocalFiles.cwd(in: file.url)) ?? "Claude Code · \(formatter.string(from: file.created))"
            return ActiveSessionInfo(id: file.url.path, title: title, startedAt: file.created)
        }
        usage.activity = LocalFiles.activity(windows: usage.quotaSource == nil ? usage.windows : [],
                                             newest: files.first?.modified, now: now)
        return usage
    }

    static func plan(_ credentials: [String: Any]?) -> String? {
        if let tier = credentials?["rateLimitTier"] as? String, tier.hasPrefix("default_claude_max_"),
           let multiplier = tier.split(separator: "_").last, multiplier.hasSuffix("x"),
           Int(multiplier.dropLast()) != nil { return "Max \(multiplier)" }
        return (credentials?["subscriptionType"] as? String)?.capitalized
    }

    func parse(_ data: Data) throws -> ProviderUsage {
        let object = try LocalFiles.json(data)
        var usage = ProviderUsage(info: info)
        for (key, label, duration) in [("five_hour", "Sesión (5 h)", 18_000), ("seven_day", "Semanal", 604_800),
                                      ("seven_day_opus", "Semanal Opus", 604_800), ("seven_day_sonnet", "Semanal Sonnet", 604_800)] as [(String, String, TimeInterval)] {
            guard let window = object[key] as? [String: Any], let percent = LocalFiles.number(window["utilization"]) else { continue }
            usage.windows.append(UsageWindow(label: label, used: LocalFiles.fraction(percent),
                                             resetsAt: LocalFiles.date(window["resets_at"]), duration: duration))
        }
        guard !usage.windows.isEmpty else { throw ConnectorError.unexpectedResponse("cuotas de Claude Code") }
        return usage
    }
}
