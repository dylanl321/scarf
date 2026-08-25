import Foundation

/// HTTP client for `hermes serve` / `hermes dashboard`.
///
/// Inject `session` in tests (URLProtocol stub). Production uses a
/// cookie-aware `URLSession` so password-login cookies attach to later
/// `/api/*` and `/api/auth/ws-ticket` calls.
public actor HermesServeClient {
    public let config: HermesServeConfig
    private let session: URLSession
    /// Loopback token, or last ticket — never logged.
    private var sessionToken: String?

    public init(config: HermesServeConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let conf = URLSessionConfiguration.ephemeral
            conf.httpCookieAcceptPolicy = .always
            conf.httpShouldSetCookies = true
            self.session = URLSession(configuration: conf)
        }
    }

    public func originURL() throws -> URL {
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw HermesServeError.invalidURL(trimmed)
        }
        return url
    }

    // MARK: - Public API

    public func fetchStatus() async throws -> HermesServeStatus {
        let data = try await get(path: "/api/status", authenticated: false)
        return try decode(HermesServeStatus.self, from: data)
    }

    /// Probe used by Add Server / onboarding. Classifies auth and, in
    /// token mode, stashes the process session token.
    public func probe() async throws -> HermesServeStatus {
        let status = try await fetchStatus()
        if status.advertisedAuthMode == .sessionToken, let token = status.session_token {
            sessionToken = token
        }
        return status
    }

    public func loginBasic(username: String, password: String) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["username": username, "password": password]
        )
        _ = try await request(
            path: "/auth/password-login",
            method: "POST",
            body: body,
            authenticated: false,
            acceptRedirect: true
        )
        _ = try await me()
    }

    public func me() async throws -> HermesServeAuthMe {
        let data = try await get(path: "/api/auth/me", authenticated: true)
        return try decode(HermesServeAuthMe.self, from: data)
    }

    public func mintWSTicket() async throws -> String {
        let data = try await request(
            path: "/api/auth/ws-ticket",
            method: "POST",
            body: nil,
            authenticated: true
        )
        let ticket = try decode(HermesServeWSTicket.self, from: data)
        return ticket.ticket
    }

    public func websocketURL() async throws -> URL {
        let origin = try originURL()
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        comps?.scheme = (origin.scheme == "https") ? "wss" : "ws"
        comps?.path = "/api/ws"
        var items: [URLQueryItem] = []
        if let profile = config.profile, !profile.isEmpty {
            items.append(URLQueryItem(name: "profile", value: profile))
        }
        switch config.authMode {
        case .sessionToken:
            // `??` is an autoclosure and cannot contain `await`.
            let token: String?
            if let existing = sessionToken {
                token = existing
            } else {
                token = (try? await fetchStatus())?.session_token
            }
            if let token {
                items.append(URLQueryItem(name: "token", value: token))
            }
        case .basic:
            let ticket = try await mintWSTicket()
            items.append(URLQueryItem(name: "ticket", value: ticket))
        }
        comps?.queryItems = items.isEmpty ? nil : items
        guard let url = comps?.url else {
            throw HermesServeError.invalidURL(origin.absoluteString)
        }
        return url
    }

    public func listSessions() async throws -> [HermesSession] {
        let data = try await get(path: "/api/sessions", authenticated: true)
        if let array = try? decode([HermesServeSessionDTO].self, from: data) {
            return array.map { $0.asHermesSession() }
        }
        // Some builds wrap the list.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["sessions"] {
            let wrapped = try JSONSerialization.data(withJSONObject: raw)
            let array = try decode([HermesServeSessionDTO].self, from: wrapped)
            return array.map { $0.asHermesSession() }
        }
        throw HermesServeError.decoding("sessions list")
    }

    public func fetchConfigJSON() async throws -> Data {
        try await get(path: profiled("/api/config"), authenticated: true)
    }

    public func putConfigJSON(_ json: Data) async throws {
        _ = try await request(
            path: profiled("/api/config"),
            method: "PUT",
            body: json,
            authenticated: true
        )
    }

    public func listCronJobs() async throws -> Data {
        try await get(path: "/api/cron/jobs", authenticated: true)
    }

    public func pauseCronJob(id: String) async throws {
        _ = try await request(
            path: "/api/cron/jobs/\(id)/pause",
            method: "POST",
            body: nil,
            authenticated: true
        )
    }

    public func resumeCronJob(id: String) async throws {
        _ = try await request(
            path: "/api/cron/jobs/\(id)/resume",
            method: "POST",
            body: nil,
            authenticated: true
        )
    }

    public func deleteCronJob(id: String) async throws {
        _ = try await request(
            path: "/api/cron/jobs/\(id)",
            method: "DELETE",
            body: nil,
            authenticated: true
        )
    }

    public func listSkills() async throws -> [HermesServeSkillDTO] {
        let data = try await get(path: profiled("/api/skills"), authenticated: true)
        if let array = try? decode([HermesServeSkillDTO].self, from: data) {
            return array
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["skills"] {
            let wrapped = try JSONSerialization.data(withJSONObject: raw)
            return try decode([HermesServeSkillDTO].self, from: wrapped)
        }
        throw HermesServeError.decoding("skills list")
    }

    public func toggleSkill(name: String, enabled: Bool) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["name": name, "enabled": enabled]
        )
        _ = try await request(
            path: profiled("/api/skills/toggle"),
            method: "PUT",
            body: body,
            authenticated: true
        )
    }

    public func applySessionToken(_ token: String) {
        sessionToken = token
    }

    /// Login (or token-mode stash) using the process credential store.
    public func authenticate(serverID: ServerID, username: String?) async throws {
        let status = try await probe()
        switch status.advertisedAuthMode {
        case .sessionToken:
            if let token = status.session_token {
                applySessionToken(token)
            }
        case .basic:
            let store = HermesServeRuntime.credentials
            let secret: String
            if let loaded = try await store.load(for: serverID) {
                secret = loaded
            } else if let loaded = try await store.load(fingerprint: config.fingerprint) {
                secret = loaded
            } else {
                secret = ""
            }
            let user = username ?? config.username ?? ""
            try await loginBasic(username: user, password: secret)
        }
    }

    public func listCronJobsDecoded() async throws -> [HermesCronJob] {
        let data = try await listCronJobs()
        if let jobs = try? JSONDecoder().decode([HermesCronJob].self, from: data) {
            return jobs
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["jobs"] {
            let wrapped = try JSONSerialization.data(withJSONObject: raw)
            if let jobs = try? JSONDecoder().decode([HermesCronJob].self, from: wrapped) {
                return jobs
            }
            let dtos = try JSONDecoder().decode([HermesServeCronJobDTO].self, from: wrapped)
            return dtos.map { $0.asHermesCronJob() }
        }
        if let dtos = try? JSONDecoder().decode([HermesServeCronJobDTO].self, from: data) {
            return dtos.map { $0.asHermesCronJob() }
        }
        throw HermesServeError.decoding("cron jobs")
    }

    public func listSkillCategories() async throws -> [HermesSkillCategory] {
        let skills = try await listSkills()
        var byCategory: [String: [HermesSkill]] = [:]
        for dto in skills {
            let skill = dto.asHermesSkill()
            byCategory[skill.category, default: []].append(skill)
        }
        return byCategory.keys.sorted().map { key in
            HermesSkillCategory(id: key, name: key, skills: byCategory[key] ?? [])
        }
    }

    // MARK: - HTTP

    private func profiled(_ path: String) -> String {
        guard let profile = config.profile, !profile.isEmpty else { return path }
        let sep = path.contains("?") ? "&" : "?"
        return "\(path)\(sep)profile=\(profile)"
    }

    private func get(path: String, authenticated: Bool) async throws -> Data {
        try await request(path: path, method: "GET", body: nil, authenticated: authenticated)
    }

    @discardableResult
    private func request(
        path: String,
        method: String,
        body: Data?,
        authenticated: Bool,
        acceptRedirect: Bool = false
    ) async throws -> Data {
        let origin = try originURL()
        guard let url = URL(string: path, relativeTo: origin) else {
            throw HermesServeError.invalidURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            if let token = sessionToken {
                req.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
            }
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HermesServeError.httpStatus(-1, "non-HTTP response")
        }
        if http.statusCode == 401 { throw HermesServeError.unauthorized }
        if (200...299).contains(http.statusCode) { return data }
        if acceptRedirect, (300...399).contains(http.statusCode) { return data }
        let snippet = String(data: data, encoding: .utf8) ?? ""
        let clipped = String(snippet.prefix(200))
        throw HermesServeError.httpStatus(http.statusCode, clipped)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HermesServeError.decoding(error.localizedDescription)
        }
    }
}
