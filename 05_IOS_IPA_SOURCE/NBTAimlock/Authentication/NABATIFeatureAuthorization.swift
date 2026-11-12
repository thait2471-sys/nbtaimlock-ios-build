import Foundation

/// Server authorization for a single feature module.
///
/// The web client turns a toggle on only after `POST /api/license/authorize`
/// returns `authorized: true`. This is the same contract: the KEY, the bound
/// device and the session are re-checked server-side on *every* activation, so a
/// modified client cannot switch a module on by editing local state alone —
/// there is no local state that grants permission, only what the server returned
/// for this request.
///
/// ## Why the signature is stored but not verified here
///
/// The Worker signs the payload with HMAC-SHA256 under `LICENSE_SIGNING_SECRET`.
/// HMAC verification needs the secret itself, and compiling that secret into the
/// app would hand every attacker the ability to mint their own "authorized"
/// payload — the exact bypass this module exists to prevent. So the app treats
/// the signature as an opaque server artefact and instead performs the checks a
/// client *can* perform without holding any secret:
///
///   * the `nonce` must be the one this request generated (not a replay),
///   * `deviceId` must be this device,
///   * `featureId` must be the module that was asked for,
///   * `timestamp` must be recent.
///
/// Every one of those values came back through a response the server produced
/// while re-validating the KEY and the device. A tampered client can fake them
/// only by faking the whole HTTPS response, which is out of scope for the
/// threat model this app is defending against (repackaged IPA, local state
/// edits, airplane-mode unlock).
public enum NABATIFeatureAuthError: Error, LocalizedError {
    case notUnlocked
    case rejected(String)
    case transport(String)
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .notUnlocked:
            return "Vui lòng xác thực KEY trước khi bật chức năng!"
        case .rejected(let message):
            return message
        case .transport(let message):
            return "Không thể kết nối máy chủ xác thực. \(message)"
        case .invalidPayload(let message):
            return "Phản hồi máy chủ không hợp lệ. \(message)"
        }
    }
}

public struct NABATIFeatureGrant {
    public let featureId: String
    /// Opaque server payload. Kept for diagnostics and for a future
    /// server-side re-check endpoint; nothing in the UI trusts it directly.
    public let payload: [String: Any]
    public let signature: String
    public let grantedAt: Date
    /// Server-issued KEY expiry at the time of the grant. When the KEY is
    /// permanent this is `nil`.
    public let expiresAtMillis: Double?
}

public final class NABATIFeatureAuthorization {
    public static let shared = NABATIFeatureAuthorization()
    private init() {}

    /// Grants are held in memory only.
    ///
    /// Persisting them would let a customer relaunch the app with the network
    /// down and still see modules "on". The web client has the same property:
    /// `resetAllFeaturesToOff()` runs on every lock, and features are never
    /// written to storage.
    private var grants: [String: NABATIFeatureGrant] = [:]
    private let lock = NSLock()

    // MARK: - Local grant bookkeeping

    public func grant(for featureId: String) -> NABATIFeatureGrant? {
        lock.lock(); defer { lock.unlock() }
        return grants[featureId]
    }

    public func hasGrant(for featureId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return grants[featureId] != nil
    }

