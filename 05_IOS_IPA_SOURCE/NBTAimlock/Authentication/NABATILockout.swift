import Foundation

/// The server's brute-force guard for this device.
///
/// `/api/verify` already refuses a locked device, so this type adds no security
/// of its own — it exists so the KEY screen can say *why* the button is dead and
/// for how long, instead of showing a generic rejection. The countdown is a
/// display of the server's `remainingSeconds`, never a local timer that could
/// re-enable the button early.
public struct NABATILockoutState {
    public let isLockedOut: Bool
    public let failedCount: Int
    public let remainingSeconds: Int
    public let maxAttempts: Int

    public var remainingText: String {
        let total = max(0, remainingSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    public var attemptsLeft: Int {
        max(0, maxAttempts - failedCount)
    }
}

/// Reads `POST /api/lockout-status` for this device.
///
/// A transport failure returns `nil` rather than "not locked": the screen then
/// leaves the button enabled and lets `/api/verify` deliver the real verdict.
/// Guessing "unlocked" is harmless here (the server still enforces it); guessing
/// "locked" would lock a paying customer out of their own app on a flaky network.
public enum NABATILockoutClient {
    public static func fetch(completion: @escaping (NABATILockoutState?) -> Void) {
        let body: [String: Any] = ["deviceId": NABATIDevice.shared.hardwareId]

        NABATINetwork.shared.post(endpoint: NBTF.K.apiLockoutStatus, body: body) { result in
            guard case .success(let json) = result, (json["success"] as? Bool) == true else {
                completion(nil)
                return
            }

            let locked = (json["isLockedOut"] as? Bool) ?? false
            let failed = (json["failedCount"] as? NSNumber)?.intValue ?? 0
            let remaining = (json["remainingSeconds"] as? NSNumber)?.intValue ?? 0
            let maximum = (json["maxAttempts"] as? NSNumber)?.intValue ?? 5

            completion(NABATILockoutState(
                isLockedOut: locked,
                failedCount: max(0, failed),
                remainingSeconds: max(0, remaining),
                maxAttempts: maximum > 0 ? maximum : 5
            ))
        }
    }
}
