import Foundation
import Security
import CryptoKit

public final class NABATICrypto {
    public static let shared = NABATICrypto()
    private init() {}

    private let serviceName = "com.nbtaimlock.ios.vault"
    private let keyHardwareId = "nbt_secure_hwid_v4"
    private let keySessionToken = "nbt_session_token_v4"
    private let keyActiveLicense = "nbt_active_license_v4"

    // MARK: - Hardware UUID Management
    public func getOrCreateHardwareUUID() -> String {
        if let existing = loadString(key: keyHardwareId), !existing.isEmpty {
            return existing
        }
        let newUUID = "NBT-IOS-" + UUID().uuidString.uppercased()
        saveString(key: keyHardwareId, value: newUUID)
        return newUUID
    }

    // MARK: - Session Token Storage
    public func saveSessionToken(_ token: String) {
        saveString(key: keySessionToken, value: token)
    }

    public func getSessionToken() -> String? {
        return loadString(key: keySessionToken)
    }

    public func clearSessionToken() {
        deleteKey(key: keySessionToken)
    }

    // MARK: - Active License Storage
    public func saveActiveLicenseKey(_ key: String) {
        saveString(key: keyActiveLicense, value: key)
    }

    public func getActiveLicenseKey() -> String? {
        return loadString(key: keyActiveLicense)
    }

    public func clearActiveLicenseKey() {
        deleteKey(key: keyActiveLicense)
    }

    // MARK: - Generic Keychain Helpers
    private func saveString(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        deleteKey(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadString(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKey(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Cryptographic Utilities
    public func sha256Hex(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func generateSecureNonce(length: Int = 16) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status == errSecSuccess {
            return Data(bytes).map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
