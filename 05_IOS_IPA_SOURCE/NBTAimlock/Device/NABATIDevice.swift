import Foundation
import UIKit

// MARK: - UIDevice Commercial Model Mapping
public extension UIDevice {
    static var machineIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    static var modelCommercialName: String {
        let id = machineIdentifier
        switch id {
        // iPhone 16 series
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone17,2": return "iPhone 16 Pro Max"
        case "iPhone17,3": return "iPhone 16"
        case "iPhone17,4": return "iPhone 16 Plus"

        // iPhone 15 series
        case "iPhone16,1": return "iPhone 15 Pro"
        case "iPhone16,2": return "iPhone 15 Pro Max"
        case "iPhone15,4": return "iPhone 15"
        case "iPhone15,5": return "iPhone 15 Plus"

        // iPhone 14 series
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        case "iPhone14,7": return "iPhone 14"
        case "iPhone14,8": return "iPhone 14 Plus"

        // iPhone 13 series
        case "iPhone14,2": return "iPhone 13 Pro"
        case "iPhone14,3": return "iPhone 13 Pro Max"
        case "iPhone14,5": return "iPhone 13"
        case "iPhone14,4": return "iPhone 13 mini"

        // iPhone 12 series
        case "iPhone13,3": return "iPhone 12 Pro"
        case "iPhone13,4": return "iPhone 12 Pro Max"
        case "iPhone13,2": return "iPhone 12"
        case "iPhone13,1": return "iPhone 12 mini"

        // iPhone 11 series
        case "iPhone12,1": return "iPhone 11"
        case "iPhone12,3": return "iPhone 11 Pro"
        case "iPhone12,5": return "iPhone 11 Pro Max"

        // iPhone XS / XR / X
        case "iPhone11,2": return "iPhone XS"
        case "iPhone11,4", "iPhone11,6": return "iPhone XS Max"
        case "iPhone11,8": return "iPhone XR"
        case "iPhone10,3", "iPhone10,6": return "iPhone X"

        // iPhone 8 / 7 / 6s / SE
        case "iPhone10,1", "iPhone10,4": return "iPhone 8"
        case "iPhone10,2", "iPhone10,5": return "iPhone 8 Plus"
        case "iPhone9,1", "iPhone9,3": return "iPhone 7"
        case "iPhone9,2", "iPhone9,4": return "iPhone 7 Plus"
        case "iPhone8,1": return "iPhone 6s"
        case "iPhone8,2": return "iPhone 6s Plus"
        case "iPhone8,4": return "iPhone SE (1st gen)"
        case "iPhone12,8": return "iPhone SE (2nd gen)"
        case "iPhone14,6": return "iPhone SE (3rd gen)"

        default:
            if id.hasPrefix("iPhone") {
                return "iPhone (\(id))"
            } else if id.hasPrefix("iPad") {
                return "iPad (\(id))"
            }
            return UIDevice.current.model
        }
    }
}

// MARK: - Confirmed device model (web-parity "chon dong may")
//
// The web client asks the customer to confirm their phone model and stores the
// confirmed name, which it then sends as `deviceName` so Admin shows a readable
// device label. iOS can detect the model itself, so the confirmed name defaults
// to the detected one — but the customer can still change it, which is what the
// web's "Doi dong may" button does.
//
// This affects the *label only*. Device binding, KEY validity and the device
// limit are decided by the server from `deviceId` (the hardware UUID), so
// renaming the model can never consume another device slot or bypass a check.
public enum NABATIPhoneCatalog {
    public struct Entry {
        public let brand: String
        public let name: String
    }

    public struct Normalized {
        public let valid: Bool
        public let canonicalName: String
        public let message: String
    }

