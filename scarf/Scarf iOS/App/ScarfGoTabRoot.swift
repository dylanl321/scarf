import SwiftUI
import ScarfCore
import ScarfIOS
import ScarfDesign

/// ScarfGo's primary navigation surface. v2.5 expands the original
/// 4-tab layout (Chat | Dashboard | Memory | More) to 5 primary tabs
/// with Chat in the mathematical center:
///
///     Dashboard | Projects (or Kanban on Hermes URL) | Chat | Skills | System
///
/// "Chat in the middle" is the v2.5 product ask — chat is the action
/// users come back for, so it's the most thumb-reachable slot on a
/// phone-sized device. We stay on Apple's native `TabView` instead of
/// drawing a custom raised center button: 5 tabs is exactly the iPhone
/// system maximum (no auto-collapse to "More"), and `.sidebarAdaptable`
/// continues to give us a real sidebar on iPad / macCatalyst for free.
/// Memory drops out of primary slots and lives inside the renamed
/// "System" tab (was "More"). Skills graduates from a System sub-row
/// into its own primary tab to match v2.5's full Mac parity for skills
/// (Installed / Browse Hub / Updates).
///
/// Each tab wraps its feature view in its own `NavigationStack` so push
/// navigation (Cron editor, Memory detail, Project detail, etc.) stays
/// scoped to the tab instead of bleeding across.
struct ScarfGoTabRoot: View {
    let serverID: ServerID
    let config: IOSServerConfig
    let key: SSHKeyBundle?
    let onSoftDisconnect: @MainActor @Sendable () async -> Void
    let onForget: @MainActor @Sendable () async -> Void
    let onRefreshConfig: @MainActor @Sendable () async -> Void

