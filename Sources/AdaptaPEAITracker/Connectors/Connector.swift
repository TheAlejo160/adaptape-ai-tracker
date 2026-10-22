import Foundation
import os

/// One data source for one provider. Add an AI = add a type conforming to this and list it in `ConnectorRegistry`.
protocol UsageConnector: Sendable {
    var info: ProviderInfo { get }
    /// `nil` → not installed / not configured on this Mac, so the provider stays hidden.
    /// Throw → configured but failing; the store keeps the last data and shows the error.
    func fetch() async throws -> ProviderUsage?
}

enum ConnectorError: LocalizedError {
    case unauthorized
    case invalidToken(tool: String)
    case forbidden
    case googleForbidden(reason: String)
    case credentialsUnavailable(hint: String)
    /// Token expired; `hint` tells the user which tool to run to refresh it.
    case expired(hint: String)
    case http(Int)
    /// HTTP 429. `retryAfter` comes from the Retry-After header when the server sends one.
    case rateLimited(retryAfter: TimeInterval?)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Credencial ausente o inválida: vuelve a usar la herramienta para iniciar sesión"
        case .invalidToken(let tool): "Token inválido o caducado (401): ejecuta «\(tool)» una vez para renovar la sesión"
        case .forbidden: "Acceso rechazado (403): el proveedor no permite esta consulta; revisa los permisos de la cuenta"
        case .googleForbidden(let reason): "Google rechazó la consulta (403): \(reason). El permiso del Llavero ya no interviene; comprueba la cuota en «agy»."
        case .credentialsUnavailable(let hint): "No se pudieron leer las credenciales. \(hint)"
        case .expired(let hint): "Token caducado: \(hint)"
        case .http(let code): "El servidor respondió \(code)"
        case .rateLimited(let after): "El servidor limitó las consultas (429)"
            + (after.map { " · reintento en \(compactDuration($0))" } ?? "")
        case .unexpectedResponse(let what): "Respuesta inesperada (\(what))"
        }
    }
}

/// Shared HTTP for connectors: ephemeral (no cookie jar, no cache), short timeout.
/// Tokens only travel in headers set per request and are never persisted by us.
enum HTTP {
    private static let logger = Logger(subsystem: KeychainStore.service, category: "HTTP")
    /// Usage payloads are tiny; cap the body so a hostile or broken server can't grow memory unbounded.
    static let maxResponseBytes = 4 * 1024 * 1024

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30 // total deadline: a trickling server can't hold a slot open
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try await send(request)
    }

    static func post(_ url: URL, headers: [String: String] = [:], jsonBody: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try await send(request)
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite { return seconds > 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value), date > now else { return nil }
        return date.timeIntervalSince(now)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: SameHostRedirects.shared)
        if let http = response as? HTTPURLResponse, http.statusCode == 403,
           ["daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com"].contains(http.url?.host ?? "") {
            var body = Data()
            for try await byte in bytes {
                if body.count >= 65_536 { break }
                body.append(byte)
            }
            try validate(http, errorBody: body)
        }
        try validate(response as? HTTPURLResponse)
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), maxResponseBytes))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponseBytes { throw ConnectorError.unexpectedResponse("respuesta demasiado grande") }
        }
        return data
    }

    static func validate(_ http: HTTPURLResponse?, errorBody: Data? = nil) throws {
        let code = http?.statusCode ?? 0
        let delay = retryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
        // Only the host: paths and query strings may contain account data.
        let operation = ["loadCodeAssist", "fetchAvailableModels", "retrieveUserQuotaSummary", "retrieveUserQuota"]
            .first { http?.url?.path.hasSuffix(":" + $0) == true } ?? "usage"
        logger.info("response host=\(http?.url?.host ?? "unknown", privacy: .public) operation=\(operation, privacy: .public) status=\(code) retrySeconds=\(delay ?? 0)")
        switch code {
        case 200..<300: return
        case 401:
            let tool: String? = switch http?.url?.host {
            case "api.anthropic.com": "claude"
            case "daily-cloudcode-pa.googleapis.com": "agy"
            case "cloudcode-pa.googleapis.com": "gemini"
            case "chatgpt.com": "codex"
            default: nil
            }
            if let tool { throw ConnectorError.invalidToken(tool: tool) }
            throw ConnectorError.unauthorized
        case 403:
            if ["daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com"].contains(http?.url?.host ?? "") {
                let reason = googlePermissionReason(errorBody)
                logger.info("google permission=\(reason, privacy: .public)")
                throw ConnectorError.googleForbidden(reason: reason)
            }
            throw ConnectorError.forbidden
        case 429:
            throw ConnectorError.rateLimited(retryAfter: delay)
        case let code: throw ConnectorError.http(code)
        }
    }

    static func googlePermissionReason(_ data: Data?) -> String {
        let error = data.flatMap { try? LocalFiles.json($0)["error"] as? [String: Any] }
        let details = error?["details"] as? [[String: Any]] ?? []
        for detail in details {
            switch detail["reason"] as? String {
            case "ACCESS_TOKEN_SCOPE_INSUFFICIENT": return "el token no tiene el alcance requerido"
            case "SERVICE_DISABLED": return "esta API no está habilitada para el proyecto"
            case "BILLING_DISABLED": return "el proyecto requiere facturación habilitada"
            case "CONSUMER_INVALID": return "el proyecto de la cuenta no es válido para esta API"
            default: continue
            }
        }
        return "la cuenta no tiene acceso a este endpoint"
    }

    static func getJSON<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:]) async throws -> T {
        let data = try await get(url, headers: headers)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ConnectorError.unexpectedResponse(String(describing: T.self)) }
    }
}

