import Testing
import Foundation
@testable import ScarfCore

@Suite(.serialized) struct HermesServeTests {

    @Test func serveConfigFingerprintAndCodable() throws {
        let src = HermesServeConfig(
            baseURL: "http://192.168.1.10:9119",
            profile: "work",
            authMode: .basic
        )
        #expect(src.fingerprint == "serve|http://192.168.1.10:9119|work")
        let data = try JSONEncoder().encode(src)
        let dec = try JSONDecoder().decode(HermesServeConfig.self, from: data)
        #expect(dec == src)
    }

    @Test func serverKindServeRoundTrip() throws {
        let kind = ServerKind.serve(HermesServeConfig(baseURL: "http://h:9119"))
        let data = try JSONEncoder().encode(kind)
        let dec = try JSONDecoder().decode(ServerKind.self, from: data)
        #expect(dec == kind)
    }

    @Test func serveContextIsRemoteAndDoesNotUseSSHTransport() {
        let ctx = ServerContext(
            id: ServerID(),
            displayName: "Serve box",
            kind: .serve(HermesServeConfig(baseURL: "http://127.0.0.1:9119"))
        )
        #expect(ctx.isRemote)
        #expect(ctx.isServe)
        #expect(ctx.serveConfig?.baseURL == "http://127.0.0.1:9119")
        #expect(ctx.makeTransport() is ServeUnavailableTransport)
        #expect(HermesVersionCache.key(for: ctx) == "serve|http://127.0.0.1:9119|")
    }

    @Test func serveScopedProfileUpdatesQueryNotHomeNesting() {
        let ctx = ServerContext(
            id: ServerID(),
            displayName: "Serve",
            kind: .serve(HermesServeConfig(baseURL: "http://h:9119"))
        )
        let scoped = ctx.scoped(toProfile: "work")
        #expect(scoped.serveConfig?.profile == "work")
        #expect(scoped.paths.home.contains("profiles/work"))
        let back = scoped.scoped(toProfile: nil)
        #expect(back.serveConfig?.profile == nil)
    }

