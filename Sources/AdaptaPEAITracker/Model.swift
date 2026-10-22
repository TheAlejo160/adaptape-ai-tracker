import Foundation

/// Which section a provider lives in. Order of cases = order on screen.
enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case cloud, codeAssistant, local
    var id: Self { self }

    var title: String {
        switch self {
        case .cloud: "Modelos en la nube"
        case .codeAssistant: "Asistentes de código"
        case .local: "Modelos locales"
        }
    }
}

/// How a connector finds its credentials. The app never stores anything of its own: it only
/// reads what other tools already saved on this Mac, and holds tokens in memory for one fetch.
enum AuthMethod: Equatable, Sendable {
    /// Local server or a plain file the user's own CLI wrote. Read without asking.
    case automatic
    /// Reads another app's Keychain item; macOS shows its own access prompt. Opt-in.
    case keychainConsent
    /// File/session detection stays automatic; the toggle only authorizes optional Keychain access.
    case optionalKeychainConsent
    /// Reads an API key from this environment variable. Nothing is stored by the app.
    case apiKeyEnv(String)
}

/// Static description of a provider, known before any fetch.
struct ProviderInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let kind: ProviderKind
    /// Any SVG/PNG/PDF URL (https or file). Nil → monogram fallback.
    let iconURL: URL?
    var auth: AuthMethod = .automatic

    /// lobe-icons (MIT, mono SVG, covers AI brands). Pinned so icons never change under the user.
    static func lobeIcon(_ slug: String) -> URL? {
        URL(string: "https://cdn.jsdelivr.net/npm/@lobehub/icons-static-svg@1.97.0/icons/\(slug).svg")
    }

    /// simple-icons fallback for SVGs CoreSVG can't parse (lobe's Gemini uses compact arc flags).
    static func simpleIcon(_ slug: String) -> URL? {
        URL(string: "https://cdn.jsdelivr.net/npm/simple-icons@16.35.0/icons/\(slug).svg")
    }
}

/// One rate-limit window (5 h session, weekly, premium requests…). Same metaphor for every provider.
struct UsageWindow: Identifiable, Equatable, Sendable {
    var id: String { label }
    let label: String
    /// Used fraction, 0…1.
    var used: Double
    var resetsAt: Date?
    /// Optional absolute count, e.g. "312 / 500".
    var detail: String?
    /// Window length in seconds (5 h = 18 000). Needed for pace and projection; nil hides them.
    var duration: TimeInterval?
    var group: String?

    var remaining: Double { 1 - used }

    /// Fraction of the window already elapsed, when its length and reset are known.
    func elapsed(at now: Date) -> Double? {
        guard let duration, duration > 0, let resetsAt else { return nil }
        let fraction = 1 - resetsAt.timeIntervalSince(now) / duration
        return fraction.isFinite ? min(max(fraction, 0), 1) : nil
    }

    /// When the quota runs out if spending keeps its average pace so far; nil if it lasts until
    /// the reset. Skips the first 5 % of the window, where one burst would project nonsense.
    func exhaustion(at now: Date) -> Date? {
        guard let duration, let resetsAt, let elapsed = elapsed(at: now), elapsed > 0.05, used > 0, used < 1 else { return nil }
        let perSecond = used / (elapsed * duration)
        let empty = now.addingTimeInterval(remaining / perSecond)
        return empty < resetsAt ? empty : nil
    }

    enum Severity { case ok, warning, critical }

    var severity: Severity {
        switch used {
        case ..<0.6: .ok
        case ..<0.85: .warning
        default: .critical
        }
    }
}

/// Local runtimes have no quota; they report hardware instead.
struct LocalStats: Equatable, Sendable {
    var vramUsedGB: Double
    var vramTotalGB: Double
    var tokensPerSecond: Double?
    var loadedModel: String?
}

enum Activity: Equatable, Sendable {
    case idle
    /// A session is open (written in the last 10 min) but not working right now.
    case waiting
    case processing(task: String?)
    case rateLimited(until: Date?)
    case offline
}

struct ActiveSessionInfo: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var startedAt: Date
}

struct ProviderUsage: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: ProviderKind
    let iconURL: URL?
    var plan: String?
    var models: [String] = []
    var modelsSource: String?
    var recentModel: String?
    var windows: [UsageWindow] = []
    var local: LocalStats?
    var activity: Activity = .idle
    var sessions: [ActiveSessionInfo] = []
    /// One-line figure for providers without a quota, e.g. "Hoy: 1,2 M tokens · 0,84 US$".
    var summary: String?
    /// Last fetch error; the row keeps showing stale data alongside it.
    var error: String?
    var quotaSource: String?
    var observedAt: Date?

    var orderedWindows: [UsageWindow] {
        windows.enumerated().sorted {
            let lhs = $0.element.duration ?? .infinity
            let rhs = $1.element.duration ?? .infinity
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    var quotaStatus: String {
        if windows.isEmpty { return error == nil ? "Sin cuota informada" : "Cuota no disponible" }
        return error == nil ? "Cuota recibida" : "Última cuota disponible"
    }
}

extension ProviderUsage {
    /// Connectors start from their info and fill in the rest.
    init(info: ProviderInfo) {
        self.init(id: info.id, name: info.name, kind: info.kind, iconURL: info.iconURL)
    }
}

func modelName(_ id: String) -> String {
    guard id.hasPrefix("claude-") || id.hasPrefix("gemini-") else { return id }
    let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
    var result: [String] = []
    for part in parts {
        if part.count <= 2, Int(part) != nil, let last = result.last, Int(last) != nil {
            result[result.count - 1] += "." + part
        } else {
            result.append(part.capitalized)
        }
    }
    return result.joined(separator: " ")
}
