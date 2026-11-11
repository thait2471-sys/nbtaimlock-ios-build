import Foundation

/// Remote Configuration and Asset Synchronization Manager
public final class RemoteConfigManager {

    public static let shared = RemoteConfigManager()
    private let remoteConfigEndpoint = "https://nbtaimlockshopcom.thait2471.workers.dev/api/config"
    private let cacheFileName = "nbt_remote_config_cache.json"

    public private(set) var activeConfig: [String: Any] = [:]

    private init() {
        loadCachedConfig()
    }

    /// Fetches latest UI/Theme configuration from server without requiring new IPA install
    public func fetchLatestConfig(completion: @escaping (Bool, [String: Any]?) -> Void) {
        guard let url = URL(string: "\(remoteConfigEndpoint)?_t=\(Int(Date().timeIntervalSince1970))") else {
            completion(false, nil)
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
        request.setValue("ios_ipa", forHTTPHeaderField: "X-Client-Platform")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else {
                completion(false, self?.activeConfig)
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let config = json["config"] as? [String: Any] {
                    self.activeConfig = config
                    self.saveConfigToCache(data: data)
                    DispatchQueue.main.async {
                        completion(true, config)
                    }
                    return
                }
            } catch {
                print("Failed to parse remote config: \(error)")
            }

            DispatchQueue.main.async {
                completion(false, self.activeConfig)
            }
        }
        task.resume()
    }

    private func getCacheFileURL() -> URL? {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return cacheDir.appendingPathComponent(cacheFileName)
    }

    private func saveConfigToCache(data: Data) {
        guard let url = getCacheFileURL() else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadCachedConfig() {
        guard let url = getCacheFileURL(), let data = try? Data(contentsOf: url) else {
            // Default built-in fallback
            self.activeConfig = [
                "appName": "⚡ NBTAIMLOCK iOS",
                "bgImageUrl": "bg-nabati-iphone.jpg",
                "keyInputTimeoutSeconds": 45
            ]
            return
        }
        if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
           let config = json["config"] as? [String: Any] {
            self.activeConfig = config
        }
    }
}
