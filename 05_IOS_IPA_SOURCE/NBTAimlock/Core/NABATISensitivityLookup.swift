import Foundation

/// Per-model sensitivity lookup — the same endpoint the web client's
/// "ĐỘ NHẠY THEO DÒNG MÁY" tab uses.
///
/// `GET /api/sensitivity?model=<q>` returns either:
///
///   * a hit — `found: true` plus a `presets` object with three tiers
///     (`light` / `mid` / `heavy`), each a `{ name, value, params, desc }` —
///   * a miss — `found: false` plus an optional `suggestions` array of
///     `{ brand, model }` rows the customer can tap to retry with.
///
/// The endpoint is public and read-only: it returns reference numbers for the
/// customer to type into the game's own settings screen. Nothing about the
/// request or response can unlock a feature, so no license field is sent.
public struct NABATISensitivityResult {
    public let brand: String
    public let model: String
    public let light: NABATISensitivityTier?
    public let mid: NABATISensitivityTier?
    public let heavy: NABATISensitivityTier?

    /// A tier name to the rendered, copyable configuration text. Used both by
    /// the "Sao chép" button and for keeping the on-screen numbers in sync with
    /// what goes to the clipboard.
    public func copyText(for tier: NABATISensitivityTier) -> String {
        var lines = [
            "\(brand) \(model) — \(tier.name)",
            "Độ nhạy: \(tier.value)"
        ]
        if !tier.params.isEmpty {
            lines.append(contentsOf: tier.params.map { "\($0.key): \($0.value)" })
        }
        return lines.joined(separator: "\n")
    }
}

public struct NABATISensitivityTier {
    public let name: String
    /// The headline sensitivity figure (e.g. "97").
    public let value: String
    /// Free-form `param → value` pairs from the database row.
    public let params: [String: String]
    public let desc: String
}

public enum NABATISensitivityLookup {
    public static func lookup(
        model rawModel: String,
        completion: @escaping (Result<NABATISensitivityResult, Error>) -> Void
    ) {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            completion(.failure(NABATINetworkError.invalidPayload))
            return
        }

        NABATINetwork.shared.get(endpoint: NBTF.K.apiSensitivity, query: ["model": model]) { result in
            switch result {
            case .success(let json):
                if (json["found"] as? Bool) == true {
                    completion(.success(parse(json)))
                } else {
                    // A 200 with `found: false` is a legitimate "no match"
                    // answer, not a transport failure. The suggestions it may
                    // carry are still useful, so surface them through the error.
                    let suggestions = parseSuggestions(json)
                    completion(.failure(NABATISensitivityMiss(suggestions: suggestions)))
                }

            case .failure(let error):
                // `found: false` can also come back as a 200 payload that took
                // the non-success HTTP path in a Worker variant — check the
                // verdict body too, so a suggestions list is never swallowed.
                if let netError = error as? NABATINetworkError, netError.isServerVerdict,
                   let payload = netError.payload {
                    if (payload["found"] as? Bool) == true {
                        completion(.success(parse(payload)))
                        return
                    }
                    let suggestions = parseSuggestions(payload)
                    if !suggestions.isEmpty || (payload["found"] as? Bool) == false {
                        completion(.failure(NABATISensitivityMiss(suggestions: suggestions)))
                        return
                    }
                }
                completion(.failure(error))
            }
        }
    }

    /// The endpoint's "no match" result. Carries the server's suggestion list
    /// so the UI can offer tappable alternatives instead of a dead end.
    public struct NABATISensitivityMiss: Error, LocalizedError {
        public let suggestions: [NABATISensitivitySuggestion]

        public var errorDescription: String? {
            suggestions.isEmpty
                ? "Không tìm thấy dòng máy này. Hãy thử tên khác."
                : "Không tìm thấy dòng máy này."
        }
    }

    public struct NABATISensitivitySuggestion {
        public let brand: String
        public let model: String
        public var query: String { "\(brand) \(model)".trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Parsing

    private static func parse(_ json: [String: Any]) -> NABATISensitivityResult {
        let presets = (json["presets"] as? [String: Any]) ?? [:]
        return NABATISensitivityResult(
            brand: (json["brand"] as? String) ?? "",
            model: (json["model"] as? String) ?? "",
            light: parseTier(presets["light"]),
            mid: parseTier(presets["mid"]),
            heavy: parseTier(presets["heavy"])
        )
    }

    private static func parseTier(_ raw: Any?) -> NABATISensitivityTier? {
        guard let tier = raw as? [String: Any] else { return nil }
        let rawParams = (tier["params"] as? [String: Any]) ?? [:]
        // `params` arrives from JSON and can be any scalar. Stringify each value
        // so the UI can render them all through one dictionary.
        let params = rawParams.reduce(into: [String: String]()) { out, pair in
            out[pair.key] = "\(pair.value)"
        }
        return NABATISensitivityTier(
            name: (tier["name"] as? String) ?? "",
            value: "\(tier["value"] ?? "")",
            params: params,
            desc: (tier["desc"] as? String) ?? ""
        )
    }

    private static func parseSuggestions(_ json: [String: Any]) -> [NABATISensitivitySuggestion] {
        guard let list = json["suggestions"] as? [[String: Any]] else { return [] }
        return list.compactMap { raw in
            let brand = (raw["brand"] as? String) ?? ""
            let model = (raw["model"] as? String) ?? ""
            guard !model.isEmpty else { return nil }
            return NABATISensitivitySuggestion(brand: brand, model: model)
        }
    }
}
