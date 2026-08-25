// iOS-specific Dashboard state. Uses `HermesDataService` directly via
// a Citadel-backed `ServerTransport` — no Mac-only `HermesFileService`
// dependency, so the Dashboard shows session + token stats only, not
// the config.yaml / gateway-state / pgrep checks the Mac dashboard
// surfaces. Those come in a later phase once `HermesFileService` is
// either moved to ScarfCore or replicated in an iOS-compatible form.
#if canImport(SQLite3)

import Foundation
import Observation
import ScarfCore

/// iOS Dashboard view-state. Loaded on view appear; refreshes on
/// pull-to-refresh. The VM owns a `HermesDataService` instance which
/// (via the transport factory wired in `ScarfIOSApp.init`) routes all
/// DB reads through Citadel SFTP + SSH exec.
@Observable
@MainActor
public final class IOSDashboardViewModel {
    public let context: ServerContext
    private let dataService: HermesDataService

    public init(context: ServerContext) {
        self.context = context
        self.dataService = HermesDataService(context: context)
    }

    // MARK: - Published state

    public var stats: HermesDataService.SessionStats = .empty
    /// Recent sessions for the Overview sub-tab (glance-only surface).
    public var recentSessions: [HermesSession] = []
    /// Session list for the Sessions sub-tab. First page is
    /// `QueryDefaults.dashboardSessionPageSize`; "Load more" appends.
    public var allSessions: [HermesSession] = []
    public var sessionPreviews: [String: String] = [:]
    public var isLoading: Bool = true
    public var isLoadingMore: Bool = false
    /// Total listable sessions reported by the host (serve envelope or
    /// SQLite COUNT with the same list predicate).
    public var totalSessionCount: Int = 0
    public var hasMoreSessions: Bool {
        allSessions.count < totalSessionCount
    }

    /// session-id → project display name, for sessions attributed to
    /// a registered Scarf project. Populated in `load()` by a single
    /// SFTP read of `session_project_map.json` + the project registry;
    /// subsequent row renders are O(1) dict lookups. Empty when no
    /// sessions on screen are attributed.
    public private(set) var sessionProjectNames: [String: String] = [:]

    /// Every configured project, for the filter picker in the
    /// Sessions sub-tab. Populated alongside `sessionProjectNames`.
    public private(set) var allProjects: [ProjectEntry] = []

    /// Surfaced when the SQLite snapshot or DB open fails. Shown in a
    /// yellow banner above the stats with a "Retry" button. `nil` means
    /// the last load was healthy.
    public var lastError: String?

    // MARK: - Loading

    /// Refresh the dashboard. Does a `dataService.refresh()` (close +
    /// reopen, forces a fresh Citadel snapshot on iOS) then reads the
    /// visible bits.
    public func load() async {
        isLoading = true
        lastError = nil

        if context.isServe {
            await loadFromServe()
            return
        }

        let opened = await dataService.refresh()
        if !opened {
            lastError = await dataService.lastOpenError
                ?? "Couldn't read the Hermes database — check that the server is reachable and that `~/.hermes/state.db` exists."
            isLoading = false
            return
        }

        await ScarfMon.measureAsync(.sessionLoad, "ios.loadDashboard") {
            stats = await dataService.fetchStats()
            totalSessionCount = await dataService.fetchSessionListTotal()
            allSessions = await dataService.fetchSessions(
                limit: QueryDefaults.dashboardSessionPageSize,
                offset: 0
            )
            recentSessions = Array(allSessions.prefix(QueryDefaults.dashboardOverviewCount))
            sessionPreviews = await dataService.fetchSessionPreviews(
                limit: QueryDefaults.dashboardSessionPageSize
            )
        }
        ScarfMon.event(.sessionLoad, "ios.allSessions.count", count: allSessions.count)

        // Attribution lookup (pass-2 UX): load the session→project
        // sidecar + project registry once so Dashboard rows can show
        // which project each session belongs to. Batched (not per-row)
        // so we don't pay a SFTP round-trip for every Recent Sessions
        // cell. Failure is silent — the absence of project labels is
        // a cosmetic degradation, not a data-loss problem.
        let ctx = context
        let bundle: (names: [String: String], projects: [ProjectEntry]) = await Task.detached {
            let attribution = SessionAttributionService(context: ctx)
            let projectRegistry = ProjectDashboardService(context: ctx).loadRegistry()
            let pathToName = Dictionary(
                uniqueKeysWithValues: projectRegistry.projects.map { ($0.path, $0.name) }
            )
            let map = attribution.load().mappings
            var result: [String: String] = [:]
            for (sessionID, path) in map {
                if let name = pathToName[path] {
                    result[sessionID] = name
                }
            }
            return (names: result, projects: projectRegistry.projects)
        }.value
        sessionProjectNames = bundle.names
        allProjects = bundle.projects

        await dataService.close()
        isLoading = false
    }

