import Foundation

/// One data source for one provider. Add an AI = add a type conforming to this and list it in `ConnectorRegistry`.
protocol UsageConnector: Sendable {
    var info: ProviderInfo { get }
    /// `nil` → not installed / not configured on this Mac, so the provider stays hidden.
    /// Throw → configured but failing; the store keeps the last data and shows the error.
    func fetch() async throws -> ProviderUsage?
}

enum ConnectorError: LocalizedError {
    case unauthorized
    /// Token expired; `hint` tells the user which tool to run to refresh it.
    case expired(hint: String)
    case http(Int)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Sesión caducada: vuelve a usar la herramienta para renovarla"
        case .expired(let hint): "Token caducado: \(hint)"
        case .http(let code): "El servidor respondió \(code)"
        case .unexpectedResponse(let what): "Respuesta inesperada (\(what))"
        }
    }
}

/// Shared HTTP for connectors: ephemeral (no cookie jar, no cache), short timeout.
/// Tokens only travel in headers set per request and are never persisted by us.
enum HTTP {
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
        let (bytes, response) = try await session.bytes(for: request, delegate: SameHostRedirects.shared)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: break
        case 401, 403: throw ConnectorError.unauthorized
        case let code: throw ConnectorError.http(code)
        }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), maxResponseBytes))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponseBytes { throw ConnectorError.unexpectedResponse("respuesta demasiado grande") }
        }
        return data
    }

    static func getJSON<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:]) async throws -> T {
        let data = try await get(url, headers: headers)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ConnectorError.unexpectedResponse(String(describing: T.self)) }
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
