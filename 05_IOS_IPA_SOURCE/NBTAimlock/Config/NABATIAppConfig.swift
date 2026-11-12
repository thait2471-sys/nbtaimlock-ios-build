import Foundation
import UIKit

/// Server-driven client configuration.
///
/// The admin "Chức năng kéo tâm" panel writes one `app_config` row that the
/// Worker merges over `DEFAULT_CONFIG` and serves at `GET /api/config`. Every
/// field below mirrors that payload so the iOS dashboard renders the exact
/// same feature modules, brand text, marquee announcement and optimization
/// flag the web client uses — synced live, not hardcoded.
///
/// A toggle is only *shown* when the server lists the module; authorization to
/// actually run it still goes through `/api/license/authorize` per module.
public struct NABATIAppConfig {
    public var appName: String
    public var appSub: String
    public var announcement: String
    public var showAnnouncement: Bool
    public var optimizeAnimation: Bool
    public var features: [NABATIFeature]

    public struct NABATIFeature {
        public let id: String
        public let category: String   // "aim" | "device"
        public let name: String
        public let desc: String
        public let icon: String

        public init(id: String, category: String, name: String, desc: String, icon: String) {
            self.id = id
            self.category = category
            self.name = name
            self.desc = desc
            self.icon = icon
        }
    }

    /// The shipped fallback. Mirrors `DEFAULT_CONFIG` in `worker.js` so a brand
    /// new device that has not fetched config yet still shows the same eight
    /// modules the web client renders.
    public static let `default` = NABATIAppConfig(
        appName: "⚡ NBTAIMLOCK v4.2",
        appSub: "HỖ TRỢ KÉO TÂM & CẢM ỨNG DI ĐỘNG",
        announcement: "🔥 Chào mừng đến với hệ thống hỗ trợ kéo tâm đỉnh cao NBTAIMLOCK VIP! Chúc anh em kéo tâm full đỏ!",
        showAnnouncement: true,
        optimizeAnimation: true,
        features: [
            NABATIFeature(id: "feat_aim_1", category: "aim",    name: "Data Aimlock",        desc: "Hỗ Trợ Bám Đầu Cao Tỉ Lệ 65%",           icon: "crosshair"),
            NABATIFeature(id: "feat_aim_2", category: "aim",    name: "AimBot Drag Head",    desc: "Nhẹ Tâm Kéo Đầu Cận Chiến & Tầm Xa",     icon: "eye"),
            NABATIFeature(id: "feat_aim_3", category: "aim",    name: "No Recoil 2x & 4x",   desc: "Ổn Định Đường Đạn Khi Bật Ống Ngắm",      icon: "phone"),
            NABATIFeature(id: "feat_aim_4", category: "aim",    name: "Lock Bone Headshot",  desc: "Khóa Cứng Vị Trí Đầu & Chống Rung Tâm",   icon: "bolt"),
            NABATIFeature(id: "feat_dev_1", category: "device", name: "Smooth Game",         desc: "Làm Mượt Khung Hình, Giảm Giật Lag",      icon: "eye"),
            NABATIFeature(id: "feat_dev_2", category: "device", name: "Phone Sensi",         desc: "Cảm Biến Nhạy Máy Hơn",                   icon: "phone"),
            NABATIFeature(id: "feat_dev_3", category: "device", name: "Speed Touch Screen",  desc: "Tốc Độ Kéo Thả Màn Hình Nhanh Hơn",       icon: "bolt"),
            NABATIFeature(id: "feat_dev_4", category: "device", name: "Boost 120FPS & RAM",  desc: "Giải Phóng Bộ Nhớ Đệm, Chống Nóng Máy",   icon: "crosshair"),
        ]
    )

    /// Parses the `/api/config` payload (`{ success, config: {...} }`).
    /// Returns `nil` when the body is not a valid config object so callers fall
    /// back to the shipped default instead of rendering an empty dashboard.
    public static func parse(_ json: [String: Any]) -> NABATIAppConfig? {
        let cfg = (json["config"] as? [String: Any]) ?? json
        var out = NABATIAppConfig.default

        if let s = cfg["appName"] as? String, !s.isEmpty { out.appName = s }
        if let s = cfg["appSub"] as? String, !s.isEmpty { out.appSub = s }
        if let s = cfg["announcement"] as? String { out.announcement = s }
        if let b = cfg["showAnnouncement"] as? Bool { out.showAnnouncement = b }
        if let b = cfg["optimizeAnimation"] as? Bool { out.optimizeAnimation = b }

        if let list = cfg["features"] as? [[String: Any]], !list.isEmpty {
            let total = list.count
            let half = Int(ceil(Double(total) / 2.0))
            let parsed: [NABATIFeature] = list.enumerated().compactMap { (index, raw) in
                guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
                let name = (raw["name"] as? String) ?? id
                let desc = (raw["desc"] as? String) ?? ""
                // Worker-side: when `category` is absent the first half is "aim",
                // the second half "device". Keep the same defaulting.
                let category = (raw["category"] as? String) ?? (index < half ? "aim" : "device")
                let icon = (raw["icon"] as? String) ?? "bolt"
                return NABATIFeature(id: id, category: category, name: name, desc: desc, icon: icon)
            }
            if !parsed.isEmpty { out.features = parsed }
        }
        return out
    }
}

/// Fetch layer for the public config endpoints.
public final class NABATIAppConfigClient {
    public static let shared = NABATIAppConfigClient()
    private init() {}

    public func fetch(completion: @escaping (Result<NABATIAppConfig, Error>) -> Void) {
        NABATINetwork.shared.get(endpoint: NBTF.K.apiConfig) { result in
            switch result {
            case .success(let json):
                if let cfg = NABATIAppConfig.parse(json) {
                    completion(.success(cfg))
                } else {
                    completion(.failure(NABATINetworkError.invalidPayload))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Fetches the active notices from `/api/announcement`.
    ///
    /// The web client loads this *in addition* to `config.announcement` and
    /// joins the rows into one marquee line (`title: content • title: content`).
    /// Keeping the same rule means an admin who posts a notice in the
    /// Announcements panel sees it on both clients without editing the config
    /// row as well.
    ///
    /// Returns an empty array — never an error — for "no notices", so callers
    /// can treat a failure and an empty list the same way.
    public func fetchAnnouncements(completion: @escaping ([String]) -> Void) {
        NABATINetwork.shared.get(endpoint: NBTF.K.apiAnnouncement) { result in
            guard case .success(let json) = result,
                  let rows = json["announcements"] as? [[String: Any]] else {
                completion([])
                return
            }
            let lines: [String] = rows.compactMap { row in
                let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let content = (row["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if title.isEmpty && content.isEmpty { return nil }
                if title.isEmpty { return content }
                if content.isEmpty { return title }
                return "\(title): \(content)"
            }
            completion(lines)
        }
    }
}
