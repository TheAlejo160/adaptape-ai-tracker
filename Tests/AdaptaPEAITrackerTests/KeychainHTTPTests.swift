import Foundation
import Security
import LocalAuthentication
import Testing
@testable import AdaptaPEAITracker

@Test func httpStatusMessages() throws {
    for (host, tool) in [("api.anthropic.com", "claude"), ("daily-cloudcode-pa.googleapis.com", "agy"),
                         ("cloudcode-pa.googleapis.com", "gemini"), ("chatgpt.com", "codex")] {
        let url = URL(string: "https://\(host)/fixture")!
        do {
            try HTTP.validate(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
            Issue.record("401 accepted")
        } catch ConnectorError.invalidToken(let actual) {
            #expect(actual == tool)
            #expect(ConnectorError.invalidToken(tool: actual).localizedDescription.contains("401"))
        }
        #expect(throws: ConnectorError.self) {
            try HTTP.validate(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil))
        }
        do {
            try HTTP.validate(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil))
        } catch ConnectorError.forbidden {
            #expect(ConnectorError.forbidden.localizedDescription.contains("403"))
            #expect(!ConnectorError.forbidden.localizedDescription.contains("caducad"))
        } catch ConnectorError.googleForbidden(let reason) {
            #expect(host.hasSuffix("googleapis.com"))
            #expect(reason == "la cuenta no tiene acceso a este endpoint")
        }
        do {
            try HTTP.validate(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                             headerFields: ["Retry-After": "3600"]))
            Issue.record("429 accepted")
        } catch ConnectorError.rateLimited(let delay) {
            #expect(delay == 3600)
        }
        try HTTP.validate(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }
}

@Test func http429KeepsQuotaAndDoesNotRetryEarly() async throws {
    let cache = QuotaCache()
    let now = Date()
    var fixture = ProviderUsage(info: ClaudeCodeConnector().info)
    fixture.windows = [UsageWindow(label: "Sesión (5 h)", used: 0.25)]
    let known = fixture
    _ = try await cache.usage(id: "fixture", minInterval: 300, now: now) { known }
    let limited = try await cache.usage(id: "fixture", minInterval: 300, now: now.addingTimeInterval(301)) {
        try HTTP.validate(HTTPURLResponse(url: URL(string: "https://api.anthropic.com/fixture")!,
                                         statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "3600"]))
        return known
    }
    #expect(limited.windows == known.windows)
    #expect(limited.error?.contains("429") == true)
    #expect(limited.error?.contains("reintento en") == true)
    #expect(limited.error?.contains("datos de hace") == true)
    #expect(limited.error?.contains("caducad") == false)
    let blocked = try await cache.usage(id: "fixture", minInterval: 300, now: now.addingTimeInterval(3600)) {
        Issue.record("retried before Retry-After"); return known
    }
    #expect(blocked.windows == known.windows)
    #expect(blocked.error?.contains("429") == true)
}

@Test func keychainPollingDisallowsInteraction() {
    let query = KeychainStore.query(service: "gemini", account: "antigravity", allowInteraction: false)
    #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
    #expect(query[kSecAttrService as String] as? String == "gemini")
    #expect(query[kSecAttrAccount as String] as? String == "antigravity")
    let interactive = KeychainStore.query(service: "Claude Code-credentials", account: nil, allowInteraction: true)
    #expect((interactive[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == false)
    #expect(interactive[kSecAttrAccount as String] == nil)
}

@Test func processOutputIsBoundedAndDrainsAfterExit() {
    for _ in 0..<10 {
        #expect(LocalFiles.processOutput(executable: "/usr/bin/printf", arguments: ["fixture"], timeout: 2) == Data("fixture".utf8))
    }
    #expect(LocalFiles.processOutput(executable: "/usr/bin/false", arguments: [], timeout: 2) == nil)
    #expect(LocalFiles.processOutput(executable: "/usr/bin/head", arguments: ["-c", "70000", "/dev/zero"], timeout: 2) == nil)
    let start = ProcessInfo.processInfo.systemUptime
    #expect(LocalFiles.processOutput(executable: "/bin/sleep", arguments: ["2"], timeout: 0.05) == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
}

@Test func homeProjectUsesTimeFallbackAndKeychainFailuresKeepSessions() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(LocalFiles.projectName(cwd: home) == nil)
    #expect(LocalFiles.projectName(cwd: home + "/") == nil)
    #expect(LocalFiles.projectName(cwd: home + "/.") == nil)
    #expect(LocalFiles.projectName(cwd: home + "/Project") == "Project")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("internal-hash")
    let chats = root.appendingPathComponent("chats")
    try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    try Data(home.utf8).write(to: root.appendingPathComponent(".project_root"))
    let session = chats.appendingPathComponent("session.jsonl")
    try Data("{}".utf8).write(to: session)
    let auth = directory.appendingPathComponent("absent.json")
    let gemini = try #require(await GeminiConnector().fetch(credentials: auth, chats: directory, antigravity: [], installed: true))
    #expect(gemini.error?.contains("«agy»") == true)
    let created = try session.resourceValues(forKeys: [.creationDateKey]).creationDate!
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    #expect(gemini.sessions.first?.title == "Gemini CLI · \(formatter.string(from: created))")

    let expired = Data(#"{"token":{"access_token":"fixture","expiry":"2020-01-01T00:00:00Z"}}"#.utf8)
    let agy = try #require(await GeminiConnector().fetch(credentials: auth, keyring: expired,
                                                        chats: directory, antigravity: [], installed: true))
    #expect(agy.error == "Token caducado: ejecuta «agy» una vez para renovar la sesión")
    #expect(agy.sessions.count == 1)
    let claude = try await ClaudeCodeConnector().fetch(credentials: nil,
        files: [.init(url: session, modified: Date(), created: created)], now: Date())
    #expect(claude.sessions.count == 1)
    #expect(claude.error?.contains("Llavero") == true)
}

@Test @MainActor func optionalKeychainDoesNotDisableLocalQuotas() {
    #expect(GeminiConnector().info.auth == .optionalKeychainConsent)
    #expect(UsageStore().isEnabled(GeminiConnector().info))
    #expect(ClaudeCodeConnector().info.auth == .optionalKeychainConsent)
    #expect(UsageStore().isEnabled(ClaudeCodeConnector().info))
}
