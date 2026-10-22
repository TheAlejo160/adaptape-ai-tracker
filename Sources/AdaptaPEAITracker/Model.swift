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

/// How a connector gets its credentials. Anything but `.automatic` needs the user to opt in.
enum AuthMethod: Equatable, Sendable {
    /// Local server or a plain file the user's own CLI wrote. Read without asking.
    case automatic
    /// Reads another app's Keychain item; macOS shows its own access prompt.
    case keychainConsent
    /// User signs in once in an embedded web view; session cookies live in our Keychain.
    case webLogin(URL)
    /// User pastes an official API key; stored in our Keychain.
    case apiKey
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
    var windows: [UsageWindow] = []
    var local: LocalStats?
    var activity: Activity = .idle
    var sessions: [ActiveSessionInfo] = []
    /// One-line figure for providers without a quota, e.g. "Hoy: 1,2 M tokens · 0,84 US$".
    var summary: String?
    /// Last fetch error; the row keeps showing stale data alongside it.
    var error: String?

    /// Worst window drives the menu bar readout.
    var peakUsage: Double? { windows.map(\.used).max() }
}

extension ProviderUsage {
    /// Connectors start from their info and fill in the rest.
    init(info: ProviderInfo) {
        self.init(id: info.id, name: info.name, kind: info.kind, iconURL: info.iconURL)
    }
}
