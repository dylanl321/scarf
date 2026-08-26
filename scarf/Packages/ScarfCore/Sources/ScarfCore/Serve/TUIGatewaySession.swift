import Foundation

/// Result of `session.create` / `session.resume` on the Hermes TUI gateway.
///
/// Hermes distinguishes a short-lived **runtime** id (`session_id`, used for
/// `prompt.submit` while the WS session is live) from a durable **stored**
/// id (`stored_session_id` / `session_key`, used to reattach after the
/// WebSocket drops). Clients must keep both: prompts need the live id,
/// reconnect/resume need the stored id.
public struct TUIGatewaySessionBind: Sendable, Equatable {
    /// Live runtime id for in-process gateway RPCs (`prompt.submit`, etc.).
    public var liveSessionID: String
    /// Durable id for `session.resume` after disconnect. Empty when Hermes
    /// omitted it (older servers); callers should fall back to `liveSessionID`.
    public var storedSessionID: String
    /// Display transcript from the RPC payload (may be empty for brand-new
    /// sessions or when Hermes deferred history).
    public var messages: [HermesMessage]
    /// True when this bind came from `session.resume` (vs `session.create`).
    public var resumed: Bool

    public init(
        liveSessionID: String,
        storedSessionID: String,
        messages: [HermesMessage] = [],
        resumed: Bool = false
    ) {
        self.liveSessionID = liveSessionID
        self.storedSessionID = storedSessionID
        self.messages = messages
        self.resumed = resumed
    }

    /// Id to pass to a later `session.resume`. Prefer the durable key.
    public var resumeTargetID: String {
        storedSessionID.isEmpty ? liveSessionID : storedSessionID
    }
}

/// Pure parsers for TUI-gateway session RPC payloads. Kept free of the
/// WebSocket actor so unit tests can cover the wire contract without a socket.
public enum TUIGatewaySessionParsing {
    /// Decode `session.create` / `session.resume` result JSON.
    public static func parseBind(
        from data: Data,
        sessionIDFallback: String? = nil,
        defaultResumed: Bool = false
    ) throws -> TUIGatewaySessionBind {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let obj = flattenResult(root) else {
            throw HermesServeError.decoding("session bind: not an object")
        }
        let live = stringValue(obj["session_id"])
            ?? stringValue(obj["id"])
            ?? sessionIDFallback
        guard let live, !live.isEmpty else {
            throw HermesServeError.decoding("session bind: missing session_id")
        }
        let stored = stringValue(obj["stored_session_id"])
            ?? stringValue(obj["session_key"])
            ?? ""
        let resumedFlag: Bool
        if obj["resumed"] != nil {
            resumedFlag = true
        } else {
            resumedFlag = defaultResumed
        }
        let rawMessages = obj["messages"] as? [Any] ?? []
        let messages = mapHistory(rawMessages, sessionID: live)
        return TUIGatewaySessionBind(
            liveSessionID: live,
            storedSessionID: stored,
            messages: messages,
            resumed: resumedFlag
        )
    }

    /// Map Hermes `_history_to_messages` projection rows onto `HermesMessage`.
    public static func mapHistory(
        _ raw: [Any],
        sessionID: String
    ) -> [HermesMessage] {
        var out: [HermesMessage] = []
        out.reserveCapacity(raw.count)
        var nextID = 1
        for item in raw {
            guard let row = item as? [String: Any] else { continue }
            let role = stringValue(row["role"]) ?? ""
            guard role == "user" || role == "assistant" || role == "tool" || role == "system" else {
                continue
            }
            if stringValue(row["display_kind"]) == "hidden" { continue }

            let text = stringValue(row["text"])
                ?? stringValue(row["content"])
                ?? ""
            let reasoning = stringValue(row["reasoning"])
            let reasoningContent = stringValue(row["reasoning_content"])
            let hasReasoning = !(reasoning ?? "").isEmpty || !(reasoningContent ?? "").isEmpty
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               role != "tool",
               !hasReasoning {
                continue
            }

            let rowID = intValue(row["row_id"]) ?? nextID
            nextID = max(nextID, rowID + 1)

            var toolCalls: [HermesToolCall] = []
            if role == "tool" {
                let name = stringValue(row["name"]) ?? "tool"
                // Tool rows in the display projection are flattened; surface
                // them as tool-result bubbles via role=tool + toolName.
                out.append(
                    HermesMessage(
                        id: rowID,
                        sessionId: sessionID,
                        role: "tool",
                        content: stringValue(row["context"]) ?? text,
                        toolCallId: nil,
                        toolCalls: [],
                        toolName: name,
                        timestamp: dateValue(row["timestamp"]),
                        tokenCount: nil,
                        finishReason: nil,
                        reasoning: nil,
                        reasoningContent: nil
                    )
                )
                continue
            }

            if let calls = row["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let fn = call["function"] as? [String: Any] ?? [:]
                    let callId = stringValue(call["id"]) ?? UUID().uuidString
                    let name = stringValue(fn["name"]) ?? "tool"
                    let arguments: String
                    if let rawArgs = fn["arguments"] as? String {
                        arguments = rawArgs
                    } else if let obj = fn["arguments"],
                              let data = try? JSONSerialization.data(withJSONObject: obj),
                              let s = String(data: data, encoding: .utf8) {
                        arguments = s
                    } else {
                        arguments = "{}"
                    }
                    toolCalls.append(
                        HermesToolCall(callId: callId, functionName: name, arguments: arguments)
                    )
                }
            }

            out.append(
                HermesMessage(
                    id: rowID,
                    sessionId: sessionID,
                    role: role,
                    content: text,
                    toolCallId: nil,
                    toolCalls: toolCalls,
                    toolName: nil,
                    timestamp: dateValue(row["timestamp"]),
                    tokenCount: nil,
                    finishReason: nil,
                    reasoning: reasoning,
                    reasoningContent: reasoningContent,
                    reasoningContentAvailable: !(reasoningContent ?? "").isEmpty
                )
            )
        }
        return out.sorted(by: HermesMessage.chronologicalOrder)
    }

    // MARK: - Helpers

    private static func flattenResult(_ root: Any) -> [String: Any]? {
        guard let obj = root as? [String: Any] else { return nil }
        if let result = obj["result"] as? [String: Any] {
            return result
        }
        return obj
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let i = Int(s) { return i }
        return nil
    }

    private static func dateValue(_ any: Any?) -> Date? {
        if let d = any as? Double, d > 0 {
            return Date(timeIntervalSince1970: d)
        }
        if let n = any as? NSNumber {
            let d = n.doubleValue
            return d > 0 ? Date(timeIntervalSince1970: d) : nil
        }
        return nil
    }
}
