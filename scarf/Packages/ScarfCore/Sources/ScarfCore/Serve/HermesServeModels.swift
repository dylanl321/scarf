import Foundation

/// Public `GET /api/status` body. Extra keys are ignored.
public struct HermesServeStatus: Sendable, Hashable, Codable {
    public var version: String?
    public var agent_version: String?
    public var auth_required: Bool?
    public var auth_providers: [String]?
    public var session_token: String?

    public init(
        version: String? = nil,
        agent_version: String? = nil,
        auth_required: Bool? = nil,
        auth_providers: [String]? = nil,
        session_token: String? = nil
    ) {
        self.version = version
        self.agent_version = agent_version
        self.auth_required = auth_required
        self.auth_providers = auth_providers
        self.session_token = session_token
    }

    public var advertisedAuthMode: HermesServeAuthMode {
        (auth_required ?? false) ? .basic : .sessionToken
    }

    /// Provider id for `POST /auth/password-login`. Hermes requires this
    /// field; the bundled dashboard plugin is `basic`.
    public var passwordLoginProvider: String {
        let names = (auth_providers ?? []).filter { !$0.isEmpty }
        if names.contains("basic") { return "basic" }
        return names.first ?? "basic"
    }

    /// Best-effort version line for `HermesCapabilities.parse`.
    public var versionLineForCapabilities: String {
        if let version, version.contains("Hermes Agent v") { return version }
        if let agent_version, agent_version.contains("Hermes Agent v") {
            return agent_version
        }
        if let version, version.contains("v") {
            return "Hermes Agent \(version.hasPrefix("v") ? version : "v\(version)")"
        }
        if let agent_version {
            return "Hermes Agent v\(agent_version)"
        }
        return ""
    }
}

public struct HermesServeAuthMe: Sendable, Hashable, Codable {
    public var provider: String?
    public var user_id: String?
    public var email: String?
}

public struct HermesServeWSTicket: Sendable, Hashable, Codable {
    public var ticket: String
    public var ttl_seconds: Int?
}

/// Session row as returned by `GET /api/sessions`. Unknown fields ignored.
public struct HermesServeSessionDTO: Sendable, Hashable, Codable {
    public var id: String
    public var title: String?
    public var source: String?
    public var model: String?
    public var message_count: Int?
    public var tool_call_count: Int?
    public var started_at: Double?
    public var ended_at: Double?
    public var preview: String?
    public var input_tokens: Int?
    public var output_tokens: Int?
    public var estimated_cost_usd: Double?

    public func asHermesSession() -> HermesSession {
        let started = started_at.map { Date(timeIntervalSince1970: $0) }
        let ended = ended_at.map { Date(timeIntervalSince1970: $0) }
        return HermesSession(
            id: id,
            source: source ?? "cli",
            userId: nil,
            model: model,
            title: title,
            parentSessionId: nil,
            startedAt: started,
            endedAt: ended,
            endReason: nil,
            messageCount: message_count ?? 0,
            toolCallCount: tool_call_count ?? 0,
            inputTokens: input_tokens ?? 0,
            outputTokens: output_tokens ?? 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            estimatedCostUSD: estimated_cost_usd,
            reasoningTokens: 0,
            actualCostUSD: nil,
            costStatus: nil,
            billingProvider: nil,
            apiCallCount: 0,
            rewindCount: 0,
            pinned: false,
            lastActivityAt: ended ?? started,
            lastActivityDescription: preview,
            lastReadAt: nil,
            lastActive: ended ?? started
        )
    }
}

public struct HermesServeCronJobDTO: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var prompt: String?
    public var schedule: String?
    public var state: String?
    public var enabled: Bool?
    public var deliver: String?

    public func asHermesCronJob() -> HermesCronJob {
        HermesCronJob(
            id: id,
            name: name ?? id,
            prompt: prompt ?? "",
            schedule: CronSchedule(
                kind: "cron",
                display: schedule,
                expression: schedule
            ),
            enabled: enabled ?? (state != "paused"),
            state: state ?? "idle",
            deliver: deliver
        )
    }
}

public struct HermesServeSkillDTO: Sendable, Hashable, Codable {
    public var name: String
    public var description: String?
    public var category: String?
    public var enabled: Bool?

    public func asHermesSkill() -> HermesSkill {
        let categoryName = (category?.isEmpty == false) ? category! : "other"
        return HermesSkill(
            id: name,
            name: name,
            category: categoryName,
            path: "",
            files: [],
            requiredConfig: [],
            enabled: enabled ?? true,
            pinned: false
        )
    }
}

public enum HermesServeError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case httpStatus(Int, String)
    case unauthorized
    case decoding(String)
    case notAServeContext
    case transportUnavailable
    case websocket(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s):
            return "Invalid Hermes URL: \(s)"
        case .httpStatus(let code, let body):
            return "Hermes serve returned HTTP \(code). \(Self.redactSecrets(in: body))"
        case .unauthorized:
            return "Hermes serve rejected the credentials. Check username and password."
        case .decoding(let msg):
            return "Couldn't read Hermes serve response: \(msg)"
        case .notAServeContext:
            return "This server is not a Hermes URL connection."
        case .transportUnavailable:
            return "Hermes URL connections do not support SSH file or process I/O."
        case .websocket(let msg):
            return "Hermes chat WebSocket failed: \(msg)"
        }
    }

    /// Pydantic 422s echo the request body, including the password.
    static func redactSecrets(in body: String) -> String {
        let pattern = #""password"\s*:\s*"(?:\\.|[^"\\])*""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return body }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.stringByReplacingMatches(in: body, options: [], range: range, withTemplate: "\"password\":\"***\"")
    }
}
