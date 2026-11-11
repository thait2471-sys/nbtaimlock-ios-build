import Foundation
import UIKit
import Combine

public enum NABATIAppState {
    case locked
    case verifying
    case authorized(NABATISessionInfo)
}

/// What the service gate currently wants to show on top of the app.
public enum NABATIServiceGateMode {
    case hidden
    case checking          // initial check in flight
    case connectionError   // server unreachable — never assumed to be maintenance
    case maintenance       // server confirmed maintenance for iOS
    case update            // server confirmed a new release for iOS
}

public final class NABATICore: ObservableObject {
    public static let shared = NABATICore()

    @Published public var appState: NABATIAppState = .locked
    @Published public var errorMessage: String? = nil
    @Published public var statusMessage: String? = nil

    // Service gate (server authority)
    @Published public var gateMode: NABATIServiceGateMode = .checking
    @Published public var gateErrorText: String? = nil
    @Published public var serviceStatus: NABATIServiceStatus? = nil
    @Published public var gateBusy: Bool = false

    // Sensitivity presets.
    //
    // These values are recommendations the customer enters into Free Fire's own
    // settings screen. The app never writes to another app's memory or process:
    // it only stores the preset locally and copies it to the clipboard so the
    // customer can paste the numbers while configuring the game.
    @Published public var selectedGameIndex: Int = 1 { didSet { persistPresets() } } // 0: FF Thường, 1: FF MAX
    @Published public var generalSensitivity: Double = 98.0 { didSet { persistPresets() } }
    @Published public var redDotSensitivity: Double = 95.0 { didSet { persistPresets() } }
    @Published public var scope2xSensitivity: Double = 92.0 { didSet { persistPresets() } }
    @Published public var scope4xSensitivity: Double = 90.0 { didSet { persistPresets() } }

    private static let presetStoreKey = "NBTAIMLOCK_SENSITIVITY_PRESET_V1"

    // Haptic feedback
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    /// True only while a verification round-trip is in flight.
    public var isVerifying: Bool {
        if case .verifying = appState { return true }
        return false
    }

    public var isAuthorized: Bool {
        if case .authorized = appState { return true }
        return false
    }

    /// True when the server has told us the app must not operate (maintenance
    /// that blocks auth, or a forced update).
    public var isGateBlocking: Bool {
        serviceStatus?.isBlocking ?? false
    }

    /// Whether the customer may close the current notice and keep using the app.
    /// Mirrors the server's own policy flags; a blocking gate is never dismissible.
    public var canDismissGate: Bool {
        switch gateMode {
        case .hidden, .checking, .connectionError:
            return false
        case .maintenance:
            let state = serviceStatus?.state
            if state?.blockAuth == false { return true }
            if state?.retryEnabled == false { return true }
            return false
        case .update:
            return !(serviceStatus?.update?.forceUpdate ?? false)
        }
    }

    private init() {
        restorePresets()
        // A cached Keychain session is NOT proof of authorization. It is only a
        // hint that lets us try a silent revalidation with the server. Until the
        // server confirms, the app stays locked.
        bootstrapSession()
    }

    // MARK: - Sensitivity preset persistence

    private func persistPresets() {
        UserDefaults.standard.set([
            "gameIndex": selectedGameIndex,
            "general": generalSensitivity,
            "redDot": redDotSensitivity,
            "scope2x": scope2xSensitivity,
            "scope4x": scope4xSensitivity
        ], forKey: NABATICore.presetStoreKey)
    }

    private func restorePresets() {
        guard let stored = UserDefaults.standard.dictionary(forKey: NABATICore.presetStoreKey) else { return }
        if let value = stored["gameIndex"] as? Int { selectedGameIndex = value }
        if let value = stored["general"] as? Double { generalSensitivity = value }
        if let value = stored["redDot"] as? Double { redDotSensitivity = value }
        if let value = stored["scope2x"] as? Double { scope2xSensitivity = value }
        if let value = stored["scope4x"] as? Double { scope4xSensitivity = value }
    }

    /// Human-readable preset that mirrors the numbers shown on screen, so the
    /// clipboard payload can never drift from the visible sliders.
    public var sensitivityConfigText: String {
        let mode = selectedGameIndex == 1 ? "Free Fire MAX" : "Free Fire"
        return """
        NABATI AIMLOCK — ĐỘ NHẠY GỢI Ý (\(mode))
        Nhìn xung quanh: \(Int(generalSensitivity))%
        Red Dot: \(Int(redDotSensitivity))%
        Ống ngắm 2x: \(Int(scope2xSensitivity))%
        Ống ngắm 4x: \(Int(scope4xSensitivity))%
        Nhập các giá trị trên vào Cài đặt > Độ nhạy trong game.
        """
    }

