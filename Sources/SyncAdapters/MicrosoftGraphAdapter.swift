import Foundation
import SyncDomain
import SyncContracts

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Microsoft To Do / Graph adapter. Graph delta links are opaque URLs; the cursor
/// stores one list delta link plus one task delta link per known list.
public struct MicrosoftGraphAdapter: ExternalSyncAdapter, FieldDiagnosticsProviding {
    public let account: SyncAccount
    public let capabilities: Set<AdapterCapability> = [
        .lists, .taskNotes, .dueDates, .priorities, .incrementalPull,
        .conditionalWrites, .remoteDeletion, .providerRevision, .fieldDiagnostics
    ]
    public let fieldCapabilities: AdapterFieldCapabilities = AdapterFieldCapabilities(
        fields: [
            .listTitle: .native, .listColor: .unsupported, .listPosition: .unsupported,
            .taskTitle: .native, .taskNotes: .transformed, .taskList: .native,
            .taskCompletion: .native, .taskDueDate: .transformed, .taskCompletedAt: .transformed,
            .taskPriority: .transformed, .taskPosition: .unsupported
        ]
    )

    private let baseURL: URL
    private let transport: any HTTPTransport
    private let accessToken: @Sendable () async throws -> String
    private let now: @Sendable () -> Date

    public init(
        account: SyncAccount,
        baseURL: URL = URL(string: "https://graph.microsoft.com/v1.0")!,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        accessToken: @escaping @Sendable () async throws -> String
    ) {
        self.account = account
        self.baseURL = baseURL
        self.transport = transport
        self.now = now
        self.accessToken = accessToken
    }

