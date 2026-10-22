import Foundation
import os

struct GeminiConnector: UsageConnector {
    private static let logger = Logger(subsystem: KeychainStore.service, category: "Gemini")
    let info = ProviderInfo(id: "gemini", name: "Gemini", kind: .cloud,
                            iconURL: ProviderInfo.simpleIcon("googlegemini"), auth: .optionalKeychainConsent)

    nonisolated func fetch() async throws -> ProviderUsage? {
        let credentials = LocalFiles.home(".gemini/oauth_creds.json")
        let antigravity = [LocalFiles.home(".gemini/antigravity-cli"), LocalFiles.home(".gemini/antigravity"),
                           LocalFiles.home("Library/Application Support/Antigravity")]
        let installed = ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", LocalFiles.home(".local/bin/agy").path]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
            || antigravity.contains { FileManager.default.fileExists(atPath: $0.path) }
        let keychainEnabled = UserDefaults.standard.stringArray(forKey: "enabledConnectors")?.contains(info.id) == true
        let keyring = keychainEnabled ? KeychainStore.readForeign(service: "gemini", account: "antigravity") : nil
        return try await fetch(credentials: credentials, keyring: keyring, chats: LocalFiles.home(".gemini/tmp"),
                               antigravity: antigravity, installed: installed, cliExecutable: AntigravityCLIQuota.executable)
    }

