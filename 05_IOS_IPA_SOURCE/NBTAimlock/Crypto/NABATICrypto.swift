import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Security
import CryptoKit

public final class NABATICrypto {
    public static let shared = NABATICrypto()
    private init() {}

    private let serviceName = NBTF.K.keychainService
    private let keyHardwareId = "nbt_secure_hwid_v4"
    private let keySessionToken = "nbt_session_token_v4"
    private let keyActiveLicense = "nbt_active_license_v4"

    /// Account names used by the previous Objective-C build. It shared our
    /// keychain service but wrote different account names, so an upgrade from
    /// that build otherwise reads an empty vault and looks like a new device.
    enum LegacyAccount {
        static let hardwareId = "nbt_hwid_v5"
        static let sessionToken = "nbt_session_v5"
        static let licenseKey = "nbt_key_v5"
    }

    // MARK: - Hardware UUID Management
    private let hardwareIdLock = NSLock()
    private var cachedHardwareId: String?

    /// Returns the identifier this device already registered with, and only mints
    /// a new one when there genuinely is none to reuse.
    ///
    /// The order is chosen around one fact: every paying customer who exists
    /// today registered through the previous Objective-C build, so the value the
    /// server has bound is the one *that* build wrote. Any other order hands
    /// those customers a new identity and burns a device slot — the exact lockout
    /// this fixes.
    ///
    /// 1. `nbt_hwid_v5` (the previous build's account, same keychain service).
    /// 2. `NSUserDefaults` under that name — the legacy build mirrored its ID
    ///    there, and that store survives a re-sign that changes the keychain
    ///    access group.
    /// 3. This build's own account, for anyone who already registered with it.
    /// 4. `identifierForVendor`, which is also what the legacy build used. It is
    ///    keyed to (team, bundle-id) rather than to the keychain, so it is the
    ///    only value that still resolves after a re-sign wipes the keychain.
    /// 5. A random UUID, persisted for the next launch.
    ///
    /// Memoised because `NABATIDevice.hardwareId` is read while building every
    /// verify and heartbeat request; resolving it each time would mean keychain
    /// traffic on every network call.
    public func getOrCreateHardwareUUID() -> String {
        // One critical section for the whole resolution. Two threads resolving at
        // once on first launch could otherwise mint two different random UUIDs,
        // and the loser would register the device with an identity that is then
        // overwritten — the same "new device" problem this method exists to avoid.
        hardwareIdLock.lock()
        defer { hardwareIdLock.unlock() }
        if let cached = cachedHardwareId { return cached }
        let resolved = resolveHardwareId()
        cachedHardwareId = resolved
        return resolved
    }

    private func resolveHardwareId() -> String {
        if let legacy = loadString(key: LegacyAccount.hardwareId), !legacy.isEmpty {
            persistHardwareId(legacy)
            return legacy
        }
        for legacyKey in [LegacyAccount.hardwareId, keyHardwareId] {
            if let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty {
                persistHardwareId(legacy)
                return legacy
            }
        }
        if let existing = loadString(key: keyHardwareId), !existing.isEmpty {
            persistHardwareId(existing)
            return existing
        }
        #if canImport(UIKit)
        if let vendor = UIDevice.current.identifierForVendor?.uuidString, !vendor.isEmpty {
            let idfvBased = "NBT-IOS-" + vendor.uppercased()
            persistHardwareId(idfvBased)
            return idfvBased
        }
        #endif
        let newUUID = "NBT-IOS-" + UUID().uuidString.uppercased()
        persistHardwareId(newUUID)
        return newUUID
    }

    /// Stores the device identity in both places on purpose.
    ///
    /// The keychain is the durable store, but it is scoped to the app's keychain
    /// access group — and ESign/Sideloadly issue a *different* group when they
    /// re-sign. Everything in the keychain disappears at that point, while
    /// `NSUserDefaults` lives in the app container and is untouched. Writing the
    /// identity here is what makes it survive a re-sign, which is precisely when
    /// a customer must not be treated as a new device.
    ///
    /// Only the identifier is mirrored. Session tokens and license keys stay in
    /// the keychain, so a re-sign costs the customer a re-entry of the KEY but
    /// never a device slot.
    private func persistHardwareId(_ value: String) {
        UserDefaults.standard.set(value, forKey: keyHardwareId)
        saveString(key: keyHardwareId, value: value)
    }

    // MARK: - Session Token Storage
    public func saveSessionToken(_ token: String) {
        saveString(key: keySessionToken, value: token)
    }

    public func getSessionToken() -> String? {
        if let token = loadString(key: keySessionToken), !token.isEmpty {
            return token
        }
        if let legacy = loadString(key: LegacyAccount.sessionToken), !legacy.isEmpty {
            saveString(key: keySessionToken, value: legacy)
            return legacy
        }
        if let legacy = UserDefaults.standard.string(forKey: LegacyAccount.sessionToken), !legacy.isEmpty {
            saveString(key: keySessionToken, value: legacy)
            return legacy
        }
        return nil
    }

    public func clearSessionToken() {
        deleteKey(key: keySessionToken)
        deleteKey(key: LegacyAccount.sessionToken)
    }

    // MARK: - Active License Storage
    public func saveActiveLicenseKey(_ key: String) {
        saveString(key: keyActiveLicense, value: key)
    }

    public func getActiveLicenseKey() -> String? {
        if let key = loadString(key: keyActiveLicense), !key.isEmpty {
            return key
        }
        if let legacy = loadString(key: LegacyAccount.licenseKey), !legacy.isEmpty {
            saveString(key: keyActiveLicense, value: legacy)
            return legacy
        }
        if let legacy = UserDefaults.standard.string(forKey: LegacyAccount.licenseKey), !legacy.isEmpty {
            saveString(key: keyActiveLicense, value: legacy)
            return legacy
        }
        return nil
    }

    public func clearActiveLicenseKey() {
        deleteKey(key: keyActiveLicense)
        deleteKey(key: LegacyAccount.licenseKey)
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