    /// Stable per-tab context UUID — used for the System tab's Curator
    /// row so its CuratorViewModel reuses the cached SSH connection
    /// keyed by this id rather than building a fresh one. Same pattern
    /// as `sharedContextID` on ChatView.
    static let systemTabContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A2"
    )!

    /// One coordinator per server-connected session. Cross-tab
    /// signalling (Dashboard row → Chat tab resume, Project Detail
    /// → in-project chat handoff, notification deep-link → Chat) flows
    /// through here. Also owns the selected Hermes profile (#120).
    @State private var coordinator: ScarfGoCoordinator

    /// Hermes version + capability flags for this remote. Drives the
    /// iOS version banner (v0.11 hosts get a yellow "update for new
    /// features" banner) and capability-gated affordances like ACP
    /// image attachments. Constructed once per server connection so
    /// the detection runs over the active SSH transport.
    @State private var capabilities: HermesCapabilitiesStore

    init(
        serverID: ServerID,
        config: IOSServerConfig,
        key: SSHKeyBundle?,
        onSoftDisconnect: @escaping @MainActor @Sendable () async -> Void,
        onForget: @escaping @MainActor @Sendable () async -> Void,
        onRefreshConfig: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.serverID = serverID
        self.config = config
        self.key = key
        self.onSoftDisconnect = onSoftDisconnect
        self.onForget = onForget
        self.onRefreshConfig = onRefreshConfig
        // Capability detection is host-level (Hermes version), so it runs
        // against the base context regardless of the selected profile.
        let ctx = config.toServerContext(id: serverID)
        _capabilities = State(initialValue: HermesCapabilitiesStore(context: ctx))
        // Coordinator owns the per-server profile selection (#120); it
        // loads any persisted choice from the store on construction.
        _coordinator = State(initialValue: ScarfGoCoordinator(serverID: serverID))
    }

    /// `config` with `remoteHome` re-pointed at the selected profile's
    /// directory (#120, Design B). Default selection leaves the base home
    /// untouched. Threaded to every feature view so all direct-file/DB
    /// reads and writes follow the profile through `HermesPathSet` —
    /// without mutating the host's `active_profile`.
    private var effectiveConfig: IOSServerConfig {
        var resolved = config
        if config.isServe {
            resolved.serveProfile = coordinator.selectedProfile
            if config.hasCompanionSSH {
                resolved.remoteHome = HermesProfileScope.resolveHome(
                    baseHome: config.remoteHome ?? HermesPathSet.defaultRemoteHome,
                    profile: coordinator.selectedProfile
                )
            }
            return resolved
        }
        resolved.remoteHome = HermesProfileScope.resolveHome(
            baseHome: config.remoteHome ?? HermesPathSet.defaultRemoteHome,
            profile: coordinator.selectedProfile
        )
        return resolved
    }

    /// SwiftUI's `.onChange(of: ScenePhase)` modifier on a non-active
    /// tab doesn't fire while the tab is unmounted — the coordinator
    /// is the single source of truth for scene-phase transitions
    /// across all tabs.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        profileScopedTabs
            .onAppear {
                // Give the notification router a handle to this session's
                // coordinator so notification-taps can route across tabs.
                // Weak ref — coordinator owns its own lifetime, router
                // just observes.
                NotificationRouter.shared.coordinator = coordinator
            }
            // Funnel scene-phase transitions through the coordinator so
            // tab view-models (notably ChatController) can react even
            // when their tab isn't currently on-screen.
            .onChange(of: scenePhase) { _, newPhase in
                coordinator.setScenePhase(newPhase)
            }
    }

    /// The 5-tab tree, re-identified by the selected profile so a switch
    /// fully rebuilds it (and every feature view-model) against the new
    /// profile's HERMES_HOME (#120) — the scoped, no-relaunch analogue of
    /// the Mac app's switch-and-relaunch. `body` wraps this with
    /// `.onAppear`/`.onChange` from the stable outer position, so those
    /// don't re-fire on a switch.
    private var profileScopedTabs: some View {
        // The transport factory is keyed by ServerID, so the correct
        // Keychain slot + config is picked automatically. Reuses the
        // server's own id as the context id so the CitadelServerTransport
        // pool caches per-server (instead of the singleton we had
        // pre-M9). Two active servers → two connection holders, no
        // SSH channel contention.
        let cfg = effectiveConfig
        let ctx = cfg.toServerContext(id: serverID)
        return TabView(selection: $coordinator.selectedTab) {
            // 1 — Dashboard: stats + recent sessions.
            NavigationStack {
                DashboardView(config: cfg, key: key, onSoftDisconnect: onSoftDisconnect)
            }
            .tabItem {
                Label("Dashboard", systemImage: "gauge.with.needle")
            }
            .tag(ScarfGoCoordinator.Tab.dashboard)
            .accessibilityLabel("Dashboard tab")

            // 2 — Projects: registered projects → per-project dashboard,
            // site, and sessions. Read-only registry on iOS — add /
            // rename / archive happens in the Mac app.
            NavigationStack {
                if cfg.isServe && !cfg.hasCompanionSSH {
                    ScarfGoKanbanView(project: nil, context: ctx)
                        .navigationTitle("Kanban")
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    ProjectsListView(config: cfg.fileAccessConfig())
                }
            }
            .tabItem {
                if cfg.isServe && !cfg.hasCompanionSSH {
                    Label("Kanban", systemImage: "rectangle.split.3x1")
                } else {
                    Label("Projects", systemImage: "square.grid.2x2")
                }
            }
            .tag(ScarfGoCoordinator.Tab.projects)
            .accessibilityLabel(
                (cfg.isServe && !cfg.hasCompanionSSH) ? "Kanban tab" : "Projects tab"
            )

            // 3 — Chat: the reason the app is on your phone. Centered
            // among the 5 tabs for thumb reach + visual prominence.
            NavigationStack {
                ChatTabHost(config: cfg, key: key)
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(ScarfGoCoordinator.Tab.chat)
            .accessibilityLabel("Chat tab")

            // 4 — Skills: Installed | Browse Hub | Updates, mirroring
            // the Mac app's 3-tab skills surface.
            NavigationStack {
                SkillsView(config: cfg)
            }
            .tabItem {
                Label("Skills", systemImage: "lightbulb")
            }
            .tag(ScarfGoCoordinator.Tab.skills)
            .accessibilityLabel("Skills tab")

            // 5 — System: server identity, Memory, Cron, Settings, plus
            // the destructive disconnect / forget actions. Renamed from
            // "More" to match the user-facing v2.5 vocabulary; the
            // .sidebarAdaptable system fallback label happens not to
            // matter here because we never overflow.
            NavigationStack {
                SystemTab(
                    serverID: serverID,
                    config: cfg,
                    onSoftDisconnect: onSoftDisconnect,
                    onForget: onForget,
                    onRefreshConfig: onRefreshConfig
                )
            }
            .tabItem {
                Label("System", systemImage: "gearshape.fill")
            }
            .tag(ScarfGoCoordinator.Tab.system)
            .accessibilityLabel("System tab")
        }
        // Rebuild the whole tab subtree when the selected profile changes
        // so every feature view (and its view-model) reconstructs against
        // the new profile's HERMES_HOME (#120). This is the scoped,
        // no-relaunch analogue of the Mac app's switch-and-relaunch.
        .id(coordinator.selectedProfile ?? HermesProfileScope.defaultProfileName)
        // Pulls the sidebar-on-iPad affordance into the same code path
        // as the bottom-bar-on-iPhone one. No-op on iPhone today.
        .tabViewStyle(.sidebarAdaptable)
        .environment(\.serverContext, ctx)
        .environment(\.scarfGoCoordinator, coordinator)
        .environment(capabilities)
        .hermesCapabilities(capabilities)
    }
}

