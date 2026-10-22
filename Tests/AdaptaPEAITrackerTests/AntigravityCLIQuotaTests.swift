import Foundation
import Testing
@testable import AdaptaPEAITracker

@Test func agyQuotaCommandIsFixedAndIsolated() throws {
    let executable = URL(fileURLWithPath: "/fixed/agy")
    let temporary = URL(fileURLWithPath: "/private/tmp/aitracker-fixture")
    let arguments = AntigravityCLIQuota.arguments(executable: executable, temporaryDirectory: temporary)
    #expect(Array(arguments.suffix(7)) == ["/fixed/agy", "-p", "/quota", "--output-format", "json", "--print-timeout", "30s"])
    #expect(arguments.contains("TEMP=/private/tmp/aitracker-fixture"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = LocalFiles.processOutput(executable: "/bin/pwd", arguments: [], timeout: 2, temporaryDirectory: directory)
    #expect(output.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } == AntigravityCLIQuota.canonical(directory))
}

@Test func agySandboxDeniesUnrelatedFilesAndShells() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let allowed = directory.appendingPathComponent("quota-fixture")
    let unrelated = directory.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString)-unrelated")
    try Data("fixture".utf8).write(to: allowed)
    try Data("private-fixture".utf8).write(to: unrelated)
    defer { try? FileManager.default.removeItem(at: unrelated) }
    let arguments = AntigravityCLIQuota.arguments(executable: URL(fileURLWithPath: "/bin/cat"), temporaryDirectory: directory)
    let profile = Array(arguments.dropLast(7))
    #expect(LocalFiles.processOutput(executable: "/usr/bin/sandbox-exec", arguments: profile + ["/bin/cat", allowed.path], timeout: 2) == Data("fixture".utf8))
    #expect(LocalFiles.processOutput(executable: "/usr/bin/sandbox-exec", arguments: profile + ["/bin/cat", unrelated.path], timeout: 2) == nil)
    #expect(LocalFiles.processOutput(executable: "/usr/bin/sandbox-exec", arguments: profile + ["/bin/sh", "-c", "exit 0"], timeout: 2) == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AITRACKER_AGY_QUOTA"] == "1"))
func installedAgyProvidesQuotaWithoutModelPrompt() async throws {
    let executable = try #require(AntigravityCLIQuota.executable)
    let cache = QuotaCache()
    let usage = try await cache.usage(id: "agy-live-verification", minInterval: 300) {
        try await AntigravityCLIQuota.fetch(executable: executable)
    }
    #expect(!usage.windows.isEmpty)
    #expect(usage.windows.contains { $0.duration == 18_000 })
    #expect(usage.windows.contains { $0.duration == 604_800 })
    print("Agy quota verified: windows=\(usage.windows.count)")
}
