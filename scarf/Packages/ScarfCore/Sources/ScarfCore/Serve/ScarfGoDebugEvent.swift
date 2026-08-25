import Foundation

/// One redacted ScarfGo client event. Landed as JSONL with no LLM.
public struct ScarfGoDebugEvent: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(ts)|\(kind)|\(code)" }
    public var ts: String
    public var app: String
    public var kind: String
    public var code: String
    public var message: String
    public var connection: String
    public var serverFingerprint: String?

    public init(
        ts: String,
        app: String,
        kind: String,
        code: String,
        message: String,
        connection: String,
        serverFingerprint: String? = nil
    ) {
        self.ts = ts
        self.app = app
        self.kind = kind
        self.code = code
        self.message = message
        self.connection = connection
        self.serverFingerprint = serverFingerprint
    }
}

public enum ScarfGoDebugKind: String, Sendable {
    case error
    case hang
    case login
    case chatFail = "chat-fail"
    case test
}

public enum ScarfGoDebugRedactor: Sendable {
    private static let secretNeedles = [
        "password", "secret", "token", "authorization", "cookie", "api_key", "api-key",
    ]

    public static func keyLooksSecret(_ key: String) -> Bool {
        let lower = key.lowercased()
        return secretNeedles.contains { lower.contains($0) }
    }

    /// Strip secret-shaped substrings and clamp message text.
    public static func redact(message: String) -> String {
        var text = message
        for needle in secretNeedles {
            if let range = text.range(of: needle, options: .caseInsensitive) {
                text.replaceSubrange(range, with: "[redacted]")
            }
        }
        if text.count > 400 {
            text = String(text.prefix(400)) + "…"
        }
        return text
    }

    public static func stripSecretKeys(from object: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in object {
            if keyLooksSecret(key) { continue }
            if let nested = value as? [String: Any] {
                out[key] = stripSecretKeys(from: nested)
            } else if let text = value as? String {
                out[key] = redact(message: text)
            } else {
                out[key] = value
            }
        }
        return out
    }

    public static func connectionLabel(for config: IOSServerConfig) -> String {
        if config.isServe && config.hasCompanionSSH { return "hybrid" }
        if config.isServe { return "serve" }
        return "ssh"
    }
}
