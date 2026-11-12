import Foundation

/// Runtime string de-obfuscation.
///
/// The iOS app ships as a stripped Mach-O, but stripping removes symbols, not
/// the `__cstring` section. A repackaged IPA is therefore patched by grepping
/// the binary for "/api/license/authorize", "/api/heartbeat" or the keychain
/// service name and rewriting the bytes that follow. Keeping those literals as
/// XOR-masked arrays (generated into `NABATIObfuscationTables.swift`) means a
/// `strings` dump finds nothing recognisable and a patch has to reverse the
/// mask first.
///
/// This is obfuscation, not encryption, and deliberately so: a key compiled into
/// the app is a key an attacker has. Nothing here is a secret — no signing key,
/// no admin key, no database credential is on the device. The only authority in
/// this system is the server, which re-validates the KEY, the device and the
/// session on every authentication, heartbeat and feature authorization.
///
/// The mask is a deterministic SHA-256 keystream derived from the plaintext, so
/// regenerating the tables produces identical output (diffable in review) and no
/// secret needs to exist for the build to work.
public enum NBTF {

    /// Recovers a literal from its `(cipher, mask)` pair.
    ///
    /// Both arrays are the same length; a mismatch means the generated table was
    /// edited by hand and the result would be garbage, so it returns an empty
    /// string and callers treat that as a configuration failure.
    public static func decode(_ cipher: [UInt8], _ mask: [UInt8]) -> String {
        guard cipher.count == mask.count, !cipher.isEmpty else { return "" }
        var bytes = [UInt8](repeating: 0, count: cipher.count)
        for i in 0..<cipher.count {
            bytes[i] = cipher[i] ^ mask[i]
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    // MARK: - Obfuscated literals used by the network and storage layers

    public enum K {
        public static var apiVerify: String {
            decode(NABATIObfuscationTables.apiVerifyCipher, NABATIObfuscationTables.apiVerifyMask)
        }
        public static var apiHeartbeat: String {
            decode(NABATIObfuscationTables.apiHeartbeatCipher, NABATIObfuscationTables.apiHeartbeatMask)
        }
        public static var apiAuthorize: String {
            decode(NABATIObfuscationTables.apiAuthorizeCipher, NABATIObfuscationTables.apiAuthorizeMask)
        }
        public static var apiConfig: String {
            decode(NABATIObfuscationTables.apiConfigCipher, NABATIObfuscationTables.apiConfigMask)
        }
        public static var apiServiceStatus: String {
            decode(NABATIObfuscationTables.apiServiceStatusCipher, NABATIObfuscationTables.apiServiceStatusMask)
        }
        public static var apiLockoutStatus: String {
            decode(NABATIObfuscationTables.apiLockoutStatusCipher, NABATIObfuscationTables.apiLockoutStatusMask)
        }
        public static var apiAnnouncement: String {
            decode(NABATIObfuscationTables.apiAnnouncementCipher, NABATIObfuscationTables.apiAnnouncementMask)
        }
        public static var apiSensitivity: String {
            decode(NABATIObfuscationTables.apiSensitivityCipher, NABATIObfuscationTables.apiSensitivityMask)
        }

        public static var apiLegal: String {
            decode(NABATIObfuscationTables.apiLegalCipher, NABATIObfuscationTables.apiLegalMask)
        }

        public static var installManifestPath: String {
            decode(NABATIObfuscationTables.installManifestPathCipher, NABATIObfuscationTables.installManifestPathMask)
        }
        public static var keychainService: String {
            decode(NABATIObfuscationTables.keychainServiceCipher, NABATIObfuscationTables.keychainServiceMask)
        }
        public static var baseURL: String {
            decode(NABATIObfuscationTables.baseURLCipher, NABATIObfuscationTables.baseURLMask)
        }
        public static var clientPlatform: String {
            decode(NABATIObfuscationTables.clientPlatformCipher, NABATIObfuscationTables.clientPlatformMask)
        }
    }
}
