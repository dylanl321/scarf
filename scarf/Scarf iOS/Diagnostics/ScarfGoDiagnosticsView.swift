import SwiftUI
import UIKit
import ScarfCore
import ScarfIOS
import ScarfDesign

/// Phone-side debug log (no LLM) plus optional host ingest / review cron.
struct ScarfGoDiagnosticsView: View {
    let config: IOSServerConfig
    let serverID: ServerID

    @State private var events: [ScarfGoDebugEvent] = []
    @State private var enabled = ScarfGoDebug.isEnabled
    @State private var reviewEnabled = false
    @State private var kindFilter: String = "all"
    @State private var status: String?
    @State private var isWorking = false

    var body: some View {
        List {
            Section {
                Toggle("Advanced debugging", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        ScarfGoDebug.isEnabled = on
                        if on {
                            Task { await sendTest(kind: .test, code: "enabled") }
                        }
                    }
                if let post = ScarfGoDebug.lastPostStatus {
                    Text(post)
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                if ScarfGoDebug.usingGatewayLogFallback {
                    Text("Host ingest fell back to gateway.log — later AI review will be weaker.")
                        .font(.caption)
                        .foregroundStyle(ScarfColor.warning)
                }
            } footer: {
                Text("Lands redacted events on this phone. No model is called. You can collect days of crashes with zero token use.")
            }

            Section {
                Button("Send test event") {
                    Task { await sendTest(kind: .test, code: "manual") }
                }
                .disabled(!enabled || isWorking)
                Button("Set up host ingest") {
                    Task { await setupHostIngest() }
                }
                .disabled(!enabled || isWorking)
                Toggle("Review log with AI (daily cron)", isOn: $reviewEnabled)
                    .disabled(!enabled || isWorking)
                    .onChange(of: reviewEnabled) { _, on in
                        guard on else { return }
                        Task { await setupReviewCron() }
                    }
            } header: {
                Text("Host")
            } footer: {
                Text("Host ingest writes ~/.hermes/logs/scarfgo-client.jsonl through a silent webhook. The review cron is optional and is the only LLM step.")
            }

            Section {
                Picker("Kind", selection: $kindFilter) {
                    Text("All").tag("all")
                    Text("Error").tag("error")
                    Text("Hang").tag("hang")
                    Text("Login").tag("login")
                    Text("Chat").tag("chat-fail")
                    Text("Test").tag("test")
                }
                .pickerStyle(.menu)
                let filtered = events.filter { kindFilter == "all" || $0.kind == kindFilter }
                if filtered.isEmpty {
                    Text("No events yet.")
                        .foregroundStyle(ScarfColor.foregroundMuted)
                } else {
                    ForEach(filtered) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.kind)
                                .font(.caption)
                                .foregroundStyle(ScarfColor.accent)
                            Text(event.message)
                                .font(.body)
                            Text("\(event.code) · \(event.ts)")
                                .font(.caption2)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                        }
                    }
                }
            } header: {
                Text("This phone")
            }

            Section {
                Button("Copy log") {
                    let text = events.map { "\($0.ts) \($0.kind) \($0.code) \($0.message)" }.joined(separator: "\n")
                    UIPasteboard.general.string = text
                }
                Button("Delete local log", role: .destructive) {
                    Task {
                        await ScarfGoDebugActor.shared.clear()
                        events = []
                    }
                }
            }

            if let status {
                Section {
                    Text(status)
                        .font(.caption)
                }
            }
            if isWorking {
                Section {
                    ProgressView("Working…")
                }
            }
        }
        .navigationTitle("Advanced debugging")
        .task { await reload() }
    }

    private func reload() async {
        events = await ScarfGoDebugActor.shared.events()
    }

    private func sendTest(kind: ScarfGoDebugKind, code: String) async {
        ScarfGoDebug.record(
            kind: kind,
            code: code,
            message: "ScarfGo test event",
            config: config
        )
        try? await Task.sleep(for: .milliseconds(300))
        await reload()
    }

    private func setupHostIngest() async {
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await ScarfGoDebugHostSetup.installIngest(
                config: config,
                serverID: serverID
            )
        } catch {
            status = error.localizedDescription
        }
    }

    private func setupReviewCron() async {
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await ScarfGoDebugHostSetup.installReviewCron(
                config: config,
                serverID: serverID
            )
        } catch {
            status = error.localizedDescription
            reviewEnabled = false
        }
    }
}