    // MARK: - Startup bootstrap

    /// Resolves the service state first, then (only if the server allows it) tries
    /// to restore a previously verified session.
    public func bootstrapSession() {
        if let token = NABATICrypto.shared.getSessionToken(), !token.isEmpty,
           let cachedKey = NABATICrypto.shared.getActiveLicenseKey(), !cachedKey.isEmpty {
            statusMessage = "Đang xác minh phiên sử dụng với máy chủ..."
            appState = .verifying
        }

        checkServiceGate(isUserRetry: false) { [weak self] reachable in
            guard let self = self else { return }

            // The server state is unknown (transport failure). The app must not
            // proceed as if it were online, and must not spin forever either.
            guard reachable else {
                if case .verifying = self.appState {
                    self.appState = .locked
                    self.statusMessage = nil
                }
                return
            }

            guard let token = NABATICrypto.shared.getSessionToken(), !token.isEmpty,
                  let cachedKey = NABATICrypto.shared.getActiveLicenseKey(), !cachedKey.isEmpty else {
                if case .verifying = self.appState { self.appState = .locked }
                self.statusMessage = nil
                return
            }

            // The server may block auth in maintenance mode. Respect it even for a
            // cached session: the stored token is not a bypass.
            if self.isGateBlocking {
                self.statusMessage = nil
                self.appState = .locked
                return
            }

            NABATIAuthentication.shared.checkHeartbeat { outcome in
                switch outcome {
                case .valid(let expiresAt, _):
                    let session = NABATISessionInfo(
                        key: cachedKey,
                        maskedKey: self.maskKey(cachedKey),
                        sessionToken: token,
                        planType: "VIP",
                        remainingDays: self.daysRemaining(until: expiresAt),
                        expiresAt: self.formatExpiry(expiresAt),
                        boundDevice: NABATIDevice.shared.modelName
                    )
                    self.statusMessage = nil
                    self.appState = .authorized(session)

                case .rejected(let message, _):
                    // The server revoked or expired this session: drop local state.
                    NABATIAuthentication.shared.logout()
                    self.statusMessage = nil
                    self.errorMessage = message
                    self.appState = .locked

                case .paused(let message):
                    // Maintenance is not a license verdict. Keep the stored KEY and
                    // only pause the session; the gate overlay explains why.
                    self.statusMessage = nil
                    self.errorMessage = nil
                    self.appState = .locked
                    self.gateMode = .maintenance
                    self.gateErrorText = message

                case .unreachable(let message):
                    // Cannot confirm with the server: stay locked rather than
                    // trusting a cached session forever.
                    self.statusMessage = nil
                    self.errorMessage = "Không thể xác minh phiên với máy chủ. \(message)"
                    self.appState = .locked
                }
            }
        }
    }

    // MARK: - Service gate

    private var gateCompletionQueue: [((Bool) -> Void)] = []

    /// Fetches `/api/service-status` and derives the gate UI state.
    /// - Parameter completion: `true` only when the server answered with a valid
    ///   snapshot. `false` means the state is unknown and the caller must not
    ///   proceed as if the system were online.
    public func checkServiceGate(isUserRetry: Bool, completion: ((Bool) -> Void)? = nil) {
        if gateBusy {
            // A request is already in flight: piggyback on its result instead of
            // reporting a fabricated outcome.
            if let completion = completion { gateCompletionQueue.append(completion) }
            return
        }
        gateBusy = true
        if let completion = completion { gateCompletionQueue.append(completion) }
        if isUserRetry {
            gateErrorText = nil
        } else if case .hidden = gateMode {
            gateMode = .checking
        }

        NABATIServiceClient.shared.fetchStatus { [weak self] result in
            guard let self = self else { return }
            self.gateBusy = false

            let reachable: Bool
            switch result {
            case .success(let status):
                self.serviceStatus = status
                self.gateErrorText = nil

                if status.state.isMaintenance {
                    self.gateMode = .maintenance
                } else if status.update != nil {
                    // A newer release is published: show it once over the lock
                    // screen. Only `forceUpdate` blocks the customer from working.
                    self.gateMode = .update
                } else {
                    self.gateMode = .hidden
                }
                reachable = true

            case .failure(let error):
                self.serviceStatus = nil
                self.gateMode = .connectionError
                self.gateErrorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                reachable = false
            }

            let queued = self.gateCompletionQueue
            self.gateCompletionQueue.removeAll()
            for callback in queued { callback(reachable) }
        }
    }

