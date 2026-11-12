import Foundation

/// Server-reported release metadata for this platform.
public struct NABATIReleaseInfo {
    public let version: String
    public let buildNumber: String
    public let downloadUrl: String
    public let releaseNotes: String
    public let publishedAt: Double
    public let sha256: String
    public let fileSize: Int
    public let minSupportedVersion: String
    public let forceUpdate: Bool
    public let belowMinimum: Bool
}

/// Server-reported service state, scoped to the iOS platform by the Worker.
public struct NABATIServiceState {
    public let mode: String          // "online" | "maintenance" | "updating"
    public let applies: Bool
    public let active: Bool
    public let title: String
    public let content: String
    public let estimatedEndAt: Double?
    public let retryEnabled: Bool
    public let blockAuth: Bool
    public let updateCenterEnabled: Bool

    public var isMaintenance: Bool { mode != "online" && applies && active }
    /// A maintenance window that actually blocks authentication on the server.
    public var blocksAuthentication: Bool { isMaintenance && blockAuth }
    public var modeLabel: String {
        switch mode {
        case "updating": return "HỆ THỐNG ĐANG CẬP NHẬT"
        case "maintenance": return "HỆ THỐNG ĐANG BẢO TRÌ"
        default: return "ONLINE"
        }
    }
}

/// Combined snapshot returned by GET /api/service-status.
public struct NABATIServiceStatus {
    public let state: NABATIServiceState
    public let update: NABATIReleaseInfo?

    /// The client must show a blocking gate (cannot proceed to key verification).
    public var isBlocking: Bool {
        if state.blocksAuthentication { return true }
        if let update = update, update.forceUpdate { return true }
        return false
    }

    public var showsNotice: Bool {
        state.isMaintenance || update != nil
    }

    // MARK: - Parsing

    public static func parse(_ json: [String: Any]) -> NABATIServiceStatus? {
        guard (json["success"] as? Bool) == true else { return nil }
        guard let stateObj = json["state"] as? [String: Any] else { return nil }

        let mode = (stateObj["mode"] as? String) ?? "online"
        let state = NABATIServiceState(
            mode: mode,
            applies: (stateObj["applies"] as? Bool) ?? (mode != "online"),
            active: (stateObj["active"] as? Bool) ?? (mode != "online"),
            title: (stateObj["title"] as? String) ?? "NABATI AIMLOCK ĐANG BẢO TRÌ",
            content: (stateObj["content"] as? String)
                ?? "Hệ thống hiện đang trong quá trình cập nhật và bảo trì. Vui lòng quay lại sau.",
            estimatedEndAt: numberOrNil(stateObj["estimatedEndAt"]),
            // Fail-safe defaults: if the server omits a flag we assume the stricter
            // behaviour (retry allowed, auth blocked) rather than an open door.
            retryEnabled: (stateObj["retryEnabled"] as? Bool) ?? true,
            blockAuth: (stateObj["blockAuth"] as? Bool) ?? true,
            updateCenterEnabled: (stateObj["updateCenterEnabled"] as? Bool) ?? true
        )

        var release: NABATIReleaseInfo? = nil
        if let updateObj = json["update"] as? [String: Any],
           (updateObj["available"] as? Bool) == true {
            let downloadUrl = (updateObj["downloadUrl"] as? String) ?? ""
            // Never surface a download link that is not HTTPS: the UI would offer a
            // button that either does nothing or opens an unsafe target.
            if isHttps(downloadUrl) || downloadUrl.isEmpty {
                release = NABATIReleaseInfo(
                    version: (updateObj["version"] as? String) ?? "",
                    buildNumber: (updateObj["buildNumber"] as? String) ?? "",
                    downloadUrl: isHttps(downloadUrl) ? downloadUrl : "",
                    releaseNotes: (updateObj["releaseNotes"] as? String) ?? "",
                    publishedAt: numberOrNil(updateObj["publishedAt"]) ?? 0,
                    sha256: (updateObj["sha256"] as? String) ?? "",
                    fileSize: Int(numberOrNil(updateObj["fileSize"]) ?? 0),
                    minSupportedVersion: (updateObj["minSupportedVersion"] as? String) ?? "",
                    forceUpdate: (updateObj["forceUpdate"] as? Bool) ?? false,
                    belowMinimum: (updateObj["belowMinimum"] as? Bool) ?? false
                )
            }
        }

        return NABATIServiceStatus(state: state, update: release)
    }

    private static func isHttps(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        return url.scheme?.lowercased() == "https" && (url.host?.isEmpty == false)
    }

    private static func numberOrNil(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}

/// Fetch layer for the public service status endpoint.
public final class NABATIServiceClient {
    public static let shared = NABATIServiceClient()
    private init() {}

    /// Fetches platform-scoped service status.
    /// - Parameter completion: `.success` only when the server produced a valid
    ///   snapshot. Any transport or payload failure is returned as `.failure` so
    ///   callers never treat an unreachable server as "online" or "maintenance".
    public func fetchStatus(completion: @escaping (Result<NABATIServiceStatus, Error>) -> Void) {
        NABATINetwork.shared.get(
            endpoint: NBTF.K.apiServiceStatus,
            query: [
                "platform": NABATIAppVersion.platform,
                "version": NABATIAppVersion.version,
                "build": NABATIAppVersion.build
            ]
        ) { result in
            switch result {
            case .success(let json):
                if let parsed = NABATIServiceStatus.parse(json) {
                    completion(.success(parsed))
                } else {
                    completion(.failure(NABATINetworkError.invalidPayload))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}
