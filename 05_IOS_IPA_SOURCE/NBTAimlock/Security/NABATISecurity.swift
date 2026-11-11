import Foundation
import UIKit
import MachO
import QuartzCore
import Darwin

public final class NABATISecurity {
    public static let shared = NABATISecurity()
    private init() {}

    public static let expectedBundleIdentifier = "com.nbtaimlock.ios"

    public struct SecurityStatus {
        public let isSecure: Bool
        public let warnings: [String]

        /// Warnings that prove the bundle was modified by someone other than us,
        /// rather than merely suggesting the device is unusual.
        ///
        /// The distinction matters: jailbreak heuristics produce false positives
        /// on ordinary carrier/enterprise setups, and locking a paying customer
        /// out over a heuristic is worse than the tampering it guesses at. These
        /// two cannot be produced by a normal install — the bundle identifier is
        /// baked into the binary, and an unexpected loaded dylib means code was
        /// injected into this process.
        public var isTampered: Bool {
            warnings.contains("REPACKAGED_BUNDLE_IDENTIFIER_MISMATCH")
                || warnings.contains("RUNTIME_INJECTION_FRAMEWORKS_FOUND")
                || warnings.contains("UNAUTHORIZED_RUNTIME_DYLIB_LOADED")
        }
    }

    /// Performs comprehensive integrity and runtime security assessment
    public func checkSecurityEnvironment() -> SecurityStatus {
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
        if !checkBundleDylibIntegrity() {
            warnings.append("UNAUTHORIZED_EMBEDDED_DYLIB_DETECTED")
        }
        if !checkRuntimeDylibAllowlist() {
            warnings.append("UNAUTHORIZED_RUNTIME_DYLIB_LOADED")
        }
        #endif

        return SecurityStatus(isSecure: warnings.isEmpty, warnings: warnings)
    }

    // MARK: - Jailbreak Detection Heuristics
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
        if let dyldInsert = getenv("DYLD_INSERT_LIBRARIES"), String(cString: dyldInsert).count > 0 {
            return true
        }
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

    public func checkBundleDylibIntegrity() -> Bool {
        guard let bundlePath = Bundle.main.resourcePath else { return false }
        let fileManager = FileManager.default
        let frameworksPath = (bundlePath as NSString).appendingPathComponent("Frameworks")
        if fileManager.fileExists(atPath: frameworksPath) {
            do {
                let items = try fileManager.contentsOfDirectory(atPath: frameworksPath)
                let dylibs = items.filter { $0.hasSuffix(".dylib") || $0.hasSuffix(".framework") }
                if !dylibs.isEmpty { return false }
            } catch {
                return false
            }
        }
        return true
    }

    public func checkRuntimeDylibAllowlist() -> Bool {
        let count = _dyld_image_count()
        guard let mainExec = Bundle.main.executablePath?.lowercased() else { return true }

        for i in 0..<count {
            guard let rawName = _dyld_get_image_name(i) else { continue }
            let path = String(cString: rawName).lowercased()
            if path.hasPrefix("/system/library/") || path.hasPrefix("/usr/lib/") || path.hasPrefix("/developer/") || path == mainExec {
                continue
            }
            return false
        }
        return true
    }

    public func checkBundleIntegrity() -> Bool {
        guard let currentId = Bundle.main.bundleIdentifier else { return false }
        return currentId == NABATISecurity.expectedBundleIdentifier
    }

    /// Whether a specific warning indicates an environment that cannot be
    /// trusted to run unmodified — used to enforce (fail closed) on hard
    /// evidence while only warning on jailbreak heuristics.
    public func warningIsTampering(_ warning: String) -> Bool {
        warning == "REPACKAGED_BUNDLE_IDENTIFIER_MISMATCH"
            || warning == "RUNTIME_INJECTION_FRAMEWORKS_FOUND"
            || warning == "UNAUTHORIZED_RUNTIME_DYLIB_LOADED"
    }

    public func currentMonotonicSeconds() -> Double {
        return CACurrentMediaTime()
    }
}