    /// Mirrors the Apple section of `REAL_PHONE_DATABASE` in the web client so
    /// both clients suggest the same canonical names.
    public static let appleModels: [String] = [
        "iPhone 16 Pro Max", "iPhone 16 Pro", "iPhone 16 Plus", "iPhone 16",
        "iPhone 15 Pro Max", "iPhone 15 Pro", "iPhone 15 Plus", "iPhone 15",
        "iPhone 14 Pro Max", "iPhone 14 Pro", "iPhone 14 Plus", "iPhone 14",
        "iPhone 13 Pro Max", "iPhone 13 Pro", "iPhone 13", "iPhone 13 mini",
        "iPhone 12 Pro Max", "iPhone 12 Pro", "iPhone 12", "iPhone 12 mini",
        "iPhone 11 Pro Max", "iPhone 11 Pro", "iPhone 11",
        "iPhone XS Max", "iPhone XS", "iPhone XR", "iPhone X",
        "iPhone 8 Plus", "iPhone 8", "iPhone 7 Plus", "iPhone 7",
        "iPhone 6s Plus", "iPhone 6s",
        "iPhone SE (3rd gen)", "iPhone SE (2nd gen)", "iPhone SE",
        "iPad Pro", "iPad Air", "iPad mini", "iPad Gen 10", "iPad Gen 9"
    ]

    public static var entries: [Entry] {
        appleModels.map { Entry(brand: "Apple", name: $0) }
    }

    /// Case-insensitive substring filter over the catalogue, capped the way the
    /// web suggestion list is capped.
    public static func suggestions(for query: String, limit: Int = 40) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = q.isEmpty
            ? appleModels
            : appleModels.filter { $0.lowercased().contains(q) }
        return Array(matched.prefix(limit))
    }

    private static func ok(_ name: String) -> Normalized {
        Normalized(valid: true, canonicalName: name, message: "")
    }

    private static func bad(_ message: String) -> Normalized {
        Normalized(valid: false, canonicalName: "", message: message)
    }

    private static func groups(of pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var out: [String] = []
        for idx in 0..<match.numberOfRanges {
            let r = match.range(at: idx)
            if r.location == NSNotFound {
                out.append("")
            } else if let swiftRange = Range(r, in: text) {
                out.append(String(text[swiftRange]))
            } else {
                out.append("")
            }
        }
        return out
    }

    private static func titleCase(_ text: String) -> String {
        return text.split(separator: " ").map { word -> String in
            guard let first = word.first else { return "" }
            return String(first).uppercased() + String(word.dropFirst())
        }.joined(separator: " ")
    }

    /// Same rules the web client applies in `validateAndNormalizeRealPhone`,
    /// restricted to the Apple product line.
    public static func normalize(_ rawInput: String) -> Normalized {
        let collapsed = rawInput.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        let cleaned = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count < 2 || cleaned.count > 50 {
            return bad("Vui lòng nhập tên dòng điện thoại của bạn!")
        }
        let lower = cleaned.lowercased()

        for name in appleModels where name.lowercased() == lower {
            return ok(name)
        }

        if let g = groups(of: "^(?:ip|iphone)?\\s*(\\d+)\\s*(?:prm|promax|pro\\s*max)$", in: lower),
           g.count >= 2 {
            return ok("iPhone \(g[1]) Pro Max")
        }
        if groups(of: "^(?:ip|iphone)?\\s*xs\\s*max$", in: lower) != nil { return ok("iPhone XS Max") }
        if groups(of: "^(?:ip|iphone)?\\s*xs$", in: lower) != nil { return ok("iPhone XS") }
        if groups(of: "^(?:ip|iphone)?\\s*xr$", in: lower) != nil { return ok("iPhone XR") }
        if groups(of: "^(?:ip|iphone)?\\s*x$", in: lower) != nil { return ok("iPhone X") }

        if let g = groups(of: "^(?:ip|iphone)?\\s*(6s|7|8)\\s*(?:\\+|\\s*plus)$", in: lower),
           g.count >= 2 {
            return ok("iPhone \(g[1]) Plus")
        }

        if let g = groups(of: "^(?:ip|iphone)?\\s*(\\d{1,2})\\s*(pro\\s*max|pro|plus|\\+|mini)?$", in: cleaned),
           g.count >= 2 {
            var suffix = g[2].trimmingCharacters(in: .whitespaces)
            if suffix == "+" {
                suffix = "Plus"
            } else if !suffix.isEmpty {
                suffix = titleCase(
                    suffix.replacingOccurrences(of: "\\s*max", with: " Max", options: .regularExpression)
                )
            }
            return ok("iPhone \(g[1]) \(suffix)".trimmingCharacters(in: .whitespaces))
        }

        if groups(of: "^ipad\\s*(pro|air|mini|\\d+)?", in: lower) != nil {
            return ok(titleCase(cleaned))
        }

        if lower.contains("iphone") || lower.contains("ipad") {
            return ok(titleCase(cleaned))
        }

        if let g = groups(of: "^(?:s|galaxy\\s*s)?\\s*(\\d{2})\\s*(ultra|plus|\\+|fe)?$", in: lower),
           g.count >= 2 {
            var sfx = g[2].uppercased()
            if sfx == "+" { sfx = "Plus" }
            let name = ("Samsung Galaxy S\(g[1]) \(sfx)").trimmingCharacters(in: .whitespaces)
            return ok(name)
        }

        let known = "samsung|galaxy|xiaomi|redmi|poco|oppo|realme|oneplus|vivo|iqoo|rog|" +
                    "redmagic|red magic|tecno|infinix|pixel|huawei|honor|vsmart|sony|xperia|" +
                    "zte|nubia|black\\s*shark"
        if groups(of: "(\(known))", in: lower) != nil {
            return ok(titleCase(cleaned))
        }

        if cleaned.count >= 3,
           groups(of: "^[a-zA-Z0-9\\s\\.\\+\\-_]+$", in: cleaned) != nil {
            return ok(titleCase(cleaned))
        }

        return bad("Tên máy \"\(cleaned)\" không hợp lệ. Vui lòng nhập đúng tên máy của bạn.")
    }
}

