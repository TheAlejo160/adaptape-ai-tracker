import Testing
@testable import AdaptaPEAITracker

@Test func allQuotaWindowsStayVisibleInTimeOrder() {
    var usage = ProviderUsage(info: CodexConnector().info)
    usage.windows = [UsageWindow(label: "Semanal", used: 0.9, duration: 604_800),
                     UsageWindow(label: "Mensual", used: 0.1, duration: 2_592_000),
                     UsageWindow(label: "Sesión (5 h)", used: 0.2, duration: 18_000),
                     UsageWindow(label: "Sin periodo", used: 0.3)]
    #expect(usage.orderedWindows.map(\.label) == ["Sesión (5 h)", "Semanal", "Mensual", "Sin periodo"])
    #expect(usage.orderedWindows.count == usage.windows.count)
    usage.windows[0].used = 0.01
    #expect(usage.orderedWindows.first?.label == "Sesión (5 h)")
    usage.windows = [UsageWindow(label: "Gemini", used: 0.1), UsageWindow(label: "Claude", used: 1)]
    #expect(usage.orderedWindows.map(\.label) == ["Gemini", "Claude"])
}