    /// Called on every lock transition (logout, revoke, expiry, maintenance
    /// pause, unreachable-heartbeat lockout). Clearing here is what guarantees a
    /// grant can never survive the session it was issued for.
    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        grants.removeAll()
    }

    /// Revokes one module's grant, used when the customer turns a toggle off.
    public func revoke(_ featureId: String) {
        lock.lock(); defer { lock.unlock() }
        grants.removeValue(forKey: featureId)
    }

    /// Fans a successful `"all"` grant out to each module id.
    ///
    /// `/api/license/authorize` echoes `featureId: "all"` for the bulk action, so
    /// the grant is stored under that key. Without this, every individual row
    /// would look unauthorized to `hasGrant(for:)` — a config refresh would
    /// switch all modules off, and turning one row off would not revoke anything
    /// the bulk grant covered. Copying the same server-issued grant to each id
    /// keeps one authorization event and one expiry for the whole set.
    public func widenAllGrant(to featureIds: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard let bulk = grants["all"] else { return }
        for id in featureIds where grants[id] == nil {
            grants[id] = NABATIFeatureGrant(
                featureId: id,
                payload: bulk.payload,
                signature: bulk.signature,
                grantedAt: bulk.grantedAt,
                expiresAtMillis: bulk.expiresAtMillis
            )
        }
    }

    private func store(_ grant: NABATIFeatureGrant) {
        lock.lock(); defer { lock.unlock() }
        grants[grant.featureId] = grant
    }

    // MARK: - Authorization call

    /// Requests authorization for one module, or `"all"` for the bulk action.
    public func authorize(
        featureId: String,
        completion: @escaping (Result<NABATIFeatureGrant, Error>) -> Void
    ) {
        guard let key = NABATICrypto.shared.getActiveLicenseKey(), !key.isEmpty else {
            completion(.failure(NABATIFeatureAuthError.notUnlocked))
            return
        }
        guard let token = NABATICrypto.shared.getSessionToken(), !token.isEmpty else {
            completion(.failure(NABATIFeatureAuthError.notUnlocked))
            return
        }

        // Echoed back by the Worker as `payload.nonce`; proves the reply belongs
        // to this request rather than a captured earlier one.
        let clientNonce = "nce_" + NABATICrypto.shared.generateSecureNonce(length: 12)
        let issuedAtMillis = Date().timeIntervalSince1970 * 1000
        let deviceId = NABATIDevice.shared.hardwareId

        let body: [String: Any] = [
            "key": key,
            "deviceId": deviceId,
            "sessionToken": token,
            "clientNonce": clientNonce,
            "featureId": featureId
        ]

        NABATINetwork.shared.post(endpoint: NBTF.K.apiAuthorize, body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let json):
                guard (json["authorized"] as? Bool) == true else {
                    let message = (json["message"] as? String) ?? "Không có quyền truy cập tính năng này!"
                    completion(.failure(NABATIFeatureAuthError.rejected(message)))
                    return
                }
                self.accept(
                    json: json,
                    requestedFeatureId: featureId,
                    expectedNonce: clientNonce,
                    expectedDeviceId: deviceId,
                    issuedAtMillis: issuedAtMillis,
                    completion: completion
                )

            case .failure(let error):
                if let netError = error as? NABATINetworkError, netError.isServerVerdict {
                    let payload = netError.payload ?? [:]
                    let message = (payload["message"] as? String)
                        ?? (payload["error"] as? String)
                        ?? netError.localizedDescription
                    completion(.failure(NABATIFeatureAuthError.rejected(message)))
                } else {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    completion(.failure(NABATIFeatureAuthError.transport(message)))
                }
            }
        }
    }

    /// Rejects a grant whose echoed values do not match this request.
    ///
    /// Anything the Worker did not actually issue for this device, this module
    /// and this nonce is discarded rather than shown as an activated module.
    private func accept(
        json: [String: Any],
        requestedFeatureId: String,
        expectedNonce: String,
        expectedDeviceId: String,
        issuedAtMillis: Double,
        completion: @escaping (Result<NABATIFeatureGrant, Error>) -> Void
    ) {
        guard let payload = json["payload"] as? [String: Any] else {
            completion(.failure(NABATIFeatureAuthError.invalidPayload("Thiếu dữ liệu uỷ quyền.")))
            return
        }

        let echoedNonce = (payload["nonce"] as? String) ?? ""
        guard !echoedNonce.isEmpty, echoedNonce == expectedNonce else {
            completion(.failure(NABATIFeatureAuthError.invalidPayload("Mã kiểm tra (nonce) không khớp.")))
            return
        }

        let echoedDevice = (payload["deviceId"] as? String) ?? ""
        guard echoedDevice.uppercased() == expectedDeviceId.uppercased() else {
            completion(.failure(NABATIFeatureAuthError.invalidPayload("Thiết bị trong uỷ quyền không khớp.")))
            return
        }

        let echoedFeature = (payload["featureId"] as? String) ?? ""
        guard echoedFeature == requestedFeatureId else {
            completion(.failure(NABATIFeatureAuthError.invalidPayload("Chức năng trong uỷ quyền không khớp.")))
            return
        }

        // A response cached by an intermediary, or replayed much later, must not
        // activate anything. The Worker stamps `timestamp` with `Date.now()`.
        if let raw = (payload["timestamp"] as? NSNumber)?.doubleValue {
            let stamp = raw > 100_000_000_000 ? raw : raw * 1000
            let skew = abs(issuedAtMillis - stamp)
            if skew > 120_000 {
                completion(.failure(NABATIFeatureAuthError.invalidPayload("Uỷ quyền đã quá cũ.")))
                return
            }
        }

        let expires = (payload["expiresAt"] as? NSNumber)?.doubleValue
        let grant = NABATIFeatureGrant(
            featureId: requestedFeatureId,
            payload: payload,
            signature: (json["signature"] as? String) ?? "",
            grantedAt: Date(),
            expiresAtMillis: expires.map { $0 > 100_000_000_000 ? $0 : $0 * 1000 }
        )
        store(grant)
        completion(.success(grant))
    }
}