/// Server identity + Memory + Cron + Settings + destructive actions.
/// "System" reads as configuration / server-meta; the reorganization
/// in v2.5 promotes Skills out of here into its own primary tab and
/// pulls Memory in from a primary tab into a NavigationLink row.
///
/// Kept private to this file because we don't expect it to be reused
/// elsewhere — if a feature graduates to a primary tab, that's a
/// deliberate design decision.
private struct SystemTab: View {
    let serverID: ServerID
    let config: IOSServerConfig
    let onSoftDisconnect: @MainActor @Sendable () async -> Void
    let onForget: @MainActor @Sendable () async -> Void
    let onRefreshConfig: @MainActor @Sendable () async -> Void

    @Environment(\.hermesCapabilities) private var capabilitiesStore

    @State private var showForgetConfirmation = false
    @State private var isForgetting = false
    @State private var isDisconnecting = false
    /// Mirror of `SSHKeyICloudPreference.isEnabled` — drives the iCloud
    /// Keychain sync toggle (issue #52). Initial value is read on view
    /// init so the toggle reflects today's preference before the user
    /// taps anything; flipping triggers `migrateAllItems(toICloudSync:)`.
    @State private var iCloudSyncEnabled: Bool = SSHKeyICloudPreference.isEnabled
    @State private var iCloudMigrationInFlight = false
    @State private var iCloudMigrationError: String?
    @State private var showCompanionSSH = false

    init(
        serverID: ServerID,
        config: IOSServerConfig,
        onSoftDisconnect: @escaping @MainActor @Sendable () async -> Void,
        onForget: @escaping @MainActor @Sendable () async -> Void,
        onRefreshConfig: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.serverID = serverID
        self.config = config
        self.onSoftDisconnect = onSoftDisconnect
        self.onForget = onForget
        self.onRefreshConfig = onRefreshConfig
    }

