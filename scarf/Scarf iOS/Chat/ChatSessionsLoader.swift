import Foundation
import Observation
import ScarfCore
import ScarfIOS

#if canImport(SQLite3)

/// Shared session-list loader for the Chat tab (idle landing + Sessions
/// sheet). Reuses `IOSDashboardViewModel`'s SSH / Serve load paths so
/// Chat and Dashboard cannot diverge on how pages are fetched.
@Observable
@MainActor
final class ChatSessionsLoader {
    private let dashboard: IOSDashboardViewModel
    private var inFlight: Task<Void, Never>?

    init(context: ServerContext) {
        self.dashboard = IOSDashboardViewModel(context: context)
    }

    var sessions: [HermesSession] { dashboard.allSessions }
    var sessionPreviews: [String: String] { dashboard.sessionPreviews }
    var isLoading: Bool { dashboard.isLoading }
    var lastError: String? { dashboard.lastError }
    var allProjects: [ProjectEntry] { dashboard.allProjects }
    var hasMoreSessions: Bool { dashboard.hasMoreSessions }
    var isLoadingMore: Bool { dashboard.isLoadingMore }

    func projectName(for session: HermesSession) -> String? {
        dashboard.projectName(for: session)
    }

    func sessions(filteredBy projectName: String?) -> [HermesSession] {
        dashboard.sessions(filteredBy: projectName)
    }

    func preview(for session: HermesSession) -> String {
        if let preview = sessionPreviews[session.id], !preview.isEmpty {
            return preview
        }
        return session.displayTitle
    }

    /// Most recent non-cron session when hide-cron is on; else first row.
    func continueTarget(hideCron: Bool) -> HermesSession? {
        let base = hideCron
            ? sessions.filter { $0.source != "cron" }
            : sessions
        return base.first
    }

    /// Coalesce overlapping loads — a second open while the first is
    /// in flight joins the same task (Mac `loadRecentSessions` pattern).
    func load() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in
            await dashboard.load()
        }
        inFlight = task
        await task.value
        if inFlight == task {
            inFlight = nil
        }
    }

    func loadMore() async {
        await dashboard.loadMoreSessions()
    }

    func refresh() async {
        inFlight?.cancel()
        inFlight = nil
        await load()
    }
}

#endif
