import Foundation

struct CursorConnector: UsageConnector {
    let info = ProviderInfo(id: "cursor", name: "Cursor", kind: .codeAssistant,
                            iconURL: ProviderInfo.lobeIcon("cursor"))

    nonisolated func fetch() async throws -> ProviderUsage? {
        let database = LocalFiles.home("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let rows = try LocalFiles.query(database, sql: """
            SELECT key, value FROM ItemTable WHERE key IN
            ('cursorAuth/accessToken','cursorAuth/cachedEmail','cursorAuth/stripeMembershipType')
            """
        )
        let values = Dictionary(rows.compactMap { row -> (String, String)? in
            guard let key = row["key"], let value = row["value"] else { return nil }
            return (key, value)
        }, uniquingKeysWith: { _, latest in latest })
        guard let token = values["cursorAuth/accessToken"], let user = Self.userID(token) else {
            throw ConnectorError.unauthorized
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ";&=+%:#? /\r\n")
        guard let user = user.addingPercentEncoding(withAllowedCharacters: allowed),
              let escapedToken = token.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ConnectorError.unauthorized
        }
        let data = try await HTTP.get(URL(string: "https://cursor.com/api/usage-summary")!, headers: [
            "Cookie": "WorkosCursorSessionToken=\(user)%3A%3A\(escapedToken)"
        ])
        var usage = try parse(data)
        usage.plan = values["cursorAuth/stripeMembershipType"] ?? usage.plan
        return usage
    }

    static func userID(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let object = try? LocalFiles.json(data),
              let sub = object["sub"] as? String,
              let user = sub.split(separator: "|", omittingEmptySubsequences: false).last, !user.isEmpty else { return nil }
        return String(user)
    }

    func parse(_ data: Data) throws -> ProviderUsage {
        let object = try LocalFiles.json(data)
        guard let individual = object["individualUsage"] as? [String: Any],
              let plan = individual["plan"] as? [String: Any] else {
            throw ConnectorError.unexpectedResponse("plan de Cursor")
        }
        let used = LocalFiles.number(plan["used"])
        let limit = LocalFiles.number(plan["limit"])
        let percent = LocalFiles.number(plan["totalPercentUsed"])
            ?? used.flatMap { used in limit.flatMap { $0 > 0 ? used / $0 * 100 : nil } }
        guard let percent else { throw ConnectorError.unexpectedResponse("cuota de Cursor") }
        var usage = ProviderUsage(info: info)
        usage.plan = object["membershipType"] as? String
        // Free plans report limit 0; a "0 / 0" detail would read as broken.
        let detail = used.flatMap { used in limit.flatMap { $0 > 0 ? "\(used.formatted()) / \($0.formatted())" : nil } }
        usage.windows = [UsageWindow(label: "Plan mensual", used: LocalFiles.fraction(percent),
                                     resetsAt: LocalFiles.date(object["billingCycleEnd"]), detail: detail)]
        usage.activity = LocalFiles.activity(windows: usage.windows, newest: nil, now: Date())
        return usage
    }
}