    public func pullChanges(since cursor: String?) async throws -> RemoteChanges {
        try validateBaseURL()
        let state = try decodeCursor(cursor)
        var listDeltaLink: String
        if let rawListDeltaLink = state?.listDeltaLink {
            listDeltaLink = try validatedDeltaURL(rawListDeltaLink, context: "Microsoft Graph list delta").absoluteString
        } else {
            listDeltaLink = relativeURL("me/todo/lists/delta")
        }
        var taskLinks: [String: String] = [:]
        for link in state?.taskDeltaLinks ?? [] {
            taskLinks[link.listID] = try validatedDeltaURL(link.deltaLink, context: "Microsoft Graph task delta").absoluteString
        }
        let token = try await accessToken()
        var lists: [RemoteList] = []
        var tasks: [RemoteTask] = []
        var diagnostics: [FieldLossDiagnostic] = []
        var activeListIDs = Set(taskLinks.keys)
        var pageCount = 0

        while true {
            pageCount += 1
            guard pageCount <= 10_000 else { throw SyncAdapterError.invalidResponse("Microsoft Graph delta pagination exceeded 10000 pages.") }
            let listURL = try validatedDeltaURL(listDeltaLink, context: "Microsoft Graph list delta")
            let page: GraphListPage = try await get(url: listURL, token: token)
            for item in page.value {
                guard let id = item.id else { continue }
                let list = RemoteList(
                    remoteID: id,
                    name: item.displayName ?? "",
                    isDeleted: item.removed != nil,
                    updatedAt: nil,
                    revision: item.etag
                )
                lists.append(list)
                diagnostics.append(contentsOf: ProviderFieldDiagnostics.forMicrosoft(list: list))
                if list.isDeleted {
                    activeListIDs.remove(id)
                    taskLinks.removeValue(forKey: id)
                } else {
                    activeListIDs.insert(id)
                    if taskLinks[id] == nil { taskLinks[id] = relativeURL("me/todo/lists/\(id)/tasks/delta") }
                }
            }
            if let nextLink = page.nextLink {
                listDeltaLink = try validatedDeltaURL(nextLink, context: "Microsoft Graph list pagination").absoluteString
                continue
            }
            if let deltaLink = page.deltaLink {
                listDeltaLink = try validatedDeltaURL(deltaLink, context: "Microsoft Graph list delta").absoluteString
            }
            break
        }

        // Fetch every known list's task delta. Graph only emits a list delta when the
        // list itself changed, so skipping unchanged lists would lose task edits.
        for listID in activeListIDs.sorted() {
            guard let link = taskLinks[listID] else { continue }
            var taskLink = link
            var pageCount = 0
            while true {
                pageCount += 1
                guard pageCount <= 10_000 else { throw SyncAdapterError.invalidResponse("Microsoft Graph task delta pagination exceeded 10000 pages.") }
                let taskURL = try validatedDeltaURL(taskLink, context: "Microsoft Graph task delta")
                let page: GraphTaskPage = try await get(url: taskURL, token: token)
                for item in page.value {
                    guard let id = item.id else { continue }
                    let task = ProviderMutationSupport.remoteTask(
                        id: id,
                        title: item.title ?? "",
                        notes: item.body?.content,
                        listID: listID,
                        completed: item.status == "completed",
                        dueDate: item.dueDateTime.flatMap { ProviderDateCodec.parse($0.dateTime) },
                        completedAt: item.completedDateTime.flatMap { ProviderDateCodec.parse($0.dateTime) },
                        priority: item.importance.flatMap(Self.priority(from:)) ?? .none,
                        deleted: item.removed != nil,
                        updatedAt: nil,
                        revision: item.etag
                    )
                    tasks.append(task)
                    diagnostics.append(contentsOf: ProviderFieldDiagnostics.forMicrosoft(task: task))
                    if item.body?.contentType?.lowercased() == "html" {
                        diagnostics.append(FieldLossDiagnostic.providerField(
                            .taskNotes,
                            resourceType: "task",
                            resourceID: id,
                            message: "Microsoft Graph returned HTML notes; canonical notes preserve text but not rich formatting.",
                            transformed: true,
                            targetProvider: .microsoftGraph
                        ))
                    }
                }
                if let nextLink = page.nextLink {
                    taskLink = try validatedDeltaURL(nextLink, context: "Microsoft Graph task pagination").absoluteString
                    continue
                }
                if let deltaLink = page.deltaLink {
                    taskLinks[listID] = try validatedDeltaURL(deltaLink, context: "Microsoft Graph task delta").absoluteString
                }
                break
            }
        }

        let encodedCursor = try encodeCursor(GraphCursor(
            listDeltaLink: listDeltaLink,
            taskDeltaLinks: taskLinks.keys.sorted().compactMap { key in taskLinks[key].map { GraphTaskDeltaLink(listID: key, deltaLink: $0) } }
        ))
        return RemoteChanges(
            changes: lists.map(RemoteChange.list) + tasks.map(RemoteChange.task),
            nextCursor: encodedCursor,
            serverNow: now(),
            isFullSnapshot: cursor == nil,
            diagnostics: diagnostics
        )
    }

