import CryptoKit
import Foundation
import ScarfCore

/// Local JSONL + optional HMAC post to the Hermes webhook gateway.
/// Never calls a model.
enum ScarfGoDebug {
    static let enabledKey = "scarf.debug.advancedEnabled"
    static let ingestURLKey = "scarf.debug.ingestURL"
    static let lastPostKey = "scarf.debug.lastPostStatus"
    static let usingGatewayLogKey = "scarf.debug.usingGatewayLogFallback"
    static let secretService = "com.scarf.debug-webhook"
    static let secretAccount = "scarfgo-debug"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var ingestURL: String? {
        get { UserDefaults.standard.string(forKey: ingestURLKey) }
        set { UserDefaults.standard.set(newValue, forKey: ingestURLKey) }
    }

    static var lastPostStatus: String? {
        get { UserDefaults.standard.string(forKey: lastPostKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastPostKey) }
    }

    static var usingGatewayLogFallback: Bool {
        get { UserDefaults.standard.bool(forKey: usingGatewayLogKey) }
        set { UserDefaults.standard.set(newValue, forKey: usingGatewayLogKey) }
    }

    static func record(
        kind: ScarfGoDebugKind,
        code: String,
        message: String,
        config: IOSServerConfig?
    ) {
        Task {
            await ScarfGoDebugActor.shared.record(
                kind: kind,
                code: code,
                message: message,
                config: config
            )
        }
    }

    static func hmacSHA256Hex(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

actor ScarfGoDebugActor {
    static let shared = ScarfGoDebugActor()

    private var lastSent: [String: Date] = [:]
    private let maxEvents = 500
    private let maxBytes = 256 * 1024

    func record(
        kind: ScarfGoDebugKind,
        code: String,
        message: String,
        config: IOSServerConfig?
    ) async {
        guard ScarfGoDebug.isEnabled else { return }
        let coalesceKey = "\(kind.rawValue)|\(code)"
        if let previous = lastSent[coalesceKey], Date().timeIntervalSince(previous) < 60 {
            return
        }
        lastSent[coalesceKey] = Date()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var fingerprint: String?
        if let config, config.isServe, let url = config.serveBaseURL {
            fingerprint = HermesServeConfig(
                baseURL: url,
                profile: config.serveProfile,
                authMode: config.serveAuthMode ?? .basic,
                username: config.serveUsername
            ).fingerprint
        }
        let event = ScarfGoDebugEvent(
            ts: iso.string(from: Date()),
            app: "\(version) (\(build))",
            kind: kind.rawValue,
            code: code,
            message: ScarfGoDebugRedactor.redact(message: message),
            connection: config.map { ScarfGoDebugRedactor.connectionLabel(for: $0) } ?? "unknown",
            serverFingerprint: fingerprint
        )
        appendLocal(event)
        await postToHost(event)
    }

    func events() -> [ScarfGoDebugEvent] {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(ScarfGoDebugEvent.self, from: Data(line.utf8))
        }.reversed()
    }

    func clear() {
        try? FileManager.default.removeItem(at: logURL)
    }

    private var logURL: URL {
        MetricKitSubscriber.diagnosticsDirectory.appendingPathComponent("client-events.jsonl")
    }

    private func appendLocal(_ event: ScarfGoDebugEvent) {
        let dir = MetricKitSubscriber.diagnosticsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let line = try? JSONEncoder().encode(event),
              var text = String(data: line, encoding: .utf8)
        else { return }
        text += "\n"
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: logURL, options: .atomic)
        }
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        let url = logURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int ?? 0
        let lineCount: Int = {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else { return 0 }
            return text.split(whereSeparator: \.isNewline).count
        }()
        if size > maxBytes || lineCount > maxEvents {
            let rotated = url.deletingLastPathComponent().appendingPathComponent("client-events.jsonl.1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
    }

    private func postToHost(_ event: ScarfGoDebugEvent) async {
        guard let urlString = ScarfGoDebug.ingestURL,
              let url = URL(string: urlString),
              let body = try? JSONEncoder().encode(event)
        else { return }
        let store = KeychainHermesServeCredentialStore(service: ScarfGoDebug.secretService)
        let secret = try? await store.load(fingerprint: ScarfGoDebug.secretAccount)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret, !secret.isEmpty {
            request.setValue(secret, forHTTPHeaderField: "X-Hermes-Token")
            let signature = ScarfGoDebug.hmacSHA256Hex(body: body, secret: secret)
            request.setValue("sha256=\(signature)", forHTTPHeaderField: "X-Hub-Signature-256")
            request.setValue(signature, forHTTPHeaderField: "X-Hermes-Signature")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            ScarfGoDebug.lastPostStatus = (200...299).contains(code) ? "Host OK (\(code))" : "Host HTTP \(code)"
        } catch {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                ScarfGoDebug.lastPostStatus = (200...299).contains(code) ? "Host OK after retry" : "Host HTTP \(code)"
            } catch {
                ScarfGoDebug.lastPostStatus = "Local only (host post failed)"
            }
        }
    }
}