    private func loadFromServe() async {
        guard let cfg = context.serveConfig else {
            lastError = HermesServeError.notAServeContext.errorDescription
            isLoading = false
            return
        }
        do {
            let client = HermesServeClient(config: cfg)
            try await client.authenticate(serverID: context.id, username: cfg.username)
            let page = try await client.listSessionPage(
                limit: QueryDefaults.dashboardSessionPageSize,
                offset: 0
            )
            allSessions = page.sessions
            recentSessions = Array(page.sessions.prefix(QueryDefaults.dashboardOverviewCount))
            totalSessionCount = page.total
            var previews: [String: String] = [:]
            for session in page.sessions {
                if let preview = session.lastActivityDescription {
                    previews[session.id] = preview
                }
            }
            sessionPreviews = previews
            stats = HermesDataService.SessionStats(
                totalSessions: page.total,
                totalMessages: page.sessions.reduce(0) { $0 + $1.messageCount },
                totalToolCalls: page.sessions.reduce(0) { $0 + $1.toolCallCount },
                totalInputTokens: page.sessions.reduce(0) { $0 + $1.inputTokens },
                totalOutputTokens: page.sessions.reduce(0) { $0 + $1.outputTokens },
                totalCostUSD: page.sessions.reduce(0) { $0 + ($1.estimatedCostUSD ?? 0) },
                totalReasoningTokens: page.sessions.reduce(0) { $0 + $1.reasoningTokens },
                totalActualCostUSD: page.sessions.reduce(0) { $0 + ($1.actualCostUSD ?? 0) }
            )
            sessionProjectNames = [:]
            allProjects = []
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    /// Sessions matching the given project filter. `nil` returns
    /// every loaded session (no filtering). `projectName` is the
    /// ProjectEntry.name that's the key in `sessionProjectNames`.
    public func sessions(filteredBy projectName: String?) -> [HermesSession] {
        guard let projectName, !projectName.isEmpty else { return allSessions }
        return allSessions.filter { session in
            sessionProjectNames[session.id] == projectName
        }
    }

    /// Helper used by DashboardView rows. Returns the project display
    /// name a session is attributed to, or nil for unattributed
    /// sessions (CLI-started, or started before v2.3).
    public func projectName(for session: HermesSession) -> String? {
        sessionProjectNames[session.id]
    }

    /// Called from the pull-to-refresh gesture.
    public func refresh() async {
        ScarfMon.event(.sessionLoad, "ios.dashboardRefresh.trigger", count: 1)
        await load()
    }

    /// Next page for the Sessions tab. No-op when already loading or
    /// when the host says there is nothing left.
    public func loadMoreSessions() async {
        guard hasMoreSessions, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let offset = allSessions.count
        if context.isServe {
            await loadMoreFromServe(offset: offset)
            return
        }
        let opened = await dataService.refresh()
        guard opened else { return }
        let page = await dataService.fetchSessions(
            limit: QueryDefaults.dashboardSessionPageSize,
            offset: offset
        )
        let extraPreviews = await dataService.fetchSessionPreviews(
            limit: offset + page.count
        )
        await dataService.close()
        appendSessions(page)
        for (id, preview) in extraPreviews where sessionPreviews[id] == nil {
            sessionPreviews[id] = preview
        }
    }

    private func loadMoreFromServe(offset: Int) async {
        guard let cfg = context.serveConfig else { return }
        do {
            let client = HermesServeClient(config: cfg)
            try await client.authenticate(serverID: context.id, username: cfg.username)
            let page = try await client.listSessionPage(
                limit: QueryDefaults.dashboardSessionPageSize,
                offset: offset
            )
            totalSessionCount = page.total
            appendSessions(page.sessions)
            for session in page.sessions {
                if let preview = session.lastActivityDescription, sessionPreviews[session.id] == nil {
                    sessionPreviews[session.id] = preview
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func appendSessions(_ page: [HermesSession]) {
        let seen = Set(allSessions.map(\.id))
        let fresh = page.filter { !seen.contains($0.id) }
        allSessions.append(contentsOf: fresh)
        ScarfMon.event(.sessionLoad, "ios.allSessions.count", count: allSessions.count)
    }
}

#endif // canImport(SQLite3)
