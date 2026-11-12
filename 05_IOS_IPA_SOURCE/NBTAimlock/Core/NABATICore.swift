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

    @Published public var appState: NABATIAppState = .locked {
        didSet {
            // One central place so every transition into/out of `.authorized`
            // starts or stops the server-authority guard. Putting the calls at
            // each assignment site is what let the initial version miss the
            // background/heartbeat path entirely.
            //
            // Only a *transition* starts or stops the guard: a heartbeat refreshes
            // `.authorized` every 20 s, and restarting the timers on each refresh
            // would make the schedule depend on network latency.
            let wasAuthorized = NABATICore.isAuthorizedState(oldValue)
            let isAuthorized = NABATICore.isAuthorizedState(appState)
            if isAuthorized && !wasAuthorized {
                startServerGuard()
            } else if !isAuthorized && wasAuthorized {
                stopServerGuard()
                // The web client's `resetAllFeaturesToOff()` runs on every lock:
                // revocation, expiry, maintenance and unreachable-heartbeat
                // lockouts all clear local feature state. The grants live in
                // `NABATIFeatureAuthorization` and are only meaningful while
                // a session is open, so dropping them here is what keeps a
                // module from appearing "on" after the KEY behind it is gone.
                NABATIFeatureStore.shared.resetAll()
            }
        }
    }

    private static func isAuthorizedState(_ state: NABATIAppState) -> Bool {
        if case .authorized = state { return true }
        return false
    }
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

    // Continuous server-authority guard.
    //
    // The web client re-checks the session every 20 s and runs a one-second
    // expiry watchdog. This app used to validate only on dashboard `.onAppear`,
    // which meant a customer could leave the dashboard open forever and the app
    // would keep showing "authorized" after the KEY was revoked or expired.
    // The heartbeat loop below restores the same continuous guarantee without
    // busy-polling:
    //
    //   * `heartbeatTimer` revalidates with the server every
    //     `heartbeatIntervalSeconds` (fail-closed: the server must answer).
    //   * `expiryWatchdogTimer` runs on `RunLoop.main.commonModes` so it still
    //     fires while the customer scrolls, and forces a lock when the
    //     server-issued expiry passes even before the next heartbeat lands.
    //   * The session's expiry is refreshed from the server on every
    //     revalidation, so a `session.expiresAtMillis` value is never trusted
    //     on its own for more than one heartbeat interval.
    private var heartbeatTimer: Timer?
    private var expiryWatchdogTimer: Timer?
    private var heartbeatInFlight = false

    /// Transport failures tolerated before the session is locked. Three
    /// consecutive misses is roughly one minute of an unreachable server: long
    /// enough for a tunnel or a tower handover, short enough that airplane mode
    /// cannot be used to keep the app unlocked.
    private var consecutiveUnreachableHeartbeats = 0
    private static let maxUnreachableHeartbeats = 3

    private static let heartbeatIntervalSeconds: TimeInterval = 20.0
    private static let expiryWatchdogIntervalSeconds: TimeInterval = 1.0

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
                        boundDevice: NABATIDevice.shared.modelName,
                        expiresAtMillis: expiresAt.map { $0 > 100_000_000_000 ? $0 : $0 * 1000 }
                    )
                    self.consecutiveUnreachableHeartbeats = 0
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
    private static var iosInstallManifestURL: String {
        // Host and path both live in the XOR tables, so a static scan of the
        // binary does not reveal the Worker origin.
        NABATINetwork.shared.primaryBaseURL + NBTF.K.installManifestPath
    }

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

        // Hard tamper evidence (rewritten bundle id, injected dylib) means this
        // process is not the app we shipped. Refuse before the KEY is even sent:
        // a modified binary could also have been modified to ignore the server's
        // answer, so continuing would waste the customer's attempts and hand an
        // attacker a valid session token.
        let security = NABATISecurity.shared.checkSecurityEnvironment()
        if security.isTampered {
            notificationFeedback.notificationOccurred(.error)
            errorMessage = "Ứng dụng đã bị chỉnh sửa trái phép. Vui lòng cài lại bản chính thức từ cửa hàng."
            appState = .locked
            return
        }

        // Repackaged-IPA evidence: a flipped byte in `__TEXT`, or an image that
        // is not mapped from the bundle on disk. Checked here rather than at
        // launch so the refusal happens before the KEY is transmitted, and for
        // the same reason as above — a patched binary cannot be trusted to
        // honour the server's answer either.
        if NABATIAppIntegrity.shared.inspect().blocksExecution {
            notificationFeedback.notificationOccurred(.error)
            errorMessage = "Ứng dụng đã bị chỉnh sửa trái phép. Vui lòng cài lại bản chính thức từ cửa hàng."
            appState = .locked
            return
        }

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

            case .success(.rejected(let message, let code)):
                self.notificationFeedback.notificationOccurred(.error)
                self.statusMessage = nil
                // A device-limit rejection is the one verdict the customer can
                // actually resolve, but only if they are told how. The bare
                // server text reads like a dead end, so append the exact steps
                // and the device id support needs to find the slot.
                if code == "KEY_DA_GAN_THIET_BI" || code == "GIOI_HAN_THIET_BI" {
                    self.errorMessage = message +
                        "\n\nCách xử lý: nhờ quản trị viên vào Admin → tab Keys → mở KEY của bạn → bấm “📱 Gỡ 1 thiết bị”, " +
                        "rồi bấm MỞ KHÓA lại.\nMã thiết bị của bạn: \(NABATIDevice.shared.hardwareId)"
                } else {
                    self.errorMessage = message
                }
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
                        boundDevice: session.boundDevice,
                        expiresAtMillis: expiresAt > 100_000_000_000 ? expiresAt : expiresAt * 1000
                    )
                    self.appState = .authorized(refreshed)
                }
                // A positive server verdict clears the transport grace counter:
                // the next unreachable run starts its own window rather than
                // inheriting partial credit from before this heartbeat.
                self.consecutiveUnreachableHeartbeats = 0
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
                // the token, the stored license key and the customer's tuned
                // presets intact — wiping their sensitivity numbers because the
                // server went into maintenance would be data loss for something
                // that is not their fault.
                self.statusMessage = nil
                self.errorMessage = nil
                self.appState = .locked
                self.gateMode = .maintenance
                self.gateErrorText = message
                self.checkServiceGate(isUserRetry: true)
                completion?(false)

            case .unreachable(let message):
                // Transport failure is not a successful heartbeat. A transient
                // outage should not throw the customer out, but an app that keeps
                // working forever while the server is unreachable is a bypass:
                // turning on airplane mode would unlock the features indefinitely.
                // Allow a short grace window, then fail closed like the server
                // verdict path does.
                self.consecutiveUnreachableHeartbeats += 1
                if self.consecutiveUnreachableHeartbeats >= NABATICore.maxUnreachableHeartbeats {
                    NABATIAuthentication.shared.logout()
                    self.notificationFeedback.notificationOccurred(.error)
                    self.errorMessage = "Mất kết nối máy chủ quá lâu nên phiên đã bị khóa. Vui lòng kiểm tra mạng và nhập lại KEY."
                    self.statusMessage = nil
                    self.appState = .locked
                    // Presets are the customer's own tuned numbers and survive
                    // an outage; the session lock is temporary, their input is not.
                    self.consecutiveUnreachableHeartbeats = 0
                    completion?(false)
                    return
                }
                self.statusMessage = "Đang kết nối lại máy chủ… (\(self.consecutiveUnreachableHeartbeats)/\(NABATICore.maxUnreachableHeartbeats))"
                _ = message
                completion?(false)
            }
        }
    }

    // MARK: - Continuous server-authority guard

    /// Starts (or restarts) the heartbeat + expiry watchdog for the active session.
    /// Idempotent: calling it while timers already run only refreshes the schedule.
    private func startServerGuard() {
        stopServerGuard()

        let heartbeat = Timer(timeInterval: NABATICore.heartbeatIntervalSeconds,
                              repeats: true) { [weak self] _ in
            self?.serverGuardTick()
        }
        // .common keeps the heartbeat alive while the UI is tracking a scroll or
        // gesture; .default alone silently pauses during interaction.
        RunLoop.main.add(heartbeat, forMode: .common)
        heartbeatTimer = heartbeat

        let watchdog = Timer(timeInterval: NABATICore.expiryWatchdogIntervalSeconds,
                             repeats: true) { [weak self] _ in
            self?.expiryWatchdogTick()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        expiryWatchdogTimer = watchdog
    }

    private func stopServerGuard() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        expiryWatchdogTimer?.invalidate()
        expiryWatchdogTimer = nil
        heartbeatInFlight = false
    }

    /// Pauses the guard while the app is in the background. iOS suspends timers
    /// anyway, and a revalidation on foreground (`applicationDidBecomeActive`)
    /// is a stronger check than a stale timer firing late.
    public func suspendServerGuard() {
        stopServerGuard()
    }

    /// Resumes after the app returns to the foreground and re-checks immediately:
    /// the customer may have spent hours in another app, so the first check must
    /// not wait for the next interval.
    public func resumeServerGuard() {
        guard case .authorized = appState else { return }
        startServerGuard()
        serverGuardTick()
        checkServiceGate(isUserRetry: false)
    }

    private func serverGuardTick() {
        guard case .authorized = appState, !heartbeatInFlight else { return }
        heartbeatInFlight = true
        revalidateSession { [weak self] _ in
            self?.heartbeatInFlight = false
        }
    }

    /// Locks immediately when the server-issued expiry has passed. This is the
    /// same rule the web client enforces every second; it does not replace the
    /// heartbeat, it closes the window between expiry and the next round trip.
    private func expiryWatchdogTick() {
        guard case .authorized(let session) = appState else { return }
        guard let millis = session.expiresAtMillis else { return } // permanent KEY
        if Date().timeIntervalSince1970 * 1000 >= millis {
            NABATIAuthentication.shared.logout()
            notificationFeedback.notificationOccurred(.error)
            errorMessage = "KEY đã hết hạn sử dụng! Vui lòng nhập KEY mới."
            statusMessage = nil
            appState = .locked
            resetPresetToDefault()
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
