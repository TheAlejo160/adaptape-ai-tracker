import Foundation
import Security

/// Generic-password Keychain access. Our own secrets (API keys, web session cookies) live under
/// one service; `readForeign` reads items other tools wrote (e.g. Claude Code's OAuth token).
enum KeychainStore {
    static let service = "com.thealejo.adaptapeaitracker"

    /// Updates in place so a failed write never destroys the working credential.
    static func save(_ data: Data, account: String) throws {
        let match = baseQuery(account: account)
        var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(account: String) -> Data? {
        read(service: service, account: account)
    }

    /// True when the item is gone afterwards (deleted now or never existed).
    @discardableResult
    static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Another app's item. macOS asks the user the first time; only call after they opted in.
    static func readForeign(service: String, account: String? = nil) -> Data? {
        read(service: service, account: account)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(service: String, account: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
