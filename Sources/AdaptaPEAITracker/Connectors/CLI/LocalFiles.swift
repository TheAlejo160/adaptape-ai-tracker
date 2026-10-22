import Foundation
import CoreFoundation
import SQLite3
import Darwin

enum LocalFiles {
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

    static func activity(windows: [UsageWindow], newest: Date?, now: Date) -> Activity {
        if let exhausted = windows.first(where: { $0.used >= 1 }) {
            return .rateLimited(until: exhausted.resetsAt)
        }
        return newest.map { now.timeIntervalSince($0) < 120 } == true
            ? .processing(task: "Sesión activa") : .idle
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
                              limit: Int = 65_536) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        // Minimal environment: don't leak our own env (which may hold API keys) to the child.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { return nil }
        do { try process.run() } catch { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            if data.count > limit || ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return nil
            }
            if !process.isRunning && count <= 0 {
                // The child may have written and exited between the read above and this check: drain once more.
                while true {
                    let rest = read(descriptor, &buffer, buffer.count)
                    guard rest > 0 else { break }
                    data.append(contentsOf: buffer.prefix(rest))
                    if data.count > limit { return nil }
                }
                break
            }
            if count <= 0 { usleep(10_000) }
        }
        return process.terminationStatus == 0 ? data : nil
    }
}
