import Foundation
import Security

/// Read-only Keychain access. The app stores NOTHING of its own; it only reads items that other
/// tools already saved (e.g. Claude Code's OAuth token). macOS shows its own prompt the first time.
enum KeychainStore {
    /// Subsystem name reused for os.Logger categories.
    static let service = "com.thealejo.adaptapeaitracker"

    /// Another app's generic-password item. Only call for `.keychainConsent` providers the user opted in.
    static func readForeign(service: String, account: String? = nil) -> Data? {
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
