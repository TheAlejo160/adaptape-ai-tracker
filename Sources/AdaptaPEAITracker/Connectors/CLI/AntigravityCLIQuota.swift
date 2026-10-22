import Foundation
import Darwin

enum AntigravityCLIQuota {
    static var executable: URL? {
        [LocalFiles.home(".local/bin/agy"), URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
         URL(fileURLWithPath: "/usr/local/bin/agy")].first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }.map { URL(fileURLWithPath: canonical($0)) }
    }

    static func fetch(executable: URL) async throws -> ProviderUsage {
        try Task.checkCancellation()
        let usage: ProviderUsage = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try read(executable: executable) })
            }
        }
        try Task.checkCancellation()
        return usage
    }

    private static func read(executable: URL) throws -> ProviderUsage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aitracker-quota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let data = LocalFiles.processOutput(executable: "/usr/bin/sandbox-exec",
            arguments: arguments(executable: executable, temporaryDirectory: directory),
            timeout: 40, limit: HTTP.maxResponseBytes, temporaryDirectory: directory) else {
            throw ConnectorError.unexpectedResponse("«agy /quota» no respondió; comprueba «/quota» en agy")
        }
        var usage = try GeminiConnector().parseQuotaSummary(data, account: Data("{}".utf8))
        usage.quotaSource = "Cuota de «agy /quota»"
        return usage
    }

    static func arguments(executable: URL, temporaryDirectory: URL) -> [String] {
        ["-p", profile, "-D", "HOME=\(canonical(FileManager.default.homeDirectoryForCurrentUser))",
         "-D", "EXEC=\(canonical(executable))", "-D", "STATE=\(canonical(LocalFiles.home(".gemini")))",
         "-D", "HELPERS=\(canonical(LocalFiles.home(".gemini/antigravity-cli/bin")))",
         "-D", "TEMP=\(canonical(temporaryDirectory))",
         "-D", "KEYCHAINS=\(canonical(LocalFiles.home("Library/Keychains")))",
         executable.path, "-p", "/quota", "--output-format", "json", "--print-timeout", "30s"]
    }

    static func canonical(_ url: URL) -> String {
        guard let pointer = realpath(url.path, nil) else { return url.path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    // LimitBar's isolation pattern: quota command only, no shell, hooks or project files.
    static let profile = #"""
    (version 1)
    (allow default)
    (deny process-exec)
    (allow process-exec (literal (param "EXEC")) (literal "/usr/bin/security") (subpath (param "HELPERS")))
    (deny file-read* file-write* (subpath "/Users") (subpath (param "HOME")) (subpath "/Volumes")
        (subpath "/private/tmp") (subpath "/private/var/folders"))
    (allow file-read-metadata)
    (allow file-read* file-write* (subpath (param "STATE")) (subpath (param "TEMP")) (subpath (param "KEYCHAINS")))
    (allow file-read* (literal (param "EXEC")))
    (deny file-write* (require-not (require-any (subpath (param "STATE")) (subpath (param "TEMP")) (subpath (param "KEYCHAINS")))))
    (allow file-write* (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/fd/") (regex #"^/dev/ttys"))
    """#
}
