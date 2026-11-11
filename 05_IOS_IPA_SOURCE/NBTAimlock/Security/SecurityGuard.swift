import Foundation
import UIKit
import MachO
import CryptoKit
import QuartzCore
import Darwin

/// Multi-layer Anti-Tamper, Anti-Dylib & Security Verification System for iOS
public final class SecurityGuard {

    public static let shared = SecurityGuard()

    private init() {}

    /// Performs comprehensive integrity, anti-dylib & jailbreak assessment
    public func checkSecurityEnvironment() -> (isSecure: Bool, warnings: [String]) {
        var warnings: [String] = []

        #if !targetEnvironment(simulator)
        if hasJailbreakFiles() {
            warnings.append("SUSPICIOUS_SYSTEM_BINARIES_DETECTED")
        }
        if canWriteOutsideSandbox() {
            warnings.append("SANDBOX_VIOLATION_WRITABLE_ROOT")
        }
        if canOpenJailbreakSchemes() {
            warnings.append("JAILBREAK_PACKAGE_MANAGER_FOUND")
        }
        if isDebuggerAttached() {
            warnings.append("ACTIVE_DEBUGGER_ATTACHED")
        }
        if hasHookingLibraries() {
            warnings.append("RUNTIME_INJECTION_FRAMEWORKS_FOUND")
        }
        if !checkBundleIntegrity() {
            warnings.append("REPACKAGED_BUNDLE_IDENTIFIER_MISMATCH")
        }
        if !checkCoreAssetsIntegrity() {
            warnings.append("TAMPERED_CORE_ASSETS_MISSING")
        }
        if !checkBundleDylibIntegrity() {
            warnings.append("UNAUTHORIZED_EMBEDDED_DYLIB_DETECTED")
        }
        if !checkRuntimeDylibAllowlist() {
            warnings.append("UNAUTHORIZED_RUNTIME_DYLIB_LOADED")
        }
        #endif

        return (warnings.isEmpty, warnings)
    }

    // MARK: - Jailbreak & Tamper Heuristics

