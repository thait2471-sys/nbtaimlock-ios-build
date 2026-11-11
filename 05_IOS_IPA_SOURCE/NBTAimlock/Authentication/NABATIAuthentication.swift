import Foundation

public struct NABATISessionInfo {
    public let key: String
    public let maskedKey: String
    public let sessionToken: String
    public let planType: String
    public let remainingDays: Int
    public let expiresAt: String
    public let boundDevice: String
}

/// Result of a server-side KEY verification.
///
/// `failure(Error)` is reserved for transport / malformed-payload problems. The
/// server's own rejection always arrives as `.rejected` so callers can
/// distinguish "the server said no" from "we could not ask the server".
public enum NABATIVerifyOutcome {
    case authorized(NABATISessionInfo)
    case rejected(message: String, code: String)
    /// The server is in maintenance/update mode. This is NOT a KEY verdict: the
    /// stored KEY must be preserved and the customer must not be treated as
    /// unauthorised.
    case paused(message: String)
}

/// Result of a heartbeat / session revalidation.
public enum NABATIHeartbeatOutcome {
    case valid(expiresAt: Double?, remainingText: String)
    case rejected(message: String, code: String)
    /// Server-confirmed maintenance window. Keep the session, pause the features.
    case paused(message: String)
    /// No answer from the server after all attempts: a state that must never be
    /// silently upgraded to "valid".
    case unreachable(message: String)
}

/// The Worker answers maintenance with `SERVICE_MAINTENANCE`. Detect it so it is
/// never confused with an invalid/revoked license.
func isMaintenanceResponse(_ payload: [String: Any]) -> Bool {
    let code = ((payload["code"] as? String) ?? (payload["errorCode"] as? String) ?? "").uppercased()
    if code.contains("MAINTENANCE") { return true }
    if (payload["maintenance"] as? Bool) == true { return true }
    return false
}

public final class NABATIAuthentication {
    public static let shared = NABATIAuthentication()
    private init() {}

    private let maxHeartbeatAttempts = 3

    // MARK: - Verify

    public func verifyKey(licenseKey: String, completion: @escaping (Result<NABATIVerifyOutcome, Error>) -> Void) {
        let cleanedKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            completion(.success(.rejected(message: "Vui lòng nhập mã kích hoạt key!", code: "KEY_REQUIRED")))
            return
        }

        // The Worker reads `body.key`; `licenseKey` is only kept as a secondary
        // field for older deployments that have not been updated yet.
        let body: [String: Any] = [
            "key": cleanedKey,
            "deviceId": NABATIDevice.shared.hardwareId,
            "deviceName": NABATIDevice.shared.modelName,
            "clientPlatform": NABATIAppVersion.clientPlatform,
            "platform": NABATIAppVersion.platform,
            "appVersion": NABATIAppVersion.version,
            "clientVersion": NABATIAppVersion.version,
            "deviceModel": NABATIDevice.shared.modelName,
            "osVersion": NABATIDevice.shared.systemVersion
        ]