    /// Dismisses a non-blocking notice. Blocking gates stay visible.
    public func dismissGateNotice() {
        guard !isGateBlocking else { return }
        gateMode = .hidden
    }

    /// Builds the URL the "Cập nhật" button opens.
    ///
    /// Three distribution shapes are supported, decided by the server-side
    /// download link — no client rebuild needed when the link changes:
    ///   * `itms-services://...` — already a full OTA install URL, opened as-is.
    ///   * `https://.../*.plist` — an OTA manifest, wrapped into `itms-services`.
    ///   * `https://.../*.ipa` — iOS cannot install a bare IPA URL, so it is
    ///     wrapped in our Worker manifest, which resolves the *published* D1 row
    ///     at install time. Changing the IPA URL in Admin therefore takes effect
    ///     without rebuilding the app.
    ///   * anything else (TestFlight / App Store) — opened as-is.
    private static let iosInstallManifestURL =
        "https://nbtaimlockshopcom.thait2471.workers.dev/api/ios/install-manifest.plist"

    private static func otaInstallURL(manifestURL: String) -> URL? {
        let encoded = manifestURL.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        ) ?? manifestURL
        return URL(string: "itms-services://?action=download-manifest&url=\(encoded)")
    }

    private func resolveInstallTarget(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("itms-services://") {
            return URL(string: trimmed)
        }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return nil
        }

        let path = url.path.lowercased()
        if path.hasSuffix(".plist") {
            return NABATICore.otaInstallURL(manifestURL: trimmed)
        }
        if path.hasSuffix(".ipa") {
            return NABATICore.otaInstallURL(manifestURL: NABATICore.iosInstallManifestURL)
        }
        return url
    }

    public func openDownloadUrl() {
        guard let raw = serviceStatus?.update?.downloadUrl,
              let url = resolveInstallTarget(raw) else {
            gateErrorText = "Link tải chưa hợp lệ. Vui lòng liên hệ quản trị viên."
            return
        }
        // Never auto-install anything: hand the URL to the system so iOS keeps
        // the user in control of the installation decision.
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: - Unlock

    public func unlockWithKey(_ key: String) {
        errorMessage = nil

        guard !isGateBlocking else {
            errorMessage = serviceStatus?.state.content ?? "Hệ thống đang bảo trì. Vui lòng quay lại sau."
            return
        }

        if case .connectionError = gateMode {
            errorMessage = "Chưa xác minh được trạng thái hệ thống. Vui lòng thử lại."
            return
        }

        statusMessage = "Đang kết nối xác thực máy chủ Cloudflare..."
        appState = .verifying
        impactFeedback.impactOccurred()

        NABATIAuthentication.shared.verifyKey(licenseKey: key) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(.authorized(let session)):
                self.notificationFeedback.notificationOccurred(.success)
                self.statusMessage = nil
                self.errorMessage = nil
                self.appState = .authorized(session)

            case .success(.rejected(let message, _)):
                self.notificationFeedback.notificationOccurred(.error)
                self.statusMessage = nil
                self.errorMessage = message
                self.appState = .locked

            case .success(.paused(let message)):
                // Maintenance started mid-attempt. Nothing is wrong with the KEY,
                // so do not report a license error and do not clear stored state.
                self.statusMessage = nil
                self.appState = .locked
                self.errorMessage = nil
                self.gateMode = .maintenance
                self.gateErrorText = message
                self.checkServiceGate(isUserRetry: true)

            case .failure(let error):
                self.notificationFeedback.notificationOccurred(.error)
                self.statusMessage = nil
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.appState = .locked
            }
        }
    }

    // MARK: - Heartbeat loop (called by the dashboard)

    /// Revalidates the active session. Returns `false` when the session must end.
    public func revalidateSession(completion: ((Bool) -> Void)? = nil) {
        guard case .authorized(let session) = appState else {
            completion?(false)
            return
        }

        NABATIAuthentication.shared.checkHeartbeat { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .valid(let expiresAt, _):
                if let expiresAt = expiresAt {
                    let refreshed = NABATISessionInfo(
                        key: session.key,
                        maskedKey: session.maskedKey,
                        sessionToken: session.sessionToken,
                        planType: session.planType,
                        remainingDays: self.daysRemaining(until: expiresAt),
                        expiresAt: self.formatExpiry(expiresAt),
                        boundDevice: session.boundDevice
                    )
                    self.appState = .authorized(refreshed)
                }
                completion?(true)

            case .rejected(let message, _):
                NABATIAuthentication.shared.logout()
                self.notificationFeedback.notificationOccurred(.error)
                self.errorMessage = message
                self.appState = .locked
                self.resetPresetToDefault()
                completion?(false)

            case .paused(let message):
                // The KEY is still valid; the service is simply unavailable. Keep
                // the token and the stored license key intact.
                self.statusMessage = nil
                self.errorMessage = nil
                self.appState = .locked
                self.gateMode = .maintenance
                self.gateErrorText = message
                self.resetPresetToDefault()
                self.checkServiceGate(isUserRetry: true)
                completion?(false)

            case .unreachable:
                // Transport failure is not a successful heartbeat. Keep the
                // current UI session for a transient outage, but report failure to
                // the caller and let the next dashboard appearance retry.
                completion?(false)
            }
        }
    }

    public func logout() {
        impactFeedback.impactOccurred()
        NABATIAuthentication.shared.logout()
        appState = .locked
        errorMessage = nil
        statusMessage = nil
        resetPresetToDefault()
    }

    // MARK: - Feature controls

    /// Loads the tuned preset. Nothing outside this app is touched: the numbers
    /// are copied by the customer into Free Fire's own settings screen.
    public func applyRecommendedPreset() {
        impactFeedback.impactOccurred()
        generalSensitivity = 100.0
        redDotSensitivity = 98.0
        scope2xSensitivity = 96.0
        scope4xSensitivity = 94.0
        notificationFeedback.notificationOccurred(.success)
    }

    /// Copies the visible preset to the system clipboard and confirms it in the
    /// UI. Returns `true` when the pasteboard accepted the write.
    @discardableResult
    public func copySensitivityPreset() -> Bool {
        impactFeedback.impactOccurred()
        UIPasteboard.general.string = sensitivityConfigText
        let copied = UIPasteboard.general.string == sensitivityConfigText
        statusMessage = copied
            ? "Đã sao chép độ nhạy. Dán vào Cài đặt trong game."
            : "Không sao chép được. Vui lòng đọc số trên màn hình."
        if copied { notificationFeedback.notificationOccurred(.success) }
        return copied
    }

    public func resetPresetToDefault() {
        selectedGameIndex = 1
        generalSensitivity = 98.0
        redDotSensitivity = 95.0
        scope2xSensitivity = 92.0
        scope4xSensitivity = 90.0
    }

    public func launchFreeFire() {
        impactFeedback.impactOccurred()
        if let url = URL(string: "freefire://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } else if let appStoreURL = URL(string: "https://apps.apple.com/app/id1300146617") {
            UIApplication.shared.open(appStoreURL, options: [:], completionHandler: nil)
        }
    }

    public func launchFreeFireMax() {
        impactFeedback.impactOccurred()
        if let url = URL(string: "freefiremax://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } else if let appStoreURL = URL(string: "https://apps.apple.com/app/id1480516829") {
            UIApplication.shared.open(appStoreURL, options: [:], completionHandler: nil)
        }
    }

    public func openZaloSupport() {
        impactFeedback.impactOccurred()
        if let url = URL(string: "https://zalo.me/0356075419") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    // MARK: - Helpers

    private func maskKey(_ key: String) -> String {
        if key.count > 8 {
            let start = key.prefix(4)
            return "\(start)-VIP-****"
        }
        return "NBT-VIP-****"
    }

    private func daysRemaining(until millis: Double?) -> Int {
        guard let millis = millis else { return 0 }
        let value = millis > 100_000_000_000 ? millis : millis * 1000
        let days = Int(((value - Date().timeIntervalSince1970 * 1000) / 86_400_000).rounded(.up))
        return max(0, days)
    }

    private func formatExpiry(_ millis: Double?) -> String {
        guard let millis = millis else { return "—" }
        let value = millis > 100_000_000_000 ? millis : millis * 1000
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: value / 1000))
    }
}
