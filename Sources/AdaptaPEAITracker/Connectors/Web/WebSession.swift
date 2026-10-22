import Foundation

/// A connector backed by a signed-in web account. `WebLogin` waits for these cookies before saving.
protocol WebLoginConnector: UsageConnector {
    /// Cookie names that prove the user is signed in. Chunked cookies (`name.0`, `name.1`) also match.
    var requiredCookies: [String] { get }
    /// One real request with freshly captured cookies; true only if the session actually works.
    func validate(_ headers: [String: String]) async -> Bool
}

/// Session cookies captured by `WebLogin`, kept only in our Keychain under `web.<id>`.
enum WebSession {
    /// One desktop-Safari identity for the login web view and for URLSession, so Cloudflare
    /// sees the same client that passed its check.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    private struct StoredCookie: Codable {
        let name, value, domain, path: String
        let expires: Date?
    }

    static func account(_ id: String) -> String { "web.\(id)" }

    static func isLinked(_ id: String) -> Bool { KeychainStore.load(account: account(id)) != nil }

    /// False if the Keychain item could not be removed.
    @discardableResult
    static func unlink(_ id: String) -> Bool { KeychainStore.delete(account: account(id)) }

    static func save(_ cookies: [HTTPCookie], id: String) throws {
        let stored = cookies.map {
            StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate)
        }
        try KeychainStore.save(try JSONEncoder().encode(stored), account: account(id))
    }

    /// Cookie, User-Agent and Accept headers for the provider's own API. Nil → account not linked.
    /// Expired cookies are dropped, so a dead session surfaces as 401 → "vuelve a conectar".
    static func headers(id: String) -> [String: String]? {
        guard let data = KeychainStore.load(account: account(id)),
              let cookies = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return nil }
        let now = Date()
        return headers(cookies.filter { ($0.expires ?? .distantFuture) > now }.map { ($0.name, $0.value) })
    }

    /// Same headers from cookies just captured in the login web view, before they are saved.
    static func headers(for cookies: [HTTPCookie]) -> [String: String] {
        headers(cookies.map { ($0.name, $0.value) })
    }

    private static func headers(_ pairs: [(name: String, value: String)]) -> [String: String] {
        let cookie = pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return ["Cookie": cookie, "User-Agent": userAgent, "Accept": "application/json"]
    }

    /// True when a browser would send `cookie` to `host` (same domain or a parent domain).
    static func applies(_ cookie: HTTPCookie, to host: String) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return host == domain || host.hasSuffix("." + domain)
    }

    static func matches(_ name: String, required: String) -> Bool {
        name == required || name.hasPrefix(required + ".")
    }
}
