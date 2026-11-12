import Foundation
import UIKit
import Combine

/// One module row on the dashboard.
///
/// `active` is only ever set from a server grant — there is no local path that
/// flips it. `authorizing` distinguishes "the customer moved the switch and we
/// are waiting for the server" from "the module is running", so the UI can show
/// progress instead of pretending the feature is already on.
public struct NABATIFeatureState: Identifiable {
    public let id: String
    public let category: String
    public let name: String
    public let desc: String
    public let icon: String
    public var active: Bool
    public var authorizing: Bool

    public var isAim: Bool { category == "aim" }
}

/// The activation overlay's progress, mirroring the web client's 1→100% cyber
/// sequence. It is purely cosmetic timing around a real server round trip: the
/// grant is already in hand before the overlay finishes, so cancelling the
/// animation cancels the module.
public struct NABATIActivationProgress {
    public var percent: Int
    public var phaseLabel: String
    public var subsystemLabel: String
    public var log: [NABATIActivationLogLine]
    public var finished: Bool
}

public struct NABATIActivationLogLine: Identifiable {
    public let id = UUID()
    public let module: String
    public var done: Bool
}

/// Owns the config, the module roster and the authorization flow.
///
/// The web client keeps this in JS (`features`, `pendingToggle`,
/// `cyberInitInProgress`). Keeping the same shape here means the two clients
/// behave identically when a KEY is revoked mid-session: grants are dropped and
/// every switch returns to off.
public final class NABATIFeatureStore: ObservableObject {
    public static let shared = NABATIFeatureStore()

    @Published public private(set) var config: NABATIAppConfig = .default
    @Published public private(set) var features: [NABATIFeatureState] = NABATIFeatureStore.makeStates(from: .default)
    @Published public private(set) var activation: NABATIActivationProgress? = nil
    @Published public private(set) var statusMessage: String? = nil

    /// Live notices from `/api/announcement`, joined into one marquee line the
    /// same way the web client does. Empty when the admin has published none.
    @Published public private(set) var announcementLines: [String] = []

    /// The device-optimization preset the customer last applied, so the UI can
    /// show the selection. Purely a display value: the modules it covers are
    /// still authorized one by one with the server.
    @Published public private(set) var activeDevicePreset: String? = nil

    /// Mirrors the web client's `selectedGame`: "FFTH" (Free Fire) or "FFM" (MAX).
    @Published public var selectedGame: String = "FFTH"

    private var activationTimer: Timer?
    private var pendingFeatureId: String?
    private var optimizeAllMode = false
    private var activationCancelled = false
    private var configLoaded = false
    private var announcementsLoaded = false
    private var presetInFlight = false

    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()

    private init() {
        restoreSelectedGame()
    }

    // MARK: - Config

