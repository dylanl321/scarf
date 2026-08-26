import SwiftUI
import ScarfCore
import ScarfIOS
import ScarfDesign

#if canImport(SQLite3)

/// Phone-sized Sessions browser for the Chat tab — Mac
/// `ChatSessionListPane` adapted as a sheet (search, project filter,
/// hide-cron, active-row highlight). No rename/delete menus this pass.
struct ChatSessionsSheet: View {
    @Bindable var loader: ChatSessionsLoader
    let activeSessionID: String?
    let isAgentWorking: Bool
    let onSelect: (HermesSession) -> Void
    let onNew: () -> Void
    let onDismiss: () -> Void

    @State private var searchText: String = ""
    /// nil = all projects; "" = unattributed; else match project name.
    @State private var projectFilter: String?
    @AppStorage("scarf.chat.hideCronSessions") private var hideCronSessions: Bool = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterRow
                searchField
                sessionsList
            }
            .background(ScarfColor.backgroundPrimary.ignoresSafeArea())
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onNew()
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .task {
                await loader.load()
            }
        }
    }

    private var filterRow: some View {
        HStack(spacing: ScarfSpace.s2) {
            projectFilterMenu
            Spacer(minLength: 0)
            Button {
                hideCronSessions.toggle()
            } label: {
                Label(
                    hideCronSessions ? "Cron hidden" : "Cron shown",
                    systemImage: hideCronSessions ? "clock.badge.xmark" : "clock"
                )
                .font(.caption)
                .foregroundStyle(
                    hideCronSessions ? ScarfColor.accent : ScarfColor.foregroundMuted
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, ScarfSpace.s2)
    }

    private var projectFilterMenu: some View {
        Menu {
            Button("All projects") { projectFilter = nil }
            Button("Unattributed") { projectFilter = "" }
            if !loader.allProjects.isEmpty {
                Divider()
                ForEach(loader.allProjects) { project in
                    Button(project.name) { projectFilter = project.name }
                }
            }
        } label: {
            Label(projectFilterLabel, systemImage: "folder")
                .font(.caption)
                .foregroundStyle(
                    projectFilter != nil ? ScarfColor.accent : ScarfColor.foregroundMuted
                )
        }
    }

    private var projectFilterLabel: String {
        switch projectFilter {
        case .none: return "All projects"
        case .some(let s) where s.isEmpty: return "Unattributed"
        case .some(let s): return s
        }
    }

    private var searchField: some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ScarfColor.foregroundMuted)
            TextField("Search sessions", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
        .background(ScarfColor.backgroundSecondary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.bottom, ScarfSpace.s2)
    }

    private var sessionsList: some View {
        List {
            if let err = loader.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .listRowBackground(Color.clear)
            }
            if loader.isLoading, visibleSessions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if visibleSessions.isEmpty {
                Text("No sessions yet")
                    .font(.body)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(visibleSessions) { session in
                    Button {
                        onSelect(session)
                    } label: {
                        ChatSessionListRow(
                            session: session,
                            preview: loader.preview(for: session),
                            projectName: loader.projectName(for: session),
                            isActive: session.id == activeSessionID,
                            isLive: session.id == activeSessionID && isAgentWorking
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        session.id == activeSessionID
                            ? ScarfColor.accentTint
                            : ScarfColor.backgroundPrimary
                    )
                }
                if loader.hasMoreSessions {
                    Button {
                        Task { await loader.loadMore() }
                    } label: {
                        if loader.isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Load more")
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(ScarfColor.accent)
                        }
                    }
                    .disabled(loader.isLoadingMore)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await loader.refresh()
        }
    }

    private var visibleSessions: [HermesSession] {
        var base: [HermesSession]
        switch projectFilter {
        case .none:
            base = loader.sessions
        case .some(let name) where name.isEmpty:
            base = loader.sessions.filter { loader.projectName(for: $0) == nil }
        case .some(let name):
            base = loader.sessions(filteredBy: name)
        }
        if hideCronSessions {
            base = base.filter { $0.source != "cron" }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { session in
            session.displayTitle.lowercased().contains(q)
                || loader.preview(for: session).lowercased().contains(q)
                || (loader.projectName(for: session)?.lowercased().contains(q) ?? false)
        }
    }
}

/// Shared session row for the Sessions sheet and Chat idle landing.
struct ChatSessionListRow: View {
    let session: HermesSession
    let preview: String
    let projectName: String?
    let isActive: Bool
    var isLive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isActive {
                    Circle()
                        .fill(isLive ? ScarfColor.accent : ScarfColor.accent.opacity(0.5))
                        .frame(width: 8, height: 8)
                }
                Text(preview)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .lineLimit(2)
                    .foregroundStyle(
                        isActive ? ScarfColor.accent : ScarfColor.foregroundPrimary
                    )
            }
            HStack(spacing: 12) {
                Label(session.source, systemImage: session.sourceIcon)
                    .font(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                if let started = session.startedAt {
                    Text(started, format: .relative(presentation: .numeric))
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
            if let projectName {
                Label(projectName, systemImage: "folder.fill")
                    .font(.caption2)
                    .foregroundStyle(ScarfColor.accent)
                    .labelStyle(.titleAndIcon)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(ScarfColor.accentTint, in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Compact idle landing: Continue + New + recent rows, with "See all".
struct ChatIdleLanding: View {
    @Bindable var loader: ChatSessionsLoader
    let onContinue: (HermesSession) -> Void
    let onNew: () -> Void
    let onSeeAll: () -> Void
    let onSelect: (HermesSession) -> Void

    @AppStorage("scarf.chat.hideCronSessions") private var hideCronSessions: Bool = true

    private var recent: [HermesSession] {
        let base = hideCronSessions
            ? loader.sessions.filter { $0.source != "cron" }
            : loader.sessions
        return Array(base.prefix(QueryDefaults.dashboardOverviewCount))
    }

    private var continueSession: HermesSession? {
        loader.continueTarget(hideCron: hideCronSessions)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s5) {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    Text("Chat")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    Text("Continue a recent session or start a new one.")
                        .font(.body)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                .padding(.top, ScarfSpace.s4)

                VStack(spacing: ScarfSpace.s3) {
                    if let continueSession {
                        Button {
                            onContinue(continueSession)
                        } label: {
                            Text("Continue")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, ScarfSpace.s3)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ScarfColor.accent)
                    }

                    Button {
                        onNew()
                    } label: {
                        Text("New chat")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, ScarfSpace.s3)
                    }
                    .buttonStyle(.bordered)
                }

                if loader.isLoading, recent.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, ScarfSpace.s6)
                } else if let err = loader.lastError, recent.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                } else if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                        HStack {
                            Text("Recent")
                                .font(.headline)
                                .foregroundStyle(ScarfColor.foregroundPrimary)
                            Spacer()
                            Button("See all") { onSeeAll() }
                                .font(.subheadline)
                                .foregroundStyle(ScarfColor.accent)
                        }
                        ForEach(recent) { session in
                            Button {
                                onSelect(session)
                            } label: {
                                ChatSessionListRow(
                                    session: session,
                                    preview: loader.preview(for: session),
                                    projectName: loader.projectName(for: session),
                                    isActive: false
                                )
                                .padding(.vertical, ScarfSpace.s2)
                            }
                            .buttonStyle(.plain)
                            if session.id != recent.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, ScarfSpace.s4)
            .padding(.bottom, ScarfSpace.s6)
        }
        .refreshable {
            await loader.refresh()
        }
        .task {
            await loader.load()
        }
    }
}

#endif
