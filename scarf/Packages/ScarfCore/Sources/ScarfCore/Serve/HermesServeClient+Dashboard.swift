import Foundation

extension HermesServeClient {
    // MARK: - Kanban plugin (`/api/plugins/kanban/`)

    public func listKanbanTasks(
        tenant: String? = nil,
        includeArchived: Bool = false,
        board: String? = nil
    ) async throws -> [HermesKanbanTask] {
        let path = kanbanPath(
            "/api/plugins/kanban/board",
            [
                "tenant": tenant,
                "include_archived": includeArchived ? "true" : nil,
                "board": board,
            ]
        )
        let data = try await get(path: path, authenticated: true)
        return try decode(HermesServeKanbanBoardDTO.self, from: data).allTasks()
    }

    public func kanbanTaskDetail(taskId: String, board: String? = nil) async throws -> HermesKanbanTaskDetail {
        let path = kanbanPath(
            "/api/plugins/kanban/tasks/\(encodedPath(taskId))",
            ["board": board]
        )
        let data = try await get(path: path, authenticated: true)
        return try decode(HermesKanbanTaskDetail.self, from: data)
    }

    public func kanbanTaskRuns(taskId: String, board: String? = nil) async throws -> [HermesKanbanRun] {
        let path = kanbanPath(
            "/api/plugins/kanban/tasks/\(encodedPath(taskId))",
            ["board": board]
        )
        let data = try await get(path: path, authenticated: true)
        struct Envelope: Decodable { let runs: [HermesKanbanRun]? }
        if let wrapped = try? decode(Envelope.self, from: data), let runs = wrapped.runs {
            return runs
        }
        return []
    }

    public func kanbanStats(board: String? = nil) async throws -> HermesKanbanStats {
        let path = kanbanPath("/api/plugins/kanban/stats", ["board": board])
        let data = try await get(path: path, authenticated: true)
        return try decode(HermesServeKanbanStatsDTO.self, from: data).asStats()
    }

    public func kanbanAssignees(board: String? = nil) async throws -> [HermesKanbanAssignee] {
        let path = kanbanPath("/api/plugins/kanban/assignees", ["board": board])
        let data = try await get(path: path, authenticated: true)
        struct Envelope: Decodable { let assignees: [HermesServeKanbanAssigneeDTO]? }
        let rows = (try decode(Envelope.self, from: data).assignees) ?? []
        return rows.compactMap { $0.asAssignee() }
    }

    public func kanbanTaskLog(
        taskId: String,
        tailBytes: Int? = nil,
        board: String? = nil
    ) async throws -> String {
        var items: [String: String?] = ["board": board]
        if let tailBytes { items["tail"] = String(tailBytes) }
        let path = kanbanPath(
            "/api/plugins/kanban/tasks/\(encodedPath(taskId))/log",
            items
        )
        do {
            let data = try await get(path: path, authenticated: true)
            return try decode(HermesServeKanbanLogDTO.self, from: data).content ?? ""
        } catch let error as HermesServeError {
            if case .httpStatus(404, _) = error { return "" }
            throw error
        }
    }

    // MARK: - Webhooks / profiles

    public func listWebhooks() async throws -> HermesServeWebhookListDTO {
        let data = try await get(path: "/api/webhooks", authenticated: true)
        return try decode(HermesServeWebhookListDTO.self, from: data)
    }

    public func listProfiles() async throws -> [HermesServeProfileDTO] {
        let data = try await get(path: "/api/profiles", authenticated: true)
        struct Envelope: Decodable { let profiles: [HermesServeProfileDTO]? }
        if let wrapped = try? decode(Envelope.self, from: data), let rows = wrapped.profiles {
            return rows
        }
        return try decode([HermesServeProfileDTO].self, from: data)
    }

    public func fetchActiveProfile() async throws -> HermesServeActiveProfileDTO {
        let data = try await get(path: "/api/profiles/active", authenticated: true)
        return try decode(HermesServeActiveProfileDTO.self, from: data)
    }

    // MARK: - Query helpers

    private func kanbanPath(_ path: String, _ items: [String: String?]) -> String {
        queryPath(path, items)
    }

    private func queryPath(_ path: String, _ items: [String: String?]) -> String {
        var comps = URLComponents()
        comps.path = path
        let queryItems = items.compactMap { key, value -> URLQueryItem? in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        if !queryItems.isEmpty {
            comps.queryItems = queryItems
        }
        return comps.string ?? path
    }

    private func encodedPath(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }
}
