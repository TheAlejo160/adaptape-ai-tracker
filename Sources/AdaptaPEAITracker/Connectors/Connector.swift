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
    case http(Int)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Sesión caducada: vuelve a conectar la cuenta"
        case .http(let code): "El servidor respondió \(code)"
        case .unexpectedResponse(let what): "Respuesta inesperada (\(what))"
        }
    }
}

/// Shared HTTP for connectors: ephemeral (no cookie jar, no cache), short timeout.
/// Tokens only travel in headers set per request and are never persisted by us.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request, delegate: SameHostRedirects.shared)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return data
        case 401, 403: throw ConnectorError.unauthorized
        case let code: throw ConnectorError.http(code)
        }
    }

    static func getJSON<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:]) async throws -> T {
        let data = try await get(url, headers: headers)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ConnectorError.unexpectedResponse(String(describing: T.self)) }
    }
}

/// URLSession copies request headers onto redirects; refuse any hop to another host so a
/// token or session cookie can never reach a server other than the one it was meant for.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
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
        // Cloud: signed-in web accounts or API keys.
        ClaudeWebConnector(),
        ChatGPTWebConnector(),
        OpenRouterConnector(),
        // Code assistants: reuse the credentials their own CLIs already stored.
        ClaudeCodeConnector(),
        CodexConnector(),
        CursorConnector(),
        CopilotConnector(),
        OpenCodeConnector(),
        // Local runtimes.
        OllamaConnector(),
        LMStudioConnector(),
    ]
}
