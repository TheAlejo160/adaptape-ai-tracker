import Foundation

extension UsageWindow {
    func consumptionRate(at now: Date) -> Double? {
        guard used.isFinite, used > 0, used <= 1, let duration, duration.isFinite, duration > 0,
              let resetsAt, resetsAt > now, let elapsed = elapsed(at: now), elapsed > 0.05, elapsed < 1 else { return nil }
        return used / (elapsed * duration)
    }

    func estimatedRunTime(agents: Int, at now: Date) -> TimeInterval? {
        guard (1...16).contains(agents), let resetsAt, resetsAt > now, let rate = consumptionRate(at: now) else { return nil }
        return min(max(remaining, 0) / (rate * Double(agents)), resetsAt.timeIntervalSince(now))
    }

    func projectedRemaining(after seconds: TimeInterval, agents: Int, at now: Date) -> Double? {
        guard seconds.isFinite, seconds >= 0, (1...16).contains(agents),
              let resetsAt, seconds <= resetsAt.timeIntervalSince(now), let rate = consumptionRate(at: now) else { return nil }
        return max(0, remaining - seconds * rate * Double(agents))
    }
}

extension ProviderUsage {
    /// Weekly limits from another model group must not replace the selected group's weekly limit.
    var planningWindows: [UsageWindow] {
        let session = orderedWindows.first { $0.duration == 18_000 }
        let weekly = orderedWindows.first { $0.duration == 604_800 && (session == nil || $0.group == session?.group) }
        return [session, weekly].compactMap { $0 }
    }

    var menuName: String { name == "ChatGPT" ? "GPT" : name }

    var modelGroups: [String] { Array(Set(windows.compactMap(\.group))).sorted() }

    static func menuProvider(in providers: [ProviderUsage], selectedID: String) -> ProviderUsage? {
        let candidates = providers.filter { !$0.planningWindows.isEmpty }
        if let selected = candidates.first(where: { $0.id == selectedID }) { return selected }
        return candidates.first(where: { $0.error == nil && $0.quotaSource == nil && $0.planningWindows.first?.resetsAt != nil })
            ?? candidates.first(where: { $0.error == nil && $0.planningWindows.first?.resetsAt != nil })
            ?? candidates.first
    }

    func menuReadout(at now: Date, mode: String, rotating: Bool = true) -> String {
        let windows = planningWindows
        guard !windows.isEmpty else { return "\(menuName) · —" }
        let index: Int
        switch mode {
        case "5h": index = windows.firstIndex { $0.duration == 18_000 } ?? 0
        case "weekly": index = windows.firstIndex { $0.duration == 604_800 } ?? 0
        default: index = rotating ? Int(now.timeIntervalSince1970 / 8) % windows.count : 0
        }
        let window = windows[max(0, index)]
        let period = window.duration == 18_000 ? "5h" : "7d"
        guard window.used.isFinite, (0...1).contains(window.used) else { return "\(menuName) · \(period) —" }
        guard window.resetsAt.map({ $0 > now }) ?? true else { return "\(menuName) · \(period) —" }
        let percent = Int((min(max(window.remaining.isFinite ? window.remaining : 0, 0), 1) * 100).rounded())
        let approximate = error != nil || quotaSource?.hasPrefix("Registro") == true ? "≈" : ""
        return "\(menuName) · \(period) \(approximate)\(percent)% libre"
    }
}