    var body: some View {
        List {
            Section("Server") {
                if config.isServe, let url = config.serveBaseURL {
                    LabeledContent("Hermes URL", value: url)
                        .listRowBackground(ScarfColor.backgroundSecondary)
                    LabeledContent("Connection", value: config.hasCompanionSSH ? "Hermes URL + SSH" : "Hermes URL")
                        .listRowBackground(ScarfColor.backgroundSecondary)
                    if config.hasCompanionSSH, let host = config.companionHost {
                        LabeledContent("SSH host", value: host)
                            .listRowBackground(ScarfColor.backgroundSecondary)
                    }
                } else {
                    LabeledContent("Host", value: config.host)
                        .listRowBackground(ScarfColor.backgroundSecondary)
                }
                if let user = config.user {
                    LabeledContent("User", value: user)
                        .listRowBackground(ScarfColor.backgroundSecondary)
                }
                if let port = config.port {
                    LabeledContent("Port", value: String(port))
                        .listRowBackground(ScarfColor.backgroundSecondary)
                }
            }

            Section("Features") {
                if config.isServe && !config.hasCompanionSSH {
                    Label("MEMORY.md files need SSH", systemImage: "brain.head.profile")
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .scarfGoCompactListRow()
                        .listRowBackground(ScarfColor.backgroundSecondary)
                    Button {
                        showCompanionSSH = true
                    } label: {
                        Label("Add SSH for files", systemImage: "key.fill")
                    }
                    .scarfGoCompactListRow()
                    .listRowBackground(ScarfColor.backgroundSecondary)
                } else {
                    NavigationLink {
                        MemoryListView(config: config.fileAccessConfig())
                    } label: {
                        Label("Memory", systemImage: "brain.head.profile")
                    }
                    .scarfGoCompactListRow()
                    .listRowBackground(ScarfColor.backgroundSecondary)
                }
                if (!config.isServe || config.hasCompanionSSH),
                   capabilitiesStore?.capabilities.hasCurator ?? false {
                    NavigationLink {
                        CuratorView(context: config.fileAccessConfig().toServerContext(id: ScarfGoTabRoot.systemTabContextID))
                    } label: {
                        Label("Curator", systemImage: "sparkles")
                    }
                    .scarfGoCompactListRow()
                    .listRowBackground(ScarfColor.backgroundSecondary)
                }
                NavigationLink {
                    CronListView(config: config)
                } label: {
                    Label("Cron jobs", systemImage: "clock.arrow.circlepath")
                }
                .scarfGoCompactListRow()
                .listRowBackground(ScarfColor.backgroundSecondary)
                NavigationLink {
                    SettingsView(config: config)
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .scarfGoCompactListRow()
                .listRowBackground(ScarfColor.backgroundSecondary)
            }

            // Read-only inspect lists. Hermes URL uses dashboard REST for
            // webhooks + profiles; plugin directory listing is still SSH.
            Section("Inspect") {
                NavigationLink {
                    WebhooksView(config: config)
                } label: {
                    Label("Webhooks", systemImage: "arrow.up.right.square")
                }
                .scarfGoCompactListRow()
                .listRowBackground(ScarfColor.backgroundSecondary)
                if config.isServe && !config.hasCompanionSSH {
                    Label("Plugin directory listing needs SSH", systemImage: "app.badge.checkmark")
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .scarfGoCompactListRow()
                        .listRowBackground(ScarfColor.backgroundSecondary)
                } else {
                    NavigationLink {
                        PluginsView(config: config.fileAccessConfig())
                    } label: {
                        Label("Plugins", systemImage: "app.badge.checkmark")
                    }
                    .scarfGoCompactListRow()
                    .listRowBackground(ScarfColor.backgroundSecondary)
                }
                NavigationLink {
                    ProfilesView(config: config)
                } label: {
                    Label("Profiles", systemImage: "person.2.crop.square.stack")
                }
                .scarfGoCompactListRow()
                .listRowBackground(ScarfColor.backgroundSecondary)
            }

            Section {
                Toggle(isOn: $iCloudSyncEnabled) {
                    HStack(spacing: 10) {
                        Image(systemName: "key.icloud.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync login with iCloud Keychain")
                            Text(iCloudSyncEnabled
                                 ? "Synced — uninstalling and reinstalling on this Apple ID restores hosts and login."
                                 : "This device only — reinstalling wipes hosts and passwords.")
                                .font(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                        }
                    }
                }
                .tint(ScarfColor.accent)
                .disabled(iCloudMigrationInFlight)
                .onChange(of: iCloudSyncEnabled) { _, newValue in
                    Task {
                        iCloudMigrationInFlight = true
                        iCloudMigrationError = nil
                        defer { iCloudMigrationInFlight = false }
                        do {
                            try await KeychainSSHKeyStore().migrateAllItems(toICloudSync: newValue)
                            try await KeychainHermesServeCredentialStore().migrateAllItems(toICloudSync: newValue)
                            let all = try await UserDefaultsIOSServerConfigStore().listAll()
                            try KeychainIOSServerConfigMirror().saveAll(all)
                        } catch {
                            iCloudMigrationError = error.localizedDescription
                            iCloudSyncEnabled = !newValue
                            SSHKeyICloudPreference.isEnabled = !newValue
                        }
                    }
                }
                if iCloudMigrationInFlight {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating Keychain…")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                }
                if let err = iCloudMigrationError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(ScarfColor.warning)
                }
            } header: {
                Text("Security")
            } footer: {
                Text("End-to-end encrypted via iCloud Keychain. Passwords never go in UserDefaults. With Advanced Data Protection on, encryption keys never leave your devices. Toggle off to keep secrets device-only.")
                    .font(.caption)
            }
            .listRowBackground(ScarfColor.backgroundSecondary)

            Section {
                Button {
                    Task {
                        isDisconnecting = true
                        await onSoftDisconnect()
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isDisconnecting {
                            ProgressView()
                        } else {
                            Text("Disconnect")
                        }
                        Spacer()
                    }
                }
                .disabled(isDisconnecting || isForgetting)
                .listRowBackground(ScarfColor.backgroundSecondary)
            } footer: {
                Text("Closes the live connection. Your key and host details stay on this device; tapping the server from the list reconnects with no re-onboarding.")
                    .font(.caption)
            }

            Section {
                Button(role: .destructive) {
                    showForgetConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        if isForgetting {
                            ProgressView()
                        } else {
                            Text("Forget this server")
                        }
                        Spacer()
                    }
                }
                .disabled(isForgetting || isDisconnecting)
                .listRowBackground(ScarfColor.backgroundSecondary)
            } footer: {
                Text("Removes this server's SSH key and host info from the device. You'll need to add the public key back to `~/.ssh/authorized_keys` to reconnect.")
                    .font(.caption)
            }
        }
        .scarfGoListDensity()
        .scrollContentBackground(.hidden)
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("System")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCompanionSSH) {
            OnboardingRootView(
                targetServerID: serverID,
                canCancel: true,
                attachCompanionTo: config,
                onFinished: {
                    showCompanionSSH = false
                    await onRefreshConfig()
                },
                onCancel: {
                    showCompanionSSH = false
                }
            )
        }
        .confirmationDialog(
            "Forget this server?",
            isPresented: $showForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget \(config.displayName)", role: .destructive) {
                Task {
                    isForgetting = true
                    await onForget()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(config.isServe
                 ? "Host details for \(config.displayName) will be removed. Other servers stay configured. This cannot be undone."
                 : "Your SSH key and host settings for \(config.displayName) will be removed. Other servers stay configured. This cannot be undone.")
        }
    }
}