@MainActor
enum ScarfGoDebugHostSetup {
    enum SetupError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    static func installIngest(config: IOSServerConfig, serverID: ServerID) async throws -> String {
        guard config.isServe, let base = config.serveBaseURL else {
            throw SetupError.message("Host ingest needs a Hermes URL connection.")
        }
        let client = try await HermesServeClient.authenticated(
            context: config.toServerContext(id: serverID)
        )
        try? await client.enableWebhooks()
        var hooks = try await client.listWebhooks()
        var usedScript = false
        if let ssh = config.toSSHCompanionContext(id: serverID) {
            usedScript = installSinkOverSSH(context: ssh)
            if usedScript {
                installSkillOverSSH(context: ssh)
            }
        }
        ScarfGoDebug.usingGatewayLogFallback = !usedScript
        let existing = hooks.subscriptions?.contains(where: { $0.name == ScarfGoDebugHostAssets.webhookName }) ?? false
        var secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        if !existing {
            let created = try await client.createWebhook(
                name: ScarfGoDebugHostAssets.webhookName,
                script: usedScript ? "~/.hermes/scripts/scarfgo_debug_sink.py" : nil,
                deliver: "log",
                secret: secret,
                description: "ScarfGo client events (silent JSONL ingest)"
            )
            if let returned = created.secret, !returned.isEmpty {
                secret = returned
            }
        }
        let store = KeychainHermesServeCredentialStore(service: ScarfGoDebug.secretService)
        try await store.save(secret, fingerprint: ScarfGoDebug.secretAccount)
        hooks = (try? await client.listWebhooks()) ?? hooks
        let ingest = ingestURL(from: hooks, serveBaseURL: base)
        ScarfGoDebug.ingestURL = ingest
        ScarfGoDebug.record(kind: .test, code: "host-setup", message: "Host ingest configured", config: config)
        if usedScript {
            return "Host ingest ready. Events append to ~/.hermes/logs/scarfgo-client.jsonl."
        }
        return "Host ingest ready without the sink script, so events land in gateway.log. Later AI review will be weaker."
    }

    static func installReviewCron(config: IOSServerConfig, serverID: ServerID) async throws -> String {
        let ctx = config.toServerContext(id: serverID)
        let vm = IOSCronViewModel(context: ctx)
        await vm.load()
        if vm.jobs.contains(where: { $0.name == ScarfGoDebugHostAssets.cronJobName }) {
            return "Review cron already exists. Pause it from the Cron tab when you do not want a model pass."
        }
        if let ssh = config.toSSHCompanionContext(id: serverID) {
            installSkillOverSSH(context: ssh)
        }
        let job = HermesCronJob(
            id: "scarfgo-debug-review",
            name: ScarfGoDebugHostAssets.cronJobName,
            prompt: ScarfGoDebugHostAssets.reviewPrompt,
            schedule: CronSchedule(
                kind: "cron",
                display: ScarfGoDebugHostAssets.defaultCronSchedule,
                expression: ScarfGoDebugHostAssets.defaultCronSchedule
            ),
            enabled: true,
            state: "scheduled",
            deliver: "local"
        )
        let ok = await vm.upsert(job)
        if !ok {
            throw SetupError.message(vm.lastError ?? "Could not create cron job")
        }
        return "Daily review cron installed. It creates one Dashboard session per run. Pause it from the Cron tab anytime."
    }

    private static func ingestURL(from hooks: HermesServeWebhookListDTO, serveBaseURL: String) -> String {
        if let listed = hooks.subscriptions?.first(where: { $0.name == ScarfGoDebugHostAssets.webhookName })?.url,
           !listed.isEmpty {
            return rewriteWebhookPort(listed)
        }
        if let base = hooks.base_url, let url = URL(string: base) {
            return rewriteWebhookPort(
                url.appendingPathComponent("webhooks/\(ScarfGoDebugHostAssets.webhookName)").absoluteString
            )
        }
        var comps = URLComponents(string: serveBaseURL)
        comps?.port = 8644
        comps?.path = "/webhooks/\(ScarfGoDebugHostAssets.webhookName)"
        return comps?.string ?? "http://127.0.0.1:8644/webhooks/\(ScarfGoDebugHostAssets.webhookName)"
    }

    /// Gateway ingest is `:8644`; dashboard `:9119` is the REST control plane.
    private static func rewriteWebhookPort(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw), comps.port == 9119 else { return raw }
        comps.port = 8644
        return comps.string ?? raw
    }

    private static func installSinkOverSSH(context: ServerContext) -> Bool {
        let transport = context.makeTransport()
        let path = context.paths.home + "/" + ScarfGoDebugHostAssets.sinkRelativePath
        let parent = (path as NSString).deletingLastPathComponent
        do {
            try transport.createDirectory(parent)
            try transport.writeFile(path, data: Data(ScarfGoDebugHostAssets.sinkScript.utf8))
            return true
        } catch {
            return false
        }
    }

    private static func installSkillOverSSH(context: ServerContext) {
        let transport = context.makeTransport()
        let path = context.paths.home + "/" + ScarfGoDebugHostAssets.skillRelativePath
        let parent = (path as NSString).deletingLastPathComponent
        try? transport.createDirectory(parent)
        try? transport.writeFile(path, data: Data(ScarfGoDebugHostAssets.skillMarkdown.utf8))
    }
}