    public func push(_ mutations: [RemoteMutation], cursor: String?) async throws -> PushResult {
        try validateBaseURL()
        let token = try await accessToken()
        var accepted = 0
        var rejected: [RejectedMutation] = []
        var mappings: [RemoteIDMapping] = []
        var diagnostics: [FieldLossDiagnostic] = []

        for mutation in mutations {
            do {
                switch mutation {
                case .upsertList(let canonicalID, let list):
                    let result = try await upsertList(list, token: token)
                    accepted += 1
                    mappings.append(RemoteIDMapping(canonicalListID: canonicalID, remoteID: result.id ?? list.remoteID, revision: result.etag ?? list.revision))
                    diagnostics.append(contentsOf: ProviderFieldDiagnostics.forMicrosoft(list: list))
                case .deleteList(_, let remoteID, let revision):
                    try await delete(path: "me/todo/lists/\(remoteID)", token: token, revision: revision)
                    accepted += 1
                case .upsertTask(let canonicalID, let task):
                    guard let listID = task.remoteListID, !listID.isEmpty else {
                        throw SyncAdapterError.unsupported("A Microsoft task must be mapped to a remote list.")
                    }
                    let result = try await upsertTask(task, listID: listID, token: token)
                    accepted += 1
                    mappings.append(RemoteIDMapping(canonicalTaskID: canonicalID, remoteID: result.id ?? task.remoteID, revision: result.etag ?? task.revision))
                    diagnostics.append(contentsOf: ProviderFieldDiagnostics.forMicrosoft(task: task))
                    if task.notes != nil {
                        diagnostics.append(FieldLossDiagnostic.providerField(.taskNotes, resourceType: "task", resourceID: task.remoteID, message: "Microsoft Graph notes use provider text/HTML semantics; exact rich text is not preserved.", transformed: true, targetProvider: .microsoftGraph))
                    }
                    if task.dueDate != nil || task.completedAt != nil {
                        diagnostics.append(FieldLossDiagnostic.providerField(.taskDueDate, resourceType: "task", resourceID: task.remoteID, message: "Microsoft Graph stores date-time values with provider timezone semantics.", transformed: true, targetProvider: .microsoftGraph))
                    }
                case .deleteTask(_, let remoteID, let remoteListID, let revision):
                    guard let remoteListID, !remoteListID.isEmpty else {
                        throw SyncAdapterError.unsupported("Deleting a Microsoft task requires its mapped list.")
                    }
                    try await delete(path: "me/todo/lists/\(remoteListID)/tasks/\(remoteID)", token: token, revision: revision)
                    accepted += 1
                }
            } catch {
                rejected.append(RejectedMutation(mutation: mutation, reason: error.localizedDescription, retryable: Self.isRetryable(error)))
            }
        }
        return PushResult(accepted: accepted, rejected: rejected, mappings: mappings, nextCursor: cursor, serverNow: now(), diagnostics: diagnostics)
    }

    private func upsertList(_ list: RemoteList, token: String) async throws -> GraphList {
        let body = try JSONEncoder().encode(GraphListWrite(displayName: list.name))
        let path = list.remoteID.isEmpty ? "me/todo/lists" : "me/todo/lists/\(list.remoteID)"
        if list.remoteID.isEmpty { return try await post(path: path, body: body, token: token) }
        return try await patch(path: path, body: body, token: token, revision: list.revision)
    }

    private func upsertTask(_ task: RemoteTask, listID: String, token: String) async throws -> GraphTask {
        let payload = GraphTaskWrite(
            title: task.title,
            body: task.notes.map { GraphBody(content: $0, contentType: "text") },
            status: task.isCompleted ? "completed" : "notStarted",
            importance: Self.importance(for: task.priority),
            dueDateTime: task.dueDate.map { GraphDateTime(dateTime: Self.graphDate($0), timeZone: "UTC") }
        )
        let body = try JSONEncoder().encode(payload)
        let path = task.remoteID.isEmpty ? "me/todo/lists/\(listID)/tasks" : "me/todo/lists/\(listID)/tasks/\(task.remoteID)"
        if task.remoteID.isEmpty { return try await post(path: path, body: body, token: token) }
        return try await patch(path: path, body: body, token: token, revision: task.revision)
    }

    private func get<T: Decodable>(url: URL, token: String) async throws -> T {
        try ProviderRequestSupport.validateProviderURL(url, baseURL: baseURL, context: "Microsoft Graph pagination")
        let request = HTTPRequestBuilder.make(url: url, method: "GET", bearerToken: token)
        return try HTTPRequestBuilder.decodeOrThrow(T.self, from: try await transport.execute(request))
    }

    private func post<T: Decodable>(path: String, body: Data, token: String) async throws -> T {
        let request = try HTTPRequestBuilder.make(baseURL: baseURL, path: path, method: "POST", bearerToken: token, body: body)
        return try HTTPRequestBuilder.decodeOrThrow(T.self, from: try await transport.execute(request))
    }