// MARK: - NABATIDevice Management
public final class NABATIDevice {
    public static let shared = NABATIDevice()
    private static let confirmedModelKey = "NBTAIMLOCK_CONFIRMED_PHONE_MODEL_V1"
    private init() {}

    public var hardwareId: String {
        return NABATICrypto.shared.getOrCreateHardwareUUID()
    }

    /// The hardware model the OS reports. Never customer-editable: this is what
    /// the dashboard's hardware fact cell and `deviceModel` in the verify
    /// payload describe.
    public var modelName: String {
        return UIDevice.modelCommercialName
    }

    /// The model label the customer confirmed (or the detected model when they
    /// have not changed it). This is what the UI shows and what is sent as
    /// `deviceName`, matching the web client's `savedPhone`.
    public var displayModelName: String {
        let confirmed = UserDefaults.standard.string(forKey: NABATIDevice.confirmedModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return confirmed.isEmpty ? modelName : confirmed
    }

    /// Validates and stores the customer's model choice.
    /// - Returns: the canonical name, or `nil` when the input was rejected.
    @discardableResult
    public func confirmModelName(_ raw: String) -> String? {
        let result = NABATIPhoneCatalog.normalize(raw)
        guard result.valid, !result.canonicalName.isEmpty else { return nil }
        UserDefaults.standard.set(result.canonicalName, forKey: NABATIDevice.confirmedModelKey)
        return result.canonicalName
    }

    public var hasConfirmedModelName: Bool {
        let confirmed = UserDefaults.standard.string(forKey: NABATIDevice.confirmedModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !confirmed.isEmpty
    }

    public var systemVersion: String {
        return UIDevice.current.systemVersion
    }

    public var machineId: String {
        return UIDevice.machineIdentifier
    }

    public var formattedInfoSummary: String {
        return "\(modelName) • iOS \(systemVersion)"
    }
}
