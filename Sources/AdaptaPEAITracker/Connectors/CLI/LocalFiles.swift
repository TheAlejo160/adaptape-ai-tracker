import Foundation
import CoreFoundation
import SQLite3
import Darwin
import os

enum LocalFiles {
    private static let logger = Logger(subsystem: KeychainStore.service, category: "LocalFiles")
    static func home(_ path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.unexpectedResponse("JSON")
        }
        return object
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    static func date(_ value: Any?) -> Date? {
        if let number = number(value) {
            return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        }
        return (value as? String).flatMap(FlexibleDate.parse)
    }

    static func fraction(_ percent: Double) -> Double { min(1, max(0, percent / 100)) }

    /// A session file written within this long counts as open and is listed under its provider.
    static let openSessionAge: TimeInterval = 600

    static func activity(windows: [UsageWindow], newest: Date?, now: Date) -> Activity {
        // A stale 100 % window whose reset already passed is not a limit any more.
        if let exhausted = windows.first(where: { $0.used >= 1 && ($0.resetsAt.map { $0 > now } ?? true) }) {
            return .rateLimited(until: exhausted.resetsAt)
        }
        guard let age = newest.map({ now.timeIntervalSince($0) }) else { return .idle }
        // Same threshold as the session list, so "Inactivo" never sits above a listed session.
        return age < 120 ? .processing(task: "Trabajando") : age < openSessionAge ? .waiting : .idle
    }

    /// Working directory a CLI recorded in its session log (Claude: top-level `cwd`, Codex:
    /// `payload.cwd` in the first line). Reads only the first 64 KB.
    static func cwd(in url: URL) -> String? {
        guard let head = try? head(url) else { return nil }
        for line in head.split(separator: 10) where line.range(of: Data("\"cwd\"".utf8)) != nil {
            guard let object = try? json(Data(line)) else { continue }
            let cwd = (object["cwd"] ?? (object["payload"] as? [String: Any])?["cwd"]) as? String
            if let cwd, !cwd.isEmpty { return cwd }
        }
        return nil
    }

    /// Folder name for a session title; nil for app-managed scratch dirs (Library, tmp),
    /// whose random names say nothing to the user.
    static func projectName(cwd: String?) -> String? {
        guard let cwd, !cwd.contains("/Library/"), !cwd.hasPrefix("/private/"), !cwd.hasPrefix("/tmp/") else { return nil }
        let url = URL(fileURLWithPath: cwd).standardizedFileURL
        guard url.path != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path else { return nil }
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    struct SessionFile {
        let url: URL
        let modified: Date
        let created: Date
    }

    static func sessionFiles(in directory: URL) -> [SessionFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [SessionFile] = []
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let modified = values.contentModificationDate else { continue }
            result.append(SessionFile(url: url, modified: modified, created: values.creationDate ?? modified))
        }
        return result.sorted { $0.modified > $1.modified }
    }

    static func tail(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        return try file.read(upToCount: 262_144) ?? Data()
    }

    static func head(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: 65_536) ?? Data()
    }

    static func recentModel(_ data: Data) -> String? {
        for line in data.split(separator: 10).reversed() {
            guard let object = try? json(Data(line)) else { continue }
            let model: String?
            if object["type"] as? String == "assistant" {
                model = (object["message"] as? [String: Any])?["model"] as? String
            } else if object["type"] as? String == "turn_context" {
                model = (object["payload"] as? [String: Any])?["model"] as? String
            } else if object["type"] as? String == "gemini" {
                model = object["model"] as? String
            } else { continue }
            if let model, !model.isEmpty, model != "<synthetic>" { return model }
        }
        return nil
    }

    static func query(_ url: URL, sql: String) throws -> [[String: String]] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uri = components?.string else { throw ConnectorError.unexpectedResponse("ruta SQLite") }
        var database: OpaquePointer?
        let status = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { if let database { sqlite3_close(database) } }
        guard status == SQLITE_OK, let database else {
            throw ConnectorError.unexpectedResponse("no se puede abrir SQLite en lectura")
        }
        sqlite3_busy_timeout(database, 1_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ConnectorError.unexpectedResponse("esquema SQLite no compatible")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw ConnectorError.unexpectedResponse("lectura SQLite bloqueada") }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let text = sqlite3_column_text(statement, index) {
                    row[String(cString: sqlite3_column_name(statement, index))] = String(cString: text)
                }
            }
            rows.append(row)
        }
    }

    static func ghToken() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // Only fixed install paths — never resolve `gh` through PATH, which an attacker could poison.
                guard let binary = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: {
                    FileManager.default.isExecutableFile(atPath: $0)
                }) else { continuation.resume(returning: nil); return }
                continuation.resume(returning: processToken(
                    executable: binary, arguments: ["auth", "token", "--hostname", "github.com"]))
            }
        }
    }

    static func processToken(executable: String, arguments: [String], timeout: TimeInterval = 5) -> String? {
        guard let data = processOutput(executable: executable, arguments: arguments, timeout: timeout),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { return nil }
        return token
    }

    /// Stdout of a successful run, or nil on failure, timeout or more than `limit` bytes.
    /// Never blocks on EOF, so a grandchild that inherits the pipe cannot hang the caller.
    static func processOutput(executable: String, arguments: [String], timeout: TimeInterval,
                              limit: Int = 65_536, temporaryDirectory: URL? = nil) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = temporaryDirectory ?? URL(fileURLWithPath: "/")
        // Minimal environment: don't leak our own env (which may hold API keys) to the child.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        if let temporaryDirectory { process.environment?["TMPDIR"] = temporaryDirectory.path + "/" }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var data = Data()
        var timedOut = false
        var overLimit = false
        var started = false
        defer {
            logger.debug("process binary=\(URL(fileURLWithPath: executable).lastPathComponent, privacy: .public) started=\(started) status=\(started && !process.isRunning ? process.terminationStatus : -1) bytes=\(data.count) timeout=\(timedOut) overLimit=\(overLimit)")
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { return nil }
        do { try process.run() } catch { return nil }
        started = true
        try? output.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            overLimit = data.count > limit
            timedOut = ProcessInfo.processInfo.systemUptime >= deadline
            if overLimit || timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return nil
            }
            if !process.isRunning && count <= 0 {
                // The child may have written and exited between the read above and this check: drain once more.
                while true {
                    let rest = read(descriptor, &buffer, buffer.count)
                    guard rest > 0 else { break }
                    data.append(contentsOf: buffer.prefix(rest))
                    if data.count > limit { overLimit = true; return nil }
                }
                break
            }
            if count <= 0 { usleep(10_000) }
        }
        return process.terminationStatus == 0 ? data : nil
    }
}
