import Foundation

/// ChatGPT account usage. Reads the OAuth token Codex already stored in ~/.codex/auth.json — the
/// same quota the ChatGPT app uses — so there is no separate login. Falls back to the local
/// session log when the endpoint is unreachable. Active Codex sessions appear under this row.
struct CodexConnector: UsageConnector {
    let info = ProviderInfo(id: "chatgpt", name: "ChatGPT", kind: .cloud,
                            iconURL: ProviderInfo.lobeIcon("openai"))

    nonisolated func fetch() async throws -> ProviderUsage? {
        try await fetch(auth: LocalFiles.home(".codex/auth.json"), sessions: LocalFiles.home(".codex/sessions"),
                        config: LocalFiles.home(".codex/config.toml"))
    }

    func fetch(auth: URL, sessions: URL, config: URL) async throws -> ProviderUsage? {
        guard FileManager.default.fileExists(atPath: auth.path) else { return nil }
        let files = LocalFiles.sessionFiles(in: sessions)
        var logNotBefore: Date?
        var usage: ProviderUsage
        do {
            let object = try LocalFiles.json(LocalFiles.head(auth))
            let tokens = object["tokens"] as? [String: Any]
            let token = tokens?["access_token"] as? String
            let account = tokens?["account_id"] as? String
            guard let token, !token.isEmpty, let account, !account.isEmpty else { throw ConnectorError.unauthorized }
            logNotBefore = try? auth.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            usage = try await QuotaCache.shared.usage(id: "\(info.id):\(account):\(token.hashValue)", minInterval: 120, cooldownID: "chatgpt") {
                let data = try await HTTP.get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: [
                    "Authorization": "Bearer \(token)", "ChatGPT-Account-Id": account,
                    "User-Agent": "Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X) AdaptaPEAITracker/1.0"
                ])
                return try self.parse(data)
            }
            // Logs have no account identity: retain a known account's API snapshot, even when stale.
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { throw CancellationError() }
            if let logNotBefore, let logged = fromLog(files, notBefore: logNotBefore) {
                usage = logged
            } else {
                usage = ProviderUsage(info: info)
                usage.error = error.localizedDescription
            }
        }
        usage.recentModel = files.first.flatMap { try? LocalFiles.tail($0.url) }.flatMap(LocalFiles.recentModel)
            ?? (try? LocalFiles.head(config)).flatMap(Self.configModel)
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        usage.sessions = files.filter { now.timeIntervalSince($0.modified) < LocalFiles.openSessionAge }.map {
            let name = LocalFiles.projectName(cwd: LocalFiles.cwd(in: $0.url)) ?? formatter.string(from: $0.created)
            return ActiveSessionInfo(id: $0.url.path, title: "Codex · \(name)", startedAt: $0.created)
        }
        usage.activity = LocalFiles.activity(windows: usage.windows, newest: files.first?.modified, now: now)
        return usage
    }

    func fromLog(_ files: [LocalFiles.SessionFile], notBefore: Date, now: Date = Date()) -> ProviderUsage? {
        var newest: LogSnapshot?
        for file in files.prefix(3) {
            guard let data = try? LocalFiles.tail(file.url), let snapshot = try? logSnapshot(data),
                  snapshot.recordedAt >= notBefore, now.timeIntervalSince(snapshot.recordedAt) >= 0,
                  now.timeIntervalSince(snapshot.recordedAt) < LocalFiles.openSessionAge,
                  newest.map({ snapshot.recordedAt > $0.recordedAt }) ?? true else { continue }
            newest = snapshot
        }
        guard var usage = newest?.usage, let at = newest?.recordedAt else { return nil }
        usage.error = "Cuota del registro local (\(at.formatted(date: .abbreviated, time: .shortened))); cuenta sin verificar"
        return usage
    }

    static func configModel(_ data: Data) -> String? {
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'",
                  let end = value.dropFirst().firstIndex(of: quote) else { return nil }
            let model = String(value[value.index(after: value.startIndex)..<end])
            return model.isEmpty ? nil : model
        }
        return nil
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

    func parseLog(_ data: Data) throws -> ProviderUsage {
        try logSnapshot(data).usage
    }

    private struct LogSnapshot {
        let usage: ProviderUsage
        let recordedAt: Date
    }

    private func logSnapshot(_ data: Data) throws -> LogSnapshot {
        for line in data.split(separator: 10).reversed() {
            guard line.range(of: Data("\"rate_limits\"".utf8)) != nil,
                  let object = try? LocalFiles.json(Data(line)),
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any],
                  let recordedAt = LocalFiles.date(object["timestamp"]) else { continue }
            var usage = ProviderUsage(info: info)
            // Relative reset times in a cached log are relative to the event, not the refresh.
            guard let windows = try? windows(limits, log: true, now: recordedAt) else { continue }
            usage.windows = windows
            usage.plan = limits["plan_type"] as? String
            return LogSnapshot(usage: usage, recordedAt: recordedAt)
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
            result.append(UsageWindow(label: label, used: LocalFiles.fraction(percent), resetsAt: reset, duration: seconds))
        }
        guard !result.isEmpty else { throw ConnectorError.unexpectedResponse("ventanas de Codex") }
        return result
    }
}
