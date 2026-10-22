import Foundation
import Security
import LocalAuthentication
import os

enum KeychainStore {
    static let service = "com.thealejo.adaptapeaitracker"
    private static let logger = Logger(subsystem: service, category: "Keychain")
    private static let interactionLock = NSLock()

    /// Polling must never open a password dialog. Interaction is reserved for the Accounts toggle.
    static func readForeign(service: String, account: String? = nil, allowInteraction: Bool = false) -> Data? {
        try? withInteractionAllowed(allowInteraction) {
            let query = query(service: service, account: account, allowInteraction: allowInteraction)
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            let data = status == errSecSuccess ? result as? Data : nil
            logger.info("read source=SecItemCopyMatching service=\(service, privacy: .public) interactive=\(allowInteraction) status=\(status) bytes=\(data?.count ?? 0)")
            return data
        }
    }

    static func withInteractionAllowed<T>(_ allowed: Bool, operation: () throws -> T) throws -> T {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        // Legacy login-keychain ACLs ignore LAContext; this flag is process-wide, so serialize and restore it.
        var previous: DarwinBoolean = false
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else {
            logger.error("interaction readStatus=\(readStatus)")
            throw ConnectorError.unexpectedResponse("control de interacción del Llavero")
        }
        let status = SecKeychainSetUserInteractionAllowed(allowed)
        guard status == errSecSuccess else {
            logger.error("interaction setStatus=\(status)")
            throw ConnectorError.unexpectedResponse("control de interacción del Llavero")
        }
        defer {
            let restored = SecKeychainSetUserInteractionAllowed(previous.boolValue)
            if restored != errSecSuccess { logger.error("interaction restoreStatus=\(restored)") }
        }
        return try operation()
    }

    static func query(service: String, account: String?, allowInteraction: Bool) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    static func requestAccess(providerID: String) {
        switch providerID {
        case "claude": _ = readForeign(service: "Claude Code-credentials", allowInteraction: true)
        case "gemini": _ = readForeign(service: "gemini", account: "antigravity", allowInteraction: true)
        default: break
        }
    }
}