    private func patch<T: Decodable>(path: String, body: Data, token: String, revision: String?) async throws -> T {
        let request = try HTTPRequestBuilder.make(baseURL: baseURL, path: path, method: "PATCH", bearerToken: token, body: body, headers: revision.map { ["If-Match": $0] } ?? [:])
        return try HTTPRequestBuilder.decodeOrThrow(T.self, from: try await transport.execute(request))
    }

    private func delete(path: String, token: String, revision: String?) async throws {
        let request = try HTTPRequestBuilder.make(baseURL: baseURL, path: path, method: "DELETE", bearerToken: token, headers: revision.map { ["If-Match": $0] } ?? [:])
        try HTTPRequestBuilder.checkSuccess(try await transport.execute(request))
    }

    private func validateBaseURL() throws {
        try ProviderRequestSupport.validateHTTPSBaseURL(baseURL)
    }

    private func validatedDeltaURL(_ raw: String, context: String) throws -> URL {
        try ProviderRequestSupport.validatedProviderURL(raw, baseURL: baseURL, context: context)
    }

    private func relativeURL(_ path: String) -> String {
        baseURL.appendingPathComponent(path).absoluteString
    }

    private func encodeCursor(_ cursor: GraphCursor) throws -> String {
        let data = try JSONEncoder().encode(cursor)
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func decodeCursor(_ raw: String?) throws -> GraphCursor? {
        guard let raw else { return nil }
        var value = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { throw SyncAdapterError.invalidResponse("The Microsoft Graph cursor is invalid.") }
        do { return try JSONDecoder().decode(GraphCursor.self, from: data) } catch { throw SyncAdapterError.invalidResponse("The Microsoft Graph cursor is invalid.") }
    }

    private static func graphDate(_ date: Date) -> String { date.formatted(.iso8601) }

    private static func priority(from value: String) -> TaskPriority? {
        switch value.lowercased() {
        case "low": return .low
        case "normal": return .medium
        case "high": return .high
        default: return nil
        }
    }

    private static func importance(for priority: TaskPriority) -> String {
        switch priority { case .low: return "low"; case .none, .medium: return "normal"; case .high, .urgent: return "high" }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case SyncAdapterError.rateLimited = error { return true }
        if case SyncAdapterError.transport = error { return true }
        return false
    }
}

private struct GraphCursor: Codable, Hashable, Sendable {
    let listDeltaLink: String
    let taskDeltaLinks: [GraphTaskDeltaLink]
}
private struct GraphTaskDeltaLink: Codable, Hashable, Sendable { let listID: String; let deltaLink: String }
private struct GraphListPage: Codable {
    let value: [GraphList]
    let nextLink: String?
    let deltaLink: String?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink"; case deltaLink = "@odata.deltaLink" }
}
private struct GraphTaskPage: Codable {
    let value: [GraphTask]
    let nextLink: String?
    let deltaLink: String?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink"; case deltaLink = "@odata.deltaLink" }
}
private struct GraphRemoved: Codable { let reason: String? }
private struct GraphList: Codable { let id: String?; let displayName: String?; let etag: String?; let removed: GraphRemoved?; enum CodingKeys: String, CodingKey { case id; case displayName; case etag = "@odata.etag"; case removed = "@removed" } }
private struct GraphListWrite: Codable { let displayName: String }
private struct GraphTask: Codable {
    let id: String?
    let title: String?
    let body: GraphBody?
    let status: String?
    let importance: String?
    let dueDateTime: GraphDateTime?
    let completedDateTime: GraphDateTime?
    let etag: String?
    let removed: GraphRemoved?
    enum CodingKeys: String, CodingKey { case id; case title; case body; case status; case importance; case dueDateTime; case completedDateTime; case etag = "@odata.etag"; case removed = "@removed" }
}
private struct GraphTaskWrite: Codable { let title: String; let body: GraphBody?; let status: String; let importance: String; let dueDateTime: GraphDateTime? }
private struct GraphBody: Codable { let content: String; let contentType: String? }
private struct GraphDateTime: Codable { let dateTime: String; let timeZone: String }
