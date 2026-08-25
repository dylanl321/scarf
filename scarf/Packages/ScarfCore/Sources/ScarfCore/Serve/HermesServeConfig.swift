import Foundation

/// How a native client authenticates to `hermes serve` / `hermes dashboard`.
public enum HermesServeAuthMode: String, Sendable, Hashable, Codable {
    /// Loopback (or un-gated) server: `X-Hermes-Session-Token` / `?token=`.
    case sessionToken
    /// Non-loopback gate with the bundled username/password provider.
    case basic
}

/// Connection parameters for a Hermes installation reached over HTTP +
/// WebSocket (`hermes serve` / `hermes dashboard`, default port 9119).
public struct HermesServeConfig: Sendable, Hashable, Codable {
    /// Origin only — scheme + host + port, no path. Example:
    /// `http://192.168.1.10:9119`.
    public var baseURL: String
    /// Optional dashboard profile switcher (`?profile=`). `nil` = the
    /// server's own profile.
    public var profile: String?
    /// Auth mode last observed (or chosen at add-server time).
    public var authMode: HermesServeAuthMode
    /// Basic-auth username. Password stays in the credential store.
    public var username: String?

    public init(
        baseURL: String,
        profile: String? = nil,
        authMode: HermesServeAuthMode = .basic,
        username: String? = nil
    ) {
        self.baseURL = baseURL
        self.profile = profile
        self.authMode = authMode
        self.username = username
    }

    /// Normalized origin used as a cache / Keychain fingerprint.
    public var fingerprint: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let profilePart = (profile ?? "").trimmingCharacters(in: .whitespaces)
        return "serve|\(trimmed)|\(profilePart)"
    }
}
