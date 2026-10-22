import Foundation

struct OpenCodeConnector: UsageConnector {
    let info = ProviderInfo(id: "opencode", name: "OpenCode", kind: .codeAssistant, iconURL: ProviderInfo.lobeIcon("opencode"))

    nonisolated func fetch() async throws -> ProviderUsage? {
        let database = LocalFiles.home(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        return try read(database, now: Date())
    }

    func read(_ database: URL, now: Date) throws -> ProviderUsage {
        let threshold = Int64(now.addingTimeInterval(-900).timeIntervalSince1970 * 1000)
        let sessions = try LocalFiles.query(database, sql: """
            SELECT id, title, model, time_created, time_updated FROM session
            WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated >= \(threshold)
            ORDER BY time_updated DESC
            """
        )
        let start = Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000)
        let totals = try LocalFiles.query(database, sql: """
            SELECT SUM(COALESCE(tokens_input,0) + COALESCE(tokens_output,0) + COALESCE(tokens_reasoning,0)) AS tokens,
                   SUM(COALESCE(cost,0)) AS cost,
                   (SELECT model FROM session WHERE parent_id IS NULL AND time_archived IS NULL
                    ORDER BY time_updated DESC LIMIT 1) AS latest_model
            FROM session WHERE time_updated >= \(start)
            """
        ).first
        var usage = ProviderUsage(info: info)
        usage.sessions = sessions.compactMap { row in
            guard let id = row["id"], let created = row["time_created"].flatMap(Double.init) else { return nil }
            return ActiveSessionInfo(id: id, title: row["title"] ?? "OpenCode",
                                     startedAt: Date(timeIntervalSince1970: created / 1000))
        }
        if let latest = sessions.first, let updated = latest["time_updated"].flatMap(Double.init),
           now.timeIntervalSince1970 - updated / 1000 < 120 {
            usage.activity = .processing(task: latest["title"])
        }
        // `model` is stored as JSON ({"id":…,"providerID":…}) in recent OpenCode versions, plain text in older ones.
        usage.plan = totals?["latest_model"].map { raw in
            (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["id"] as? String ?? raw
        }
        let tokens = totals?["tokens"].flatMap(Double.init) ?? 0
        let cost = totals?["cost"].flatMap(Double.init) ?? 0
        let currency = NumberFormatter()
        currency.locale = Locale(identifier: "es_ES")
        currency.numberStyle = .currency
        currency.currencyCode = "USD"
        let amount = currency.string(from: NSNumber(value: cost)) ?? "\(cost) USD"
        usage.summary = "Hoy: \(Self.compactTokens(tokens)) tokens · \(amount)"
        return usage
    }

    static func compactTokens(_ value: Double) -> String {
        let divisor = value >= 1_000_000 ? 1_000_000.0 : value >= 1_000 ? 1_000.0 : 1.0
        let suffix = divisor == 1_000_000 ? " M" : divisor == 1_000 ? " k" : ""
        return (value / divisor).formatted(.number.locale(Locale(identifier: "es_ES"))
            .precision(.fractionLength(0...1))) + suffix
    }
}