    @Test func oldIOSServerConfigStillDecodesAsSSH() throws {
        let json = """
        {"host":"box.local","user":"alan","port":22,"displayName":"Home"}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(IOSServerConfig.self, from: json)
        #expect(!cfg.isServe)
        #expect(cfg.host == "box.local")
        let ctx = cfg.toServerContext(id: ServerID())
        if case .ssh(let ssh) = ctx.kind {
            #expect(ssh.host == "box.local")
        } else {
            Issue.record("expected .ssh")
        }
    }

    @Test func serveIOSServerConfigBridgesToServeKind() {
        let cfg = IOSServerConfig(
            host: "192.168.1.10",
            displayName: "Pi",
            serveBaseURL: "http://192.168.1.10:9119",
            serveAuthMode: .basic,
            serveUsername: "alan"
        )
        #expect(cfg.isServe)
        let ctx = cfg.toServerContext(id: ServerID())
        #expect(ctx.isServe)
        #expect(ctx.serveConfig?.baseURL == "http://192.168.1.10:9119")
    }

    @Test func companionSSHDoesNotChangeServeKind() {
        let cfg = IOSServerConfig(
            host: "192.168.1.10",
            displayName: "Pi",
            serveBaseURL: "http://192.168.1.10:9119",
            serveAuthMode: .basic,
            companionHost: "192.168.1.10",
            companionUser: "alan",
            companionPort: 22
        )
        #expect(cfg.isServe)
        #expect(cfg.hasCompanionSSH)
        #expect(cfg.toServerContext(id: ServerID()).isServe)
        let ssh = cfg.toSSHCompanionContext(id: ServerID())
        #expect(ssh?.isServe == false)
        if case .ssh(let c) = ssh?.kind {
            #expect(c.host == "192.168.1.10")
            #expect(c.user == "alan")
            #expect(c.port == 22)
        } else {
            Issue.record("expected companion .ssh")
        }
    }

    @Test func debugRedactorStripsSecretKeysAndClamps() {
        let obj: [String: Any] = [
            "message": "hello",
            "password": "secret",
            "nested": ["token": "abc", "ok": "yes"],
        ]
        let stripped = ScarfGoDebugRedactor.stripSecretKeys(from: obj)
        #expect(stripped["password"] == nil)
        #expect(stripped["message"] as? String == "hello")
        let nested = stripped["nested"] as? [String: Any]
        #expect(nested?["token"] == nil)
        #expect(nested?["ok"] as? String == "yes")
        let long = String(repeating: "x", count: 500)
        #expect(ScarfGoDebugRedactor.redact(message: long).count < 420)
        let hybrid = IOSServerConfig(
            host: "h",
            displayName: "h",
            serveBaseURL: "http://h:9119",
            companionHost: "h"
        )
        #expect(ScarfGoDebugRedactor.connectionLabel(for: hybrid) == "hybrid")
    }

    @Test func validateServeURL() {
        #expect(OnboardingLogic.validateServeURL("http://192.168.1.10:9119").canAdvance)
        #expect(OnboardingLogic.validateServeURL("https://hermes.example.com").canAdvance)
        #expect(!OnboardingLogic.validateServeURL("box.local").canAdvance)
        #expect(!OnboardingLogic.validateServeURL("ftp://x").canAdvance)
        #expect(!OnboardingLogic.validateServeURL("").canAdvance)
    }

    @Test func statusAdvertisesAuthMode() {
        let gated = HermesServeStatus(auth_required: true)
        #expect(gated.advertisedAuthMode == .basic)
        let open = HermesServeStatus(auth_required: false, session_token: "tok")
        #expect(open.advertisedAuthMode == .sessionToken)
        let line = HermesServeStatus(version: "v0.20.4").versionLineForCapabilities
        #expect(line.contains("0.20.4"))
    }

    @Test func passwordLoginProviderPrefersBasic() {
        #expect(HermesServeStatus(auth_required: true).passwordLoginProvider == "basic")
        #expect(HermesServeStatus(auth_providers: ["nous", "basic"]).passwordLoginProvider == "basic")
        #expect(HermesServeStatus(auth_providers: ["ldap"]).passwordLoginProvider == "ldap")
    }

    @Test func httpErrorDoesNotShowResponseBody() {
        let raw = #"{"detail":[{"input":{"password":"secret","username":"admin"}}]}"#
        let shown = HermesServeError.httpStatus(422, raw).errorDescription ?? ""
        #expect(!shown.contains("secret"))
        #expect(!shown.contains("admin"))
        #expect(!shown.contains("password"))
        #expect(!shown.contains("{"))
        #expect(shown.contains("rejected the login"))
    }

    @Test func sessionDTOMapsToHermesSession() {
        let dto = HermesServeSessionDTO(
            id: "s1",
            title: "Hello",
            source: "cli",
            model: "gpt",
            message_count: 3,
            tool_call_count: 1,
            started_at: 1_700_000_000,
            ended_at: nil,
            preview: "hi",
            input_tokens: 10,
            output_tokens: 20,
            estimated_cost_usd: 0.01
        )
        let session = dto.asHermesSession()
        #expect(session.id == "s1")
        #expect(session.title == "Hello")
        #expect(session.messageCount == 3)
        #expect(session.inputTokens == 10)
    }

    @Test func tuiGatewayMapperMessageAndTools() {
        let delta: [String: Any] = [
            "method": "event",
            "params": [
                "type": "message.delta",
                "payload": ["session_id": "abc", "text": "hi"],
            ],
        ]
        let event = TUIGatewayEventMapper.acpEvent(from: delta)
        if case .messageChunk(let sid, let text, _, _) = event {
            #expect(sid == "abc")
            #expect(text == "hi")
        } else {
            Issue.record("expected messageChunk, got \(String(describing: event))")
        }

        let approval: [String: Any] = [
            "method": "event",
            "params": [
                "type": "approval.request",
                "payload": ["session_id": "abc", "request_id": 7, "title": "edit"],
            ],
        ]
        let perm = TUIGatewayEventMapper.acpEvent(from: approval)
        if case .permissionRequest(let sid, let rid, _) = perm {
            #expect(sid == "abc")
            #expect(rid == 7)
        } else {
            Issue.record("expected permissionRequest")
        }
    }

    @Test func serveClientFetchesStatusViaURLProtocol() async throws {
        let session = ServeURLProtocol.makeSession(handler: { request in
            #expect(request.url?.path == "/api/status")
            let body = #"{"version":"v0.20.4","auth_required":false,"session_token":"t"}"#
            return (200, Data(body.utf8))
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119", authMode: .sessionToken),
            session: session
        )
        let status = try await client.probe()
        #expect(status.advertisedAuthMode == .sessionToken)
        #expect(status.session_token == "t")
    }

    @Test func serveClientPasswordLoginSendsProvider() async throws {
        let session = ServeURLProtocol.makeSession(handler: { request in
            if request.url?.path == "/auth/password-login" {
                let body = ServeURLProtocol.bodyString(of: request)
                #expect(body.contains("\"provider\""))
                #expect(body.contains("basic"))
                #expect(body.contains("admin"))
                return (200, Data(#"{"ok":true}"#.utf8))
            }
            if request.url?.path == "/api/auth/me" {
                return (200, Data(#"{"provider":"basic","user_id":"admin"}"#.utf8))
            }
            return (500, Data())
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119"),
            session: session
        )
        try await client.loginBasic(username: "admin", password: "unused-test-secret")
    }

    @Test func serveClientUnauthorizedLogin() async {
        let session = ServeURLProtocol.makeSession(handler: { request in
            if request.url?.path == "/auth/password-login" {
                return (401, Data("nope".utf8))
            }
            return (200, Data("{}".utf8))
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119"),
            session: session
        )
        do {
            try await client.loginBasic(username: "a", password: "b")
            Issue.record("expected unauthorized")
        } catch let error as HermesServeError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func serveClientDecodesWrappedSessions() async throws {
        let session = ServeURLProtocol.makeSession(handler: { request in
            #expect(request.url?.path == "/api/sessions")
            let body = #"{"sessions":[{"id":"s1","title":"T","message_count":2}]}"#
            return (200, Data(body.utf8))
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119"),
            session: session
        )
        let rows = try await client.listSessions()
        #expect(rows.count == 1)
        #expect(rows[0].id == "s1")
        #expect(rows[0].title == "T")
    }

    @Test func serveClientPagesSessionsWithLimitOffsetAndTotal() async throws {
        let session = ServeURLProtocol.makeSession(handler: { request in
            #expect(request.url?.path == "/api/sessions")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.contains(where: { $0.name == "limit" && $0.value == "100" }))
            #expect(items.contains(where: { $0.name == "offset" && $0.value == "100" }))
            #expect(items.contains(where: { $0.name == "order" && $0.value == "recent" }))
            let body = #"{"sessions":[{"id":"s2","title":"Next"}],"total":140,"limit":100,"offset":100}"#
            return (200, Data(body.utf8))
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119"),
            session: session
        )
        let page = try await client.listSessionPage(limit: 100, offset: 100)
        #expect(page.sessions.count == 1)
        #expect(page.sessions[0].id == "s2")
        #expect(page.total == 140)
        #expect(page.hasMore)
    }

    @Test func serveClientFlattensKanbanBoardColumns() async throws {
        let session = ServeURLProtocol.makeSession(handler: { request in
            #expect(request.url?.path == "/api/plugins/kanban/board")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.contains(where: { $0.name == "tenant" && $0.value == "scarf:demo" }))
            let body = """
            {"columns":[
              {"name":"todo","tasks":[
                {"id":"t1","title":"First","status":"todo","priority":40,"skills":null}
              ]},
              {"name":"running","tasks":[
                {"id":"t2","title":"Second","status":"running","assignee":"coder","skills":["debug"]}
              ]}
            ],"tenants":["scarf:demo"],"assignees":["coder"],"latest_event_id":3,"now":1710000000}
            """
            return (200, Data(body.utf8))
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119"),
            session: session
        )
        let tasks = try await client.listKanbanTasks(tenant: "scarf:demo")
        #expect(tasks.count == 2)
        #expect(tasks[0].id == "t1")
        #expect(tasks[0].skills.isEmpty)
        #expect(tasks[1].assignee == "coder")
        #expect(tasks[1].skills == ["debug"])
    }

    @Test func serveClientDecodesKanbanTaskDetailAndStats() async throws {
        let session = ServeURLProtocol.makeSession(handler: { request in
            switch request.url?.path {
            case "/api/plugins/kanban/tasks/t1":
                let body = """
                {"task":{"id":"t1","title":"First","status":"todo","body":"full"},
                 "comments":[{"id":1,"task_id":"t1","author":"alan","body":"hi","created_at":1710000000}],
                 "events":[],"runs":[{"id":9,"task_id":"t1","status":"done","started_at":1710000000}]}
                """
                return (200, Data(body.utf8))
            case "/api/plugins/kanban/stats":
                let body = #"{"by_status":{"todo":2,"running":1},"by_assignee":{"coder":{"todo":1}},"oldest_ready_age_seconds":12}"#
                return (200, Data(body.utf8))
            case "/api/plugins/kanban/assignees":
                let body = #"{"assignees":[{"name":"coder","on_disk":true,"counts":{"todo":1,"running":2}}]}"#
                return (200, Data(body.utf8))
            default:
                return (404, Data())
            }
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119"),
            session: session
        )
        let detail = try await client.kanbanTaskDetail(taskId: "t1")
        #expect(detail.task.title == "First")
        #expect(detail.comments.count == 1)
        let runs = try await client.kanbanTaskRuns(taskId: "t1")
        #expect(runs.count == 1)
        #expect(runs[0].id == 9)
        let stats = try await client.kanbanStats()
        #expect(stats.byStatus["todo"] == 2)
        #expect(stats.oldestReadyAgeSeconds == 12)
        let assignees = try await client.kanbanAssignees()
        #expect(assignees.count == 1)
        #expect(assignees[0].profile == "coder")
        #expect(assignees[0].totalCount == 3)
    }

    @Test func serveClientMapsSkillsAndHubWithoutSSH() async throws {
        let session = ServeURLProtocol.makeSession(handler: { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/skills":
                let body = """
                [{"name":"claude-code","description":"Claude Code workflows","category":"autonomous-ai-agents","enabled":true},
                 {"name":"ascii-art","description":"Draw ASCII","category":"creative","enabled":true}]
                """
                return (200, Data(body.utf8))
            case "/api/skills/content":
                #expect(request.url?.query?.contains("name=claude-code") == true)
                return (200, Data(#"{"name":"claude-code","content":"Use Claude.","path":"/tmp/SKILL.md"}"#.utf8))
            case "/api/skills/hub/sources":
                return (200, Data(#"{"featured":[{"name":"1password","description":"1Password CLI","source":"official","identifier":"official/security/1password"}],"index_available":true}"#.utf8))
            case "/api/skills/hub/search":
                #expect(request.url?.query?.contains("q=honcho") == true)
                return (200, Data(#"{"results":[{"name":"honcho","description":"Memory provider","source":"github","identifier":"honcho"}]}"#.utf8))
            case "/api/skills/hub/install":
                #expect(request.httpMethod == "POST")
                #expect(ServeURLProtocol.bodyString(of: request).contains("honcho"))
                return (200, Data(#"{"ok":true,"pid":12,"name":"install-honcho"}"#.utf8))
            default:
                return (404, Data())
            }
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119"),
            session: session
        )
        let cats = try await client.listSkillCategories()
        let all = cats.flatMap(\.skills)
        #expect(all.count == 2)
        let claude = all.first { $0.name == "claude-code" }
        #expect(claude?.files == ["SKILL.md"])
        #expect(claude?.summary == "Claude Code workflows")
        #expect(claude?.category == "autonomous-ai-agents")
        let content = try await client.fetchSkillContent(name: "claude-code")
        #expect(content.content?.contains("Use Claude") == true)
        let featured = try await client.listSkillHubFeatured()
        #expect(featured.first?.identifier == "official/security/1password")
        let found = try await client.searchSkillHub(query: "honcho")
        #expect(found.first?.name == "honcho")
        try await client.installHubSkill(identifier: "honcho")
    }

    @Test func serveSkillDTODefaultsMissingFilesToSkillMarkdown() {
        let dto = HermesServeSkillDTO(
            name: "codex",
            description: "Codex skill",
            category: "autonomous-ai-agents",
            enabled: true
        )
        let skill = dto.asHermesSkill()
        #expect(skill.files == ["SKILL.md"])
        #expect(skill.summary == "Codex skill")
        #expect(skill.path.isEmpty)
    }

    @Test func serveClientListsWebhooksAndProfiles() async throws {
        let session = ServeURLProtocol.makeSession(handler: { request in
            switch request.url?.path {
            case "/api/webhooks":
                let body = """
                {"enabled":true,"base_url":"http://h:9119",
                 "subscriptions":[{"name":"github","description":"PRs","deliver":"log","events":["push"],"url":"http://h:9119/webhooks/github"}]}
                """
                return (200, Data(body.utf8))
            case "/api/profiles":
                return (200, Data(#"{"profiles":[{"name":"default","is_default":true},{"name":"coder"}]}"#.utf8))
            case "/api/profiles/active":
                return (200, Data(#"{"active":"coder","current":"default"}"#.utf8))
            default:
                return (404, Data())
            }
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119"),
            session: session
        )
        let hooks = try await client.listWebhooks()
        #expect(hooks.enabled == true)
        #expect(hooks.subscriptions?.first?.name == "github")
        let profiles = try await client.listProfiles()
        #expect(profiles.compactMap(\.name) == ["default", "coder"])
        let active = try await client.fetchActiveProfile()
        #expect(active.active == "coder")
    }

    @Test func serveClientCreatesCronJob() async throws {
        let session = ServeURLProtocol.makeSession(handler: { request in
            #expect(request.url?.path == "/api/cron/jobs")
            #expect(request.httpMethod == "POST")
            let body = ServeURLProtocol.bodyString(of: request)
            #expect(body.contains("ScarfGo debug review"))
            #expect(body.contains("local"))
            return (200, Data(#"{"id":"job1","name":"ScarfGo debug review"}"#.utf8))
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119"),
            session: session
        )
        let data = try await client.createCronJob(
            name: "ScarfGo debug review",
            prompt: "summarize",
            schedule: "0 9 * * *",
            deliver: "local"
        )
        #expect(!data.isEmpty)
    }

    @Test func serveClientCreatesWebhook() async throws {
        let session = ServeURLProtocol.makeSession(handler: { request in
            #expect(request.url?.path == "/api/webhooks")
            #expect(request.httpMethod == "POST")
            return (200, Data(#"{"name":"scarfgo-debug","deliver":"log","secret":"abc"}"#.utf8))
        })
        let client = HermesServeClient(
            config: HermesServeConfig(baseURL: "http://example.test:9119"),
            session: session
        )
        let dto = try await client.createWebhook(
            name: "scarfgo-debug",
            script: "~/.hermes/scripts/scarfgo_debug_sink.py",
            deliver: "log",
            secret: "abc"
        )
        #expect(dto.name == "scarfgo-debug")
        #expect(dto.secret == "abc")
    }

    @Test func serveHTTP404CopyIsNotLoginSpecific() {
        #expect(HermesServeError.httpStatus(404, "").errorDescription?.contains("login") != true)
    }

    @Test func hasHermesServeGatesOn018() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)").hasHermesServe)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)").hasHermesServe)
        #expect(!HermesCapabilities.empty.hasHermesServe)
    }

    @Test func parseCreateBindKeepsLiveAndStoredIDs() throws {
        let json = """
        {
          "session_id": "a1b2c3d4",
          "stored_session_id": "hermes-durable-key",
          "message_count": 0,
          "messages": []
        }
        """.data(using: .utf8)!
        let bind = try TUIGatewaySessionParsing.parseBind(from: json, defaultResumed: false)
        #expect(bind.liveSessionID == "a1b2c3d4")
        #expect(bind.storedSessionID == "hermes-durable-key")
        #expect(bind.resumeTargetID == "hermes-durable-key")
        #expect(!bind.resumed)
        #expect(bind.messages.isEmpty)
    }

    @Test func parseResumeBindMapsTranscript() throws {
        let json = """
        {
          "session_id": "live99",
          "session_key": "stored-abc",
          "resumed": "stored-abc",
          "messages": [
            {"role": "user", "text": "hi", "row_id": 10, "timestamp": 1700000000},
            {"role": "assistant", "text": "hello", "row_id": 11, "reasoning": "think"},
            {"role": "system", "text": "ignore me", "display_kind": "hidden"}
          ]
        }
        """.data(using: .utf8)!
        let bind = try TUIGatewaySessionParsing.parseBind(from: json, defaultResumed: true)
        #expect(bind.liveSessionID == "live99")
        #expect(bind.storedSessionID == "stored-abc")
        #expect(bind.resumed)
        #expect(bind.messages.count == 2)
        #expect(bind.messages[0].isUser)
        #expect(bind.messages[0].content == "hi")
        #expect(bind.messages[1].isAssistant)
        #expect(bind.messages[1].reasoning == "think")
    }

#if canImport(SQLite3)
    @Test func applyServeTranscriptReplacesMessages() {
        let ctx = ServerContext(
            id: ServerID(),
            displayName: "t",
            kind: .serve(HermesServeConfig(baseURL: "http://example:9119"))
        )
        let vm = RichChatViewModel(context: ctx)
        let rows = [
            HermesMessage(
                id: 1,
                sessionId: "live",
                role: "user",
                content: "yo",
                toolCallId: nil,
                toolCalls: [],
                toolName: nil,
                timestamp: Date(),
                tokenCount: nil,
                finishReason: nil,
                reasoning: nil
            ),
        ]
        vm.applyServeTranscript(rows, liveSessionID: "live")
        #expect(vm.sessionId == "live")
        #expect(vm.messages.count == 1)
        #expect(vm.messages[0].content == "yo")

        vm.applyServeTranscript(
            [],
            liveSessionID: "live2",
            replaceMessages: false,
            reopenEngagementGate: true
        )
        #expect(vm.sessionId == "live2")
        #expect(vm.messages.count == 1) // preserved
    }
#endif
}

/// URLProtocol stub — no live network.
private final class ServeURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    nonisolated(unsafe) static var handler: Handler?

    static func makeSession(handler: @escaping Handler) -> URLSession {
        Self.handler = handler
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [ServeURLProtocol.self]
        return URLSession(configuration: conf)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func bodyString(of request: URLRequest) -> String {
        if let data = request.httpBody, !data.isEmpty {
            return String(data: data, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    override func startLoading() {
        let (code, data) = Self.handler?(request) ?? (500, Data())
        let url = request.url ?? URL(string: "http://example.test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
