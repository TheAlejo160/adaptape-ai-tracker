import Foundation

struct CodexConnector: UsageConnector {
    let info = ProviderInfo(id: "codex", name: "Codex", kind: .codeAssistant,
                            iconURL: ProviderInfo.lobeIcon("codex"))

    nonisolated func fetch() async throws -> ProviderUsage? {
        let auth = LocalFiles.home(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: auth.path) else { return nil }
        let object = try LocalFiles.json(Data(contentsOf: auth))
        let tokens = object["tokens"] as? [String: Any]
        let token = tokens?["access_token"] as? String
        let account = tokens?["account_id"] as? String
        let files = LocalFiles.sessionFiles(in: LocalFiles.home(".codex/sessions"))
        var usage: ProviderUsage
        do {
            guard let token, !token.isEmpty, let account, !account.isEmpty else { throw ConnectorError.unauthorized }
            let data = try await HTTP.get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: [
                "Authorization": "Bearer \(token)", "ChatGPT-Account-Id": account,
                "User-Agent": "Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X) AdaptaPEAITracker/1.0"
            ])
            usage = try parse(data)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { throw CancellationError() }
            guard let newest = files.first, let data = try? LocalFiles.tail(newest.url),
                  let cached = try? parseLog(data) else { throw error }
            usage = cached
            usage.error = "No se pudo actualizar; cuota del registro local (\(newest.modified.formatted(date: .abbreviated, time: .shortened)))"
        }
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        usage.sessions = files.filter { now.timeIntervalSince($0.modified) < 600 }.map {
            ActiveSessionInfo(id: $0.url.path, title: "Codex · \(formatter.string(from: $0.created))", startedAt: $0.created)
        }
        usage.activity = LocalFiles.activity(windows: usage.windows, newest: files.first?.modified, now: now)
        return usage
    }

    func parse(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        let object = try LocalFiles.json(data)
        guard let limits = object["rate_limit"] as? [String: Any] else {
            throw ConnectorError.unexpectedResponse("cuotas de Codex")
        }
        var usage = ProviderUsage(info: info)
        usage.plan = object["plan_type"] as? String
        usage.windows = try windows(limits, log: false, now: now)
        return usage
    }

    func parseLog(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        for line in data.split(separator: 10).reversed() {
            guard line.range(of: Data("\"rate_limits\"".utf8)) != nil,
                  let object = try? LocalFiles.json(Data(line)),
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            var usage = ProviderUsage(info: info)
            // Relative reset times in a cached log are relative to the event, not the refresh.
            guard let windows = try? windows(limits, log: true, now: LocalFiles.date(object["timestamp"]) ?? now) else { continue }
            usage.windows = windows
            return usage
        }
        throw ConnectorError.unexpectedResponse("registro de cuotas de Codex")
    }

    private func windows(_ limits: [String: Any], log: Bool, now: Date) throws -> [UsageWindow] {
        var result: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let window = limits[log ? key : "\(key)_window"] as? [String: Any] else { continue }
            guard let percent = LocalFiles.number(window["used_percent"]),
                  let duration = LocalFiles.number(window[log ? "window_minutes" : "limit_window_seconds"]), duration > 0 else {
                throw ConnectorError.unexpectedResponse("ventana de Codex")
            }
            let seconds = log ? duration * 60 : duration
            let label: String
            if abs(seconds - 18_000) < 60 { label = "Sesión (5 h)" }
            else if abs(seconds - 604_800) < 60 { label = "Semanal" }
            else { label = "Ventana \((seconds / 3600).formatted(.number.precision(.fractionLength(0...1)))) h" }
            let reset = LocalFiles.date(window[log ? "resets_at" : "reset_at"])
                ?? LocalFiles.number(window[log ? "resets_in_seconds" : "reset_after_seconds"]).map { now.addingTimeInterval($0) }
            result.append(UsageWindow(label: label, used: LocalFiles.fraction(percent), resetsAt: reset))
        }
        guard !result.isEmpty else { throw ConnectorError.unexpectedResponse("ventanas de Codex") }
        return result
    }
}
