import Foundation

/// Explicit transport vs. server-verdict separation.
///
/// The server is the only authority on KEY validity, device binding, maintenance
/// and update state. A transport failure (no response) must never be interpreted
/// as a server verdict, in either direction.
public enum NABATINetworkError: Error, LocalizedError {
    /// Request never reached the server / no usable response.
    case transport(Error)
    /// Server answered with a non-2xx status and a JSON payload (verdict available).
    case http(status: Int, payload: [String: Any])
    /// Server answered but the body was not a JSON object.
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .transport(let error):
            return "Không thể kết nối máy chủ. Vui lòng kiểm tra mạng và thử lại. (\(error.localizedDescription))"
        case .http(_, let payload):
            return (payload["message"] as? String)
                ?? (payload["error"] as? String)
                ?? "Máy chủ từ chối yêu cầu."
        case .invalidPayload:
            return "Phản hồi từ máy chủ không hợp lệ."
        }
    }

    /// Server-side verdict payload, when the server actually answered.
    public var payload: [String: Any]? {
        if case .http(_, let payload) = self { return payload }
        return nil
    }

    public var httpStatus: Int? {
        if case .http(let status, _) = self { return status }
        return nil
    }

    /// A verdict was produced by the server (safe to act on).
    public var isServerVerdict: Bool {
        if case .http = self { return true }
        return false
    }
}

public final class NABATINetwork {
    public static let shared = NABATINetwork()
    private init() {}

    /// Decoded from the XOR table at runtime; see `NABATIObfuscation.swift`.
    public let primaryBaseURL = NBTF.K.baseURL

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 30.0
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - Shared request construction

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NABATIAppVersion.clientPlatform, forHTTPHeaderField: "X-Client-Platform")
        request.setValue(NABATIAppVersion.version, forHTTPHeaderField: "X-App-Version")
        request.setValue(NABATIAppVersion.version, forHTTPHeaderField: "X-Client-Version")
        request.setValue(NABATIAppVersion.build, forHTTPHeaderField: "X-Client-Build")
        request.setValue(NABATIDevice.shared.hardwareId, forHTTPHeaderField: "X-Device-Id")
        request.setValue("\(Int(Date().timeIntervalSince1970))", forHTTPHeaderField: "X-Request-Timestamp")
        if let token = NABATICrypto.shared.getSessionToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(_ request: URLRequest, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        session.dataTask(with: request) { data, response, error in
            // 1. Transport failure: no server verdict exists.
            if let error = error {
                DispatchQueue.main.async { completion(.failure(NABATINetworkError.transport(error))) }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NABATINetworkError.transport(
                        NSError(domain: "NABATINetwork", code: -2, userInfo: [
                            NSLocalizedDescriptionKey: "Máy chủ không trả về dữ liệu."
                        ])
                    )))
                }
                return
            }

            var parsed: [String: Any]? = nil
            if let object = try? JSONSerialization.jsonObject(with: data, options: []) {
                parsed = object as? [String: Any]
            }
            let json = parsed

            if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                guard let json = json else {
                    DispatchQueue.main.async { completion(.failure(NABATINetworkError.invalidPayload)) }
                    return
                }
                DispatchQueue.main.async { completion(.success(json)) }
                return
            }

            // 2. Server answered with a rejection verdict.
            let payload = json ?? [
                "code": "HTTP_\(httpResponse.statusCode)",
                "message": "Máy chủ trả về mã lỗi \(httpResponse.statusCode)."
            ]
            DispatchQueue.main.async {
                completion(.failure(NABATINetworkError.http(status: httpResponse.statusCode, payload: payload)))
            }
        }.resume()
    }

    // MARK: - POST

    public func post(endpoint: String, body: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = URL(string: primaryBaseURL + endpoint) else {
            completion(.failure(NABATINetworkError.transport(
                NSError(domain: "NABATINetwork", code: -1, userInfo: [NSLocalizedDescriptionKey: "API endpoint không hợp lệ."])
            )))
            return
        }

        var request = makeRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            completion(.failure(NABATINetworkError.transport(error)))
            return
        }

        perform(request, completion: completion)
    }

    // MARK: - GET

    public func get(endpoint: String, query: [String: String] = [:], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard var components = URLComponents(string: primaryBaseURL + endpoint) else {
            completion(.failure(NABATINetworkError.transport(
                NSError(domain: "NABATINetwork", code: -1, userInfo: [NSLocalizedDescriptionKey: "API endpoint không hợp lệ."])
            )))
            return
        }
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            completion(.failure(NABATINetworkError.transport(
                NSError(domain: "NABATINetwork", code: -1, userInfo: [NSLocalizedDescriptionKey: "Không dựng được URL yêu cầu."])
            )))
            return
        }

        perform(makeRequest(url: url, method: "GET"), completion: completion)
    }
}

/// Single source of truth for the client version/build reported to the server.
/// Must match CFBundleShortVersionString / CFBundleVersion in Info.plist.
public enum NABATIAppVersion {
    public static let version = "4.2.0"
    public static let build = "420"
    public static let platform = "ios"
    public static let clientPlatform = NBTF.K.clientPlatform
}
