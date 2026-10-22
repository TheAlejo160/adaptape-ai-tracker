import Foundation

/// Demo mode: fake providers whose numbers drift on every refresh, to exercise the UI.
struct MockConnector: UsageConnector {
    let sample: ProviderUsage
    var info: ProviderInfo { ProviderInfo(id: sample.id, name: sample.name, kind: sample.kind, iconURL: sample.iconURL) }

    func fetch() async throws -> ProviderUsage? {
        try await Task.sleep(for: .milliseconds(.random(in: 200...600)))
        var usage = sample
        for i in usage.windows.indices {
            usage.windows[i].used = min(max(usage.windows[i].used + .random(in: -0.08...0.12), 0), 1)
        }
        if usage.local?.tokensPerSecond != nil { usage.local?.tokensPerSecond = .random(in: 28...64) }
        return usage
    }

    static let all: [any UsageConnector] = samples.map(MockConnector.init)

    static let samples: [ProviderUsage] = {
        let now = Date()
        func h(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }
        let icon = ProviderInfo.lobeIcon
        return [
            ProviderUsage(
                id: "demo-claude", name: "Claude", kind: .cloud, iconURL: icon("claude"), plan: "Max",
                recentModel: "claude-opus-4-6",
                windows: [
                    UsageWindow(label: "Sesión (5 h)", used: 0.42, resetsAt: h(2.3), duration: 18_000),
                    UsageWindow(label: "Semanal", used: 0.67, resetsAt: h(76), duration: 604_800),
                ],
                activity: .processing(task: "Respondiendo"),
                sessions: [ActiveSessionInfo(id: "c1", title: "Refactor del widget", startedAt: h(-0.4))]
            ),
            ProviderUsage(
                id: "demo-chatgpt", name: "ChatGPT", kind: .cloud, iconURL: icon("openai"), plan: "Plus",
                recentModel: "gpt-6.1-sol",
                windows: [
                    UsageWindow(label: "Sesión (5 h)", used: 0.91, resetsAt: h(0.6), duration: 18_000),
                    UsageWindow(label: "Semanal", used: 0.38, resetsAt: h(120), duration: 604_800),
                ]
            ),
            ProviderUsage(
                id: "demo-gemini", name: "Gemini", kind: .cloud, iconURL: ProviderInfo.simpleIcon("googlegemini"), plan: "Pro",
                models: ["gemini-3.8-flash", "gemini-3.6-flash"], recentModel: "gemini-3.8-flash",
                windows: [UsageWindow(label: "Gemini 3.8 Flash", used: 1, resetsAt: h(5), duration: 86_400),
                          UsageWindow(label: "Gemini 3.6 Flash", used: 0.2, resetsAt: h(5), duration: 86_400)],
                activity: .rateLimited(until: h(5)),
                sessions: [ActiveSessionInfo(id: "g1", title: "Antigravity · Proyecto de ejemplo", startedAt: h(-0.2))]
            ),
            ProviderUsage(
                id: "demo-perplexity", name: "Perplexity", kind: .cloud, iconURL: icon("perplexity"),
                activity: .offline
            ),
            ProviderUsage(
                id: "demo-claude-code", name: "Claude Code", kind: .codeAssistant, iconURL: icon("claudecode"),
                windows: [UsageWindow(label: "Sesión (5 h)", used: 0.55, resetsAt: h(1.8), duration: 18_000)],
                activity: .processing(task: "Generando componente SwiftUI"),
                sessions: [
                    ActiveSessionInfo(id: "cc1", title: "adaptape-tracker · Fase 3", startedAt: h(-1.2)),
                    ActiveSessionInfo(id: "cc2", title: "api · tests", startedAt: h(-0.1)),
                ]
            ),
            ProviderUsage(
                id: "demo-cursor", name: "Cursor", kind: .codeAssistant, iconURL: icon("cursor"), plan: "Pro",
                windows: [UsageWindow(label: "Requests premium", used: 0.62, resetsAt: h(240), detail: "312 / 500")],
                activity: .processing(task: "Indexando workspace")
            ),
            ProviderUsage(
                id: "demo-ollama", name: "Ollama", kind: .local, iconURL: icon("ollama"),
                local: LocalStats(vramUsedGB: 9.4, vramTotalGB: 24, tokensPerSecond: 41, loadedModel: "qwen3:14b"),
                activity: .processing(task: nil)
            ),
        ]
    }()
}