    /// Fetches `/api/config` once per session. The shipped default renders
    /// immediately so the dashboard is never blank while this is in flight.
    public func loadConfigIfNeeded() {
        if !configLoaded {
            configLoaded = true
            NABATIAppConfigClient.shared.fetch { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let cfg):
                    self.config = cfg
                    self.rebuildFeatures(from: cfg)
                case .failure:
                    // Keep the shipped default and allow a retry on the next
                    // dashboard appearance rather than leaving a permanent gap.
                    self.configLoaded = false
                }
            }
        }

        if !announcementsLoaded {
            announcementsLoaded = true
            NABATIAppConfigClient.shared.fetchAnnouncements { [weak self] lines in
                guard let self = self else { return }
                // An empty result is not an error here: the admin may simply
                // have no active notices. Marking it loaded avoids a refetch on
                // every appearance; `reloadConfig` clears the flag.
                self.announcementLines = lines
            }
        }
    }

    public func reloadConfig() {
        configLoaded = false
        announcementsLoaded = false
        loadConfigIfNeeded()
    }

    /// The marquee text: the admin's live notices when any exist, otherwise the
    /// config row's own announcement. Same precedence the web client applies by
    /// loading `/api/config` first and `/api/announcement` second.
    public var marqueeText: String {
        if !announcementLines.isEmpty {
            return announcementLines.joined(separator: "  •  ")
        }
        return config.announcement
    }

    public var shouldShowMarquee: Bool {
        guard config.showAnnouncement else { return false }
        return !marqueeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func makeStates(from cfg: NABATIAppConfig) -> [NABATIFeatureState] {
        cfg.features.map {
            NABATIFeatureState(
                id: $0.id,
                category: $0.category,
                name: $0.name,
                desc: $0.desc,
                icon: $0.icon,
                active: false,
                authorizing: false
            )
        }
    }

    /// Rebuilds the roster while preserving the on/off state of modules that
    /// still exist and already hold a grant. A config edit in Admin must not
    /// silently switch off a module the customer is using.
    private func rebuildFeatures(from cfg: NABATIAppConfig) {
        let previous = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0.active) })
        var rebuilt = NABATIFeatureStore.makeStates(from: cfg)
        for index in rebuilt.indices {
            let id = rebuilt[index].id
            rebuilt[index].active = (previous[id] ?? false) && NABATIFeatureAuthorization.shared.hasGrant(for: id)
        }
        features = rebuilt
    }

    // MARK: - Toggle

    /// Handles a switch change. Turning **on** always asks the server first;
    /// turning **off** is local and immediate.
    public func toggle(featureId: String, isOn: Bool) {
        guard let index = features.firstIndex(where: { $0.id == featureId }) else { return }

        guard isOn else {
            impact.impactOccurred()
            NABATIFeatureAuthorization.shared.revoke(featureId)
            features[index].active = false
            features[index].authorizing = false
            notify.notificationOccurred(.warning)
            return
        }

        guard NABATICore.shared.isAuthorized else {
            statusMessage = "Vui lòng xác thực KEY trước!"
            features[index].active = false
            return
        }
        guard activation == nil else {
            statusMessage = "Đang khởi tạo, vui lòng đợi..."
            return
        }

        impact.impactOccurred()
        features[index].authorizing = true

        NABATIFeatureAuthorization.shared.authorize(featureId: featureId) { [weak self] result in
            guard let self = self else { return }
            guard let idx = self.features.firstIndex(where: { $0.id == featureId }) else { return }
            self.features[idx].authorizing = false

            switch result {
            case .success:
                self.pendingFeatureId = featureId
                self.optimizeAllMode = false
                self.startActivationSequence()
            case .failure(let error):
                self.features[idx].active = false
                self.statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.notify.notificationOccurred(.error)
            }
        }
    }

    // MARK: - Row mutation helpers

    /// Single place that writes a row's flags so the `@Published` array is
    /// always replaced (not mutated in place) — SwiftUI only observes the
    /// assignment, and mutating `features[i].active` directly works but makes
    /// every call site responsible for triggering the update.
    private func setFeature(_ id: String, active: Bool? = nil, authorizing: Bool? = nil) {
        guard let idx = features.firstIndex(where: { $0.id == id }) else { return }
        var copy = features
        if let active = active { copy[idx].active = active }
        if let authorizing = authorizing { copy[idx].authorizing = authorizing }
        features = copy
    }

    // MARK: - Device presets

    /// Applies a device-optimization preset.
    ///
    /// The web client's presets (`light`, `balanced`, `perf`) are descriptions of
    /// *which modules to switch on*, not separate server actions. Each preset
    /// maps to a set of `feat_dev_*` ids and each of those is authorized with the
    /// server individually, so a preset cannot turn on a module the KEY has no
    /// right to.
    ///
    /// `custom` is not a real preset on the web client — it only moves the preset
    /// chips to a manual state. It is accepted here for display completeness and
    /// authorizes nothing.
    public func applyDevicePreset(_ preset: String) {
        let targetIds: [String]
        switch preset {
        case "light":
            // Web: `f.active = (v !== 'light')` then explicitly re-enables
            // Smooth Game, so only feat_dev_1 ends up on.
            targetIds = ["feat_dev_1"]
        case "balanced", "perf":
            // Web: every device module is switched on for both of these.
            targetIds = features.filter { !$0.isAim }.map { $0.id }
        case "custom":
            activeDevicePreset = "custom"
            return
        default:
            return
        }

        guard !presetInFlight else {
            statusMessage = "Đang áp dụng preset, vui lòng đợi…"
            return
        }
        guard NABATICore.shared.isAuthorized else {
            statusMessage = "Vui lòng xác thực KEY trước!"
            return
        }
        guard activation == nil else {
            statusMessage = "Đang khởi tạo, vui lòng đợi…"
            return
        }

        impact.impactOccurred()
        presetInFlight = true
        activeDevicePreset = preset

        applyPresetModules(targetIds, index: 0, authorizedSoFar: []) { [weak self] authorized in
            guard let self = self else { return }
            self.presetInFlight = false

            // Switch off every device module the preset did not keep. The web
            // client does this in the same pass (`f.active = ...`); revoking the
            // grant mirrors it so a module is not merely unticked but no longer
            // authorized either.
            for row in self.features where !row.isAim {
                if !authorized.contains(row.id) && row.active {
                    NABATIFeatureAuthorization.shared.revoke(row.id)
                    self.setFeature(row.id, active: false)
                }
            }

            if authorized.isEmpty {
                self.activeDevicePreset = nil
                self.statusMessage = "Không module nào trong preset được máy chủ uỷ quyền."
                self.notify.notificationOccurred(.error)
            } else {
                self.statusMessage = "Đã áp dụng preset • \(authorized.count) module được uỷ quyền."
                self.notify.notificationOccurred(.success)
            }
        }
    }

    private func applyPresetModules(
        _ ids: [String],
        index: Int,
        authorizedSoFar: [String],
        completion: @escaping ([String]) -> Void
    ) {
        guard index < ids.count else {
            completion(authorizedSoFar)
            return
        }
        let id = ids[index]
        setFeature(id, authorizing: true)
        NABATIFeatureAuthorization.shared.authorize(featureId: id) { [weak self] result in
            guard let self = self else { return }
            self.setFeature(id, authorizing: false)
            var authorized = authorizedSoFar
            switch result {
            case .success:
                self.setFeature(id, active: true)
                authorized.append(id)
            case .failure:
                // One module being refused does not cancel the rest of the
                // preset — a KEY may entitle some features and not others.
                self.setFeature(id, active: false)
            }
            self.applyPresetModules(ids, index: index + 1, authorizedSoFar: authorized, completion: completion)
        }
    }

    /// Restores the default device state: every device module off and its grant
    /// dropped. The web client's "↺ Khôi phục mặc định" button.
    public func restoreDefaultDeviceState() {
        guard !presetInFlight else { return }
        for row in features where !row.isAim {
            NABATIFeatureAuthorization.shared.revoke(row.id)
            setFeature(row.id, active: false)
        }
        // The web client's restore button only clears every device module; it
        // does not select a preset, so no chip stays highlighted.
        activeDevicePreset = nil
        statusMessage = "Đã khôi phục cấu hình tối ưu mặc định."
    }

    /// Authorizes `"all"` and turns every module on when the overlay completes.
    public func optimizeAll() {
        guard NABATICore.shared.isAuthorized else {
            statusMessage = "Vui lòng xác thực KEY!"
            return
        }
        guard activation == nil else {
            statusMessage = "Đang khởi tạo..."
            return
        }

        impact.impactOccurred()
        NABATIFeatureAuthorization.shared.authorize(featureId: "all") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                // The bulk grant is stored under `"all"`; widen it to every row
                // so the per-row toggles and a later config refresh both see it.
                NABATIFeatureAuthorization.shared.widenAllGrant(to: self.features.map { $0.id })
                self.pendingFeatureId = nil
                self.optimizeAllMode = true
                self.startActivationSequence(keepOpenForLaunch: true)
            case .failure(let error):
                self.statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.notify.notificationOccurred(.error)
            }
        }
    }

    // MARK: - Activation overlay

    private static let phases: [(start: Int, labels: [String], tag: String)] = [
        (0,  ["Đang khởi tạo AIMLOCK...", "Đang kiểm tra hệ thống...", "Đang chuẩn bị tài nguyên..."], "SYSTEM.INIT"),
        (21, ["Đang kiểm tra cấu hình...", "Đang phân tích môi trường...", "Đang chuẩn bị module..."], "CONFIG.SCAN"),
        (41, ["Đang xử lý dữ liệu...", "Đang khởi tạo thành phần...", "Đang tối ưu tiến trình..."], "PROC.EXEC"),
        (61, ["Đang tải module...", "Đang khởi chạy dịch vụ...", "Đang kiểm tra trạng thái..."], "MODULE.LOAD"),
        (81, ["Đang hoàn tất khởi tạo...", "Đang đồng bộ hệ thống...", "Đang kiểm tra lần cuối..."], "SYNC.FINAL"),
    ]

    private static let modules = [
        "Initializing Core", "Checking Runtime", "Verifying License", "Binding Device",
        "Preparing Resources", "Loading Modules", "Calibrating Sensitivity", "Syncing Config",
        "Starting Service", "Final Check"
    ]

    private func startActivationSequence(keepOpenForLaunch: Bool = false) {
        activationCancelled = false
        // The admin can disable the animation; when disabled the module turns on
        // immediately, exactly like the web client's `optimizeAnimation === false`
        // branch.
        guard config.optimizeAnimation else {
            completeActivation(success: true)
            if keepOpenForLaunch || optimizeAllMode {
                launchSelectedGame()
            }
            return
        }

        activation = NABATIActivationProgress(
            percent: 0,
            phaseLabel: NABATIFeatureStore.phases[0].labels[0],
            subsystemLabel: NABATIFeatureStore.phases[0].tag,
            log: [],
            finished: false
        )

        var current = 0
        var moduleIndex = 0
        var lastPhase = -1

        activationTimer?.invalidate()
        activationTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.activationCancelled {
                timer.invalidate()
                return
            }

            current = min(100, current + Int.random(in: 1...4))
            var phaseIdx = 0
            for (idx, phase) in NABATIFeatureStore.phases.enumerated() where current >= phase.start {
                phaseIdx = idx
            }
            let phase = NABATIFeatureStore.phases[phaseIdx]

            var progress = self.activation ?? NABATIActivationProgress(
                percent: 0, phaseLabel: "", subsystemLabel: "", log: [], finished: false
            )
            progress.percent = current
            if phaseIdx != lastPhase {
                lastPhase = phaseIdx
                progress.phaseLabel = phase.labels.randomElement() ?? phase.labels[0]
                progress.subsystemLabel = phase.tag
            }

            // One log line roughly every 12%, last one marked done.
            if current >= moduleIndex * 12 && moduleIndex < NABATIFeatureStore.modules.count {
                if moduleIndex > 0, let lastIdx = progress.log.indices.last, !progress.log[lastIdx].done {
                    progress.log[lastIdx].done = true
                }
                progress.log.append(NABATIActivationLogLine(
                    module: NABATIFeatureStore.modules[moduleIndex],
                    done: false
                ))
                moduleIndex += 1
            }

            if current >= 100 {
                timer.invalidate()
                if let lastIdx = progress.log.indices.last {
                    progress.log[lastIdx].done = true
                }
                progress.percent = 100
                progress.finished = true
                progress.phaseLabel = "AIMLOCK ĐÃ BẬT"
                progress.subsystemLabel = "HỆ THỐNG SẴN SÀNG"
                self.activation = progress
                self.completeActivation(success: true)
                return
            }
            self.activation = progress
        }
    }

    public func cancelActivation() {
        guard activation != nil else { return }
        activationCancelled = true
        activationTimer?.invalidate()
        activationTimer = nil
        activation = nil

        if let pending = pendingFeatureId, let idx = features.firstIndex(where: { $0.id == pending }) {
            features[idx].active = false
            features[idx].authorizing = false
            NABATIFeatureAuthorization.shared.revoke(pending)
        } else if optimizeAllMode {
            for idx in features.indices {
                features[idx].active = false
                NABATIFeatureAuthorization.shared.revoke(features[idx].id)
            }
        }
        pendingFeatureId = nil
        optimizeAllMode = false
        statusMessage = "Đã hủy khởi tạo"
    }

    /// Closes the finished overlay. Called by the "VÀO GAME" button or by the
    /// auto-dismiss after a single-toggle activation.
    public func dismissActivation() {
        activation = nil
        pendingFeatureId = nil
        optimizeAllMode = false
    }

    private func completeActivation(success: Bool) {
        guard success else {
            pendingFeatureId = nil
            optimizeAllMode = false
            return
        }

        if let pending = pendingFeatureId, let idx = features.firstIndex(where: { $0.id == pending }) {
            features[idx].active = true
            notify.notificationOccurred(.success)
            statusMessage = "Đã bật: \(features[idx].name)"
        } else if optimizeAllMode {
            for idx in features.indices {
                features[idx].active = true
            }
            notify.notificationOccurred(.success)
            statusMessage = "Đã bật toàn bộ chức năng"
        }

        // A single toggle closes the overlay by itself; the bulk action stays
        // open so the customer can go straight into the game.
        if pendingFeatureId != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self = self, self.activation?.finished == true else { return }
                self.dismissActivation()
            }
        }
    }

    // MARK: - Session lifecycle

    /// Drops every grant and switches every module off. Called on logout,
    /// revocation, expiry, maintenance and unreachable-heartbeat lockouts.
    public func resetAll() {
        activationTimer?.invalidate()
        activationTimer = nil
        activation = nil
        pendingFeatureId = nil
        optimizeAllMode = false
        activationCancelled = false
        presetInFlight = false
        activeDevicePreset = nil
        statusMessage = nil
        NABATIFeatureAuthorization.shared.clearAll()
        var copy = features
        for idx in copy.indices {
            copy[idx].active = false
            copy[idx].authorizing = false
        }
        features = copy
    }

    // MARK: - Game launch

    public func launchSelectedGame() {
        impact.impactOccurred()
        let freeFire = "freefire://"
        let freeFireMax = "freefiremax://"
        let target = selectedGame == "FFM" ? freeFireMax : freeFire
        let storeFallback = selectedGame == "FFM"
            ? "https://apps.apple.com/app/id1480516829"
            : "https://apps.apple.com/app/id1300146617"

        if let url = URL(string: target), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } else if let url = URL(string: storeFallback) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    public func selectGame(_ game: String) {
        selectedGame = game == "FFM" ? "FFM" : "FFTH"
        UserDefaults.standard.set(selectedGame, forKey: NABATIFeatureStore.gameStoreKey)
    }

    private static let gameStoreKey = "NBTAIMLOCK_SELECTED_GAME_V1"

    private func restoreSelectedGame() {
        if let stored = UserDefaults.standard.string(forKey: NABATIFeatureStore.gameStoreKey),
           stored == "FFTH" || stored == "FFM" {
            selectedGame = stored
        }
    }
}
