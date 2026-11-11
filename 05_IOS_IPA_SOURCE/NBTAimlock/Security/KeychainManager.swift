import Foundation
import Security
import UIKit

/// Cryptographically secure iOS Keychain service for NBTAIMLOCK
public final class KeychainManager {

    public static let shared = KeychainManager()
    private let serviceIdentifier = "com.nbtaimlock.ios.service"
    
    // Keychain keys
    public static let keySessionToken = "nbt_session_token"
    public static let keyVerifiedKey = "nbt_verified_key"
    public static let keyDeviceUUID = "nbt_device_uuid"
    public static let keyExpiresAt = "nbt_expires_at"

    private init() {}

    @discardableResult
    public func saveString(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(key: key, data: data)
    }

    public func loadString(key: String) -> String? {
        guard let data = load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(key: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    public func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }

    @discardableResult
    public func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    public func clearAll() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Returns persistent cryptographic hardware identifier for iOS
    public func getOrCreateDeviceUUID() -> String {
        if let existing = loadString(key: KeychainManager.keyDeviceUUID), !existing.isEmpty {
            return existing
        }

        var hardwareId = ""
        if let vendorId = UIDevice.current.identifierForVendor?.uuidString {
            hardwareId = "IOS_" + vendorId.replacingOccurrences(of: "-", with: "").uppercased()
        } else {
            hardwareId = "IOS_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).uppercased()
        }

        saveString(key: KeychainManager.keyDeviceUUID, value: hardwareId)
        return hardwareId
    }
}