        NABATINetwork.shared.post(endpoint: "/api/verify", body: body) { result in
            switch result {
            case .success(let json):
                let success = json["success"] as? Bool ?? (json["valid"] as? Bool ?? false)
                guard success else {
                    if isMaintenanceResponse(json) {
                        let message = json["message"] as? String ?? "Hệ thống đang bảo trì. Vui lòng quay lại sau."
                        completion(.success(.paused(message: message)))
                        return
                    }
                    let message = json["message"] as? String ?? json["error"] as? String ?? "Mã key không hợp lệ hoặc đã hết hạn!"
                    let code = json["code"] as? String ?? json["errorCode"] as? String ?? "KEY_INVALID"
                    completion(.success(.rejected(message: message, code: code)))
                    return
                }

                // Server authority: a session token is mandatory. We never invent one;
                // a session the server does not know would fail every heartbeat anyway.
                guard let token = (json["sessionToken"] as? String) ?? (json["token"] as? String),
                      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    completion(.success(.rejected(
                        message: "Máy chủ không cấp phiên xác thực hợp lệ. Vui lòng thử lại hoặc liên hệ hỗ trợ.",
                        code: "SESSION_TOKEN_MISSING"
                    )))
                    return
                }

                let masked = json["maskedKey"] as? String ?? "NBT-VIP-****"
                let plan = json["plan"] as? String ?? json["planType"] as? String ?? "VIP"
                let remaining = json["remainingDays"] as? Int
                    ?? json["daysRemaining"] as? Int
                    ?? self.remainingDays(from: json)
                let exp = self.expiresAtString(json["expiresAt"])

                NABATICrypto.shared.saveSessionToken(token)
                NABATICrypto.shared.saveActiveLicenseKey(cleanedKey)

                let session = NABATISessionInfo(
                    key: cleanedKey,
                    maskedKey: masked,
                    sessionToken: token,
                    planType: plan,
                    remainingDays: remaining,
                    expiresAt: exp,
                    boundDevice: NABATIDevice.shared.modelName
                )
                completion(.success(.authorized(session)))

            case .failure(let error):
                if let netError = error as? NABATINetworkError, netError.isServerVerdict {
                    // The server answered and refused: it is a real verdict.
                    let payload = netError.payload ?? [:]
                    if isMaintenanceResponse(payload) {
                        let message = payload["message"] as? String ?? "Hệ thống đang bảo trì. Vui lòng quay lại sau."
                        completion(.success(.paused(message: message)))
                        return
                    }
                    let code = payload["code"] as? String ?? payload["errorCode"] as? String ?? "SERVER_REJECTED"
                    let message = payload["message"] as? String ?? netError.localizedDescription
                    completion(.success(.rejected(message: message, code: code)))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Heartbeat

    /// Revalidates the stored session against the server.
    ///
    /// Retries transient transport failures, then reports `.unreachable`. It never
    /// reports `.valid` without a positive server answer.
    public func checkHeartbeat(completion: @escaping (NABATIHeartbeatOutcome) -> Void) {
        guard let token = NABATICrypto.shared.getSessionToken(), !token.isEmpty else {
            completion(.rejected(message: "Phiên sử dụng không tồn tại. Vui lòng nhập KEY.", code: "SESSION_MISSING"))
            return
        }
        guard let key = NABATICrypto.shared.getActiveLicenseKey(), !key.isEmpty else {
            completion(.rejected(message: "Không tìm thấy KEY đã lưu. Vui lòng nhập lại KEY.", code: "KEY_MISSING"))
            return
        }

        let body: [String: Any] = [
            "key": key,
            "deviceId": NABATIDevice.shared.hardwareId,
            "sessionToken": token,
            "clientPlatform": NABATIAppVersion.clientPlatform,
            "platform": NABATIAppVersion.platform,
            "appVersion": NABATIAppVersion.version,
            "clientVersion": NABATIAppVersion.version
        ]

        attemptHeartbeat(body: body, attempt: 1, completion: completion)
    }

    private func attemptHeartbeat(body: [String: Any], attempt: Int, completion: @escaping (NABATIHeartbeatOutcome) -> Void) {
        NABATINetwork.shared.post(endpoint: "/api/heartbeat", body: body) { result in
            switch result {
            case .success(let json):
                let valid = json["valid"] as? Bool ?? (json["success"] as? Bool ?? false)
                if valid {
                    let expires = (json["expiresAt"] as? NSNumber)?.doubleValue
                    completion(.valid(expiresAt: expires, remainingText: (json["remainingText"] as? String) ?? ""))
                } else if isMaintenanceResponse(json) {
                    let message = json["message"] as? String ?? "Hệ thống đang bảo trì. Vui lòng quay lại sau."
                    completion(.paused(message: message))
                } else {
                    let code = json["code"] as? String ?? "HEARTBEAT_REJECTED"
                    let message = json["message"] as? String ?? "Phiên sử dụng đã hết hạn hoặc không hợp lệ."
                    completion(.rejected(message: message, code: code))
                }

            case .failure(let error):
                if let netError = error as? NABATINetworkError, netError.isServerVerdict {
                    let payload = netError.payload ?? [:]
                    if isMaintenanceResponse(payload) {
                        let message = payload["message"] as? String ?? "Hệ thống đang bảo trì. Vui lòng quay lại sau."
                        completion(.paused(message: message))
                        return
                    }
                    let code = payload["code"] as? String ?? "HEARTBEAT_REJECTED"
                    let message = payload["message"] as? String ?? netError.localizedDescription
                    completion(.rejected(message: message, code: code))
                    return
                }

                // Transport failure: retry, then fail closed. Never "true".
                if attempt < self.maxHeartbeatAttempts {
                    let delay = Double(attempt) * 2.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.attemptHeartbeat(body: body, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    completion(.unreachable(message: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Logout

    public func logout() {
        NABATICrypto.shared.clearSessionToken()
        NABATICrypto.shared.clearActiveLicenseKey()
    }

    // MARK: - Helpers

    private func remainingDays(from json: [String: Any]) -> Int {
        guard let expires = (json["expiresAt"] as? NSNumber)?.doubleValue else { return 0 }
        let millis = expires > 100_000_000_000 ? expires : expires * 1000
        let days = Int(((millis - Date().timeIntervalSince1970 * 1000) / 86_400_000).rounded(.up))
        return max(0, days)
    }

    private func expiresAtString(_ value: Any?) -> String {
        if let s = value as? String { return s }
        guard let n = (value as? NSNumber)?.doubleValue, n > 0 else { return "—" }
        let millis = n > 100_000_000_000 ? n : n * 1000
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: millis / 1000))
    }
}