    func fetch(credentials: URL, keyring: Data? = nil, chats: URL, antigravity: [URL], installed: Bool,
               cliExecutable: URL? = nil) async throws -> ProviderUsage? {
        guard installed || keyring != nil || FileManager.default.fileExists(atPath: credentials.path) else { return nil }
        let now = Date()
        var usage: ProviderUsage
        do {
            var local: ProviderUsage?
            if let cliExecutable {
                do {
                    local = try await QuotaCache.shared.usage(id: "agy-cli:\(cliExecutable.path)", minInterval: 300, cooldownID: "gemini-cli") {
                        try await AntigravityCLIQuota.fetch(executable: cliExecutable)
                    }
                    Self.logger.info("quota source=agy-cli windows=\(local?.windows.count ?? 0)")
                } catch is CancellationError { throw CancellationError() }
                catch ConnectorError.rateLimited(let delay) { throw ConnectorError.rateLimited(retryAfter: delay) }
                catch { Self.logger.info("agy quota unavailable; checking remote source") }
            }
            // Antigravity first: agy refreshes its keyring token while it runs; Gemini CLI's file only when `gemini` runs.
            // Token checked inside the cache: once it expires (1 h after agy last ran) the row keeps the
            // last quota, marked stale with the «agy» hint, instead of going blank.
            if let local {
                usage = local
            } else if let keyring {
                usage = try await QuotaCache.shared.usage(id: "antigravity:\(keyring.hashValue)", minInterval: 300, cooldownID: "gemini") {
                    try await self.antigravityUsage(token: Self.antigravityToken(keyring, now: now))
                }
            } else {
                guard FileManager.default.fileExists(atPath: credentials.path) else {
                    throw ConnectorError.credentialsUnavailable(hint: "Para leer la sesión de «agy», activa «API de Gemini» en Cuentas › Permisos opcionales del Llavero (desactiva y activa si ya está habilitado) o inicia sesión con «gemini».")
                }
                let data = try LocalFiles.head(credentials)
                usage = try await QuotaCache.shared.usage(id: "gemini:\(data.hashValue)", minInterval: 300, cooldownID: "gemini") {
                    let token = try Self.accessToken(data, now: now)
                    Self.logger.debug("credential source=Gemini-CLI-file tokenBytes=\(token.utf8.count)")
                    let headers = ["Authorization": "Bearer \(token)"]
                    let load = try await HTTP.post(URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!,
                        headers: headers, jsonBody: Data(#"{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8))
                    let account = try LocalFiles.json(load)
                    guard let project = account["cloudaicompanionProject"] as? String, !project.isEmpty else {
                        throw ConnectorError.unexpectedResponse("proyecto de Gemini; abre «gemini» para configurar la cuenta")
                    }
                    let quota = try await HTTP.post(URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
                        headers: headers, jsonBody: JSONSerialization.data(withJSONObject: ["project": project]))
                    return try self.parse(quota, account: load)
                }
            }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { throw CancellationError() }
            usage = ProviderUsage(info: info)
            usage.error = error.localizedDescription
        }
        let files = LocalFiles.sessionFiles(in: chats).filter { $0.url.deletingLastPathComponent().lastPathComponent == "chats" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        usage.sessions = files.filter { now.timeIntervalSince($0.modified) < LocalFiles.openSessionAge }.map { file in
            let root = file.url.deletingLastPathComponent().deletingLastPathComponent()
            let cwd = (try? LocalFiles.head(root.appendingPathComponent(".project_root")))
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            let name = LocalFiles.projectName(cwd: cwd) ?? formatter.string(from: file.created)
            return ActiveSessionInfo(id: file.url.path, title: "Gemini CLI · \(name)", startedAt: file.created)
        }
        var newest = files.first?.modified
        for directory in antigravity {
            let local = antigravitySessions(in: directory, now: now)
            usage.sessions += local.sessions
            if let date = local.newest, date > (newest ?? .distantPast) { newest = date }
        }
        if let file = files.first, newest == file.modified {
            usage.recentModel = (try? LocalFiles.tail(file.url)).flatMap(LocalFiles.recentModel)
        } else if let log = antigravity.first.map({ $0.appendingPathComponent("cli.log") }) {
            usage.recentModel = (try? LocalFiles.tail(log)).flatMap(Self.antigravityModel)
        }
        usage.sessions.sort { $0.startedAt > $1.startedAt }
        // One exhausted model pool (e.g. Claude in Antigravity) must not flag the whole row as limited.
        let limiting = usage.windows.allSatisfy { $0.used >= 1 } ? usage.windows : []
        usage.activity = LocalFiles.activity(windows: limiting, newest: newest, now: now)
        return usage
    }

    /// Value agy stores via go-keyring: "go-keyring-base64:<base64 JSON>" (or the JSON itself).
    static func antigravityToken(_ data: Data, now: Date) throws -> String {
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("go-keyring-base64:") {
            text = String(decoding: Data(base64Encoded: String(text.dropFirst(18))) ?? Data(), as: UTF8.self)
        }
        let token = (try LocalFiles.json(Data(text.utf8)))["token"] as? [String: Any]
        if let expiry = LocalFiles.date(token?["expiry"]), expiry <= now {
            throw ConnectorError.expired(hint: "ejecuta «agy» una vez para renovar la sesión")
        }
        guard let access = token?["access_token"] as? String, !access.isEmpty else { throw ConnectorError.unauthorized }
        logger.debug("credential source=agy-keychain tokenBytes=\(access.utf8.count) expiry=\(LocalFiles.date(token?["expiry"])?.timeIntervalSince1970 ?? 0)")
        return access
    }

    func antigravityUsage(token: String,
        request: (@Sendable (String, Data) async throws -> Data)? = nil) async throws -> ProviderUsage {
        let send: @Sendable (String, Data) async throws -> Data = request ?? { method, body in
            try await HTTP.post(URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:\(method)")!,
                headers: ["Authorization": "Bearer \(token)"], jsonBody: body)
        }
        var account = Data("{}".utf8)
        do {
            let loaded = try await send("loadCodeAssist", Data(#"{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8))
            _ = try LocalFiles.json(loaded)
            account = loaded
        } catch let error as ConnectorError where Self.canTryAlternative(error) {
            Self.logger.info("loadCodeAssist unavailable; quota will be queried independently")
        }
        let project = (try? LocalFiles.json(account))?["cloudaicompanionProject"] as? String
        let body = try JSONSerialization.data(withJSONObject: project.map { ["project": $0] } ?? [:])
        do {
            return try parseQuotaSummary(await send("retrieveUserQuotaSummary", body), account: account)
        } catch let error as ConnectorError where Self.canTryAlternative(error) {
            Self.logger.info("quota summary unavailable; trying model quotas")
        }
        return try parseAvailableModels(await send("fetchAvailableModels", Data("{}".utf8)), account: account)
    }

    static func canTryAlternative(_ error: ConnectorError) -> Bool {
        switch error {
        case .forbidden, .googleForbidden, .unexpectedResponse, .http(404), .http(405): true
        default: false
        }
    }

    /// Models sharing one quota pool (same fraction and reset) collapse into one bar labelled by family.
    /// proto3 JSON omits zero values, so a pool with a reset but no `remainingFraction` is exhausted.
    func parseAvailableModels(_ data: Data, account: Data) throws -> ProviderUsage {
        guard let models = try LocalFiles.json(data)["models"] as? [String: Any] else {
            throw ConnectorError.unexpectedResponse("modelos de Antigravity")
        }
        var usage = ProviderUsage(info: info)
        usage.plan = Self.tierName(try LocalFiles.json(account))
        var pools: [String: (families: [String], used: Double, reset: Date?)] = [:]
        for (_, value) in models.sorted(by: { $0.key < $1.key }) {
            guard let model = value as? [String: Any], let name = model["displayName"] as? String, !name.isEmpty else { continue }
            if !usage.models.contains(name) { usage.models.append(name) }
            guard let quota = model["quotaInfo"] as? [String: Any] else { continue }
            let reset = LocalFiles.date(quota["resetTime"])
            guard let remaining = LocalFiles.number(quota["remainingFraction"]) ?? (reset != nil ? 0 : nil),
                  (0...1).contains(remaining) else { continue }
            let key = "\(remaining)|\(reset?.timeIntervalSince1970 ?? 0)"
            let family = String(name.split(separator: " ").first ?? Substring(name))
            var pool = pools[key] ?? ([], 1 - remaining, reset)
            if !pool.families.contains(family) { pool.families.append(family) }
            pools[key] = pool
        }
        usage.models.sort()
        for pool in pools.values.sorted(by: { ($0.families.first ?? "") < ($1.families.first ?? "") }) {
            var label = pool.families.joined(separator: " · ")
            while usage.windows.contains(where: { $0.label == label }) { label += " ·" }
            usage.windows.append(UsageWindow(label: label, used: pool.used, resetsAt: pool.reset))
        }
        if usage.windows.isEmpty { usage.summary = "La cuenta no devuelve cuotas por modelo" }
        return usage
    }

    /// "g1-pro-tier" → "AI Pro". The paid tier wins over the free tier the account also keeps.
    static func tierName(_ account: [String: Any]) -> String? {
        for key in ["paidTier", "currentTier"] {
            guard let tier = account[key] as? [String: Any] else { continue }
            if let name = tier["name"] as? String, !name.isEmpty { return name }
            switch tier["id"] as? String {
            case "g1-pro-tier"?: return "AI Pro"
            case "g1-ultra-tier"?: return "AI Ultra"
            case "free-tier"?: return "Free"
            case "standard-tier"?: return "Standard"
            case let id? where !id.isEmpty: return id
            default: continue
            }
        }
        return nil
    }

    /// Last model agy selected, from its log line `… model override to backend: label="Gemini 3.8 Flash (High)"`.
    static func antigravityModel(_ log: Data) -> String? {
        let text = String(decoding: log, as: UTF8.self)
        guard let range = text.range(of: #"model override to backend: label="[^"]+""#, options: [.regularExpression, .backwards]) else { return nil }
        return text[range].split(separator: "\"").dropFirst().first.map(String.init)
    }

    static func accessToken(_ data: Data, now: Date) throws -> String {
        let object = try LocalFiles.json(data)
        if let expiry = LocalFiles.number(object["expiry_date"]), expiry / 1000 <= now.timeIntervalSince1970 {
            throw ConnectorError.expired(hint: "ejecuta «gemini» una vez para renovar la sesión")
        }
        guard let token = object["access_token"] as? String, !token.isEmpty else { throw ConnectorError.unauthorized }
        return token
    }

    func parse(_ data: Data, account: Data) throws -> ProviderUsage {
        let object = try LocalFiles.json(data)
        let account = try LocalFiles.json(account)
        guard let buckets = object["buckets"] as? [[String: Any]] else {
            throw ConnectorError.unexpectedResponse("cuotas por modelo de Gemini")
        }
        var usage = ProviderUsage(info: info)
        usage.plan = Self.tierName(account)
        for bucket in buckets {
            guard let model = bucket["modelId"] as? String, !model.isEmpty else { continue }
            if !usage.models.contains(model) { usage.models.append(model) }
            guard let remaining = LocalFiles.number(bucket["remainingFraction"]), (0...1).contains(remaining) else { continue }
            let type = bucket["tokenType"] as? String
            let label = modelName(model) + (type.map { " · \($0)" } ?? "")
            let window = UsageWindow(label: label, used: 1 - remaining,
                                     resetsAt: LocalFiles.date(bucket["resetTime"]), duration: 86_400)
            if let index = usage.windows.firstIndex(where: { $0.label == label }) {
                if window.used > usage.windows[index].used { usage.windows[index] = window }
            } else { usage.windows.append(window) }
        }
        if usage.windows.isEmpty { usage.summary = "La cuenta no devuelve cuotas por modelo" }
        return usage
    }

    func antigravitySessions(in directory: URL, now: Date) -> (sessions: [ActiveSessionInfo], newest: Date?) {
        let database = directory.appendingPathComponent("conversation_summaries.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return ([], nil) }
        let threshold = Int64(now.addingTimeInterval(-LocalFiles.openSessionAge).timeIntervalSince1970)
        guard let rows = try? LocalFiles.query(database, sql: """
            SELECT conversation_id, title, workspace_uris, strftime('%s', last_modified_time) AS updated
            FROM conversation_summaries WHERE killed = 0 AND strftime('%s', last_modified_time) >= '\(threshold)'
            ORDER BY last_modified_time DESC LIMIT 50
            """) else { return ([], nil) }
        var newest: Date?
        let sessions = rows.compactMap { row -> ActiveSessionInfo? in
            guard let id = row["conversation_id"], UUID(uuidString: id) != nil,
                  let updated = row["updated"].flatMap(Double.init) else { return nil }
            let modified = Date(timeIntervalSince1970: updated)
            if modified > (newest ?? .distantPast) { newest = modified }
            let uris = row["workspace_uris"].flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
            let project = uris?.first.flatMap { URL(string: $0) }.flatMap { LocalFiles.projectName(cwd: $0.path) }
            let file = directory.appendingPathComponent("conversations/\(id).db")
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? modified
            return ActiveSessionInfo(id: database.path + ":" + id, title: "Antigravity · \(project ?? row["title"] ?? "Conversación")",
                                     startedAt: created)
        }
        return (sessions, newest)
    }
}
