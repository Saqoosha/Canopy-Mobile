import Foundation
import Security

/// Copied from Pager's `KeychainHelper` — same shape, different service
/// string so the two apps' Keychain items never collide. Diagnostics log
/// only the key name and an `OSStatus`, never the value being stored or
/// read.
enum KeychainHelper {
    private static let service = "sh.saqoo.canopy-mobile"

    @discardableResult
    static func save(key: String, value: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else {
            NSLog("KeychainHelper.save: utf8 encoding failed for key=%@", key)
            return errSecParam
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let delStatus = SecItemDelete(query as CFDictionary)
        if delStatus != errSecSuccess && delStatus != errSecItemNotFound {
            NSLog("KeychainHelper.save: SecItemDelete status=%d key=%@", delStatus, key)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            NSLog("KeychainHelper.save: SecItemAdd failed status=%d key=%@", addStatus, key)
        }
        return addStatus
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a value is stored under `key` — never reads it back. Exists
    /// so a caller (the Settings "A secret is stored" indicator) can tell
    /// the user something is there without revealing it or seeding a field
    /// with it.
    static func has(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