    private func hasJailbreakFiles() -> Bool {
        let suspiciousPaths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/usr/bin/ssh",
            "/private/var/lib/apt/",
            "/private/var/lib/cydia",
            "/usr/lib/libsubstitute.dylib",
            "/usr/lib/libhooker.dylib",
            "/usr/lib/ellekit.dylib",
            "/var/jb",
            "/var/binpack"
        ]
        for path in suspiciousPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        return false
    }

    private func canWriteOutsideSandbox() -> Bool {
        let path = "/private/nbt_sec_sandbox_probe.txt"
        do {
            try "probe".write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    private func canOpenJailbreakSchemes() -> Bool {
        let schemes = ["cydia://", "sileo://", "zbra://"]
        for scheme in schemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                return true
            }
        }
        return false
    }

    private func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let junk = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        assert(junk == 0, "sysctl failed")
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    private func hasHookingLibraries() -> Bool {
        // 1. Check dynamic library injection environment variable
        if let dyldInsert = getenv("DYLD_INSERT_LIBRARIES"), String(cString: dyldInsert).count > 0 {
            return true
        }

        // 2. Scan loaded Mach-O images in memory for known hook engines
        let count = _dyld_image_count()
        for i in 0..<count {
            if let rawName = _dyld_get_image_name(i) {
                let name = String(cString: rawName).lowercased()
                if name.contains("substrate") || name.contains("cycript") || name.contains("frida")
                    || name.contains("substitute") || name.contains("libhooker") || name.contains("ellekit")
                    || name.contains("cynject") || name.contains("preferenceloader") || name.contains("shadow") {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Anti-Dylib Protection (Bundle & Runtime)

    /// Case A: Inspects IPA bundle directory for rogue embedded dylibs or frameworks
    public func checkBundleDylibIntegrity() -> Bool {
        guard let bundlePath = Bundle.main.resourcePath else { return false }
        let fileManager = FileManager.default

        // The official NBTAimlock app has zero external embedded dynamic frameworks
        let frameworksPath = (bundlePath as NSString).appendingPathComponent("Frameworks")
        if fileManager.fileExists(atPath: frameworksPath) {
            do {
                let items = try fileManager.contentsOfDirectory(atPath: frameworksPath)
                let dylibs = items.filter { $0.hasSuffix(".dylib") || $0.hasSuffix(".framework") }
                if !dylibs.isEmpty {
                    // Rogue dylibs or frameworks were injected into Frameworks directory!
                    return false
                }
            } catch {
                return false
            }
        }

        // Check for rogue .dylib files placed directly in app root
        do {
            let rootItems = try fileManager.contentsOfDirectory(atPath: bundlePath)
            let rootDylibs = rootItems.filter { $0.hasSuffix(".dylib") }
            if !rootDylibs.isEmpty {
                return false
            }
        } catch {
            return false
        }

        return true
    }

    /// Case B: Enforces strict allowlist of loaded Mach-O dynamic images at runtime
    public func checkRuntimeDylibAllowlist() -> Bool {
        let count = _dyld_image_count()
        guard let mainExec = Bundle.main.executablePath else { return true }
        let mainExecLower = mainExec.lowercased()
        guard let bundlePath = Bundle.main.resourcePath?.lowercased() else { return true }

        for i in 0..<count {
            guard let rawName = _dyld_get_image_name(i) else { continue }
            let path = String(cString: rawName)
            let lower = path.lowercased()

            // 1. Legitimate iOS System Frameworks & Libraries
            if lower.hasPrefix("/system/library/") || lower.hasPrefix("/usr/lib/") {
                continue
            }

            // 2. Xcode Developer Debug/Simulator Image (during active test)
            if lower.hasPrefix("/developer/") {
                continue
            }

            // 3. The app's own compiled Mach-O binary
            if lower == mainExecLower {
                continue
            }

            // 4. Any other loaded image is an unauthorized injection!
            // (e.g. Sideloadly injected dylib inside app bundle, or tweak in /var/, /Library/MobileSubstrate/)
            return false
        }

        return true
    }

    /// Monotonic timestamp helper (immune to user device clock manipulation)
    public func currentMonotonicSeconds() -> Double {
        return CACurrentMediaTime()
    }

    public static let expectedBundleIdentifier = "com.nbtaimlock.ios"

    public func checkBundleIntegrity() -> Bool {
        guard let currentId = Bundle.main.bundleIdentifier else { return false }
        return currentId == SecurityGuard.expectedBundleIdentifier
    }

    public func checkCoreAssetsIntegrity() -> Bool {
        guard let _ = Bundle.main.path(forResource: "Info", ofType: "plist") else { return false }
        let hasEncryptedApp = Bundle.main.path(forResource: "app", ofType: "dat") != nil ||
                              Bundle.main.path(forResource: "app", ofType: "dat", inDirectory: "www") != nil
        let hasLegacyIndex = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: "www") != nil
        return hasEncryptedApp || hasLegacyIndex
    }

    /// Verifies SHA-256 integrity of protected package against signed assets_manifest.json
    public func checkAssetsManifestIntegrity() -> Bool {
        guard let bundlePath = Bundle.main.resourcePath else { return true }
        let manifestPath = (bundlePath as NSString).appendingPathComponent("www/assets_manifest.json")
        let appDatPath = Bundle.main.path(forResource: "app", ofType: "dat") ?? (bundlePath as NSString).appendingPathComponent("app.dat")

        guard FileManager.default.fileExists(atPath: manifestPath),
              FileManager.default.fileExists(atPath: appDatPath),
              let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let json = try? JSONSerialization.jsonObject(with: manifestData, options: []) as? [String: Any],
              let assets = json["assets"] as? [String: Any],
              let appMeta = assets["app.dat"] as? [String: Any],
              let expectedSha = appMeta["sha256"] as? String,
              let appData = try? Data(contentsOf: URL(fileURLWithPath: appDatPath)) else {
            return true
        }

        if #available(iOS 13.0, *) {
            let digest = SHA256.hash(data: appData)
            let actualSha = digest.map { String(format: "%02x", $0) }.joined()
            return actualSha.lowercased() == expectedSha.lowercased()
        }
        return true
    }

    // MARK: - In-Memory AES-256-GCM Secure Decryption Loader

    /// Derives 256-bit symmetric vault key using dual XOR masking (prevents static strings extraction)
    private func getVaultKey() -> SymmetricKey {
        let maskA: [UInt8] = [
            0x4e, 0x42, 0x54, 0x5f, 0x41, 0x49, 0x4d, 0x4c,
            0x4f, 0x43, 0x4b, 0x5f, 0x53, 0x45, 0x43, 0x55,
            0x52, 0x45, 0x5f, 0x56, 0x41, 0x55, 0x4c, 0x54,
            0x5f, 0x32, 0x30, 0x32, 0x36, 0x5f, 0x4b, 0x45
        ]
        let maskB: [UInt8] = [
            0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
            0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
            0x13, 0x57, 0x9b, 0xdf, 0x24, 0x68, 0xac, 0xe0
        ]
        var combined = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            combined[i] = maskA[i] ^ maskB[i]
        }
        let digest = SHA256.hash(data: Data(combined))
        return SymmetricKey(data: digest)
    }

    /// Decrypts encrypted app.dat entirely in RAM and returns UTF-8 HTML string
    /// Guarantees that decrypted HTML is NEVER written to file system, sandbox or cache
    public func decryptSecurePayload(data: Data) -> String? {
        guard data.count > 32 else { return nil }

        // Magic header check: 'NBT1' (4 bytes)
        let magic = data.subdata(in: 0..<4)
        guard magic == Data([0x4e, 0x42, 0x54, 0x31]) else { return nil }

        let nonceData = data.subdata(in: 4..<16)
        let tagData = data.subdata(in: 16..<32)
        let ciphertextData = data.subdata(in: 32..<data.count)

        if #available(iOS 13.0, *) {
            do {
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: tagData)
                let key = getVaultKey()
                let decryptedData = try AES.GCM.open(sealedBox, using: key)
                return String(data: decryptedData, encoding: .utf8)
            } catch {
                return nil
            }
        }
        return nil
    }
}
