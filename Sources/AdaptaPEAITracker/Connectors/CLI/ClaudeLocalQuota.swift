import Foundation

enum ClaudeLocalQuota {
    struct Snapshot: Sendable {
        var usage: ProviderUsage
        let observedAt: Date
    }

    static func latest(urls: [URL], now: Date) -> Snapshot? {
        urls.compactMap { url -> Snapshot? in
            guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? file.close() }
            guard let data = try? file.read(upToCount: 4_194_305), data.count <= 4_194_304 else { return nil }
            return try? parse(data, now: now)
        }.max { $0.observedAt < $1.observedAt }
    }

    static func parse(_ data: Data, now: Date) throws -> Snapshot? {
        let object = try LocalFiles.json(data)
        let samples = object["samples"] as? [[String: Any]] ?? [object]
        return samples.compactMap { sample -> Snapshot? in
            guard let at = LocalFiles.date(sample["t"] ?? sample["at"]),
                  (0..<86_400).contains(now.timeIntervalSince(at)) else { return nil }
            let history = sample["u"] as? [String: Any]
            let limits = sample["limits"] as? [String: Any]
            var usage = ProviderUsage(info: ClaudeCodeConnector().info)
            for (short, key, label, duration) in [("fh", "five_hour", "Sesión (5 h)", 18_000.0),
                                                   ("sd", "seven_day", "Semanal", 604_800.0)] {
                let limit = limits?[key] as? [String: Any]
                guard let percent = LocalFiles.number(history?[short] ?? limit?["percent"]),
                      (0...100).contains(percent) else { continue }
                usage.windows.append(UsageWindow(label: label, used: percent / 100,
                    resetsAt: LocalFiles.date(limit?["resets_at"]), duration: duration))
            }
            guard !usage.windows.isEmpty else { return nil }
            let source = history != nil ? "Claude Desktop" : "LimitBar"
            // These files do not prove that Desktop and Claude Code use the same account.
            usage.quotaSource = "Registro de \(source) · hace \(compactDuration(now.timeIntervalSince(at))) · cuenta sin verificar"
            return Snapshot(usage: usage, observedAt: at)
        }.max { $0.observedAt < $1.observedAt }
    }
}
