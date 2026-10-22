import Foundation

extension GeminiConnector {
    func parseQuotaSummary(_ data: Data, account: Data) throws -> ProviderUsage {
        let root = try LocalFiles.json(data)
        let command = (root["command"] as? [String: Any])?["data"] as? [String: Any]
        let nested = (root["response"] ?? root["summary"]) as? [String: Any]
        guard let groups = (root["groups"] ?? root["quotaGroups"] ?? nested?["groups"] ?? command?["groups"]) as? [[String: Any]] else {
            throw ConnectorError.unexpectedResponse("grupos de cuotas de Antigravity")
        }
        var usage = ProviderUsage(info: info)
        usage.plan = Self.tierName(try LocalFiles.json(account))
        for group in groups {
            let name = group["displayName"] as? String ?? group["name"] as? String ?? "Modelos"
            for bucket in group["buckets"] as? [[String: Any]] ?? [] where bucket["disabled"] as? Bool != true {
                let remaining = bucket["remaining"] as? [String: Any]
                let fraction = LocalFiles.number(bucket["remainingFraction"] ?? bucket["remaining_fraction"])
                    ?? LocalFiles.number(remaining?["remainingFraction"])
                    ?? (remaining?["case"] as? String == "remainingFraction" ? LocalFiles.number(remaining?["value"]) : nil)
                guard let fraction, (0...1).contains(fraction) else { continue }
                let periods = ["window", "bucketId", "displayName"].compactMap { bucket[$0] as? String }
                var duration: TimeInterval?
                for period in periods {
                    let normalized = period.lowercased().replacingOccurrences(of: "_", with: "-")
                        .replacingOccurrences(of: " ", with: "-")
                    if normalized.contains("week") || ["7d", "seven-day"].contains(normalized) {
                        duration = 604_800; break
                    }
                    if ["5h", "session", "hourly"].contains(normalized)
                        || normalized.contains("5-hour") || normalized.contains("five-hour") {
                        duration = 18_000; break
                    }
                }
                let cadence: String
                if duration == 604_800 {
                    cadence = "Semanal"
                } else if duration == 18_000 {
                    cadence = "Sesión (5 h)"
                } else {
                    cadence = periods.first ?? "Cuota"
                }
                let label = "\(name) · \(cadence)"
                let window = UsageWindow(label: label, used: 1 - fraction,
                    resetsAt: LocalFiles.date(bucket["resetTime"] ?? bucket["reset_time"]), duration: duration, group: name)
                if let index = usage.windows.firstIndex(where: { $0.label == label }) {
                    if window.used > usage.windows[index].used { usage.windows[index] = window }
                } else {
                    usage.windows.append(window)
                }
            }
        }
        guard !usage.windows.isEmpty else { throw ConnectorError.unexpectedResponse("ventanas de cuotas de Antigravity") }
        return usage
    }
}
