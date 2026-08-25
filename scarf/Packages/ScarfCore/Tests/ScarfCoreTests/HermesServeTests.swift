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

    @Test func hasHermesServeGatesOn018() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.18.0 (2026.7.1)").hasHermesServe)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)").hasHermesServe)
        #expect(!HermesCapabilities.empty.hasHermesServe)
    }
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
