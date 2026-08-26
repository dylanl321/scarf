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

    public func loginBasic(username: String, password: String, provider: String? = nil) async throws {
        let resolved = provider.flatMap { $0.isEmpty ? nil : $0 } ?? "basic"
        let body = try JSONSerialization.data(
            withJSONObject: [
                "provider": resolved,
                "username": username,
                "password": password,
            ]
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
        try await listSessionPage().sessions
    }

    /// `GET /api/sessions?limit=&offset=&order=recent`. Hermes caps
    /// `limit` at 100. Older servers that return a bare array still
    /// decode; `total` then equals the page count.
    public func listSessionPage(
        limit: Int = QueryDefaults.dashboardSessionPageSize,
        offset: Int = 0,
        order: String = "recent"
    ) async throws -> HermesServeSessionPage {
        let path = queryPath("/api/sessions", [
            "limit": String(min(max(limit, 1), 100)),
            "offset": String(max(offset, 0)),
            "order": order,
        ])
        let data = try await get(path: path, authenticated: true)
        if let array = try? decode([HermesServeSessionDTO].self, from: data) {
            let sessions = array.map { $0.asHermesSession() }
            return HermesServeSessionPage(
                sessions: sessions,
                total: sessions.count,
                limit: limit,
                offset: offset
            )
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["sessions"] {
            let wrapped = try JSONSerialization.data(withJSONObject: raw)
            let array = try decode([HermesServeSessionDTO].self, from: wrapped)
            let sessions = array.map { $0.asHermesSession() }
            let total = (obj["total"] as? Int)
                ?? (obj["total"] as? NSNumber)?.intValue
                ?? sessions.count
            return HermesServeSessionPage(
                sessions: sessions,
                total: total,
                limit: (obj["limit"] as? Int) ?? limit,
                offset: (obj["offset"] as? Int) ?? offset
            )
        }
        throw HermesServeError.decoding("sessions list")
    }

    public func fetchConfigJSON() async throws -> Data {
        try await get(path: profiled("/api/config"), authenticated: true)
    }

    /// `GET /api/config/raw` → `{yaml, path?}`. The dashboard JSON
    /// endpoint flattens `model` to a string and drops `provider`;
    /// this is the on-disk `config.yaml`.
    public func fetchConfigRaw() async throws -> HermesServeRawConfigDTO {
        let data = try await get(path: profiled("/api/config/raw"), authenticated: true)
        return try decode(HermesServeRawConfigDTO.self, from: data)
    }

    /// `GET /api/model/info` → resolved `{model, provider, ...}`.
    public func fetchModelInfo() async throws -> HermesServeModelInfoDTO {
        let data = try await get(path: profiled("/api/model/info"), authenticated: true)
        return try decode(HermesServeModelInfoDTO.self, from: data)
    }

    public func putConfigJSON(_ json: Data) async throws {
        let body = try HermesServeConfigJSON.wrapPutBody(json)
        _ = try await request(
            path: profiled("/api/config"),
            method: "PUT",
            body: body,
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

    /// `POST /api/cron/jobs`. Used by the ScarfGo debug-review wizard
    /// (not a general cron editor).
    @discardableResult
    public func createCronJob(
        name: String,
        prompt: String,
        schedule: String,
        deliver: String = "local",
        enabled: Bool = true
    ) async throws -> Data {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "name": name,
                "prompt": prompt,
                "schedule": schedule,
                "deliver": deliver,
                "enabled": enabled,
            ]
        )
        return try await request(
            path: "/api/cron/jobs",
            method: "POST",
            body: body,
            authenticated: true
        )
    }

    public func enableWebhooks() async throws {
        _ = try await request(
            path: "/api/webhooks/enable",
            method: "POST",
            body: nil,
            authenticated: true
        )
    }

    @discardableResult
    public func createWebhook(
        name: String,
        script: String?,
        deliver: String,
        secret: String?,
        description: String? = nil
    ) async throws -> HermesServeWebhookDTO {
        var payload: [String: Any] = [
            "name": name,
            "deliver": deliver,
        ]
        if let script, !script.isEmpty { payload["script"] = script }
        if let secret, !secret.isEmpty { payload["secret"] = secret }
        if let description, !description.isEmpty { payload["description"] = description }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request(
            path: "/api/webhooks",
            method: "POST",
            body: body,
            authenticated: true
        )
        if let dto = try? decode(HermesServeWebhookDTO.self, from: data) {
            return dto
        }
        return HermesServeWebhookDTO(
            name: name,
            description: description,
            events: nil,
            deliver: deliver,
            url: nil,
            script: script,
            secret: secret
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
            try await loginBasic(username: user, password: secret, provider: status.passwordLoginProvider)
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

    /// `GET /api/skills/content?name=`. Dashboard editor payload.
    public func fetchSkillContent(name: String) async throws -> HermesServeSkillContentDTO {
        let path = profiled(queryPath("/api/skills/content", ["name": name]))
        let data = try await get(path: path, authenticated: true)
        return try decode(HermesServeSkillContentDTO.self, from: data)
    }

    /// `GET /api/skills/hub/sources` featured list — Hermes browse analog
    /// (empty-query search returns nothing).
    public func listSkillHubFeatured() async throws -> [HermesHubSkill] {
        let data = try await get(path: profiled("/api/skills/hub/sources"), authenticated: true)
        let dto = try decode(HermesServeHubSourcesDTO.self, from: data)
        return (dto.featured ?? []).compactMap { $0.asHermesHubSkill() }
    }

    /// `GET /api/skills/hub/search?q=&source=&limit=`.
    public func searchSkillHub(
        query: String,
        source: String = "all",
        limit: Int = 40
    ) async throws -> [HermesHubSkill] {
        let path = profiled(queryPath("/api/skills/hub/search", [
            "q": query,
            "source": source,
            "limit": String(min(max(limit, 1), 50)),
        ]))
        let data = try await get(path: path, authenticated: true)
        let dto = try decode(HermesServeHubSearchDTO.self, from: data)
        return (dto.results ?? []).compactMap { $0.asHermesHubSkill() }
    }

    public func installHubSkill(identifier: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["identifier": identifier])
        _ = try await request(
            path: profiled("/api/skills/hub/install"),
            method: "POST",
            body: body,
            authenticated: true
        )
    }

    public func uninstallHubSkill(name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        _ = try await request(
            path: profiled("/api/skills/hub/uninstall"),
            method: "POST",
            body: body,
            authenticated: true
        )
    }

    public func updateHubSkills() async throws {
        _ = try await request(
            path: profiled("/api/skills/hub/update"),
            method: "POST",
            body: nil,
            authenticated: true
        )
    }

    /// Login (or token-mode stash) for a serve `ServerContext`.
    public static func authenticated(
        context: ServerContext,
        session: URLSession? = nil
    ) async throws -> HermesServeClient {
        guard let cfg = context.serveConfig else {
            throw HermesServeError.notAServeContext
        }
        let client = HermesServeClient(config: cfg, session: session)
        try await client.authenticate(serverID: context.id, username: cfg.username)
        return client
    }

    // MARK: - HTTP

    func profiled(_ path: String) -> String {
        guard let profile = config.profile, !profile.isEmpty else { return path }
        let sep = path.contains("?") ? "&" : "?"
        return "\(path)\(sep)profile=\(profile)"
    }

    func get(path: String, authenticated: Bool) async throws -> Data {
        try await request(path: path, method: "GET", body: nil, authenticated: authenticated)
    }

    @discardableResult
    func request(
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
        throw HermesServeError.httpStatus(http.statusCode, "")
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HermesServeError.decoding(error.localizedDescription)
        }
    }

    func queryPath(_ path: String, _ items: [String: String?]) -> String {
        var comps = URLComponents()
        comps.path = path
        let queryItems = items.compactMap { key, value -> URLQueryItem? in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        if !queryItems.isEmpty {
            comps.queryItems = queryItems
        }
        return comps.string ?? path
    }
}