/// Last good quota per connector and when it may call its endpoint again. Keeps a 429, a timeout
/// or a panel opened every few seconds from hammering an endpoint or blanking the row: the
/// connector still builds its local data (sessions) and shows the cached windows as stale.
actor QuotaCache {
    static let shared = QuotaCache(persistingIn: nil)
    private let defaults: UserDefaults?

    init() { defaults = nil }
    init(persistingIn suite: String?) { defaults = UserDefaults(suiteName: suite) }

    private struct Entry {
        var usage: ProviderUsage?
        var fetchedAt: Date?
        var blockedUntil: Date?
        var error: (any Error)?
        var strikes = 0
    }
    private var entries: [String: Entry] = [:]

    /// Fresh result if the endpoint may be called, else the cached one with `error` set.
    /// Throws only when it has never succeeded and has nothing to fall back to.
    func usage(id: String, minInterval: TimeInterval, now: Date = Date(), cooldownID: String? = nil,
               fetch: @Sendable () async throws -> ProviderUsage) async throws -> ProviderUsage {
        var entry = entries[id] ?? Entry()
        if entries[id] == nil, let cooldownID {
            entry.strikes = min(4, max(0, defaults?.integer(forKey: "quotaRetry.\(cooldownID).strikes") ?? 0))
        }
        if let cooldownID, let until = defaults?.object(forKey: "quotaRetry.\(cooldownID).until") as? Date, until > now {
            entry.blockedUntil = until
            entry.error = ConnectorError.rateLimited(retryAfter: nil)
            entry.strikes = min(4, max(0, defaults?.integer(forKey: "quotaRetry.\(cooldownID).strikes") ?? 0))
        }
        if let cached = entry.usage, let at = entry.fetchedAt, now.timeIntervalSince(at) < minInterval,
           entry.error == nil { return cached }
        if let until = entry.blockedUntil, until > now, let error = entry.error {
            return try stale(entry, because: error, retryAt: until, now: now)
        }
        do {
            var fresh = try await fetch()
            if fresh.observedAt == nil { fresh.observedAt = now }
            entries[id] = Entry(usage: fresh, fetchedAt: now)
            if let cooldownID {
                defaults?.removeObject(forKey: "quotaRetry.\(cooldownID).until")
                defaults?.removeObject(forKey: "quotaRetry.\(cooldownID).strikes")
            }
            return fresh
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { throw CancellationError() }
            var delay = minInterval
            if case ConnectorError.rateLimited(let after) = error {
                // shortcut: undocumented per-token limits; tune the backoff if 429 persists.
                entry.strikes = min(entry.strikes + 1, 4)
                let backoff = min(300 * pow(2, Double(entry.strikes - 1)), 1_800)
                delay = max(delay, max(after ?? 0, backoff))
            } else {
                entry.strikes = 0
            }
            let retryAt = now.addingTimeInterval(delay)
            entry.blockedUntil = retryAt
            entry.error = error
            if let cooldownID, case ConnectorError.rateLimited = error {
                defaults?.set(retryAt, forKey: "quotaRetry.\(cooldownID).until")
                defaults?.set(entry.strikes, forKey: "quotaRetry.\(cooldownID).strikes")
            }
            entries[id] = entry
            return try stale(entry, because: error, retryAt: retryAt, now: now)
        }
    }

    private func stale(_ entry: Entry, because error: any Error, retryAt: Date?, now: Date) throws -> ProviderUsage {
        guard var usage = entry.usage, let at = entry.fetchedAt else {
            if let retryAt, case ConnectorError.rateLimited = error {
                throw ConnectorError.rateLimited(retryAfter: retryAt.timeIntervalSince(now))
            }
            throw error
        }
        // Strip the server's own retry hint: the note below appends the real, backoff-adjusted one.
        let reason = if case ConnectorError.rateLimited = error { ConnectorError.rateLimited(retryAfter: nil) } else { error }
        var note = "\(reason.localizedDescription) · datos de hace \(compactDuration(now.timeIntervalSince(at)))"
        if let retryAt { note += " · reintento en \(compactDuration(retryAt.timeIntervalSince(now)))" }
        usage.error = note
        return usage
    }
}

/// URLSession copies request headers onto redirects; refuse any hop to another host so a
/// token or session cookie can never reach a server other than the one it was meant for.
/// Local connectors use it too, so a loopback server can't redirect the app to an external host.
final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = SameHostRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.host == task.originalRequest?.url?.host ? request : nil
    }
}

/// Providers send reset times as unix seconds, unix ms or ISO-8601. Decode any of them.
struct FlexibleDate: Decodable, Sendable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        } else if let text = try? container.decode(String.self) {
            date = Self.parse(text)
        } else {
            date = nil
        }
    }

    static func parse(_ text: String) -> Date? {
        if let number = Double(text) { return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }
}

/// Every connector the app knows, in display order within each section.
enum ConnectorRegistry {
    /// First id wins: a custom provider can't shadow a built-in (ids key Keychain items and enabled state).
    static let all: [any UsageConnector] = {
        var seen = Set<String>()
        return (builtIn + CustomConnector.loadAll()).filter { seen.insert($0.info.id).inserted }
    }()

    private static let builtIn: [any UsageConnector] = [
        // Cloud accounts: read the token the brand's own tool already stored locally. No login.
        ClaudeCodeConnector(),   // "Claude" — token from Claude Code (Keychain, opt-in)
        CodexConnector(),        // "ChatGPT" — token from ~/.codex/auth.json
        GeminiConnector(),
        OpenRouterConnector(),   // key from OPENROUTER_API_KEY
        // Code assistants with their own quota.
        CursorConnector(),
        CopilotConnector(),
        OpenCodeConnector(),
        // Local runtimes.
        OllamaConnector(),
        LMStudioConnector(),
    ]
}
