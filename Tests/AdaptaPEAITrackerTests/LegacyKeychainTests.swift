import Foundation
import Security
import Testing
@testable import AdaptaPEAITracker

@Test func legacyKeychainInteractionIsScopedAndRestoredOnFailure() throws {
    var original: DarwinBoolean = false
    #expect(SecKeychainGetUserInteractionAllowed(&original) == errSecSuccess)
    for allowed in [false, true] {
        let observed = try KeychainStore.withInteractionAllowed(allowed) {
            var current: DarwinBoolean = false
            #expect(SecKeychainGetUserInteractionAllowed(&current) == errSecSuccess)
            return current.boolValue
        }
        #expect(observed == allowed)
        var restored: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
        #expect(restored.boolValue == original.boolValue)
    }
    #expect(throws: ConnectorError.self) {
        try KeychainStore.withInteractionAllowed(false) { throw ConnectorError.http(503) }
    }
    var restored: DarwinBoolean = false
    #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
    #expect(restored.boolValue == original.boolValue)
}
