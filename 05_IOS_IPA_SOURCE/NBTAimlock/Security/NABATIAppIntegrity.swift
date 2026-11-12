import Foundation
import UIKit
import MachO
import CryptoKit
import Darwin

/// Layered code-integrity checks that complement `NABATISecurity`.
///
/// `NABATISecurity` already answers "is this process the app we shipped?" for the
/// obvious cases (injected dylib, rewritten bundle id, jailbreak files, attached
/// debugger). This type adds the two checks that specifically defeat a
/// *repackaged IPA* — the realistic attack against a sideloaded app:
///
///   1. **Self-hash of the `__TEXT` segment.** A patcher that flips opcodes or
///      NOPs out the authorization branch changes the `__TEXT` bytes. Comparing a
///      SHA-256 of that segment against a value stamped at build time detects it.
///      The expected value cannot be a literal in the same segment it protects
///      (it would change its own hash), so it is compared against the build's
///      recorded digest supplied via Info.plist, and a missing value simply
///      disables this one layer rather than failing the app open.
///
///   2. **Anti-hook mapping scan.** Beyond the dylib allowlist, this rejects a
///      process whose `__TEXT` is not mapped from the bundle on disk, which is
///      what a runtime patcher that reloads a modified image produces.
///
/// Both are advisory on their own: `NABATISecurity.isTampered` remains the single
/// gate that blocks the app, and it is fed by the hard evidence below. Ordinary
/// customers on ordinary iPhones never trip either check.
public final class NABATIAppIntegrity {
    public static let shared = NABATIAppIntegrity()
    private init() {}

    public struct Report {
        public let textSegmentHash: String?
        public let expectedTextHash: String?
        public let hashMatches: Bool
        public let imageMappedFromBundle: Bool
        /// Only signals a *hard* failure. A missing expected hash is not one:
        /// unsigned sideload builds legitimately have none, and treating that as
        /// tampering would lock out every customer who re-signs the IPA.
        public var blocksExecution: Bool {
            if expectedTextHash != nil && !hashMatches { return true }
            return !imageMappedFromBundle
        }
    }

    /// Runs both checks. Cheap enough to call at launch; the segment walk is a
    /// few hundred kilobytes of hashing on a cold start.
    public func inspect() -> Report {
        let expected = NABATIAppIntegrity.expectedTextHashFromInfoPlist()
        let actual = NABATIAppIntegrity.hashTextSegment()
        let mapped = NABATIAppIntegrity.isMainImageMappedFromBundle()

        let matches: Bool
        if let expected = expected, let actual = actual {
            matches = expected.caseInsensitiveCompare(actual) == .orderedSame
        } else {
            // No stamped value (unsigned/ad-hoc sideload) — this layer abstains.
            matches = true
        }

        return Report(
            textSegmentHash: actual,
            expectedTextHash: expected,
            hashMatches: matches,
            imageMappedFromBundle: mapped
        )
    }

    // MARK: - __TEXT self-hash

    /// SHA-256 of the `__TEXT` segment's file bytes.
    ///
    /// Reads through the already-loaded Mach-O headers rather than re-opening the
    /// executable, so the hash covers exactly what dyld mapped. Returns `nil` when
    /// the segment table cannot be walked rather than guessing.
    public static func hashTextSegment() -> String? {
        guard let header = _dyld_get_image_header(0) else { return nil }

        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        let commandCount = Int(header.pointee.ncmds)

        for _ in 0..<commandCount {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == LC_SEGMENT_64 {
                let segment = cursor.assumingMemoryBound(to: segment_command_64.self).pointee
                let name = withUnsafeBytes(of: segment.segname) { raw -> String in
                    let bytes = raw.prefix(while: { $0 != 0 })
                    return String(bytes: bytes, encoding: .utf8) ?? ""
                }
                if name == "__TEXT" {
                    let slide = Int(_dyld_get_image_vmaddr_slide(0))
                    // fileoff is 0 for __TEXT on a normal executable; the file
                    // bytes start at the image base minus the slide.
                    let base = UnsafeRawPointer(header).advanced(by: -slide + Int(segment.fileoff))
                    let size = Int(segment.filesize)
                    guard size > 0 else { return nil }
                    let buffer = UnsafeRawBufferPointer(start: base, count: size)
                    let digest = SHA256.hash(data: Data(buffer))
                    return digest.map { String(format: "%02x", $0) }.joined()
                }
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return nil
    }

    /// Optional build stamp written by CI into `Info.plist`
    /// (`NBATextSegmentSHA256`). Absent for unsigned builds on purpose.
    public static func expectedTextHashFromInfoPlist() -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "NBATextSegmentSHA256") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 64 else { return nil }
        return trimmed
    }

    // MARK: - Image provenance

    /// True when the main executable actually lives inside this bundle.
    ///
    /// A runtime patcher that swaps the image, or a build that was launched from
    /// a writable location outside the app container, fails this. The check
    /// compares the resolved `Bundle.main.executablePath` with the path dyld
    /// reports for image 0.
    public static func isMainImageMappedFromBundle() -> Bool {
        guard let bundleExec = Bundle.main.executablePath,
              let dyldPath = _dyld_get_image_name(0) else { return false }

        let resolvedBundle = URL(fileURLWithPath: bundleExec).resolvingSymlinksInPath().path
        let resolvedDyld = URL(fileURLWithPath: String(cString: dyldPath)).resolvingSymlinksInPath().path

        // The dyld path may be relative in some simulator configurations; only a
        // definite mismatch counts against the app.
        if resolvedDyld.isEmpty { return true }
        return resolvedBundle == resolvedDyld
    }

    // MARK: - Anti-hook nudge

    /// Re-runs the cheap hard checks right before a privileged action (unlock,
    /// feature authorization). A debugger can attach after launch, so a one-time
    /// launch check is not enough.
    ///
    /// Returns the list of hard failures, empty when the process still looks
    /// unmodified.
    public func hardFailuresNow() -> [String] {
        var failures: [String] = []

        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PID, getpid()]
        if sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 {
            if (info.kp_proc.p_flag & P_TRACED) != 0 {
                failures.append("DEBUGGER_ATTACHED")
            }
        }

        if let dyldInsert = getenv("DYLD_INSERT_LIBRARIES") {
            let value = String(cString: dyldInsert)
            if !value.isEmpty { failures.append("DYLD_INSERT_LIBRARIES_SET") }
        }

        let report = inspect()
        if report.blocksExecution {
            if !report.hashMatches { failures.append("TEXT_SEGMENT_MODIFIED") }
            if !report.imageMappedFromBundle { failures.append("IMAGE_OUTSIDE_BUNDLE") }
        }

        return failures
    }
}
