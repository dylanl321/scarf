import Foundation

/// JSON-RPC client over `hermes serve` `/api/ws` (TUI gateway).
///
/// Wire is newline-delimited JSON, identical to the stdio TUI gateway.
/// Events are mapped onto `ACPEvent` so existing chat VMs can ingest them.
public actor TUIGatewayClient {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var listenTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<ACPEvent>.Continuation?
    public private(set) var events: AsyncStream<ACPEvent>

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
        var continuation: AsyncStream<ACPEvent>.Continuation?
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    public func connect() async throws {
        let ws = session.webSocketTask(with: url)
        task = ws
        ws.resume()
        listenTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    public func close() async {
        listenTask?.cancel()
        listenTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        for (_, cont) in pending {
            cont.resume(throwing: HermesServeError.websocket("closed"))
        }
        pending.removeAll()
        eventContinuation?.yield(.connectionLost(reason: "closed"))
        eventContinuation?.finish()
    }

    public func ping() async throws {
        _ = try await rpc(method: "gateway.ping", params: [:])
    }

    public func createSession() async throws -> String {
        let data = try await rpc(method: "session.create", params: [:])
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let sid = obj["session_id"] as? String { return sid }
            if let sid = obj["id"] as? String { return sid }
            if let result = obj["result"] as? [String: Any] {
                if let sid = result["session_id"] as? String { return sid }
                if let sid = result["id"] as? String { return sid }
            }
        }
        throw HermesServeError.decoding("session.create")
    }

    public func submitPrompt(sessionID: String, text: String) async throws {
        _ = try await rpc(
            method: "prompt.submit",
            params: ["session_id": sessionID, "text": text]
        )
    }

    public func interrupt(sessionID: String) async throws {
        _ = try await rpc(
            method: "session.interrupt",
            params: ["session_id": sessionID]
        )
    }

    public func respondApproval(requestID: Int, optionID: String) async throws {
        _ = try await rpc(
            method: "approval.respond",
            params: ["request_id": requestID, "option_id": optionID]
        )
    }

    // MARK: - Internals

    private func rpc(method: String, params: [String: Any]) async throws -> Data {
        guard let task else { throw HermesServeError.websocket("not connected") }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw HermesServeError.decoding("utf8")
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pending[id] = cont
            task.send(.string(line)) { error in
                if let error {
                    Task { await self.failPending(id: id, error: error) }
                }
            }
        }
    }

    private func failPending(id: Int, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: HermesServeError.websocket(error.localizedDescription))
        }
    }

    private func readLoop() async {
        while let task, !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleLine(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleLine(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                eventContinuation?.yield(.connectionLost(reason: error.localizedDescription))
                for (_, cont) in pending {
                    cont.resume(throwing: HermesServeError.websocket(error.localizedDescription))
                }
                pending.removeAll()
                return
            }
        }
    }

    private func handleLine(_ raw: String) {
        for piece in raw.split(whereSeparator: \.isNewline) {
            let line = piece.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) {
                if let error = obj["error"] as? [String: Any] {
                    let msg = error["message"] as? String ?? "rpc error"
                    cont.resume(throwing: HermesServeError.websocket(msg))
                } else if let result = obj["result"] {
                    let encoded = (try? JSONSerialization.data(withJSONObject: result)) ?? data
                    cont.resume(returning: encoded)
                } else {
                    cont.resume(returning: data)
                }
                continue
            }
            if let event = TUIGatewayEventMapper.acpEvent(from: obj) {
                eventContinuation?.yield(event)
            }
        }
    }
}

public enum TUIGatewayEventMapper {
    static func acpEvent(from obj: [String: Any]) -> ACPEvent? {
        let method = obj["method"] as? String
        let params = obj["params"] as? [String: Any]
        let type = params?["type"] as? String
            ?? (obj["type"] as? String)
        let payload = params?["payload"] as? [String: Any] ?? params ?? [:]
        let sid = (payload["session_id"] as? String)
            ?? (params?["session_id"] as? String)
            ?? ""

        guard method == "event" || type != nil else { return nil }
        switch type {
        case "message.delta":
            let text = (payload["text"] as? String) ?? (payload["delta"] as? String) ?? ""
            return .messageChunk(sessionId: sid, text: text)
        case "reasoning.delta", "thinking.delta":
            let text = (payload["text"] as? String) ?? (payload["delta"] as? String) ?? ""
            return .thoughtChunk(sessionId: sid, text: text)
        case "tool.start":
            let call = ACPToolCallEvent(
                toolCallId: (payload["tool_call_id"] as? String) ?? UUID().uuidString,
                title: (payload["name"] as? String) ?? (payload["title"] as? String) ?? "tool",
                kind: (payload["kind"] as? String) ?? "other",
                status: "pending",
                content: "",
                rawInput: payload["input"] as? [String: Any]
            )
            return .toolCallStart(sessionId: sid, call: call)
        case "tool.progress", "tool.complete":
            let update = ACPToolCallUpdateEvent(
                toolCallId: (payload["tool_call_id"] as? String) ?? "",
                kind: (payload["kind"] as? String) ?? "other",
                status: type == "tool.complete" ? "completed" : "running",
                content: (payload["content"] as? String) ?? (payload["text"] as? String) ?? "",
                rawOutput: payload["output"] as? String
            )
            return .toolCallUpdate(sessionId: sid, update: update)
        case "approval.request":
            let requestID = (payload["request_id"] as? Int)
                ?? (payload["id"] as? Int)
                ?? 0
            let request = ACPPermissionRequestEvent(
                toolCallTitle: (payload["title"] as? String) ?? "Approval",
                toolCallKind: (payload["kind"] as? String) ?? "approval",
                options: [(optionId: "allow", name: "Allow"), (optionId: "deny", name: "Deny")]
            )
            return .permissionRequest(sessionId: sid, requestId: requestID, request: request)
        case "message.complete":
            let result = ACPPromptResult(
                stopReason: "end_turn",
                inputTokens: 0,
                outputTokens: 0,
                thoughtTokens: 0,
                cachedReadTokens: 0
            )
            return .promptComplete(sessionId: sid, response: result)
        case "gateway.ready":
            return .unknown(sessionId: sid, type: "gateway.ready")
        default:
            if let type { return .unknown(sessionId: sid, type: type) }
            return nil
        }
    }
}
