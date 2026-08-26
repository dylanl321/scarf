import Foundation
import CoreFoundation

/// Mapping between Hermes serve's web-normalized config JSON and the
/// YAML-shaped keys `HermesConfig` reads.
///
/// `GET /api/config` runs `_normalize_config_for_web`: a `model: {default,
/// provider, ...}` mapping becomes a **string** `model` (the default name)
/// and `provider` is dropped. `PUT /api/config` expects `{ "config": {…} }`
/// — the dashboard's `saveConfig` body — not the bare object.
enum HermesServeConfigJSON {
    /// Flatten a JSON object into `key: value` lines so `HermesConfig(yaml:)`
    /// can still pick out the fields it knows. A scalar `model` is also
    /// emitted as `model.default` so it isn't parsed as `"unknown"`.
    static func yamlishFromJSON(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        var lines: [String] = []
        func walk(_ node: Any, prefix: String) {
            if let dict = node as? [String: Any] {
                for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                    let next = prefix.isEmpty ? k : "\(prefix).\(k)"
                    walk(v, prefix: next)
                }
            } else if let arr = node as? [Any] {
                let joined = arr.map { "\($0)" }.joined(separator: ", ")
                lines.append("\(prefix): [\(joined)]")
            } else {
                let scalar = Self.yamlScalar(node)
                lines.append("\(prefix): \(scalar)")
                if prefix == "model" {
                    lines.append("model.default: \(scalar)")
                }
            }
        }
        walk(obj, prefix: "")
        return lines.joined(separator: "\n")
    }

    /// Wrap a config object as `{ "config": … }` unless it is already that
    /// envelope (a single `config` key whose value is a dictionary).
    static func wrapPutBody(_ json: Data) throws -> Data {
        let obj = try JSONSerialization.jsonObject(with: json)
        if let dict = obj as? [String: Any],
           dict.count == 1,
           dict["config"] is [String: Any] {
            return json
        }
        return try JSONSerialization.data(withJSONObject: ["config": obj])
    }

    /// Patch a dotted key on the GET `/api/config` object.
    ///
    /// `model.default` writes the web-normalized string `model` when that's
    /// how Hermes returned it, so `_denormalize_config_from_web` can recover
    /// provider / base_url from disk. `model.provider` upgrades a string
    /// `model` into `{default, provider}` so the provider isn't dropped.
    static func setJSONValue(_ data: Data, dottedKey: String, value: String) throws -> Data {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard var root = obj as? [String: Any] else {
            throw HermesServeError.decoding("config is not a JSON object")
        }
        let parts = dottedKey.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { throw HermesServeError.decoding("empty config key") }

        let typed: Any
        if value == "true" { typed = true }
        else if value == "false" { typed = false }
        else if let n = Int(value) { typed = n }
        else { typed = value }

        if dottedKey == "model.default" {
            if let current = root["model"], !(current is [String: Any]) {
                root["model"] = typed
                return try JSONSerialization.data(withJSONObject: root)
            }
        }
        if dottedKey == "model.provider" {
            var child: [String: Any]
            if let dict = root["model"] as? [String: Any] {
                child = dict
            } else if let existing = root["model"] {
                child = ["default": existing]
            } else {
                child = [:]
            }
            child["provider"] = typed
            root["model"] = child
            return try JSONSerialization.data(withJSONObject: root)
        }

        func set(_ dict: inout [String: Any], path: [String], value: Any) {
            guard let first = path.first else { return }
            if path.count == 1 {
                dict[first] = value
                return
            }
            var child = dict[first] as? [String: Any] ?? [:]
            set(&child, path: Array(path.dropFirst()), value: value)
            dict[first] = child
        }
        set(&root, path: parts, value: typed)
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Fill `unknown`/empty model + provider from `/api/model/info`.
    static func overlayModelInfo(
        _ config: HermesConfig,
        _ info: HermesServeModelInfoDTO
    ) -> HermesConfig {
        var next = config
        if Self.isMissing(next.model), let model = info.model, !model.isEmpty {
            next.model = model
        }
        if Self.isMissing(next.provider), let provider = info.provider, !provider.isEmpty {
            next.provider = provider
        }
        return next
    }

    private static func isMissing(_ value: String) -> Bool {
        value.isEmpty || value == "unknown"
    }

    /// JSONSerialization turns `true`/`false` into `NSNumber`. Print the
    /// YAML booleans `HermesConfig` actually recognizes.
    private static func yamlScalar(_ node: Any) -> String {
        if let n = node as? NSNumber, CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
            return n.boolValue ? "true" : "false"
        }
        return "\(node)"
    }
}
