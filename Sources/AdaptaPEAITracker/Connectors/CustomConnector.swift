import Foundation
import os

/// One user-declared provider from `providers.json`. See `examples/providers.json`.
struct ProviderConfig: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        enum Scale: String, Decodable, Sendable { case fraction, percent, ratio }
        let label: String
        let used: String
        let limit: String?
        let scale: Scale?
        let resetsAt: String?
        /// Template; `{used}` / `{limit}` are this window's values, any other `{path}` reads the response.
        let detail: String?
    }

    let id: String
    let name: String
    let kind: String
    /// lobe-icons slug, or a full https/file URL.
    let icon: String?
    let url: String
    let headers: [String: String]?
    let windows: [Window]?
    let summary: String?
}

/// Any AI added by endpoint + icon only: `~/Library/Application Support/AdaptaPE AI Tracker/providers.json`.
struct CustomConnector: UsageConnector {
    let config: ProviderConfig
    let info: ProviderInfo

    private static let log = Logger(subsystem: KeychainStore.service, category: "CustomConnector")

    static var configURL: URL {
        URL.applicationSupportDirectory.appending(path: "AdaptaPE AI Tracker/providers.json")
    }

    static func loadAll() -> [any UsageConnector] {
        guard let data = try? Data(contentsOf: configURL) else { return [] }
        do {
            return try JSONDecoder().decode([ProviderConfig].self, from: data).map(CustomConnector.init)
        } catch {
            log.error("providers.json inválido: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    init(config: ProviderConfig) {
        self.config = config
        let icon = config.icon.flatMap { $0.contains("://") ? URL(string: $0) : ProviderInfo.lobeIcon($0) }
        // A key goes in an env var ({{env:NAME}}); the app stores nothing.
        let envVar = config.headers?.values
            .compactMap { $0.firstMatch(of: /\{\{env:([A-Za-z0-9_]+)\}\}/).map { String($0.1) } }.first
        info = ProviderInfo(
            id: config.id,
            name: config.name,
            kind: ProviderKind(rawValue: config.kind) ?? .cloud,
            iconURL: icon,
            auth: envVar.map { .apiKeyEnv($0) } ?? .automatic
        )
    }

    func fetch() async throws -> ProviderUsage? {
        var headers: [String: String] = [:]
        for (field, template) in config.headers ?? [:] {
            var missing = false
            // {{env:NAME}} → environment variable; empty if unset (then the provider stays hidden).
            let value = template.replacing(/\{\{env:([A-Za-z0-9_]+)\}\}/) {
                guard let v = ProcessInfo.processInfo.environment[String($0.1)], !v.isEmpty else { missing = true; return "" }
                return v
            }
            if missing { return nil }
            headers[field] = value
        }
        guard let url = URL(string: config.url) else { throw ConnectorError.unexpectedResponse("url") }
        let data = try await HTTP.get(url, headers: headers)
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ConnectorError.unexpectedResponse("JSON")
        }

        var usage = ProviderUsage(info: info)
        usage.windows = (config.windows ?? []).compactMap { window in
            guard let used = Self.number(Self.value(at: window.used, in: json)) else { return nil }
            let limit = window.limit.flatMap { Self.number(Self.value(at: $0, in: json)) }
            let fraction = Self.fraction(used: used, limit: limit, scale: window.scale)
            let reset = window.resetsAt.flatMap { Self.value(at: $0, in: json) }
            let resetsAt: Date? = switch reset {
            case let text as String: FlexibleDate.parse(text)
            case let number as NSNumber: FlexibleDate.parse(number.stringValue)
            default: nil
            }
            let detail = window.detail.map { template in
                Self.render(template) { path in
                    switch path {
                    case "used": Self.format(used)
                    case "limit": limit.map(Self.format)
                    default: Self.format(Self.value(at: path, in: json))
                    }
                }
            }
            return UsageWindow(label: window.label, used: fraction, resetsAt: resetsAt, detail: detail)
        }
        usage.summary = config.summary.map { Self.render($0) { Self.format(Self.value(at: $0, in: json)) } }
        return usage
    }

    // MARK: - Pure helpers (no I/O, easy to test)

    /// Dot-separated path; numeric components index arrays. `"balance_infos.0.currency"`.
    static func value(at path: String, in json: Any) -> Any? {
        path.split(separator: ".").reduce(Optional(json)) { node, key in
            switch node {
            case let dict as [String: Any]: dict[String(key)]
            case let array as [Any]: Int(key).flatMap { array.indices.contains($0) ? array[$0] : nil }
            default: nil
            }
        }
    }

    /// JSON number or numeric string.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    static func fraction(used: Double, limit: Double?, scale: ProviderConfig.Window.Scale?) -> Double {
        let raw: Double = switch scale ?? (limit == nil ? .fraction : .ratio) {
        case .ratio: limit.map { $0 > 0 ? used / $0 : 0 } ?? used
        case .percent: used / 100
        case .fraction: used
        }
        return min(max(raw, 0), 1)
    }

    /// Replaces each `{token}`; unresolved → "–".
    static func render(_ template: String, resolve: (String) -> String?) -> String {
        template.replacing(/\{([^{}]+)\}/) { resolve(String($0.1)) ?? "–" }
    }

    static func format(_ value: Any?) -> String? {
        if let text = value as? String, Double(text) == nil { return text }
        guard let number = number(value) else { return nil }
        return format(number)
    }

    static func format(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...2)))
    }
}
